#!/bin/bash
# Gate 5f-E (lith#256): does the key-level coverage rule hold for a DIFFERENT reader stack?
#
# The key-level fit (capture 2) was measured on ONE workload: GCHP 14.7.1 fullchem,
# MAPL/pFIO, 48 MPI ranks, NetCDF-C 4.9.2 + HDF5 1.14.0 from the GCHP stack. Upstream's
# standing objection is n=1 — coverage may be a property of that reader, not of the object.
#
# This gate re-reads the SAME TWO S3 OBJECTS with an independent reader stack:
#   netCDF4 1.7.2 (its own bundled libnetcdf 4.9.4-dev / HDF5 1.14.2), single process,
#   one handle per open, on the head node. No MPI, no MAPL, no pFIO, no 48 ranks.
#
# PRE-REGISTERED on lith#256 before the first byte was read:
#   - a whole-object read lands at HIGH coverage and follow-through comparable to met's 0.74
#   - a small subset read of the SAME object lands at LOW coverage and HEMCO-like waste
#   - a LOW-coverage read that comes back with HIGH follow-through REFUTES coverage as the
#     predictor, and gets posted as such
#
# The var1 arm is the discriminator neither prediction covers: one variable read end to end
# is LOW coverage (~20% of the object) but PERFECTLY sequential. If follow-through tracks
# sequentiality rather than coverage, var1 is where it shows.
#
# DISCLOSED REGIME DIFFERENCE: one open handle here vs ~600 in the GCHP capture. The window
# is clamp(budget/open_handles, 2, max_readahead), so GCHP ran at the floor of 2 and this
# workload runs at the full 223-block window. Same rule, different side of the clamp.
#
# Cost: head node only (already up), in-region GETs, ~2 GB per whole arm. No cluster time.
set -u

#   EXTRA=... OUT=... re-runs the same six arms under different mount flags, which is how
#   gate 5f-F prices upstream's own candidate fix (--readahead-evidence-ratio) on them.

B=/scratch/lith-gates/lith-new
PYX=/scratch/ncenv/bin/python
OUT=${OUT:-/scratch/lith-gates/gate2nd}
EXTRA=${EXTRA:-}
MNT=/scratch/mnt/w
PORT_BASE=9320

MET_PREFIX=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
MET_OBJ=MERRA2.20190701.A3dyn.05x0625.nc4
HCO_PREFIX=s3://gcgrid/HEMCO/GT_Chlorine/v2024-05
HCO_OBJ=GT_Chlorine_01_01_2000_V1.0.0.nc

mkdir -p "$OUT" "$MNT"

cat > "$OUT/reader.py" <<'PY'
import sys, time
import numpy as np
from netCDF4 import Dataset

path, mode = sys.argv[1], sys.argv[2]
ds = Dataset(path)
dvars = [n for n, v in ds.variables.items() if v.ndim >= 3]
t0 = time.time()
elem = 0

if mode == "whole":
    # every data variable, end to end
    for n in dvars:
        a = ds.variables[n][:]
        elem += a.nbytes
        del a
elif mode == "var1":
    # ONE variable, end to end: low coverage of the object, perfectly sequential in it
    n = dvars[0]
    a = ds.variables[n][:]
    elem += a.nbytes
    del a
elif mode == "sub":
    # ExtData-like: one chunk-sized plane per variable at two time steps
    for n in dvars:
        v = ds.variables[n]
        ck = v.chunking()
        for t in (0, v.shape[0] // 2):
            if v.ndim == 4:
                a = v[t, 0, :, :]
            else:
                a = v[t, 0:ck[1], 0:ck[2]]
            elem += a.nbytes
            del a
else:
    sys.exit("bad mode " + mode)

print("mode=%s vars=%d elem_bytes=%d wall=%.1f" % (mode, len(dvars), elem, time.time() - t0))
ds.close()
PY

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 30); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

ARM_N=0
run_arm() {
  local cls=$1 prefix=$2 obj=$3 mode=$4
  local tag="$cls-$mode"
  # a fresh port per arm: reusing one port races the previous daemon's release and the
  # metrics scrape comes back empty (it did, on met-sub, first time through)
  ARM_N=$((ARM_N + 1))
  local PORT=$((PORT_BASE + ARM_N))
  umount_wait
  # fresh mount per arm: the cold-start tax is only real on a cold cache
  $B mount "$prefix" "$MNT" --pf-trace "$OUT/$tag.csv" --metrics ":$PORT" \
      --nic-gbps 50 --log-level warn $EXTRA > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if ! mountpoint -q "$MNT"; then
    echo "=== ARM $tag MOUNT FAILED ==="; tail -n 5 "$OUT/$tag.mount.log"; return 1
  fi
  echo "=== ARM $tag ==="
  echo -n "  "; $PYX "$OUT/reader.py" "$MNT/$obj" "$mode"
  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | grep -E \
    '^lith_(s3_bytes_total|s3_requests_total|distinct_bytes_read|prefetch_issued_total|prefetch_used_total|cache_misses_total|read_straddle_total)' \
    | sed "s/^/  $tag /"
  umount_wait
  echo -n "  trace rows: "; grep -vc '^#' "$OUT/$tag.csv"
  head -1 "$OUT/$tag.csv" | sed 's/^/  /'
}

echo "=== gate 5f-E  $(date -u +%FT%TZ)  EXTRA='$EXTRA'  OUT=$OUT ==="
echo "reader stack:"
$PYX -c 'import netCDF4,numpy;print("  netCDF4",netCDF4.__version__,"libnetcdf",netCDF4.__netcdf4libversion__,"hdf5",netCDF4.__hdf5libversion__,"numpy",numpy.__version__)'
echo "  lith: $($B version 2>&1 | head -1) ($(cd /scratch/lith-src && git describe --tags))"
echo "  host: $(hostname)  $(nproc) cores  $(free -g | awk '/^Mem:/{print $2" GiB"}')"

for mode in whole var1 sub; do
  run_arm met "$MET_PREFIX" "$MET_OBJ" "$mode"
done
for mode in whole var1 sub; do
  run_arm hco "$HCO_PREFIX" "$HCO_OBJ" "$mode"
done

echo "=== done $(date -u +%FT%TZ) ==="
