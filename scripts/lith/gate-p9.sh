#!/bin/bash
# Gate 5f-P9 (lith#284): #284's slice shape cross-region, evidence gate off vs on.
# Pre-registered in data/lith-gates/inregion-streams.txt before any cell ran.
#
# One netCDF4 process reads ONE variable of a five-variable NetCDF-4 object (the 54x arm),
# from a us-west-2 copy (58.6 ms) at --readahead-evidence-ratio 0 and 4, interleaved within
# rep. In-region pair from gcgrid as an unscored anchor. Head node; ~$0.12 of transfer.
set -u

G=${G:-/scratch/lith-gates}
OUT=${OUT:-$G/p9}
MNT=${MNT:-/scratch/mnt/p9}
B=${B:-$G/lith-324}
PYX=${PYX:-/scratch/ncenv/bin/python}
READER=${READER:-$G/gate2nd/reader.py}
OBJ=${OBJ:-MERRA2.20190701.A3dyn.05x0625.nc4}
XPREFIX=${XPREFIX:-s3://gchp-lith-xregion-usw2-942542972736/merra2}
IPREFIX=${IPREFIX:-s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07}
XREPS=${XREPS:-4}
IREPS=${IREPS:-2}
PORT_BASE=${PORT_BASE:-9990}
MODE=${MODE:-var1}     # P9b: MODE=whole TAGP=W
TAGP=${TAGP:-}
mkdir -p "$OUT" "$MNT"

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
run_cell() {
  local where=$1 ratio=$2 rep=$3 prefix tag
  [ "$where" = X ] && prefix=$XPREFIX || prefix=$IPREFIX
  tag="$TAGP$where$ratio-$rep"
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  umount_wait
  "$B" mount "$prefix" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn \
      --readahead-evidence-ratio "$ratio" --pf-trace "$OUT/$tag.trace.csv" \
      > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; }
  local t0 t1 rd
  t0=$(date +%s.%N)
  rd=$($PYX "$READER" "$MNT/$OBJ" "$MODE" 2>&1)
  t1=$(date +%s.%N)
  local met
  met=$(curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | awk '
    /^lith_s3_bytes_total /{b=$2} /^lith_s3_requests_total/{r+=$2} /^lith_distinct_bytes_read /{d=$2}
    /^lith_prefetch_issued_total /{s=$2} /^lith_prefetch_used_total /{u=$2}
    /^lith_readahead_evidence_ratio /{e=$2}
    END{printf "s3_MB=%.1f GETs=%d distinct_MB=%.1f amp=%.2f issued=%d used=%d evidence_ratio_gauge=%s",
        b/1e6, r, d/1e6, (d>0?b/d:0), s, u, (e==""?"NA":e)}')
  echo "CELL $tag wall=$(echo "$t1 - $t0" | bc) $met reader=[$rd]"
  umount_wait
}

echo "=== gate 5f-P9  $(date -u +%FT%TZ)  B=$(md5sum "$B" | cut -c1-12)  $OBJ"
for rep in $(seq 1 "$XREPS"); do
  run_cell X 0 "$rep"; run_cell X 4 "$rep"
done
for rep in $(seq 1 "$IREPS"); do
  run_cell I 0 "$rep"; run_cell I 4 "$rep"
done
echo "=== done $(date -u +%FT%TZ)"
