#!/bin/bash
# 5f-P11 (lith#350): P9y pairs with lith at default vs --s3-concurrency 64 (s3bench -workers 64). Pre-registered.
G=/scratch/lith-gates; B=$G/v1110/lith_linux_arm64; S3B=$G/lith-s3bench-384; OUT=${OUT:-$G/p11}; MNT=/scratch/mnt/p11
O=MERRA2.20190702.A3dyn.05x0625.nc4; K=GEOS_0.5x0.625/MERRA2/2019/07/$O; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
mkdir -p "$OUT" "$MNT"; PORT=${PORT:-11500}
pair() { local tag=$1; shift; PORT=$((PORT + 1))
  "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn --wire-ttfb --no-sign-request "$@" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  date -u +%FT%TZ > "$OUT/$tag.when"
  dd if="$MNT/$O" of=/dev/null bs=1M status=none & local dp=$!
  "$S3B" -bucket gcgrid -keys "$K" -workers 64 -part 8388608 -duration 1.5s > "$OUT/$tag.s3bench.txt" 2>&1 & local sp=$!
  wait $dp $sp; sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"; fusermount3 -u "$MNT"; sleep 1; }
echo "=== gate ${GATE:-5f-P11} $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12) s3bench=$(md5sum "$S3B" | cut -c1-12)"
pair WARMUP
if [ "${MODE:-p11}" = p11 ]; then for r in 1 2 3 4 5; do pair A$r; pair B$r --s3-concurrency 64; done
else for r in 1 2 3 4 5; do pair R$r; done; fi
echo "=== done $(date -u +%FT%TZ)"
