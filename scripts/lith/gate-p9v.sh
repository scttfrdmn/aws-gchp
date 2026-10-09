#!/bin/bash
# 5f-P9v (lith#350): W2 mount-alone with --wire-ttfb on v1.11.0 -- acquire / write / endpoint / wire per conn label.
G=/scratch/lith-gates; B=${B:-$G/v1110/lith_linux_arm64}; OUT=$G/p9v; MNT=/scratch/mnt/p9v
I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07; mkdir -p "$OUT" "$MNT"; PORT=10800
w2() { PORT=$((PORT + 1)); "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn --wire-ttfb > "$OUT/$1.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  dd if="$MNT/MERRA2.20190702.A3dyn.05x0625.nc4" of=/dev/null bs=1M status=none
  sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$1.final.prom"; fusermount3 -u "$MNT"; sleep 1; echo "ARM $1 done"; }
echo "=== gate 5f-P9v $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12)"
w2 WARMUP; for r in 1 2 3; do w2 W2-$r; done
echo "=== done $(date -u +%FT%TZ)"
