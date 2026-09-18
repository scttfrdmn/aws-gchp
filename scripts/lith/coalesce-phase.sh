#!/bin/bash
# Arm 3 of the lith#244 coalescing question. Arm 2 showed two clients reading an
# IDENTICAL list in lockstep dedupe perfectly (1.000x) -- which confirms upstream's
# "the block store already single-flights across connections" and kills the
# same-range form of their hypothesis (2).
#
# But lockstep is the easy case: identical requests collide inside the in-flight
# window by construction. The sub-case they named -- "8 MiB block vs 1 MiB chunk
# near-miss overlaps outside the single-flight key" -- needs the two clients OUT OF
# PHASE, so their ranges interleave without aligning in time.
#
# The working set must FIT the block cache or capacity eviction confounds phase:
# with a 97 GiB set against 8 GB of cache, reverse order refetches everything for
# reasons that have nothing to do with coalescing. So this arm scopes to ONE DAY
# (~6 GiB vs --mem-cache 8GB), which also mirrors the real job's condition
# (~3.3 GB set, --mem-cache 32GB, where upstream ruled cache pressure out).
set -u -o pipefail
GATES=/scratch/lith-gates
LITH=$GATES/lith-1.1.2
PFX=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
IDX=$GATES/idx/merra2-201907.lithidx
PORT=20490; MET=9320
A=/mnt/gwA; B=/mnt/gwB
P=${P:-8}
DAY=${DAY:-20190701}
OUT=$GATES/coalesce-probe.txt
exec > >(tee -a "$OUT") 2>&1
echo; echo "### coalesce phase arm $(date -u +%FT%TZ)  day=${DAY}  P=${P}/client"

cleanup(){ sudo umount -f $A 2>/dev/null; sudo umount -f $B 2>/dev/null; pkill -f "[l]ith-1.1.2 serve" 2>/dev/null; sleep 2; }
trap cleanup EXIT
cleanup; sudo mkdir -p $A $B
start_gw(){ pkill -f "[l]ith-1.1.2 serve" 2>/dev/null; sleep 2
  setsid nohup $LITH serve nfs "$PFX" --index-file "$IDX" --no-sign-request \
    --mem-cache 8GB --nic-gbps 7.5 --listen :${PORT} --metrics :${MET} \
    > $GATES/coalesce-gw.log 2>&1 < /dev/null &
  for i in $(seq 20); do ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN && break; sleep 1; done
  ss -ltn "sport = :${PORT}" | grep -q LISTEN || { echo "  GATEWAY FAILED"; exit 1; }; echo "  gateway up"; }
mnt(){ sudo mount -t nfs -o "vers=3,proto=tcp,port=${PORT},mountport=${PORT},nolock,ro,nosharecache" localhost:/ "$1"; }
m(){ curl -s --max-time 5 http://localhost:${MET}/metrics | awk -v k="$1" 'index($0,k)==1 {print $NF; exit}'; }
readall(){ xargs -P "$P" -a "$1" -I{} sh -c 'dd if="{}" bs=4M of=/dev/null 2>/dev/null'; }

run(){ # $1 label, $2 listA, $3 listB(optional)
  start_gw; mnt $A >/dev/null || exit 1; [ -n "${3:-}" ] && { mnt $B >/dev/null || exit 1; }
  sudo sysctl -q vm.drop_caches=3
  local b0 b1 g0 g1 t0 t1 pa pb
  b0=$(m lith_s3_bytes_total); g0=$(m 'lith_s3_requests_total{op="get",status="ok"}')
  t0=$(date +%s.%N)
  readall "$2" & pa=$!
  if [ -n "${3:-}" ]; then readall "$3" & pb=$!; wait $pa $pb; else wait $pa; fi
  t1=$(date +%s.%N)
  b1=$(m lith_s3_bytes_total); g1=$(m 'lith_s3_requests_total{op="get",status="ok"}')
  local d; d=$(awk -v a="${b0:-0}" -v b="${b1:-0}" 'BEGIN{print b-a}')
  printf '%-22s wall=%6.2fs  s3_MB=%9.1f  gets=%6s  ampl=%.3fx  prefetch_used=%s uncovered=%s evict_unread=%s\n' \
    "$1" "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "$(awk -v x=$d 'BEGIN{print x/1e6}')" \
    "$(awk -v a=${g0:-0} -v b=${g1:-0} 'BEGIN{print b-a}')" \
    "$(awk -v x=$d -v n=$NB 'BEGIN{print x/n}')" \
    "$(m lith_prefetch_used_total)" "$(m lith_prefetch_uncovered_total)" "$(m lith_prefetch_evicted_unread_total)"
  sudo umount -f $A 2>/dev/null; sudo umount -f $B 2>/dev/null
}

start_gw; mnt $A >/dev/null
find $A -type f -name "*${DAY}*" | sort > /tmp/ph.A
NB=$(du -bc $(cat /tmp/ph.A) 2>/dev/null | tail -1 | cut -f1)
tac /tmp/ph.A | sed "s|^$A|$B|" > /tmp/ph.Brev          # OUT OF PHASE: reverse order
sed "s|^$A|$B|" /tmp/ph.A > /tmp/ph.Bfwd                # in phase, as a control
echo "  day set: $(wc -l < /tmp/ph.A) files, $(awk -v b=$NB 'BEGIN{printf "%.2f", b/2^30}') GiB vs --mem-cache 8GB (fits)"
sudo umount -f $A 2>/dev/null

run "PH-one-client"        /tmp/ph.A
run "PH-two-in-phase"      /tmp/ph.A /tmp/ph.Bfwd
run "PH-two-REVERSED"      /tmp/ph.A /tmp/ph.Brev
