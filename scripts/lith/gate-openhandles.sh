#!/bin/bash
# Gate 5f-M (lith#298): is the per-handle window divisor charged for handles that are
# merely OPEN, or only for handles that are actually reading?
#
# Upstream handed #298 over ("the live thread and it's yours") after #256 closed: three
# bounds on prefetch depth, three derivations, disagreeing by ~1.5x, and the smallest
# winning silently. The bound that has never been exercised is the per-handle divisor:
#
#   perHandleWindow() = clamp(budgetBlocks / openHandles, 2, maxReadahead)
#   budgetBlocks()    = prefetchBudget / blockSize          (fs.go:1252, :1279)
#
# On this box budgetBlocks = 492 at 8 MiB (33.02 GB x 25% mem-cache x 50% prefetch-budget
# = 4.128 GB), and maxReadahead auto-resolves to 223. So at ONE handle the declared
# max_readahead binds and the divisor is invisible. It only becomes visible with more
# handles -- and whether an IDLE open handle counts is the difference between a knob that
# works and a knob that a 48-rank netCDF workload silently strangles. The banked GCHP
# observation (both production mounts ran at the window FLOOR of 2) is unexplained by
# rank count alone: 492/48 = 10, not 2. Hundreds of simultaneously-OPEN files would do it.
#
# ARMS   all in-region (2.2 ms), default flags (8 MiB / auto 223), fresh cold mount per cell
#   A  N processes each streaming a DIFFERENT 3.7 GB object concurrently   N in 1,2,3,4,8,16
#   B  1 streaming reader + (N-1) handles held OPEN after a 4 KiB header read, no streaming
#        N in 2,3,4,8,16,64,256     <- the netCDF/HEMCO shape
#   C  1 streaming reader + 7 handles opened with NO read at all (N=8)
#        <- separates "open() registers the handle" from "the first read registers it"
#
# Objects are 16 distinct GEOSFP A3dyn days, 3.72-3.81 GB each = 444-454 blocks of 8 MiB,
# so every one of them is larger than the 223-block window and can realize it in full.
#
# Head node only. In-region, so no egress; ~475 GB of GETs is ~$0.02 of requests.
set -u

B=${B:-/scratch/lith-gates/lith-new}
OUT=${OUT:-/scratch/lith-gates/gate-handles}
MNT=${MNT:-/scratch/mnt/h}
PYX=${PYX:-/scratch/ncenv/bin/python}
REPS=${REPS:-3}
PORT_BASE=${PORT_BASE:-9600}
LOGLVL=${LOGLVL:-info}      # info, deliberately: 5f-L shipped 18 zero-byte mount logs
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}

OBJS=(GEOSFP.201907{01..16}.A3dyn.025x03125.nc)

mkdir -p "$OUT" "$MNT"

cat > "$OUT/holder.py" <<'PY'
# Hold N file handles open on the lith mount without streaming them.
#   mode=read  open() then one 4 KiB pread  (the netCDF header-then-sit shape)
#   mode=open  open() only, never read      (does open() alone register the handle?)
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
run_cell() {
  local arm=$1 nh=$2 rep=$3
  local tag="$arm-n$nh-$rep"
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag.walls" "$OUT/$tag.ready" "$OUT/$tag.stop"
  umount_wait
  $B mount "$PREFIX" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level "$LOGLVL" \
      --pf-trace "$OUT/$tag.csv" ${XFLAGS:-} > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if ! mountpoint -q "$MNT"; then echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; fi

  local hold_pid="" held=0
  if [ "$arm" != "A" ] && [ "$nh" -gt 1 ]; then
    local mode=read; [ "$arm" = "C" ] && mode=open
    local plist=() i
    for ((i = 0; i < ${#OBJS[@]}; i++)); do plist+=("$MNT/${OBJS[$i]}"); done
    $PYX "$OUT/holder.py" "$mode" "$((nh - 1))" "$OUT/$tag.ready" "$OUT/$tag.stop" \
        "${plist[@]}" > "$OUT/$tag.holder.log" 2>&1 &
    hold_pid=$!
    for _ in $(seq 1 240); do [ -f "$OUT/$tag.ready" ] && break; sleep 0.5; done
    if [ ! -f "$OUT/$tag.ready" ]; then echo "$tag HOLDER NEVER READY"; fi
    held=$(cat "$OUT/$tag.ready" 2>/dev/null || echo 0)
  fi

  local nread=1; [ "$arm" = "A" ] && nread=$nh
  local t0 t1 i; local rpids=()
  t0=$(date +%s.%N)
  for ((i = 0; i < nread; i++)); do
    ( s=$(date +%s.%N)
      dd if="$MNT/${OBJS[$i]}" of=/dev/null bs=1M status=none
      e=$(date +%s.%N)
      echo "$i $(echo "$e - $s" | bc) $(stat -Lc%s "$MNT/${OBJS[$i]}")" >> "$OUT/$tag.walls" ) &
    rpids+=($!)
  done
  wait "${rpids[@]}"
  t1=$(date +%s.%N)

  [ -n "$hold_pid" ] && { touch "$OUT/$tag.stop"; wait "$hold_pid" 2>/dev/null; }

  local agg; agg=$(echo "$t1 - $t0" | bc)
  local own; own=$(awk '$1==0{print $2}' "$OUT/$tag.walls" 2>/dev/null | head -1)
  local tb;  tb=$(awk '{s+=$3}END{printf "%d", s}' "$OUT/$tag.walls" 2>/dev/null)
  echo "CELL $tag held=$held readers=$nread agg_wall=$agg own_wall=${own:-NA} bytes=${tb:-0}"
  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | grep -E \
    '^lith_(s3_bytes_total|s3_requests_total|distinct_bytes_read|prefetch_issued_total|prefetch_used_total)' \
    | awk -v t="$tag" '{printf "MET %s %s %s\n", t, $1, $2}'
  umount_wait
}

echo "=== gate 5f-M  $(date -u +%FT%TZ)  reps=$REPS ==="
echo "  lith: $($B version 2>&1 | head -1)"
echo "  host: $(hostname) $(nproc) cores  MemTotal $(awk '/MemTotal/{printf "%.2f GB", $2/1e6}' /proc/meminfo)"
echo "  prefix: $PREFIX"

for rep in $(seq 1 "$REPS"); do
  for nh in ${A_N:-1 2 3 4 8 16};        do run_cell A "$nh" "$rep"; done
  for nh in ${B_N:-2 3 4 8 16 64 256};   do run_cell B "$nh" "$rep"; done
  for nh in ${C_N:-8};                   do run_cell C "$nh" "$rep"; done
done
echo "=== done $(date -u +%FT%TZ) ==="
