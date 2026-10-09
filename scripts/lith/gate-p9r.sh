#!/bin/bash
# 5f-P9r (lith#350): wire TTFB and connection acquisition split by conn=new/reused (v1.9.0). Pre-registered.
G=/scratch/lith-gates; B=${B:-$G/v190/lith_linux_arm64}; MNT=/scratch/mnt/p9r; OUT=${OUT:-$G/p9r}
PYX=/scratch/ncenv/bin/python; READER=$G/gate2nd/reader.py; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
PORT=${PORT:-10500}; mkdir -p "$MNT" "$OUT"
arm() {  # arm TAG W1|W2
  local tag=$1 w=$2; PORT=$((PORT + 1))
  "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn --wire-ttfb > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; return 1; }
  local t0; t0=$(date +%s.%N)
  if [ "$w" = W2 ]; then dd if="$MNT/MERRA2.20190702.A3dyn.05x0625.nc4" of=/dev/null bs=1M status=none
  else local rp=() d; for d in 02 03 04 05 06 07; do $PYX "$READER" "$MNT/MERRA2.201907$d.A3dyn.05x0625.nc4" var1 >/dev/null 2>&1 & rp+=($!); done; wait "${rp[@]}"; fi
  echo "ARM $tag wall=$(echo "$(date +%s.%N) - $t0" | bc)"
  sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"
  fusermount3 -u "$MNT"; for _ in $(seq 1 40); do mountpoint -q "$MNT" || break; sleep 0.5; done
}
echo "=== gate 5f-P9r  $(date -u +%FT%TZ)  lith=$(md5sum "$B" | cut -c1-12)"
for r in 1 2 3; do arm WT-$r W2; arm W1T-$r W1; done
echo "=== done $(date -u +%FT%TZ)"
