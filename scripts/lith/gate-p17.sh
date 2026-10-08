#!/bin/bash
# 5f-P17 (lith#381): lith W2 gate ON (default) vs OFF (-1), two anon mounts at the same instant. Pre-registered.
G=/scratch/lith-gates; B=$G/v1110/lith_linux_arm64; OUT=$G/p17; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
O=MERRA2.20190702.A3dyn.05x0625.nc4; M1=/scratch/mnt/p17on; M2=/scratch/mnt/p17off; mkdir -p "$OUT" "$M1" "$M2"; PORT=13200
rep() { local tag=$1 p1 p2; PORT=$((PORT + 2)); p1=$PORT; p2=$((PORT + 1))
  "$B" mount "$I" "$M1" --metrics ":$p1" --nic-gbps 50 --log-level warn --wire-ttfb --no-sign-request > "$OUT/$tag.ON.mount.log" 2>&1 &
  "$B" mount "$I" "$M2" --metrics ":$p2" --nic-gbps 50 --log-level warn --wire-ttfb --no-sign-request --readahead-evidence-ratio -1 > "$OUT/$tag.OFF.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$M1" && mountpoint -q "$M2" && break; sleep 1; done
  date -u +%FT%TZ > "$OUT/$tag.when"
  dd if="$M1/$O" of=/dev/null bs=1M status=none & local d1=$!; dd if="$M2/$O" of=/dev/null bs=1M status=none & local d2=$!
  wait $d1 $d2; sleep 1
  curl -s "http://127.0.0.1:$p1/metrics" > "$OUT/$tag.ON.final.prom"; curl -s "http://127.0.0.1:$p2/metrics" > "$OUT/$tag.OFF.final.prom"
  fusermount3 -u "$M1"; fusermount3 -u "$M2"; sleep 1
  for k in ON OFF; do awk -v t="$tag.$k" '/^#/{next} /^lith_ttfb_seconds_count /{n=$2} /^lith_ttfb_seconds_bucket\{le="0.05"\}/{b=$2}
    /^lith_s3_endpoint_ttfb_seconds_sum/{es+=$2} /^lith_s3_endpoint_ttfb_seconds_count/{ec+=$2}
    /^lith_s3_conn_acquire_seconds_count\{conn="new"\}/{nn=$2} /^lith_s3_conn_acquire_seconds_count\{conn="reused"\}/{rn=$2}
    /^lith_s3_conn_acquire_seconds_sum\{conn="reused"\}/{rs=$2} /^lith_s3_bytes_total /{sb=$2}
    END{printf "%s fill n=%d <=50ms=%.1f%% endpoint=%.1fms new-share=%.1f%% reused-acq=%.2fms s3_MB=%.0f\n", t, n, 100*b/n, 1000*es/ec, 100*nn/(nn+rn), (rn?1000*rs/rn:0), sb/1e6}' "$OUT/$tag.$k.final.prom"; done; }
echo "=== gate 5f-P17 $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12)"
rep WARMUP; for r in 1 2 3 4 5; do rep R$r; done
echo "=== done $(date -u +%FT%TZ)"
