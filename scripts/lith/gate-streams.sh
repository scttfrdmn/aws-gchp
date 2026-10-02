#!/bin/bash
# Gate 5f-P (lith#301 closed / #312 open): does counting STREAMS instead of DESCRIPTORS
# restore arm A, fix the held-descriptor shape, and how big is the residual it leaves?
#
# Upstream reverted byte-exact admission (#309) after 5f-O measured it 5.66-11x slower, then
# fixed the divisor's INPUT instead (#311, merged 88d0c6f): N in
# clamp(budgetBlocks/N, 2, maxReadahead) is now the count of handles the detector is
# prefetching for -- prefetch.Sequential -- maintained by +1/-1 deltas from each read's
# detector transition and from Release, instead of len(f.handles).
#
# They asked for two things and said not to spend without them, so this is both, plus the
# one they said they'd most want contradicted.
#
#   1. Arm A again. Prediction: UNCHANGED from the pre-ceeb2b7 baseline on concurrent
#      readers, because every reader there streams, so N is the reader count either way.
#      Their falsifier, stated by them: "if the concurrent arms move at all, the delta
#      accounting is wrong, and I'd want that before anything else."
#   2. streaming_handles vs open_handles on the shape where descriptors dominate.
#
# The arms below are 5f-M's, because 5f-M is where the defect was measured and its numbers
# are banked at --nic-gbps 50: a single streamer is 3.19 s / 1185 MB/s at a 223-block window,
# and the same streamer behind 255 held descriptors is 20.34 s / 186 MB/s at the floor of 2.
# Same objects, same flags, same box -- so OLD here should reproduce those and NEW is the test.
#
# WHAT SEPARATES #301 FROM #312, which is the part worth the money:
#
#   arm C  holds descriptors OPEN and NEVER READS them          -> #301's shape exactly
#   arm B  holds descriptors open after ONE 4 KiB pread          -> #312's shape exactly
#
# #311 removes never-read descriptors from the divisor by construction. Whether it helps
# arm B depends on something no one has measured: does a single 4 KiB read put the detector
# in Sequential? If it does not, B is fixed too and #312 is a footnote. If it does, B stays
# at the floor and the residual upstream documented as a limitation is the DOMINANT term on
# every netCDF workload, which is the thing they said would change what they build next.
# lith_streaming_handles reads out which, so the gauge decides it and the wall confirms it.
#
# ARMS   --nic-gbps 50 (as 5f-M), fresh cold mount per cell, OLD and NEW back to back
#   S           1 streamer alone                              the ceiling, N=1 both binaries
#   R    N=16   16 concurrent streamers, whole objects         ARM A -- upstream's falsifier
#   C8   N=8    1 streamer + 7 opened, never read
#   C256 N=256  1 streamer + 255 opened, never read            the 6.38x cell from 5f-M
#   B8   N=8    1 streamer + 7 header-read then idle
#   B64  N=64   "
#   B256 N=256  "                                              #312's magnitude
#
# Head node, in-region, already running. R is the only expensive arm (60 GB/cell).
set -u

OUT=${OUT:-/scratch/lith-gates/gate-streams}
MNT=${MNT:-/scratch/mnt/s}
PYX=${PYX:-/scratch/ncenv/bin/python}
REPS=${REPS:-2}
PORT_BASE=${PORT_BASE:-9700}
LOGLVL=${LOGLVL:-info}
HZ=${HZ:-5}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}
STREAM_MB=${STREAM_MB:-0}   # 0 = whole object, so S/B/C compare directly to 5f-M's banked walls

B_OLD=${B_OLD:-/scratch/lith-gates/lith-304}   # 52138ee, the descriptor divisor
B_NEW=${B_NEW:-/scratch/lith-gates/lith-311}   # 88d0c6f, the stream divisor

OBJS=(GEOSFP.201907{01..16}.A3dyn.025x03125.nc)

mkdir -p "$OUT" "$MNT"

# Sampler: the two handle counts are the mechanism readout, the window is what they produce.
cat > "$OUT/sampler.py" <<'PY'
import os, sys, time, urllib.request
url, out, hz, stop = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
WANT = ("lith_open_handles", "lith_streaming_handles", "lith_readahead_window_blocks",
        "lith_prefetch_committed_bytes", "lith_prefetch_budget_bytes")
f = open(out, "w")
f.write("t," + ",".join(w.replace("lith_", "") for w in WANT) + "\n")
t0 = time.time()
while not os.path.exists(stop):
    try:
        body = urllib.request.urlopen(url, timeout=2).read().decode()
    except Exception:
        time.sleep(1.0 / hz); continue
    v = {}
    for ln in body.splitlines():
        if ln.startswith("#"):
            continue
        p = ln.split()
        if len(p) >= 2 and p[0] in WANT:
            v[p[0]] = p[1]
    if len(v) == len(WANT):
        f.write("%.3f,%s\n" % (time.time() - t0, ",".join(v[w] for w in WANT)))
        f.flush()
    time.sleep(1.0 / hz)
f.close()
PY

# holder.py is 5f-M's, unchanged, so the held-descriptor shape is the same one that measured
# 6.38x.  mode=read does one 4 KiB pread (netCDF header then sit); mode=open never reads.
cat > "$OUT/holder.py" <<'PY'
import os, sys, time
mode, n, ready, stop = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
paths = sys.argv[5:]
fds = []
for i in range(n):
    fd = os.open(paths[i % len(paths)], os.O_RDONLY)
    if mode == "read":
        os.pread(fd, 4096, 0)
    fds.append(fd)
with open(ready, "w") as f:
    f.write("%d\n" % len(fds))
while not os.path.exists(stop):
    time.sleep(0.2)
for fd in fds:
    os.close(fd)
PY

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
# run_cell <arm> <nh> <rep> <bin-label>
run_cell() {
  local arm=$1 nh=$2 rep=$3 lbl=$4
  local bin; eval "bin=\$B_$lbl"
  local tag="$arm-n$nh-$lbl-$rep"
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag.walls" "$OUT/$tag.ready" "$OUT/$tag.stop" "$OUT/$tag.hstop"
  umount_wait
  "$bin" mount "$PREFIX" "$MNT" --metrics ":$PORT" --nic-gbps 50 \
      --log-level "$LOGLVL" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if ! mountpoint -q "$MNT"; then echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; fi

  $PYX "$OUT/sampler.py" "http://127.0.0.1:$PORT/metrics" "$OUT/$tag.samples.csv" \
      "$HZ" "$OUT/$tag.stop" > "$OUT/$tag.sampler.log" 2>&1 &
  local spid=$!
  sleep 1

  # Holders first, so the descriptors are already registered when the streamer starts.
  local hold_pid="" held=0
  if [ "$arm" = "B" ] || [ "$arm" = "C" ]; then
    local mode=read; [ "$arm" = "C" ] && mode=open
    local plist=() i
    # Holders start at object 1; the streamer owns object 0, so a held descriptor never
    # shares a file with the reader under test.
    for ((i = 1; i < ${#OBJS[@]}; i++)); do plist+=("$MNT/${OBJS[$i]}"); done
    $PYX "$OUT/holder.py" "$mode" "$((nh - 1))" "$OUT/$tag.ready" "$OUT/$tag.hstop" \
        "${plist[@]}" > "$OUT/$tag.holder.log" 2>&1 &
    hold_pid=$!
    for _ in $(seq 1 240); do [ -f "$OUT/$tag.ready" ] && break; sleep 0.5; done
    held=$(cat "$OUT/$tag.ready" 2>/dev/null || echo 0)
    [ "$held" -eq "$((nh - 1))" ] || echo "  WARNING $tag: held=$held want $((nh - 1))"
  fi
  # Gauges with the holders in place and nothing streaming yet: this is the #301 reading.
  local pre_oh pre_sh pre_win
  read -r pre_oh pre_sh pre_win <<<"$(curl -s "http://127.0.0.1:$PORT/metrics" \
    | awk '/^lith_open_handles /{o=$2} /^lith_streaming_handles /{s=$2}
           /^lith_readahead_window_blocks /{w=$2} END{printf "%d %d %d", o, s, w}')"

  local nread=1; [ "$arm" = "R" ] && nread=$nh
  local ddargs=(bs=1M status=none)
  [ "$arm" != "R" ] && [ "$STREAM_MB" -gt 0 ] && ddargs+=("count=$STREAM_MB")
  local t0 t1 i; local rpids=()
  t0=$(date +%s.%N)
  for ((i = 0; i < nread; i++)); do
    ( s=$(date +%s.%N)
      dd if="$MNT/${OBJS[$i]}" of=/dev/null "${ddargs[@]}"
      e=$(date +%s.%N)
      echo "$i $(echo "$e - $s" | bc)" >> "$OUT/$tag.walls" ) &
    rpids+=($!)
  done
  wait "${rpids[@]}"
  t1=$(date +%s.%N)

  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | grep -E \
    '^lith_(s3_bytes_total|s3_requests_total|distinct_bytes_read|prefetch_issued_total|prefetch_used_total|prefetch_uncovered_total|prefetch_evicted_unread_total|prefetch_deestablished_total|prefetch_window_halved_total|open_handles|streaming_handles|readahead_window_blocks|prefetch_committed_bytes|prefetch_budget_bytes)' \
    | awk -v t="$tag" '{printf "MET %s %s %s\n", t, $1, $2}' > "$OUT/$tag.met"
  grep -o '"msg":"prefetch bounds".*' "$OUT/$tag.mount.log" | head -1 > "$OUT/$tag.bounds"
  grep -c 'readahead is at the 2-block floor' "$OUT/$tag.mount.log" > "$OUT/$tag.floorwarn"

  [ -n "$hold_pid" ] && { touch "$OUT/$tag.hstop"; wait "$hold_pid" 2>/dev/null; }
  touch "$OUT/$tag.stop"; wait "$spid" 2>/dev/null

  local agg own wmin wmax
  agg=$(echo "$t1 - $t0" | bc)
  own=$(awk '$1==0{print $2}' "$OUT/$tag.walls" 2>/dev/null | head -1)
  wmin=$(awk 'NR==1||$2<m{m=$2}END{printf "%.3f", m}' "$OUT/$tag.walls" 2>/dev/null)
  wmax=$(awk '$2>m{m=$2}END{printf "%.3f", m}' "$OUT/$tag.walls" 2>/dev/null)
  echo "CELL $tag held=$held readers=$nread agg_wall=$agg own_wall=${own:-NA}" \
       "rmin=$wmin rmax=$wmax pre_oh=$pre_oh pre_sh=$pre_sh pre_win=$pre_win" \
       "floorwarn=$(cat "$OUT/$tag.floorwarn")"
  cat "$OUT/$tag.bounds"
  cat "$OUT/$tag.met"
  umount_wait
}

echo "=== gate 5f-P  $(date -u +%FT%TZ)  reps=$REPS ==="
echo "  host: $(hostname) $(nproc) cores  MemTotal $(awk '/MemTotal/{printf "%.3f GB", $2/1e6}' /proc/meminfo)"
echo "  OLD=$B_OLD md5 $(md5sum "$B_OLD" | cut -c1-12)"
echo "  NEW=$B_NEW md5 $(md5sum "$B_NEW" | cut -c1-12)"
echo "  stream=${STREAM_MB}MB  objects=${#OBJS[@]}"

for rep in $(seq 1 "$REPS"); do
  # Upstream's falsifier first, and on the first rep, so a breach is reportable early.
  for b in OLD NEW; do run_cell R 16 "$rep" "$b"; done
  for b in OLD NEW; do run_cell S 1 "$rep" "$b"; done
  for nh in ${C_N:-8 256};     do for b in OLD NEW; do run_cell C "$nh" "$rep" "$b"; done; done
  for nh in ${B_N:-8 64 256};  do for b in OLD NEW; do run_cell B "$nh" "$rep" "$b"; done; done
done
echo "=== done $(date -u +%FT%TZ) ==="
