#!/bin/bash
# Arm 4, and the one that actually maps onto the real job. Arms 2-3 reversed the
# FILE order, but within each file both clients still read ascending from 0, so
# their byte ranges aligned by construction -- the near-miss sub-case of upstream's
# hypothesis (2) was never truly exercised.
#
# GCHP's pFIO gives each rank its OWN subdomain, so two nodes request DISJOINT,
# INTERLEAVED byte ranges of the same object. That is the shape to test: client A
# takes the even 8 MiB blocks, client B the odd ones. Union = the whole file
# exactly once. If the gateway fetches ~1x, block alignment and cross-connection
# dedup are both clean under disjoint interleave. If it fetches ~2x, each client's
# block fill is pulling its neighbour's blocks too -- which would be the real
# mechanism behind the 1.57x residual, and fixable.
set -u -o pipefail
GATES=/scratch/lith-gates
LITH=$GATES/lith-1.1.2
PFX=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
IDX=$GATES/idx/merra2-201907.lithidx
PORT=20490; MET=9320; A=/mnt/gwA; B=/mnt/gwB; P=${P:-8}; DAY=${DAY:-20190701}
BLK=$((8*1024*1024))
OUT=$GATES/coalesce-probe.txt
exec > >(tee -a "$OUT") 2>&1
echo; echo "### coalesce interleave arm $(date -u +%FT%TZ)  8 MiB even/odd split"
cleanup(){ sudo umount -f $A 2>/dev/null; sudo umount -f $B 2>/dev/null; pkill -f "[l]ith-1.1.2 serve" 2>/dev/null; sleep 2; }
trap cleanup EXIT
cleanup; sudo mkdir -p $A $B
start_gw(){ pkill -f "[l]ith-1.1.2 serve" 2>/dev/null; sleep 2
  setsid nohup $LITH serve nfs "$PFX" --index-file "$IDX" --no-sign-request \
    --mem-cache 8GB --nic-gbps 7.5 --listen :${PORT} --metrics :${MET} \
    > $GATES/coalesce-gw.log 2>&1 < /dev/null &
  for i in $(seq 20); do ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN && break; sleep 1; done
  ss -ltn "sport = :${PORT}" | grep -q LISTEN || { echo "  GATEWAY FAILED"; exit 1; }; }
mnt(){ sudo mount -t nfs -o "vers=3,proto=tcp,port=${PORT},mountport=${PORT},nolock,ro,nosharecache" localhost:/ "$1"; }
m(){ curl -s --max-time 5 http://localhost:${MET}/metrics | awk -v k="$1" 'index($0,k)==1 {print $NF; exit}'; }

start_gw; mnt $A >/dev/null
: > /tmp/il.A; : > /tmp/il.B
NB=0
for f in $(find $A -type f -name "*${DAY}*" | sort); do
  sz=$(stat -c %s "$f"); NB=$((NB+sz)); n=$(( (sz + BLK - 1) / BLK ))
  for i in $(seq 0 $((n-1))); do
    if [ $((i % 2)) -eq 0 ]; then echo "$f $i" >> /tmp/il.A
    else echo "${f/#$A/$B} $i" >> /tmp/il.B; fi
  done
done
echo "  set: $(awk -v b=$NB 'BEGIN{printf "%.2f", b/2^30}') GiB  blocks A=$(wc -l < /tmp/il.A) B=$(wc -l < /tmp/il.B) (disjoint, union = whole set once)"
sudo umount -f $A 2>/dev/null

readblocks(){ xargs -P "$P" -a "$1" -L1 sh -c 'dd if="$0" bs=8M skip="$1" count=1 of=/dev/null 2>/dev/null'; }

start_gw; mnt $A >/dev/null; mnt $B >/dev/null
sudo sysctl -q vm.drop_caches=3
b0=$(m lith_s3_bytes_total); g0=$(m 'lith_s3_requests_total{op="get",status="ok"}')
t0=$(date +%s.%N); readblocks /tmp/il.A & pa=$!; readblocks /tmp/il.B & pb=$!; wait $pa $pb; t1=$(date +%s.%N)
b1=$(m lith_s3_bytes_total); g1=$(m 'lith_s3_requests_total{op="get",status="ok"}')
d=$(awk -v a="${b0:-0}" -v b="${b1:-0}" 'BEGIN{print b-a}')
printf 'IL-two-DISJOINT-8MiB   wall=%6.2fs  s3_MB=%9.1f  gets=%6s  ampl=%.3fx  prefetch_used=%s uncovered=%s\n' \
  "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "$(awk -v x=$d 'BEGIN{print x/1e6}')" \
  "$(awk -v a=${g0:-0} -v b=${g1:-0} 'BEGIN{print b-a}')" "$(awk -v x=$d -v n=$NB 'BEGIN{print x/n}')" \
  "$(m lith_prefetch_used_total)" "$(m lith_prefetch_uncovered_total)"
