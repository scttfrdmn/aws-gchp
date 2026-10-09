#!/bin/bash
# 5f-P9t/P9u (lith#350): -fresh-buffers causal arm, then runtime metrics on W2. Pre-registered in inregion-streams.txt.
G=/scratch/lith-gates; S3B=$G/lith-s3bench-378; B=$G/v1100/lith_linux_arm64; OUT=$G/p9t; MNT=/scratch/mnt/p9t
KEY=GEOS_0.5x0.625/MERRA2/2019/07/MERRA2.20190708.A3dyn.05x0625.nc4; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
mkdir -p "$OUT" "$MNT"; PORT=10700
bench() { local tag=$1 w=$2; shift 2
  "$S3B" -bucket gcgrid -keys "$KEY" -workers "$w" -part 8388608 -duration 1s "$@" > "$OUT/$tag.txt" 2>&1
  echo "ARM $tag $(grep -E '^TTFB' "$OUT/$tag.txt")"; echo "    $(grep -E '^RESULT' "$OUT/$tag.txt")"; }
w2() {  # w2 TAG [scrape]  -- scrape=1 saves the full /metrics every 0.5 s (P9u)
  local tag=$1 sc=${2:-0} spid; PORT=$((PORT + 1))
  "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if [ "$sc" = 1 ]; then mkdir -p "$OUT/$tag.scrapes"; rm -f "$OUT/$tag.stop"
    ( while [ ! -f "$OUT/$tag.stop" ]; do curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.scrapes/$(date +%s.%N).prom"; sleep 0.5; done ) & spid=$!; fi
  sleep 0.6; local t0; t0=$(date +%s.%N); echo "$t0" > "$OUT/$tag.t0"
  dd if="$MNT/MERRA2.20190702.A3dyn.05x0625.nc4" of=/dev/null bs=1M status=none
  date +%s.%N > "$OUT/$tag.t1"; sleep 1
  curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"
  [ "$sc" = 1 ] && { touch "$OUT/$tag.stop"; wait "$spid" 2>/dev/null; }
  fusermount3 -u "$MNT"; sleep 1
  awk -v t="$tag" '/^lith_ttfb_seconds_count /{n=$2} /^lith_ttfb_seconds_bucket\{le="0.05"\}/{b=$2} /^lith_ttfb_seconds_sum /{s=$2}
    END{printf "ARM %s fill n=%d <=50ms=%.1f%% mean=%.1fms\n", t, n, 100*b/n, 1000*s/n}' "$OUT/$tag.final.prom"; }
echo "=== gate 5f-P9t $(date -u +%FT%TZ) s3bench=$(md5sum "$S3B" | cut -c1-12) lith=$(md5sum "$B" | cut -c1-12)"
bench WARMUP 32
for r in 1 2 3; do bench R32-$r 32; bench F32-$r 32 -fresh-buffers; bench R64-$r 64; bench F64-$r 64 -fresh-buffers; w2 W2-$r; done
echo "=== 5f-P9u $(date -u +%FT%TZ)"
for r in 1 2 3; do w2 U-$r 1; done
echo "=== done $(date -u +%FT%TZ)"
