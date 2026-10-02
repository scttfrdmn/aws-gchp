#!/bin/bash
# Gate 5f-O part 2 (lith#301/#306): the COVERAGE RATIO, and whether the regression 5f-O
# part 1 found is a property of my flag or of the design.
#
# Part 1 at --nic-gbps 50, 16 concurrent readers: byte admission is 7.17x SLOWER than the
# divisor it replaced, with BOTH of upstream's falsifiers clean (no re-dispatch, zero
# evicted_unread). The mechanism is visible in upstream's own new #308 log line:
#
#     "prefetch bounds" window_blocks=223 window_commit_bytes=1870659584
#                       prefetch_budget_bytes=4127829504  binding="--inflight-bytes"
#
# 4127829504 / 1870659584 = 2.21. The budget admits TWO full windows. The divisor sized
# each handle's window to budget/N so all N were covered shallowly; admission gives the
# first 2 handles the full window and REFUSES the other 14 down to no prefetch at all --
# admission is a prefix, so the first refusal ends the block. The log prints both numbers
# and does not say that 14 of 16 readers get nothing.
#
# So the predicted failure condition is a ratio, not a flag:
#
#     COVERED = floor(prefetch_budget_bytes / window_commit_bytes)
#     readers beyond COVERED get no prefetch and fall to synchronous 1 MiB demand reads
#
# This box: 223 blocks at --nic-gbps 50 -> COVERED = 2.  At the DEFAULT, imds-estimate
# gives 7.5 Gbps -> window 33 -> window_commit_bytes 276824064 -> COVERED = 14.9.
#
# ARMS, each testing a direction of that formula
#   L   ladder at --nic-gbps 50, N in 2,3,4,8     KNEE PREDICTED BETWEEN N=2 AND N=3
#   D   N=16 at the DEFAULT NIC (window 33, COVERED 14.9)   PREDICTED NULL -- 16 ~ 14.9
#   W   N=31 at the DEFAULT NIC (COVERED 14.9 < 31)         PREDICTED REGRESSION RETURNS
#       W is the cell that decides whether this is about my flag or about the design: it
#       sets no bandwidth flag at all and starves anyway, purely by adding readers.
#
# Each arm runs NEW (7a8b38e) and OLD (52138ee) back to back; the ratio is the result.
# Head node, in-region. Starved cells cost ~50k GETs each -- see COST in the writeup.
set -u

OUT=${OUT:-/scratch/lith-gates/gate-admit2}
MNT=${MNT:-/scratch/mnt/a2}
PYX=${PYX:-/scratch/ncenv/bin/python}
REPS=${REPS:-2}
PORT_BASE=${PORT_BASE:-9900}
LOGLVL=${LOGLVL:-info}
HZ=${HZ:-5}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}

B_OLD=${B_OLD:-/scratch/lith-gates/lith-304}
B_NEW=${B_NEW:-/scratch/lith-gates/lith-306}

# 31 days of July, so N can exceed 16 with every reader on a DISTINCT object.
ALL=(GEOSFP.201907{01..31}.A3dyn.025x03125.nc)

mkdir -p "$OUT" "$MNT"
cp -f "${SAMPLER:-/scratch/lith-gates/ga-smoke/sampler.py}" "$OUT/sampler.py"

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
# run_cell <tag> <binary> <nreaders> <count_mb: 0=whole object> [flags...]
run_cell() {
  local tag=$1 bin=$2 nread=$3 cnt=$4; shift 4
  local xf=("$@")
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag.walls" "$OUT/$tag.stop"
  umount_wait
  "$bin" mount "$PREFIX" "$MNT" --metrics ":$PORT" --log-level "$LOGLVL" "${xf[@]}" \
      > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if ! mountpoint -q "$MNT"; then echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; fi

  $PYX "$OUT/sampler.py" "http://127.0.0.1:$PORT/metrics" "$OUT/$tag.samples.csv" \
      "$HZ" "$OUT/$tag.stop" > "$OUT/$tag.sampler.log" 2>&1 &
  local spid=$!
  sleep 1

  local t0 t1 i; local rpids=()
  local ddargs=(bs=1M status=none); [ "$cnt" -gt 0 ] && ddargs+=("count=$cnt")
  t0=$(date +%s.%N)
  for ((i = 0; i < nread; i++)); do
    ( s=$(date +%s.%N)
      dd if="$MNT/${ALL[$i]}" of=/dev/null "${ddargs[@]}"
      e=$(date +%s.%N)
      echo "$i $(echo "$e - $s" | bc)" >> "$OUT/$tag.walls" ) &
    rpids+=($!)
  done
  wait "${rpids[@]}"
  t1=$(date +%s.%N)

  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | grep -E \
    '^lith_(s3_bytes_total|s3_requests_total|prefetch_issued_total|prefetch_used_total|prefetch_uncovered_total|prefetch_evicted_unread_total|prefetch_refused_total|prefetch_deestablished_total)' \
    | awk -v t="$tag" '{printf "MET %s %s %s\n", t, $1, $2}' > "$OUT/$tag.met"
  grep -o '"msg":"prefetch bounds".*' "$OUT/$tag.mount.log" | head -1 > "$OUT/$tag.bounds"

  touch "$OUT/$tag.stop"; wait "$spid" 2>/dev/null

  local agg wmin wmax
  agg=$(echo "$t1 - $t0" | bc)
  wmin=$(awk 'NR==1||$2<m{m=$2}END{printf "%.3f", m}' "$OUT/$tag.walls" 2>/dev/null)
  wmax=$(awk '$2>m{m=$2}END{printf "%.3f", m}' "$OUT/$tag.walls" 2>/dev/null)
  echo "CELL $tag readers=$nread cnt=$cnt agg_wall=$agg rmin=$wmin rmax=$wmax"
  cat "$OUT/$tag.bounds"
  cat "$OUT/$tag.met"
  umount_wait
}

echo "=== gate 5f-O part 2  $(date -u +%FT%TZ)  reps=$REPS ==="
echo "  OLD=$B_OLD md5 $(md5sum "$B_OLD" | cut -c1-12)"
echo "  NEW=$B_NEW md5 $(md5sum "$B_NEW" | cut -c1-12)"

for rep in $(seq 1 "$REPS"); do
  # C: straight replication of part 1's decisive comparison, --nic-gbps 50, N=16 whole.
  for b in OLD NEW; do
    eval "bin=\$B_$b"; run_cell "C-$b-$rep" "$bin" 16 0 --nic-gbps 50
  done
  # W: default NIC, N=31, 2 GB each. COVERED 14.9 < 31 -> predicted regression returns.
  for b in OLD NEW; do
    eval "bin=\$B_$b"; run_cell "W-$b-$rep" "$bin" 31 2048
  done
  # D: default NIC, N=16, whole objects. COVERED 14.9 -> predicted null.
  for b in OLD NEW; do
    eval "bin=\$B_$b"; run_cell "D-$b-$rep" "$bin" 16 0
  done
  # L: ladder at --nic-gbps 50, 2 GB each so low-N cells are not dominated by startup.
  for n in ${L_N:-2 3 4 8}; do
    for b in OLD NEW; do
      eval "bin=\$B_$b"; run_cell "L$n-$b-$rep" "$bin" "$n" 2048 --nic-gbps 50
    done
  done
done
echo "=== done $(date -u +%FT%TZ) ==="
