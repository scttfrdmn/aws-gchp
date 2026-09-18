#!/bin/bash
# lith#244 follow-up: distinguish the two hypotheses offered upstream for the
# gateway fetching 1.57x what a single node fetches alone.
#
#   (1) 96 ranks genuinely touch a larger distinct set than 48 -> >1x is correct
#   (2) a coalescing-window gap in the shared block store -> fixable
#
# THE TRICK that makes this free and decisive: have TWO NFS clients read the
# IDENTICAL file list through ONE gateway. Identical lists means the distinct set
# is the same by construction, so hypothesis (1) CANNOT apply. Any excess over the
# one-client baseline is attributable to coalescing alone. No compute nodes, no
# MPI, no spend -- and it isolates the variable the 96-rank job could not.
#
# nosharecache on the second mount is load-bearing: without it the Linux NFS
# client shares one superblock (and one page cache) for the same server+export, so
# the second reader would be served locally and never reach the gateway at all.
set -u -o pipefail
GATES=/scratch/lith-gates
LITH=$GATES/lith-1.1.2
PFX=${PFX:-s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07}
IDX=${IDX:-$GATES/idx/merra2-201907.lithidx}
PORT=20490; MET=9320
A=/mnt/gwA; B=/mnt/gwB
P=${P:-8}
OUT=$GATES/coalesce-probe.txt

exec > >(tee -a "$OUT") 2>&1
echo "### coalesce probe $(date -u +%FT%TZ)  lith 1.1.2  P=${P}/client"

cleanup() {
  sudo umount -f $A 2>/dev/null; sudo umount -f $B 2>/dev/null
  pkill -f "[l]ith-1.1.2 serve" 2>/dev/null; sleep 2
}
trap cleanup EXIT
cleanup
sudo mkdir -p $A $B

start_gw() {   # a FRESH gateway per arm = a cold block store per arm
  pkill -f "[l]ith-1.1.2 serve" 2>/dev/null; sleep 2
  setsid nohup $LITH serve nfs "$PFX" --index-file "$IDX" --no-sign-request \
    --mem-cache 8GB --nic-gbps 7.5 --listen :${PORT} --metrics :${MET} \
    > $GATES/coalesce-gw.log 2>&1 < /dev/null &
  for i in $(seq 20); do
    ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN && break; sleep 1
  done
  ss -ltn "sport = :${PORT}" | grep -q LISTEN && echo "  gateway up" || { echo "  GATEWAY FAILED"; tail -5 $GATES/coalesce-gw.log; exit 1; }
}

mnt() { sudo mount -t nfs -o "vers=3,proto=tcp,port=${PORT},mountport=${PORT},nolock,ro,nosharecache" localhost:/ "$1"; }

m() { curl -s --max-time 5 http://localhost:${MET}/metrics | awk -v k="$1" 'index($0,k)==1 {print $NF; exit}'; }
readall() { xargs -P "$P" -a "$1" -I{} sh -c 'dd if="{}" bs=4M of=/dev/null 2>/dev/null'; }

# ---- arm 1: ONE client ----
echo; echo "=== arm 1: one client ==="
start_gw
mnt $A || { echo "  mount A failed"; exit 1; }
find $A -type f | sort > /tmp/cl.A
NB=$(du -bc $(cat /tmp/cl.A) 2>/dev/null | tail -1 | cut -f1)
echo "  list: $(wc -l < /tmp/cl.A) files, ${NB} bytes ($(awk -v b=$NB 'BEGIN{printf "%.2f", b/2^30}') GiB)"
echo "  metric names carrying bytes/dedup/cache:"
curl -s http://localhost:${MET}/metrics | grep -vE '^#' | grep -iE 'distinct|dedup|coalesc|cache|prefetch|s3_bytes|fill' | sed 's/^/    /'
sudo sysctl -q vm.drop_caches=3
b0=$(m lith_s3_bytes_total); g0=$(m 'lith_s3_requests_total{op="get",status="ok"}')
t0=$(date +%s.%N); readall /tmp/cl.A; t1=$(date +%s.%N)
b1=$(m lith_s3_bytes_total); g1=$(m 'lith_s3_requests_total{op="get",status="ok"}')
ONE=$(awk -v a="${b0:-0}" -v b="${b1:-0}" 'BEGIN{print b-a}')
printf 'ARM1  wall=%.2fs  s3_bytes=%s (%.1f MB)  gets=%s  ampl=%.3fx\n' \
  "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "$ONE" \
  "$(awk -v x=$ONE 'BEGIN{print x/1e6}')" "$(awk -v a=${g0:-0} -v b=${g1:-0} 'BEGIN{print b-a}')" \
  "$(awk -v x=$ONE -v n=$NB 'BEGIN{print x/n}')"

# ---- arm 2: TWO clients, SAME list, concurrently ----
echo; echo "=== arm 2: two clients, identical list, concurrent ==="
sudo umount -f $A 2>/dev/null
start_gw
mnt $A || { echo "  mount A failed"; exit 1; }
mnt $B || { echo "  mount B failed"; exit 1; }
sed "s|^$A|$B|" /tmp/cl.A > /tmp/cl.B
echo "  A: $(wc -l < /tmp/cl.A) files   B: $(wc -l < /tmp/cl.B) files (same keys, independent client caches)"
sudo sysctl -q vm.drop_caches=3
b0=$(m lith_s3_bytes_total); g0=$(m 'lith_s3_requests_total{op="get",status="ok"}')
t0=$(date +%s.%N)
readall /tmp/cl.A & pa=$!
readall /tmp/cl.B & pb=$!
wait $pa $pb
t1=$(date +%s.%N)
b1=$(m lith_s3_bytes_total); g1=$(m 'lith_s3_requests_total{op="get",status="ok"}')
TWO=$(awk -v a="${b0:-0}" -v b="${b1:-0}" 'BEGIN{print b-a}')
printf 'ARM2  wall=%.2fs  s3_bytes=%s (%.1f MB)  gets=%s  ampl=%.3fx\n' \
  "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "$TWO" \
  "$(awk -v x=$TWO 'BEGIN{print x/1e6}')" "$(awk -v a=${g0:-0} -v b=${g1:-0} 'BEGIN{print b-a}')" \
  "$(awk -v x=$TWO -v n=$NB 'BEGIN{print x/n}')"

echo
printf 'VERDICT  two-client / one-client = %.3fx   (1.00 = perfect coalescing, 2.00 = none)\n' \
  "$(awk -v a=$ONE -v b=$TWO 'BEGIN{print b/a}')"
