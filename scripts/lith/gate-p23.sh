#!/bin/bash
# 5f-P23 (lith#313 + #391): pressure-gate default under evidence-gate off, S6 and D16 shapes. Pre-registered.
G=/scratch/lith-gates; B=$G/v1120/lith_linux_arm64; OUT=$G/p23; MNT=/scratch/mnt/p23; PYX=/scratch/ncenv/bin/python
READER=$G/gate2nd/reader.py; mkdir -p "$OUT" "$MNT"; PORT=13800
cell() {  # cell TAG SHAPE flags...
  local tag=$1 shape=$2; shift 2; PORT=$((PORT + 1)); local pre objs=() i
  if [ "$shape" = S6 ]; then pre=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07; for i in 02 03 04 05 06 07; do objs+=("MERRA2.201907$i.A3dyn.05x0625.nc4"); done
  else pre=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07; for i in $(seq -w 1 16); do objs+=("GEOSFP.201907$i.A3dyn.025x03125.nc"); done; fi
  "$B" mount "$pre" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level info --no-sign-request "$@" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; return 1; }
  rm -f "$OUT/$tag.stop"
  ( while [ ! -f "$OUT/$tag.stop" ]; do curl -s --max-time 1 "http://127.0.0.1:$PORT/metrics" | awk -v t="$(date +%s.%N)" '
      /^lith_prefetch_pressure /{p=$2} /^lith_prefetch_pressure_held_total /{h=$2} /^lith_prefetch_evicted_unread_total /{e=$2} /^lith_prefetch_committed_bytes /{c=$2}
      END{if (p!="") printf "%s,%s,%s,%s,%s\n", t, p, h, e, c}' >> "$OUT/$tag.ts.csv"; sleep 0.5; done ) & local sp=$!
  local t0 rp=() o; t0=$(date +%s.%N)
  for o in "${objs[@]}"; do
    ( s=$(date +%s.%N); if [ "$shape" = S6 ]; then $PYX "$READER" "$MNT/$o" var1 >/dev/null 2>&1; else dd if="$MNT/$o" of=/dev/null bs=1M status=none; fi
      echo "$o $(echo "$(date +%s.%N) - $s" | bc)" >> "$OUT/$tag.walls" ) & rp+=($!)
  done
  wait "${rp[@]}"; local w; w=$(echo "$(date +%s.%N) - $t0" | bc); sleep 1
  curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"; touch "$OUT/$tag.stop"; wait $sp
  fusermount3 -u "$MNT"; for _ in $(seq 1 40); do mountpoint -q "$MNT" || break; sleep 0.5; done
  local adm; adm=$(grep -o '"msg":"prefetch admission".*' "$OUT/$tag.mount.log" | head -1 | cut -c1-260)
  awk -v t="$tag" -v w="$w" '{x=$2+0; if(n==0||x<mn)mn=x; if(x>mx)mx=x; n++} END{printf "CELL %s wall=%.1fs readers=%d rmin=%.1f rmax=%.1f spread=%.2f", t, w, n, mn, mx, mx/mn}' "$OUT/$tag.walls"
  awk -F, '{if($2>p)p=$2} END{printf " peak_pressure=%.3f", p}' "$OUT/$tag.ts.csv"
  awk '/^lith_prefetch_evicted_unread_total /{e=$2} /^lith_prefetch_pressure_held_total /{h=$2} /^lith_s3_bytes_total /{b=$2} END{printf " evicted=%d held=%d s3_GB=%.2f\n", e, h, b/1e9}' "$OUT/$tag.final.prom"
  echo "    admission: ${adm:-<no prefetch admission line>}"; }
echo "=== gate 5f-P23 $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12)"
for shape in S6 D16; do for r in 1 2; do
  cell "$shape-A-$r" $shape; cell "$shape-B-$r" $shape --readahead-evidence-ratio -1
  cell "$shape-C-$r" $shape --readahead-evidence-ratio -1 --prefetch-pressure-max -1
done; done
echo "=== done $(date -u +%FT%TZ)"
