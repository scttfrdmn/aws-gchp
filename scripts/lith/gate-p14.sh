#!/bin/bash
# 5f-P14 (lith#350): signed vs anonymous lith W2, two mounts at the same instant. Pre-registered.
G=/scratch/lith-gates; B=$G/v1110/lith_linux_arm64; OUT=$G/p14; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
O=MERRA2.20190702.A3dyn.05x0625.nc4; MS=/scratch/mnt/p14s; MA=/scratch/mnt/p14a; mkdir -p "$OUT" "$MS" "$MA"; PORT=13000
rep() { local tag=$1 ps pa; PORT=$((PORT + 2)); ps=$PORT; pa=$((PORT + 1))
  "$B" mount "$I" "$MS" --metrics ":$ps" --nic-gbps 50 --log-level warn --wire-ttfb > "$OUT/$tag.S.mount.log" 2>&1 &
  "$B" mount "$I" "$MA" --metrics ":$pa" --nic-gbps 50 --log-level warn --wire-ttfb --no-sign-request > "$OUT/$tag.A.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MS" && mountpoint -q "$MA" && break; sleep 1; done
  date -u +%FT%TZ > "$OUT/$tag.when"
  dd if="$MS/$O" of=/dev/null bs=1M status=none & local d1=$!; dd if="$MA/$O" of=/dev/null bs=1M status=none & local d2=$!
  wait $d1 $d2; sleep 1
  curl -s "http://127.0.0.1:$ps/metrics" > "$OUT/$tag.S.final.prom"; curl -s "http://127.0.0.1:$pa/metrics" > "$OUT/$tag.A.final.prom"
  fusermount3 -u "$MS"; fusermount3 -u "$MA"; sleep 1
  for k in S A; do awk -v t="$tag.$k" '/^#/{next} /^lith_ttfb_seconds_count /{n=$2} /^lith_ttfb_seconds_bucket\{le="0.05"\}/{b=$2} /^lith_ttfb_seconds_sum /{s=$2} /^lith_s3_endpoint_ttfb_seconds_sum/{es+=$2} /^lith_s3_endpoint_ttfb_seconds_count/{ec+=$2}
    END{printf "%s fill n=%d <=50ms=%.1f%% mean=%.1fms endpoint=%.1fms\n", t, n, 100*b/n, 1000*s/n, 1000*es/ec}' "$OUT/$tag.$k.final.prom"; done; }
echo "=== gate 5f-P14 $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12)"
rep WARMUP; for r in 1 2 3 4 5; do rep R$r; done
echo "=== done $(date -u +%FT%TZ)"
