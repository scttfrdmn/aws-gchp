#!/bin/bash
# Gate 5f-P36 (lith#407 direction-1 witness, baseline before the change): scatter-then-stream on a 3.78 GB GEOS-FP
# A3dyn (scatter_stream.py: 40 irregular 8 KiB preads in the first 256 MiB, then a 1 GiB contiguous stream), plus the
# plain dd witness. Fresh mount per cell, distinct file per cell, arms D (default) and AB (per-run + sub-block).
G=/scratch/lith-gates; L=${L:-$G/v1171/lith_linux_arm64}; PYX=/scratch/ncenv/bin/python; S=$G/scatter_stream.py; NCS=$G/nc_stream.py
M=/scratch/mnt/p36; OUT=${OUT:-$G/p40w}; REPS=${REPS:-2}; PORT=10900; FPDAY=0
FP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/08
mkdir -p "$M" "$OUT"
prom() { awk -v k="$2" '$1==k{print $2}' "$1"; }
cell() {  # cell TAG ARM WORKLOAD(SS|DD)
  local tag=$1 flags="" f t0 t1 sz; PORT=$((PORT + 1)); FPDAY=$(( FPDAY % 24 + 1 ))
  case ${2%z} in AB) flags="--readahead-evidence-per-run --readahead-subblock-dispatch" ;; B) flags="--readahead-subblock-dispatch" ;; X) flags="--readahead-subblock-dispatch=false" ;; esac
  "$L" mount "$FP" "$M" --no-sign-request --nic-gbps 50 $flags --metrics ":$PORT" --pf-trace "$OUT/$tag.trace.csv" \
      --log-level warn > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 60); do mountpoint -q "$M" && break; sleep 1; done
  mountpoint -q "$M" || { echo "$tag MOUNT FAILED"; return 1; }
  pgrep -a -f "[l]ith_linux_arm64 mount $FP" | cut -c1-300 > "$OUT/$tag.args.txt"
  f=$M/$(printf 'GEOSFP.201908%02d.A3dyn.025x03125.nc' $FPDAY); sz=$(stat -c %s "$f")
  t0=$(date +%s.%N)
  case $3 in SS) $PYX "$S" "$f" 1024 > "$OUT/$tag.json" 2>&1 ;; NC) $PYX "$NCS" "$f" U > "$OUT/$tag.json" 2>&1 ;;
    *) dd if="$f" of=/dev/null bs=1M status=none ;; esac
  t1=$(date +%s.%N)
  sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"
  fusermount3 -u "$M"; for _ in $(seq 1 40); do mountpoint -q "$M" || break; sleep 0.5; done
  local s3 g pr wh; s3=$(prom "$OUT/$tag.final.prom" lith_s3_bytes_total)
  g=$(prom "$OUT/$tag.final.prom" 'lith_s3_requests_total{op="get",status="ok"}')
  pr=$(prom "$OUT/$tag.final.prom" 'lith_fill_bytes_total{kind="prefetch-range"}')
  wh=$(prom "$OUT/$tag.final.prom" 'lith_fill_bytes_total{kind="whole"}')
  awk -v t="$tag" -v a="$t0" -v b="$t1" -v s="$s3" -v g="$g" -v pr="${pr:-0}" -v wh="${wh:-0}" -v z="$sz" 'BEGIN{
    printf "CELL %s wall=%.3f s3_MB=%.1f gets=%s whole_MB=%.1f prefetch_range_MB=%.1f file_MB=%.1f", t, b-a, s/1e6, g, wh/1e6, pr/1e6, z/1e6}'
  local unc; unc=$(prom "$OUT/$tag.final.prom" lith_prefetch_uncovered_total); printf " uncovered=%s" "$unc"
  [ "$3" != DD ] && printf " %s" "$(cat "$OUT/$tag.json")"; echo
}
echo "=== gate ${GATE:-5f-P36} $(date -u +%FT%TZ) lith=$(md5sum "$L" | cut -c1-12)"
for rep in $(seq 1 "$REPS"); do for w in ${WORK:-SS DD}; do for arm in ${ARMS:-D AB}; do cell "$w-$arm-$rep" $arm $w; done; done; done
echo "=== done $(date -u +%FT%TZ)"
