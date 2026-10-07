#!/bin/bash
# 5f-P9w (lith#350): signed vs anonymous, lith and s3bench, same key. Pre-registered in inregion-streams.txt.
G=/scratch/lith-gates; S3B=$G/lith-s3bench-378; B=$G/v1110/lith_linux_arm64; OUT=$G/p9w; MNT=/scratch/mnt/p9w
K=GEOS_0.5x0.625/MERRA2/2019/07/MERRA2.20190702.A3dyn.05x0625.nc4; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
mkdir -p "$OUT" "$MNT"; PORT=10900
bench() { local tag=$1; shift; "$S3B" -bucket gcgrid -keys "$K" -workers 64 -part 8388608 -duration 1s "$@" > "$OUT/$tag.txt" 2>&1
  echo "ARM $tag $(grep -E '^TTFB' "$OUT/$tag.txt" | sed 's/  */ /g')"; grep -iE "error|denied" "$OUT/$tag.txt" | head -2; }
w2() { local tag=$1; shift; PORT=$((PORT + 1))
  "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn --wire-ttfb "$@" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  dd if="$MNT/MERRA2.20190702.A3dyn.05x0625.nc4" of=/dev/null bs=1M status=none
  sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"; fusermount3 -u "$MNT"; sleep 1
  awk -v t="$tag" '/^#/{next} /^lith_ttfb_seconds_count /{n=$2} /^lith_ttfb_seconds_bucket\{le="0.05"\}/{b=$2} /^lith_ttfb_seconds_sum /{s=$2}
    /^lith_s3_endpoint_ttfb_seconds_sum/{es+=$2} /^lith_s3_endpoint_ttfb_seconds_count/{ec+=$2}
    END{printf "ARM %s fill n=%d <=50ms=%.1f%% mean=%.1fms | endpoint mean %.1fms (n=%d)\n", t, n, 100*b/n, 1000*s/n, 1000*es/ec, ec}' "$OUT/$tag.final.prom"; }
echo "=== gate 5f-P9w $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12) s3bench=$(md5sum "$S3B" | cut -c1-12)"
bench WARMUP
for r in 1 2 3; do w2 LS-$r; w2 LA-$r --no-sign-request; bench BA-$r; bench BS-$r -no-sign-request=false; done
echo "=== done $(date -u +%FT%TZ)"
