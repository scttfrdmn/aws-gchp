#!/bin/bash
# chem_remote_selftest.sh — Phase 1b shim unit round-trip gate (NO GCHP).
#
# Builds chem_remote_shm.c + chem_remote_mod.F90 + chem_remote_selftest.F90
# into ONE executable, then launches two processes (rank + worker) keyed by the
# same GCHP_JOBID/GCHP_CHEM_RANK so they attach the same POSIX shm segments and
# named semaphores. The rank drives NSTEP supersteps and byte-verifies the
# worker's transform is visible across the process boundary, then sentinels the
# worker and tears down. PASS iff the rank prints "SELFTEST PASS" and the worker
# exits clean.
#
# This gates the entire shm plumbing (shm_open/mmap/ftruncate + sem_open/
# wait/post/timedwait + C_F_POINTER onto shm + the 2-sem handshake + rank/worker
# object naming) BEFORE any 30-min GCHP build. Must be run on Linux/glibc
# (POSIX sem_timedwait); the head node is fine.
#
# Usage:  bash chem_remote_selftest.sh
set -uo pipefail

# Locate the two shim sources in the GCHP clone (decoupled variant preferred).
GC_SRC="${GC_SRC:-/scratch/gchp-instr/GCHP-decoupled}"
MODDIR="$GC_SRC/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/GeosCore"
SHIM_C="$MODDIR/chem_remote_shm.c"
SHIM_F="$MODDIR/chem_remote_mod.F90"
HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_F="$HERE/chem_remote_selftest.F90"
WORK=/tmp/p1b_selftest.$$

# Allow overriding the sources (e.g. run straight from a git checkout).
[ -f "$SHIM_C" ] || SHIM_C="${SHIM_C_OVERRIDE:-$SHIM_C}"
[ -f "$SHIM_F" ] || SHIM_F="${SHIM_F_OVERRIDE:-$SHIM_F}"

for f in "$SHIM_C" "$SHIM_F" "$TEST_F"; do
  [ -f "$f" ] || { echo "SELFTEST FAIL: missing source $f"; exit 1; }
done

FC="${FC:-gfortran}"
CC="${CC:-gcc}"
command -v "$FC" >/dev/null || { echo "SELFTEST FAIL: no $FC"; exit 1; }
command -v "$CC" >/dev/null || { echo "SELFTEST FAIL: no $CC"; exit 1; }

mkdir -p "$WORK"; cd "$WORK"
echo "=== [selftest] build (FC=$FC CC=$CC) ==="
# The module + test only need ISO_C_BINDING; the shim needs -lrt -lpthread.
"$CC" -c -O2 "$SHIM_C" -o shm.o 2>&1 | head -20 || { echo "SELFTEST FAIL: cc shim"; exit 1; }
"$FC" -cpp -DDECOUPLED_CHEM -ffree-line-length-none -O2 -c "$SHIM_F" -o mod.o 2>&1 | head -20 \
  || { echo "SELFTEST FAIL: fc module"; exit 1; }
"$FC" -cpp -DDECOUPLED_CHEM -ffree-line-length-none -O2 -c "$TEST_F" -o test.o 2>&1 | head -20 \
  || { echo "SELFTEST FAIL: fc test"; exit 1; }
"$FC" test.o mod.o shm.o -o selftest -lrt -lpthread 2>&1 | head -20 \
  || { echo "SELFTEST FAIL: link"; exit 1; }
echo "[selftest] built $WORK/selftest"

# Same keys for both processes.
export GCHP_JOBID="selftest$$"
export GCHP_CHEM_RANK=0
# rank uses OMPI_COMM_WORLD_RANK; set it so build_stem(rank) keys r0 too.
export OMPI_COMM_WORLD_RANK=0

# sweep any stale objects for this (fresh) job id — should be none.
rm -f /dev/shm/gchp_${GCHP_JOBID}_* /dev/shm/sem.gchp_${GCHP_JOBID}_* 2>/dev/null

echo "=== [selftest] launch worker + rank ==="
./selftest worker > worker.log 2>&1 &
WPID=$!
sleep 0.5                     # let the worker begin its bounded-retry attach
./selftest rank   > rank.log   2>&1
RANK_RC=$?
wait "$WPID" 2>/dev/null; WORK_RC=$?

echo "----- rank.log -----";   cat rank.log
echo "----- worker.log -----"; cat worker.log

# Leftover-object check: after Final, no gchp_<jobid>_* should remain.
LEFT=$(ls /dev/shm/gchp_${GCHP_JOBID}_* /dev/shm/sem.gchp_${GCHP_JOBID}_* 2>/dev/null | wc -l)

echo "=== [selftest] verdict ==="
if grep -q "SELFTEST PASS" rank.log && [ "$RANK_RC" = "0" ] && [ "$LEFT" = "0" ]; then
  echo ">>> PHASE1B SHIM SELFTEST PASS (rank_rc=$RANK_RC worker_rc=$WORK_RC leftover=$LEFT)"
  rm -rf "$WORK"
  exit 0
else
  echo ">>> PHASE1B SHIM SELFTEST FAIL (rank_rc=$RANK_RC worker_rc=$WORK_RC leftover=$LEFT)"
  echo "    (workdir kept for inspection: $WORK)"
  exit 1
fi
