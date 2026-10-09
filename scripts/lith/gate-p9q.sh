#!/bin/bash
# 5f-P9q (lith#350): fill vs wire TTFB (--wire-ttfb, v1.8.0) on the W2 dd burst. Pre-registered in inregion-streams.txt.
G=/scratch/lith-gates; B=${B:-$G/v180/lith_linux_arm64}; MNT=/scratch/mnt/p9q; OUT=${OUT:-$G/p9q}
PYX=/scratch/ncenv/bin/python; READER=$G/gate2nd/reader.py; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
PORT=${PORT:-10400}; mkdir -p "$MNT" "$OUT"
arm() {  # arm TAG W1|W2 [flags]
  local tag=$1 w=$2; shift 2; PORT=$((PORT + 1))
  "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn "$@" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -3 "$OUT/$tag.mount.log"; return 1; }
  local t0; t0=$(date +%s.%N)
  if [ "$w" = W2 ]; then dd if="$MNT/MERRA2.20190702.A3dyn.05x0625.nc4" of=/dev/null bs=1M status=none
  else local rp=() d; for d in 02 03 04 05 06 07; do $PYX "$READER" "$MNT/MERRA2.201907$d.A3dyn.05x0625.nc4" var1 >/dev/null 2>&1 & rp+=($!); done; wait "${rp[@]}"; fi
  local wall; wall=$(echo "$(date +%s.%N) - $t0" | bc)
  sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"
  fusermount3 -u "$MNT"; for _ in $(seq 1 40); do mountpoint -q "$MNT" || break; sleep 0.5; done
  awk -v tag="$tag" -v w="$wall" '/^#/{next}
    /^lith_ttfb_seconds_count /{fc=$2} /^lith_s3_wire_ttfb_seconds_count /{wc=$2}
    /^lith_ttfb_seconds_bucket\{le="0.025"\}/{f25=$2} /^lith_ttfb_seconds_bucket\{le="0.05"\}/{f50=$2} /^lith_ttfb_seconds_bucket\{le="0.1"\}/{f100=$2}
    /^lith_s3_wire_ttfb_seconds_bucket\{le="0.025"\}/{w25=$2} /^lith_s3_wire_ttfb_seconds_bucket\{le="0.05"\}/{w50=$2} /^lith_s3_wire_ttfb_seconds_bucket\{le="0.1"\}/{w100=$2}
    /^lith_s3_bytes_total /{b=$2} /^lith_s3_requests_total/{r+=$2}
    END{ws="wire NA"; if (wc > 0) ws=sprintf("wire n=%d <=25 %.1f%% <=50 %.1f%% <=100 %.1f%%", wc, 100*w25/wc, 100*w50/wc, 100*w100/wc)
        printf "CELL %s wall=%.2f s3_MB=%.1f GETs=%d | fill n=%d <=25 %.1f%% <=50 %.1f%% <=100 %.1f%% | %s\n",
          tag, w, b/1e6, r, fc, 100*f25/fc, 100*f50/fc, 100*f100/fc, ws}' "$OUT/$tag.final.prom"
}
echo "=== gate 5f-P9q  $(date -u +%FT%TZ)  lith=$(md5sum "$B" | cut -c1-12)"
for r in 1 2 3; do arm WB-$r W2; arm WT-$r W2 --wire-ttfb; arm W1T-$r W1 --wire-ttfb; done
echo "=== done $(date -u +%FT%TZ)"
