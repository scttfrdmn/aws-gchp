#!/bin/bash
# 5f-P10 (lith#381): first-process ladder. Pre-registered in inregion-streams.txt. >= 10 min idle before each step.
G=/scratch/lith-gates; S3B=$G/lith-s3bench-384; OUT=$G/p10; IDLE=${IDLE:-600}
K=GEOS_0.5x0.625/MERRA2/2019/07/MERRA2.20190708.A3dyn.05x0625.nc4; mkdir -p "$OUT"
M() { "$S3B" -bucket gcgrid -keys "$K" -workers 32 -part 8388608 -duration 1s "$@" > "$OUT/$1.M.txt" 2>&1; }
step() { local tag=$1; shift; sleep "$IDLE"
  local t0 t1; t0=$(date +%s.%N)
  case "$tag" in
    b)  "$S3B" -bucket gcgrid -keys "$K" -workers 1 -part 8388608 -duration 200ms > "$OUT/b.prep.txt" 2>&1 ;;
    c)  aws s3api head-object --no-sign-request --region us-east-1 --bucket gcgrid --key "$K" > "$OUT/c.prep.txt" 2>&1 ;;
    d)  for h in gcgrid.s3.amazonaws.com s3.us-east-1.amazonaws.com gcgrid.s3.us-east-1.amazonaws.com; do getent hosts $h; done > "$OUT/d.prep.txt" 2>&1 ;;
  esac
  t1=$(date +%s.%N)
  local w=(); [ "$tag" = e ] && w=(-warmup 1s)
  "$S3B" -bucket gcgrid -keys "$K" -workers 32 -part 8388608 -duration 1s "${w[@]}" > "$OUT/$tag.M.txt" 2>&1
  echo "STEP $tag prep=$(echo "$t1 - $t0" | bc)s gap_to_M~0 $(date -u +%T) | $(grep -E '^TTFB' "$OUT/$tag.M.txt" | sed 's/  */ /g' | cut -c1-200)"
  grep -E "^SPLIT" "$OUT/$tag.M.txt" | sed 's/^/     /'; }
echo "=== gate 5f-P10 $(date -u +%FT%TZ) s3bench=$(md5sum "$S3B" | cut -c1-12) idle=${IDLE}s"
for s in a1 b c d e a2; do step "$s"; done
echo "=== done $(date -u +%FT%TZ)"
