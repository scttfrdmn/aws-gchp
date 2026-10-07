#!/bin/bash
# 5f-P9y (lith#350): lith W2 and lith-s3bench on the SAME key, anonymous, started at the same instant.
G=/scratch/lith-gates; B=$G/v1110/lith_linux_arm64; S3B=$G/lith-s3bench-383; OUT=$G/p9y; MNT=/scratch/mnt/p9y
O=MERRA2.20190702.A3dyn.05x0625.nc4; K=GEOS_0.5x0.625/MERRA2/2019/07/$O; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
mkdir -p "$OUT" "$MNT"; PORT=11100
rep() { local tag=$1; PORT=$((PORT + 1))
  "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn --wire-ttfb --no-sign-request > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  date +%s.%N > "$OUT/$tag.t0"
  dd if="$MNT/$O" of=/dev/null bs=1M status=none & local dp=$!
  "$S3B" -bucket gcgrid -keys "$K" -workers 64 -part 8388608 -duration 1.5s > "$OUT/$tag.s3bench.txt" 2>&1 & local sp=$!
  wait $dp; date +%s.%N > "$OUT/$tag.t_dd"; wait $sp; date +%s.%N > "$OUT/$tag.t_sb"
  sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"; fusermount3 -u "$MNT"; sleep 1; echo "REP $tag done"; }
echo "=== gate 5f-P9y $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12) s3bench=$(md5sum "$S3B" | cut -c1-12)"
rep WARMUP; for r in 1 2 3 4 5; do rep R$r; done
echo "=== done $(date -u +%FT%TZ)"
