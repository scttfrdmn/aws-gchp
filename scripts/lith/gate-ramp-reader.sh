#!/bin/bash
# Gate 5f-G (lith#256): is the +22.3% request cost of --readahead-evidence-ratio a property
# of the FLAG or of the READER?
#
# Upstream priced the ramp on a pure `cat` stream over a 1161 MiB object and got bytes AND
# requests byte-identical at ratio 0 vs 4 — my +22.3% did not reproduce. Their explanation:
# netCDF4 walks the object variable by variable, so accrued evidence repeatedly lags the
# window and the ramp is paid more than once, while a contiguous stream never binds at all.
#
# Their question back was the right one: does my +22.3% hold if the reader streams, on MY
# box and the SAME object? This runs three readers over the same two objects at both ratios:
#
#   dd     one contiguous stream, 1 MiB reads       (their `cat` case)
#   pread  one contiguous stream, same 1 MiB reads, from PYTHON
#          -> separates "contiguous" from "not the netCDF4/HDF5 process"
#   nc     every data variable end to end via netCDF4 (met 5 vars, hco 12 vars)
#   dd128  one contiguous stream at `cat`'s 128 KiB read size, and `cat` itself
#          -> the one axis on which my harness and upstream's differ (READERS=... selects)
#
# If upstream's reader explanation is right, the request delta should be ~0 for dd and
# pread, small for met/nc (5 variables) and large for hco/nc (12) — and my own two nc arms
# already bracket it at +0.6% and +22.3%, which is evidence FOR their explanation rather
# than against it.
#
# 3 reps per cell, fresh mount per rep, unique metrics port per mount. Head node only, $0.
set -u

B=${B:-/scratch/lith-gates/lith-new}
# PF_TRACE=1 captures the per-fetch trace and raises the mount log level. Upstream's
# ask on #256 after gate 5f-H: the empty mount logs and absent CSVs were the one piece
# neither of us had, and the window column over a slow run is what settles whether the
# ramp was ever the story.
PF_TRACE=${PF_TRACE:-0}
LOGLVL=${LOGLVL:-warn}
PYX=/scratch/ncenv/bin/python
OUT=${OUT:-/scratch/lith-gates/gate-ramp}
MNT=/scratch/mnt/r
REPS=${REPS:-3}
PORT_BASE=9400

MET_PREFIX=${MET_PREFIX:-s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07}
MET_OBJ=${MET_OBJ:-MERRA2.20190701.A3dyn.05x0625.nc4}
# HCO_PREFIX is overridden to a us-west-2 copy of the SAME object for the
# high-RTT arm (gate 5f-H): 58.6 ms connect vs 2.2 ms in-region, 26.7x.
HCO_PREFIX=${HCO_PREFIX:-s3://gcgrid/HEMCO/GT_Chlorine/v2024-05}
HCO_OBJ=${HCO_OBJ:-GT_Chlorine_01_01_2000_V1.0.0.nc}
OBJS=${OBJS:-"met hco"}

mkdir -p "$OUT" "$MNT"

cat > "$OUT/pystream.py" <<'PY'
# whole object, strictly increasing 1 MiB preads: contiguous, but from python
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
sz = os.fstat(fd).st_size
t0 = time.time(); off = 0; n = 0
while off < sz:
    b = os.pread(fd, 1 << 20, off)
    if not b:
        break
    off += len(b); n += 1
os.close(fd)
print("pystream bytes=%d reads=%d wall=%.1f" % (off, n, time.time() - t0))
PY

cat > "$OUT/ncwhole.py" <<'PY'
# every data variable end to end, netCDF4 (the arm that showed +22.3% on hco)
import sys, time
from netCDF4 import Dataset
ds = Dataset(sys.argv[1])
dv = [n for n, v in ds.variables.items() if v.ndim >= 3]
t0 = time.time(); tot = 0
for n in dv:
    a = ds.variables[n][:]; tot += a.nbytes; del a
print("ncwhole vars=%d elem_bytes=%d wall=%.1f" % (len(dv), tot, time.time() - t0))
ds.close()
PY

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
run_cell() {
  local cls=$1 prefix=$2 obj=$3 reader=$4 ratio=$5 rep=$6
  local tag="$cls-$reader-r$ratio-$rep"
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  local extra=""
  [ "$ratio" != "0" ] && extra="--readahead-evidence-ratio $ratio"
  umount_wait
  [ "$PF_TRACE" = "1" ] && extra="$extra --pf-trace $OUT/$tag.csv"
  $B mount "$prefix" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level "$LOGLVL" $extra \
      > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if ! mountpoint -q "$MNT"; then echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; fi
  local t0 t1
  t0=$(date +%s.%N)
  case $reader in
    dd)     dd if="$MNT/$obj" of=/dev/null bs=1M status=none ;;
    dd128)  dd if="$MNT/$obj" of=/dev/null bs=128K status=none ;;   # `cat`'s read size
    cat)    cat "$MNT/$obj" > /dev/null ;;
    pread)  $PYX "$OUT/pystream.py" "$MNT/$obj" > /dev/null ;;
    nc)     $PYX "$OUT/ncwhole.py" "$MNT/$obj" > /dev/null ;;
  esac
  t1=$(date +%s.%N)
  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | grep -E \
    '^lith_(s3_bytes_total|s3_requests_total|distinct_bytes_read|prefetch_issued_total|prefetch_used_total)' \
    | awk -v t="$tag" -v w="$(echo "$t1 - $t0" | bc)" '{printf "%s %s %s wall=%s\n", t, $1, $2, w}'
  umount_wait
}

echo "=== gate 5f-G  $(date -u +%FT%TZ)  reps=$REPS ==="
echo "  lith: $($B version 2>&1 | head -1)"
$PYX -c 'import netCDF4;print("  netCDF4",netCDF4.__version__,"libnetcdf",netCDF4.__netcdf4libversion__,"hdf5",netCDF4.__hdf5libversion__)'
echo "  host: $(hostname) $(nproc) cores"

for rep in $(seq 1 "$REPS"); do
  for reader in ${READERS:-dd pread nc}; do
    for ratio in 0 4; do
      for o in $OBJS; do
        case $o in
          met) run_cell met "$MET_PREFIX" "$MET_OBJ" "$reader" "$ratio" "$rep" ;;
          hco) run_cell hco "$HCO_PREFIX" "$HCO_OBJ" "$reader" "$ratio" "$rep" ;;
        esac
      done
    done
  done
done
echo "=== done $(date -u +%FT%TZ) ==="
