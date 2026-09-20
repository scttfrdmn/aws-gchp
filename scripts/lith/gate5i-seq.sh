#!/bin/bash
# Gate 5i ($0, head node): verify lith PR#271's `seq` and `max_window` columns BEFORE
# funding a second 48-rank capture. Upstream's pre-capture acceptance criterion is
# "seq strictly increasing within each fh, and the gap self-consistency test at ~0%".
#
# The two are not the same test. `seq` is allocated inside w.mu, so per-handle
# monotonicity is exact by construction. But `gap` is still computed from
# h.lastReadEnd.Load() BEFORE the lock and stored AFTER it (fs.go), so two concurrent
# reads on one fh can both measure the gap against the same stale lastReadEnd. If that
# is what remains, the gap test does NOT go to 0% on a healthy trace, and accepting
# upstream's criterion would reject a good capture.
#
# Arms, one handle each, same object, same total bytes:
#   s1  128 scattered 64 KiB preads, ONE thread            (control: no concurrency)
#   c8  128 scattered 64 KiB preads, 8 threads, ONE shared fd  (the race)
#   c8b same as c8, repeated (is the effect stable?)
set -u
BIN=/scratch/lith-gates/lith-271          # pr/271 4887d87
MNT=/mnt/lith-256
MET=9205
OBJ=AEIC.nc
OUT=/scratch/lith-gates/gate5i
mkdir -p $OUT

umount_wait() {
  fusermount3 -u $MNT 2>/dev/null
  for i in $(seq 1 30); do mountpoint -q $MNT || return 0; sleep 0.5; done
  fusermount3 -uz $MNT 2>/dev/null; sleep 1
}

cat > $OUT/scatter1.py <<'PY'
# gate 5f's b2 pattern, verbatim: ONE handle, 128 x 64 KiB aligned reads, 7 MiB apart.
import os, sys
path = sys.argv[1]
fd = os.open(path, os.O_RDONLY); sz = os.fstat(fd).st_size
E = 1 << 16; N = 128
for i in range(N):
    off = (i * 7 * (1 << 20)) % (sz - E); off -= off % E
    os.pread(fd, E, off)
os.close(fd)
print("scatter1 requested_bytes", N * E)
PY

cat > $OUT/scatterC.py <<'PY'
# Same 128 x 64 KiB scatter, same ONE fd, but issued by 8 threads. os.pread releases
# the GIL, so these are genuinely concurrent at the FUSE layer and land on ONE fh --
# which is the only way to exercise the lastReadEnd read-modify-write and the
# decision-vs-append ordering the trace is supposed to make recoverable.
import os, sys, threading
path = sys.argv[1]; T = 8
fd = os.open(path, os.O_RDONLY); sz = os.fstat(fd).st_size
E = 1 << 16; N = 128
offs = []
for i in range(N):
    off = (i * 7 * (1 << 20)) % (sz - E); off -= off % E
    offs.append(off)
def work(t):
    for i in range(t, N, T):
        os.pread(fd, E, offs[i])
ths = [threading.Thread(target=work, args=(t,)) for t in range(T)]
for th in ths: th.start()
for th in ths: th.join()
os.close(fd)
print("scatterC requested_bytes", N * E, "threads", T)
PY

run_arm() {
  local name=$1 reader=$2
  umount_wait
  rm -f $OUT/$name.csv
  $BIN mount s3://gcgrid/HEMCO/AEIC/v2015-01 $MNT --pf-trace $OUT/$name.csv \
    --metrics :$MET --nic-gbps 50 --mem-cache 4GB --log-level warn > $OUT/$name.mount.log 2>&1 &
  for i in $(seq 1 40); do mountpoint -q $MNT && break; sleep 0.5; done
  if ! mountpoint -q $MNT; then echo "$name MOUNT FAILED"; tail -4 $OUT/$name.mount.log; return 1; fi
  [ -s $OUT/$name.csv ] || { echo "$name NO TRACE FILE after mount"; umount_wait; return 1; }
  python3 $OUT/$reader $MNT/$OBJ
  curl -s localhost:$MET/metrics | grep -E "^lith_prefetch_issued_total|^lith_s3_bytes" \
    | sed "s/^/$name METRIC /"
  umount_wait
  echo "$name rows $(( $(wc -l < $OUT/$name.csv) - 2 ))"
  return 0
}

echo "################ gate 5i -- PR#271 seq / max_window, \$0"
$BIN --version 2>/dev/null | sed 's/^/BIN /'
run_arm s1  scatter1.py
run_arm c8  scatterC.py
run_arm c8b scatterC.py
echo "################ header check"
head -2 $OUT/s1.csv
echo "################ analysis"
python3 /scratch/lith-gates/gate5i-check.py $OUT/s1.csv $OUT/c8.csv $OUT/c8b.csv
