#!/bin/bash
# Gate 5f-P9o/P9p (lith#349 v1.7.0 verify, lith#350 differential probe). Pre-registered in
# data/lith-gates/inregion-streams.txt. Head node, in-region, fresh default mount per arm.
#   MA-W*  workload alone            MS-W*  workload + lith-s3bench 3 s started 0.5 s in
#   SA     lith-s3bench alone        W1 = 6 concurrent var1 readers, W2 = dd of one 1.21 GB object
G=/scratch/lith-gates; B=${B:-$G/v170/lith_linux_arm64}; S3B=${S3B:-$G/lith-s3bench-main}
MNT=/scratch/mnt/p9p; OUT=${OUT:-$G/p9p}; PYX=/scratch/ncenv/bin/python; READER=$G/gate2nd/reader.py
I=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07; KEY=GEOS_0.5x0.625/MERRA2/2019/07/MERRA2.20190708.A3dyn.05x0625.nc4
REPS=${REPS:-3}; PORT=${PORT:-10300}
mkdir -p "$MNT" "$OUT"

cat > "$OUT/sampler.py" <<'PY'
# 2 Hz: lith series + box CPU busy % from /proc/stat. One row per tick.
import os, sys, time, urllib.request
out, stop, url = sys.argv[1], sys.argv[2], sys.argv[3]
K = {'lith_ttfb_seconds_bucket{le="0.025"}': "le025", 'lith_ttfb_seconds_bucket{le="0.05"}': "le050",
     'lith_ttfb_seconds_bucket{le="0.06"}': "le060", 'lith_ttfb_seconds_bucket{le="0.1"}': "le100",
     'lith_ttfb_seconds_bucket{le="0.2"}': "le200", "lith_ttfb_seconds_count": "count",
     "lith_ttfb_median_seconds": "median", "lith_ttfb_floor_seconds": "floor", "lith_ttfb_measured": "measured",
     "lith_readahead_evidence_ratio": "gauge", "lith_s3_inflight": "inflight",
     "lith_prefetch_committed_bytes": "committed", "lith_s3_bytes_total": "s3bytes"}
cols = list(K.values())
def cpu():
    v = [int(x) for x in open("/proc/stat").readline().split()[1:]]
    return sum(v), v[3] + v[4]
f = open(out, "w"); f.write("epoch,cpu_busy_pct," + ",".join(cols) + "\n")
t0 = time.time(); pt, pi = cpu()
while not os.path.exists(stop):
    time.sleep(0.5)
    t, i = cpu(); busy = 100.0 * (1 - (i - pi) / max(t - pt, 1)); pt, pi = t, i
    try: body = urllib.request.urlopen(url, timeout=1).read().decode()
    except Exception: continue
    v = {}
    for ln in body.splitlines():
        if ln.startswith("#"): continue
        k, _, val = ln.rpartition(" ")
        if k in K: v[K[k]] = val
    f.write("%.3f,%.1f,%s\n" % (time.time(), busy, ",".join(v.get(c, "NA") for c in cols))); f.flush()
f.close()
PY

workload() {  # workload W1|W2 — runs to completion
  if [ "$1" = W1 ]; then
    local rp=() d
    for d in 02 03 04 05 06 07; do $PYX "$READER" "$MNT/MERRA2.201907$d.A3dyn.05x0625.nc4" var1 > /dev/null 2>&1 & rp+=($!); done
    wait "${rp[@]}"
  else
    dd if="$MNT/MERRA2.20190702.A3dyn.05x0625.nc4" of=/dev/null bs=1M status=none
  fi
}

s3bench() {  # s3bench TAG — prints the TTFB + RESULT lines with wall offsets
  local t0; t0=$(date +%s.%N)
  "$S3B" -bucket gcgrid -keys "$KEY" -workers 128 -part 8388608 -duration 3s > "$OUT/$1.s3bench.txt" 2>&1
  echo "s3bench_start=$t0 s3bench_end=$(date +%s.%N)" >> "$OUT/$1.s3bench.txt"   # epoch, same clock as sampler t
}

arm() {  # arm TAG W1|W2|none with_s3bench(0|1)
  local tag=$1 w=$2 sb=$3 spid t1; PORT=$((PORT + 1))
  if [ "$w" != none ]; then
    "$B" mount "$I" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn > "$OUT/$tag.mount.log" 2>&1 &
    for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
    mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -3 "$OUT/$tag.mount.log"; return 1; }
    rm -f "$OUT/$tag.stop"; $PYX "$OUT/sampler.py" "$OUT/$tag.csv" "$OUT/$tag.stop" "http://127.0.0.1:$PORT/metrics" & spid=$!
  fi
  T0=$(date +%s.%N)
  if [ "$w" != none ]; then
    workload "$w" & local wp=$!
    if [ "$sb" = 1 ]; then sleep 0.5; s3bench "$tag"; fi
    wait "$wp"
  else
    s3bench "$tag"
  fi
  t1=$(echo "$(date +%s.%N) - $T0" | bc)
  if [ "$w" != none ]; then
    sleep 1; curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$tag.final.prom"
    touch "$OUT/$tag.stop"; wait "$spid" 2>/dev/null
    fusermount3 -u "$MNT"; for _ in $(seq 1 40); do mountpoint -q "$MNT" || break; sleep 0.5; done
  fi
  echo "ARM $tag wall=$t1"
  [ -f "$OUT/$tag.s3bench.txt" ] && grep -E "^TTFB|^RESULT|s3bench_start" "$OUT/$tag.s3bench.txt" | sed 's/^/   /'
}

echo "=== gate 5f-P9o/P9p  $(date -u +%FT%TZ)  lith=$(md5sum "$B" | cut -c1-12) s3bench=$(md5sum "$S3B" | cut -c1-12)"
for r in $(seq 1 "$REPS"); do
  arm MA-W1-$r W1 0; arm MS-W1-$r W1 1; arm MA-W2-$r W2 0; arm MS-W2-$r W2 1; arm SA-$r none 1
done
echo "=== done $(date -u +%FT%TZ)"
