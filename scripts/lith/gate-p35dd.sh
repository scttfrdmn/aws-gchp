#!/bin/bash
# Gate 5f-P35dd (lith#407 arm B witness): does a sequential dd change under --readahead-evidence-per-run and/or
# --readahead-subblock-dispatch? Derived from gate-p31.sh's D cell; arms D/A/B/AB interleaved per rep.
# Pre-registered in data/lith-gates/inregion-streams.txt. Head node, in-region gcgrid, fresh cold mount per cell.
#   S  one var1 reader of MERRA2.20190701.A3dyn (#284's object; ratio 4 reference 59.8 MB, 2.65x of 22.5 MB)
#   C  6 concurrent var1 readers of 07-02..07 (P9m/P9o shape; ratio 4 reference 358.6 MB = 6 x 59.8)
#   D  dd bs=1M of a distinct 3.78 GB GEOS-FP A3dyn per cell, with --wire-ttfb (#381 conn new/reused check)
# Arms R4 / R2 interleaved within each rep. Final /metrics scraped per cell; bytes parsed with awk (exponent-safe).
G=/scratch/lith-gates; L=${L:-$G/v1140/lith_linux_arm64}; PYX=/scratch/ncenv/bin/python; READER=$G/gate2nd/reader.py
M=/scratch/mnt/p35; OUT=${OUT:-$G/p35dd}; REPS=${REPS:-2}; PORT=10800
MER=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07; FP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07; FPDAY=20
mkdir -p "$M" "$OUT"
prom() { awk -v k="$2" '$1==k{print $2}' "$1"; }

cell() {  # cell TAG ARM WORKLOAD
  local tag=$1 w=$3 src=$MER extra="" t0 t1 f sz flags
  case $2 in D) flags="" ;; A) flags="--readahead-evidence-per-run" ;; B) flags="--readahead-subblock-dispatch" ;;
    AB) flags="--readahead-evidence-per-run --readahead-subblock-dispatch" ;; esac
  PORT=$((PORT + 1))
  [ "$w" = D ] && { src=$FP; extra="--wire-ttfb"; FPDAY=$((FPDAY + 1)); }
  "$L" mount "$src" "$M" --no-sign-request --nic-gbps 50 $flags $extra \
      --metrics ":$PORT" --log-level warn > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 60); do mountpoint -q "$M" && break; sleep 1; done
  mountpoint -q "$M" || { echo "$tag MOUNT FAILED"; return 1; }
  t0=$(date +%s.%N)
  case $w in
    S) $PYX "$READER" "$M/MERRA2.20190701.A3dyn.05x0625.nc4" var1 > "$OUT/$tag.reader.txt" 2>&1 ;;
    C) local p=() d; for d in 02 03 04 05 06 07; do
         $PYX "$READER" "$M/MERRA2.201907$d.A3dyn.05x0625.nc4" var1 > "$OUT/$tag.reader-$d.txt" 2>&1 & p+=($!); done
       wait "${p[@]}" ;;
    D) f=$(printf 'GEOSFP.201907%02d.A3dyn.025x03125.nc' $FPDAY); sz=$(stat -c %s "$M/$f")
       dd if="$M/$f" of=/dev/null bs=1M status=none ;;
  esac
  t1=$(date +%s.%N)
  sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"
  fusermount3 -u "$M"; for _ in $(seq 1 40); do mountpoint -q "$M" || break; sleep 0.5; done
  local s3 gets; s3=$(prom "$OUT/$tag.final.prom" lith_s3_bytes_total); gets=$(prom "$OUT/$tag.final.prom" 'lith_s3_requests_total{op="get",status="ok"}')
  local dist; dist=$(prom "$OUT/$tag.final.prom" lith_distinct_bytes_read)
  local pr; pr=$(prom "$OUT/$tag.final.prom" 'lith_fill_bytes_total{kind="prefetch-range"}')
  awk -v t="$tag" -v a="$t0" -v b="$t1" -v s="$s3" -v g="${gets:-NA}" -v z="${sz:-0}" -v d="${dist:-0}" -v pr="${pr:-0}" 'BEGIN{
    w=b-a; printf "CELL %s wall=%.3f s3_MB=%.1f gets=%s distinct_MB=%.1f prefetch_range_MB=%.1f", t, w, s/1e6, g, d/1e6, pr/1e6
    if (z>0) printf " size_MB=%.1f s3_over_size=%.3f MBps=%.0f", z/1e6, s/z, z/w/1e6
    printf "\n"}'
}

echo "=== gate 5f-P35dd  $(date -u +%FT%TZ)  lith=$(md5sum "$L" | cut -c1-12)"
for rep in $(seq 1 "$REPS"); do
  for arm in D A B AB; do cell "D-$arm-$rep" "$arm" D; done
done
echo "=== done $(date -u +%FT%TZ)"
