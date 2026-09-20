#!/bin/bash
# Gate 5i part B: the part-A probe was too small on BOTH axes it needed to exercise.
#   * one open handle => perHandleWindow = clamp(budget/1, 2, 223) = 223, so max_window
#     was pinned at its ceiling and could not vary. The capture's met mount ran at 17
#     because ~600 handles were open.
#   * 128 reads on one fd did not contend, so zero rows were appended out of decision
#     order and `seq` had nothing to recover.
# Both are properties of the probe, not of PR#271. Scale them:
#   c64   ONE fd, 64 threads, 4096 scattered 64 KiB preads  -> same-fh decision ordering
#   h256  256 fds on the same object, 32 reads each         -> drives perHandleWindow down
set -u
BIN=/scratch/lith-gates/lith-271
MNT=/mnt/lith-256
MET=9206
OBJ=AEIC.nc
OUT=/scratch/lith-gates/gate5i
mkdir -p $OUT

umount_wait() {
  fusermount3 -u $MNT 2>/dev/null
  for i in $(seq 1 30); do mountpoint -q $MNT || return 0; sleep 0.5; done
  fusermount3 -uz $MNT 2>/dev/null; sleep 1
}

cat > $OUT/onefd.py <<'PY'
# ONE fd, T threads, N scattered 64 KiB preads. os.pread drops the GIL, so these are
# concurrent at the FUSE layer and all land on one fh -- the configuration that made
# 1.87% of the capture's met rows gap-self-inconsistent.
import os, sys, threading
path = sys.argv[1]; T = int(sys.argv[2]); N = int(sys.argv[3])
fd = os.open(path, os.O_RDONLY); sz = os.fstat(fd).st_size
E = 1 << 16
offs = []
for i in range(N):
    off = (i * 1049600) % (sz - E); off -= off % E
    offs.append(off)
def work(t):
    for i in range(t, N, T):
        os.pread(fd, E, offs[i])
ths = [threading.Thread(target=work, args=(t,)) for t in range(T)]
for th in ths: th.start()
for th in ths: th.join()
os.close(fd)
print("onefd threads", T, "reads", N, "requested_bytes", N * E)
PY

cat > $OUT/manyfd.py <<'PY'
# H threads, each with its OWN fd on the same object => H simultaneously open handles,
# so perHandleWindow = clamp(prefetch_budget / H, 2, 223) should fall well below 223.
import os, sys, threading
path = sys.argv[1]; H = int(sys.argv[2]); N = int(sys.argv[3])
E = 1 << 16
barrier = threading.Barrier(H)
def work(t):
    fd = os.open(path, os.O_RDONLY)
    sz = os.fstat(fd).st_size
    barrier.wait()                 # hold all H handles open at once
    for i in range(N):
        off = ((t * 8191 + i) * 1049600) % (sz - E); off -= off % E
        os.pread(fd, E, off)
    os.close(fd)
ths = [threading.Thread(target=work, args=(t,)) for t in range(H)]
for th in ths: th.start()
for th in ths: th.join()
print("manyfd handles", H, "reads_each", N, "requested_bytes", H * N * E)
PY

# run_arm <name> <reader.py> <args...>; the mount path is inserted as the reader's
# FIRST argument, which is where both readers expect it (argv[1]).
run_arm() {
  local name=$1 reader=$2; shift 2
  umount_wait
  rm -f $OUT/$name.csv
  $BIN mount s3://gcgrid/HEMCO/AEIC/v2015-01 $MNT --pf-trace $OUT/$name.csv \
    --metrics :$MET --nic-gbps 50 --mem-cache 4GB --log-level warn > $OUT/$name.mount.log 2>&1 &
  for i in $(seq 1 40); do mountpoint -q $MNT && break; sleep 0.5; done
  if ! mountpoint -q $MNT; then echo "$name MOUNT FAILED"; tail -4 $OUT/$name.mount.log; return 1; fi
  [ -s $OUT/$name.csv ] || { echo "$name NO TRACE FILE"; umount_wait; return 1; }
  /usr/bin/time -f "$name wall %e s" python3 $reader $MNT/$OBJ "$@" 2>&1 | tail -2
  curl -s localhost:$MET/metrics | grep -E "^lith_prefetch_issued_total|^lith_s3_bytes" \
    | sed "s/^/$name METRIC /"
  umount_wait
  echo "$name rows $(( $(wc -l < $OUT/$name.csv) - 2 ))"
}

echo "################ gate 5i part B -- contention + many handles, \$0"
run_arm c64  $OUT/onefd.py  64 4096
run_arm h256 $OUT/manyfd.py 256 32
echo "################ analysis"
python3 /scratch/lith-gates/gate5i-check.py $OUT/c64.csv $OUT/h256.csv
