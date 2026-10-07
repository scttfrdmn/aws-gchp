#!/bin/bash
# 5f-P9s (lith#350): lith-s3bench at W2's burst shape vs steady, fresh process each; W2 same-session reference.
G=/scratch/lith-gates; S3B=$G/lith-s3bench-main; B=$G/v190/lith_linux_arm64; OUT=$G/p9s; MNT=/scratch/mnt/p9s
KEY=GEOS_0.5x0.625/MERRA2/2019/07/MERRA2.20190708.A3dyn.05x0625.nc4; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
mkdir -p "$OUT" "$MNT"; PORT=10600
bench() { "$S3B" -bucket gcgrid -keys "$KEY" -workers "$2" -part 8388608 -duration "$3" > "$OUT/$1.txt" 2>&1
  echo "ARM $1 $(grep -E '^TTFB' "$OUT/$1.txt")"; echo "    $(grep -E '^RESULT' "$OUT/$1.txt")"; }
w2() { PORT=$((PORT + 1)); "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn > "$OUT/$1.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  dd if="$MNT/MERRA2.20190702.A3dyn.05x0625.nc4" of=/dev/null bs=1M status=none
  sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$1.final.prom"; fusermount3 -u "$MNT"; sleep 1
  awk -v t="$1" '/^lith_ttfb_seconds_count /{n=$2} /^lith_ttfb_seconds_bucket\{le="0.025"\}/{a=$2} /^lith_ttfb_seconds_bucket\{le="0.05"\}/{b=$2} /^lith_ttfb_seconds_sum /{s=$2}
    END{printf "ARM %s fill n=%d <=25ms=%.1f%% <=50ms=%.1f%% mean=%.1fms\n", t, n, 100*a/n, 100*b/n, 1000*s/n}' "$OUT/$1.final.prom"; }
echo "=== gate 5f-P9s $(date -u +%FT%TZ) s3bench=$(md5sum "$S3B" | cut -c1-12) lith=$(md5sum "$B" | cut -c1-12)"
for r in 1 2 3; do bench B32-$r 32 1s; bench B64-$r 64 1s; bench S64-$r 64 6s; w2 W2-$r; done
echo "=== done $(date -u +%FT%TZ)"
