#!/bin/bash
# 5f-P15 (lith#381): same-process warm-up threshold (-warmup-workers). Pre-registered. >= 10 min idle before each step.
G=/scratch/lith-gates; S3B=$G/lith-s3bench-385; OUT=$G/p15; IDLE=${IDLE:-600}
K=GEOS_0.5x0.625/MERRA2/2019/07/MERRA2.20190708.A3dyn.05x0625.nc4; mkdir -p "$OUT"
M() { local tag=$1; shift; sleep "$IDLE"
  "$S3B" -bucket gcgrid -keys "$K" -workers 32 -part 8388608 -duration 1s "$@" > "$OUT/$tag.M.txt" 2>&1
  echo "STEP $tag $(date -u +%T) | $(grep -E '^TTFB' "$OUT/$tag.M.txt" | sed 's/  */ /g' | cut -c1-190)"; grep -E "^SPLIT" "$OUT/$tag.M.txt" | sed 's/^/     /'; }
echo "=== gate 5f-P15 $(date -u +%FT%TZ) s3bench=$(md5sum "$S3B" | cut -c1-12) idle=${IDLE}s"
M a; M w1 -warmup 1s -warmup-workers 1; M w4 -warmup 1s -warmup-workers 4; M w32 -warmup 1s -warmup-workers 32
echo "=== done $(date -u +%FT%TZ)"
