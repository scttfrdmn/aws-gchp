#!/bin/bash
# Gate 5f-N (lith#301/#303): is the window x handles PROXY tight, or is the divisor
# throttling a budget that is nearly empty?
#
# #303 landed the gauge that makes this answerable -- lith_prefetch_resident_bytes, the
# bytes --prefetch-budget actually bounds -- and upstream stated the decision rule and
# said it needs a box:
#
#   "If resident sits far below 4.128 GB at N=1, the proxy is over-conservative and the
#    divisor is costing 6.38x for nothing. If it sits near it, candidate 1 is dangerous
#    and candidate 2 is the answer."
#
# They also said the blockstore alone can't produce the consumption half without
# reimplementing the FUSE read loop, so it has to be a real mount with a real streaming
# reader and the gauge scraped over time. I have the box up and the 5f-M harness, so this
# is their experiment at ~$0.01 rather than a cluster they were deferring.
#
# ARM   the netCDF/HEMCO shape from 5f-M arm B: 1 streaming reader (dd, 3.78 GB object)
#       + (N-1) descriptors held open after a 4 KiB header read, never streamed.
#       N in 1,2,4,16,64,256  -- upstream's 1/16/256 plus the trend points, free.
#
# Scraped at 10 Hz for the whole read, from the mount's OWN gauges, so the charge and the
# held quantity are both measured and neither is derived by me (5f-M's withdrawn estimator
# was a derivation; this is not):
#       lith_prefetch_resident_bytes   held      (#303)
#       lith_prefetch_budget_bytes     the limit (#303)
#       lith_readahead_window_blocks   realized window (#302)
#       lith_open_handles              the divisor     (#302)
#   tightness = resident / (window x handles x block_size), all four measured.
#
# CAVEAT, and it cuts toward the finding rather than away: blockstore.go:809 marks a chunk
# prefetched at DISPATCH (LoadOrStore before the fill), and dropPrefetched removes it on
# consume / evict-unread / failed-fill. So the gauge counts dispatched-and-unconsumed,
# which INCLUDES bytes still in flight. It is therefore an UPPER BOUND on bytes resident
# in RAM -- which only strengthens a finding that it sits far below the budget.
#
# Head node only, in-region, no egress. 6 cells x 3 reps x 3.78 GB = 68 GB of GETs.
set -u

B=${B:-/scratch/lith-gates/lith-303}
OUT=${OUT:-/scratch/lith-gates/gate-resident}
MNT=${MNT:-/scratch/mnt/r}
PYX=${PYX:-/scratch/ncenv/bin/python}
REPS=${REPS:-3}
HZ=${HZ:-10}
PORT_BASE=${PORT_BASE:-9700}
LOGLVL=${LOGLVL:-info}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}

OBJS=(GEOSFP.201907{01..16}.A3dyn.025x03125.nc)

mkdir -p "$OUT" "$MNT"

cat > "$OUT/holder.py" <<'PY'
import os, sys, time
n, ready, stop = int(sys.argv[1]), sys.argv[2], sys.argv[3]
paths = sys.argv[4:]
fds = []
for i in range(n):
    fd = os.open(paths[i % len(paths)], os.O_RDONLY)
    os.pread(fd, 4096, 0)        # the netCDF header-then-sit shape
    fds.append(fd)
with open(ready, "w") as f:
    f.write("%d\n" % len(fds))
while not os.path.exists(stop):
    time.sleep(0.2)
for fd in fds:
    os.close(fd)
PY

cat > "$OUT/sampler.py" <<'PY'
# Scrape the four gauges at HZ and write a timestamped CSV. urllib, not curl: one
# process for the whole cell, so the sample cadence is not a fork storm.
import sys, time, urllib.request
url, out, hz, stop = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
import os
WANT = ("lith_prefetch_resident_bytes", "lith_prefetch_budget_bytes",
        "lith_readahead_window_blocks", "lith_open_handles")
f = open(out, "w", buffering=1)
f.write("t,resident_bytes,budget_bytes,window_blocks,open_handles\n")
t0 = time.time()
period = 1.0 / hz
while not os.path.exists(stop):
    try:
        body = urllib.request.urlopen(url, timeout=2).read().decode()
    except Exception:
        time.sleep(period); continue
    v = {}
    for line in body.splitlines():
        if line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) == 2 and parts[0] in WANT:
            v[parts[0]] = parts[1]
    if v:
        f.write("%.3f,%s,%s,%s,%s\n" % (
            time.time() - t0,
            v.get("lith_prefetch_resident_bytes", ""), v.get("lith_prefetch_budget_bytes", ""),
            v.get("lith_readahead_window_blocks", ""), v.get("lith_open_handles", "")))
    time.sleep(period)
f.close()
PY

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
run_cell() {
  local nh=$1 rep=$2
  local tag="n$nh-$rep"
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag.ready" "$OUT/$tag.stop" "$OUT/$tag.sstop"
  umount_wait
  $B mount "$PREFIX" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level "$LOGLVL" \
      ${XFLAGS:-} > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if ! mountpoint -q "$MNT"; then echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; fi

  # sampler first, so the establishment transient is in the series
  $PYX "$OUT/sampler.py" "http://127.0.0.1:$PORT/metrics" "$OUT/$tag.samp.csv" "$HZ" \
      "$OUT/$tag.sstop" > "$OUT/$tag.samp.log" 2>&1 &
  local samp_pid=$!
  sleep 1

  local hold_pid="" held=0
  if [ "$nh" -gt 1 ]; then
    local plist=() i
    for ((i = 0; i < ${#OBJS[@]}; i++)); do plist+=("$MNT/${OBJS[$i]}"); done
    $PYX "$OUT/holder.py" "$((nh - 1))" "$OUT/$tag.ready" "$OUT/$tag.stop" "${plist[@]}" \
        > "$OUT/$tag.holder.log" 2>&1 &
    hold_pid=$!
    for _ in $(seq 1 240); do [ -f "$OUT/$tag.ready" ] && break; sleep 0.5; done
    held=$(cat "$OUT/$tag.ready" 2>/dev/null || echo 0)
  fi

  local s e wall
  s=$(date +%s.%N)
  dd if="$MNT/${OBJS[0]}" of=/dev/null bs=1M status=none
  e=$(date +%s.%N)
  wall=$(echo "$e - $s" | bc)

  touch "$OUT/$tag.sstop"; wait "$samp_pid" 2>/dev/null
  [ -n "$hold_pid" ] && { touch "$OUT/$tag.stop"; wait "$hold_pid" 2>/dev/null; }

  local bytes; bytes=$(stat -Lc%s "$MNT/${OBJS[0]}" 2>/dev/null || echo 0)
  echo "CELL $tag held=$held wall=$wall bytes=$bytes samples=$(($(wc -l < "$OUT/$tag.samp.csv") - 1))"
  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | grep -E \
    '^lith_(s3_bytes_total|s3_requests_total|prefetch_issued_total|prefetch_used_total|prefetch_evicted_unread_total|prefetch_resident_bytes|prefetch_budget_bytes)' \
    | awk -v t="$tag" '{printf "MET %s %s %s\n", t, $1, $2}'
  umount_wait
}

echo "=== gate 5f-N  $(date -u +%FT%TZ)  reps=$REPS  hz=$HZ ==="
echo "  lith: $B"
echo "  host: $(hostname) $(nproc) cores  MemTotal $(awk '/MemTotal/{print $2}' /proc/meminfo) kB"
echo "  prefix: $PREFIX"
for rep in $(seq 1 "$REPS"); do
  for nh in ${N_LIST:-1 2 4 16 64 256}; do run_cell "$nh" "$rep"; done
done
echo "=== done $(date -u +%FT%TZ) ==="
