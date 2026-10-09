#!/bin/bash
# Gate 5f-P9k (lith#349 C3/C4): TTFB floor cross-region, idle (sequential) vs 6 concurrent readers,
# plus the same concurrent read in-region as a control. Pre-registered in data/lith-gates/inregion-streams.txt.
# Each cell: one fresh default v1.5.0 mount, 2 Hz scrape (p9j sampler), final scrape.
G=/scratch/lith-gates; B=${B:-$G/v150/lith_linux_arm64}; MNT=/scratch/mnt/p9k; OUT=${OUT:-$G/p9k}
PYX=/scratch/ncenv/bin/python; READER=$G/gate2nd/reader.py; SAMPLER=${SAMPLER:-$G/p9j/sampler.py}
X=s3://gchp-lith-xregion-usw2-942542972736/merra2; I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
DAYS="02 03 04 05 06 07"; PORT=${PORT:-9960}
mkdir -p "$MNT" "$OUT"

cell() {  # cell TAG PREFIX seq|conc [extra mount args]
  local tag=$1 prefix=$2 mode=$3 extra=${4:-} d t0 t1; PORT=$((PORT + 1))
  "$B" mount "$prefix" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn $extra > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -3 "$OUT/$tag.mount.log"; return 1; }
  rm -f "$OUT/$tag.stop"
  $PYX "$SAMPLER" "$OUT/$tag.ttfb.csv" 2 "$OUT/$tag.stop" "$tag=http://127.0.0.1:$PORT/metrics" &
  local spid=$!; t0=$(date +%s.%N)
  if [ "$mode" = seq ]; then
    for d in $DAYS; do $PYX "$READER" "$MNT/MERRA2.201907$d.A3dyn.05x0625.nc4" var1 > "$OUT/$tag.$d.reader" 2>&1; done
  else
    local rp=()   # reader pids only: a bare `wait` would also wait on the backgrounded mount
    for d in $DAYS; do $PYX "$READER" "$MNT/MERRA2.201907$d.A3dyn.05x0625.nc4" var1 > "$OUT/$tag.$d.reader" 2>&1 & rp+=($!); done
    wait "${rp[@]}"
  fi
  t1=$(date +%s.%N)
  curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"
  touch "$OUT/$tag.stop"; wait "$spid" 2>/dev/null
  fusermount3 -u "$MNT"; for _ in $(seq 1 40); do mountpoint -q "$MNT" || break; sleep 0.5; done
  awk -v tag="$tag" -v w="$(echo "$t1 - $t0" | bc)" '/^#/{next}
    /^lith_ttfb_seconds_bucket\{le="0.025"\}/{a=$2} /^lith_ttfb_seconds_bucket\{le="0.06"\}/{b=$2}
    /^lith_ttfb_seconds_bucket\{le="0.1"\}/{c=$2} /^lith_ttfb_seconds_count /{n=$2} /^lith_s3_bytes_total /{s=$2}
    /^lith_ttfb_median_seconds /{m=$2}
    END{printf "CELL %s wall=%.1f n=%d le025=%d (%.1f%%) le060=%d (%.1f%%) le100=%d (%.1f%%) median_ms=%.1f s3_MB=%.1f\n",
        tag, w, n, a, 100*a/n, b, 100*b/n, c, 100*c/n, m*1000, s/1e6}' "$OUT/$tag.final.prom"
  awk -F, 'NR>1 && $9>m{m=$9} END{print "  inflight max (2 Hz): " m}' "$OUT/$tag.ttfb.csv"
}

echo "=== gate 5f-P9k  $(date -u +%FT%TZ)  B=$(md5sum "$B" | cut -c1-12)"
for c in ${CELLS:-C3-xidle:X:seq C4-xconc:X:conc C4i-iconc:I:conc}; do
  IFS=: read -r tag where mode extra <<< "$c"; [ "$where" = X ] && pre=$X || pre=$I
  cell "$tag" "$pre" "$mode" "${extra//,/ }"   # extra mount args, comma-separated
done
echo "=== done $(date -u +%FT%TZ)"
