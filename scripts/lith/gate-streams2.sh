#!/bin/bash
# Gate 5f-P2 (lith#311): WHICH sub-mechanism makes the stream divisor 3.14x slower on
# concurrent readers -- the start transient, or the late window inflation?
#
# 5f-P arm R, rep 1: OLD 33.97 s / spread 1.05x / evicted_unread 0, NEW 106.53 s / spread
# 3.66x / evicted_unread 4537 / GETs +66%. The delta accounting is CORRECT -- streaming_handles
# == open_handles == 16 and the window is 30 = 492/16, exactly the intended share -- so the
# cause upstream named for any movement here does not hold, and two others fit every number:
#
#   H-BURST  all 16 start within ~50 ms; perHandleWindow runs BEFORE the Observe that
#            establishes, so each sees N~0 and takes 223. Peak committed measured at
#            12.944 GB = 3.14x the budget and 1.57x the 8.256 GB memory tier, so blocks are
#            evicted before being read and come back as synchronous demand reads. Whoever
#            loses that first race keeps losing it: 13 readers finish on OLD's schedule, 3
#            crawl to 106 s.
#   H-QUEUE  as readers finish, N falls and every survivor's window GROWS (30 -> 32 -> 164 ->
#            223), so 3 readers at 164 blocks put up to 492 chunk requests against a fixed
#            --s3-concurrency of 128 and the next needed block queues behind hundreds that are
#            not needed yet. 5f-L is the prior: at the 8 MiB unit, 128 -> 512 slowed both arms.
#
# They have OPPOSITE repairs -- clamp the window at establishment vs bound outstanding
# requests -- so the discriminator is three interventions on NEW, each on one variable.
#
#   R-CAP   --max-readahead 30     pins every reader at the share 16 readers are entitled to.
#                                  No burst possible, no late inflation possible.
#   R-CONC  --s3-concurrency 512   more slots, window untouched.
#   R-PB    --prefetch-budget 1GB  caps the burst by the NUMERATOR (119 blocks even at N=1)
#                                  instead of by the window ceiling.
#   R-BASE  no extra flags         NEW baseline, re-run here so all four share run order.
#
# Interpretation rule was fixed in data/lith-gates/inregion-streams.txt BEFORE rep 2 of 5f-P
# was read. R-CAP restores and R-CONC does not => H-BURST. R-CONC helps and R-CAP does not
# => H-QUEUE. Both => unseparated, and it gets reported as unseparated.
#
# Head node, in-region. 60 GB/cell; 4 arms x 2 reps = ~480 GB of GETs, ~$0.03 of requests.
set -u

OUT=${OUT:-/scratch/lith-gates/gate-streams2}
MNT=${MNT:-/scratch/mnt/s2}
PYX=${PYX:-/scratch/ncenv/bin/python}
REPS=${REPS:-2}
PORT_BASE=${PORT_BASE:-9750}
LOGLVL=${LOGLVL:-info}
HZ=${HZ:-5}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}
B=${B:-/scratch/lith-gates/lith-311}

# OBJLIST overrides the object set (space-separated, relative to PREFIX). Repeating one name
# puts several readers on the SAME object, which is how 5f-P4 tests chunk dedup.
if [ -n "${OBJLIST:-}" ]; then read -r -a OBJS <<<"$OBJLIST"
else OBJS=(GEOSFP.201907{01..16}.A3dyn.025x03125.nc); fi

# label:extra flags.  Empty flags for the baseline.
ARMS=${ARMS:-"BASE: CAP:--max-readahead 30 CONC:--s3-concurrency 512 PB:--prefetch-budget 1GB"}

mkdir -p "$OUT" "$MNT"
cp -f "${SAMPLER:-/scratch/lith-gates/gate-streams/sampler.py}" "$OUT/sampler.py"

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
run_cell() {
  local lbl=$1 rep=$2; shift 2
  local xf=("$@")
  local tag="R$lbl-$rep"
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag.walls" "$OUT/$tag.stop"
  umount_wait
  # NICG=auto drops the flag so lith detects the NIC itself (stock defaults).
  local nicf=(--nic-gbps "${NICG:-50}"); [ "${NICG:-}" = auto ] && nicf=()
  "$B" mount "$PREFIX" "$MNT" --metrics ":$PORT" "${nicf[@]}" \
      --log-level "$LOGLVL" "${xf[@]}" > "$OUT/$tag.mount.log" 2>&1 &
  local lpid=$!
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if ! mountpoint -q "$MNT"; then echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; fi

  $PYX "$OUT/sampler.py" "http://127.0.0.1:$PORT/metrics" "$OUT/$tag.samples.csv" \
      "$HZ" "$OUT/$tag.stop" > "$OUT/$tag.sampler.log" 2>&1 &
  local spid=$!
  # lith RSS high-water (#314: RSS = tier + outstanding prefetch)
  ( pk=0; while [ ! -f "$OUT/$tag.stop" ]; do
      r=$(awk '/^VmRSS/{print $2}' "/proc/$lpid/status" 2>/dev/null); r=${r:-0}
      [ "$r" -gt "$pk" ] && pk=$r && echo "$pk" > "$OUT/$tag.rsskb"; sleep 0.2
    done ) &
  local rspid=$!
  sleep 1

  local t0 t1 i; local rpids=()
  local nread=${NR:-${#OBJS[@]}}     # reader-count ladder: each reader takes its own object
  t0=$(date +%s.%N)
  for ((i = 0; i < nread; i++)); do
    ( s=$(date +%s.%N)
      dd if="$MNT/${OBJS[$i]}" of=/dev/null bs=1M status=none
      e=$(date +%s.%N)
      echo "$i $(echo "$e - $s" | bc)" >> "$OUT/$tag.walls" ) &
    rpids+=($!)
  done
  wait "${rpids[@]}"
  t1=$(date +%s.%N)

  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | grep -E \
    '^lith_(s3_bytes_total|s3_requests_total|distinct_bytes_read|prefetch_issued_total|prefetch_used_total|prefetch_uncovered_total|prefetch_evicted_unread_total|prefetch_window_halved_total|readahead_window_blocks)' \
    | awk -v t="$tag" '{printf "MET %s %s %s\n", t, $1, $2}' > "$OUT/$tag.met"
  grep -o '"msg":"prefetch bounds".*' "$OUT/$tag.mount.log" | head -1 > "$OUT/$tag.bounds"

  touch "$OUT/$tag.stop"; wait "$spid" "$rspid" 2>/dev/null

  local agg wmin wmax pk
  agg=$(echo "$t1 - $t0" | bc)
  wmin=$(awk 'NR==1||$2<m{m=$2}END{printf "%.3f", m}' "$OUT/$tag.walls")
  wmax=$(awk '$2>m{m=$2}END{printf "%.3f", m}' "$OUT/$tag.walls")
  # Peak committed bytes and peak window: the two quantities the hypotheses disagree about.
  pk=$(awk -F, 'NR>1{if($5+0>c)c=$5+0; if($4+0>w)w=$4+0}END{printf "%.0f %d", c, w}' \
        "$OUT/$tag.samples.csv" 2>/dev/null)
  # RESIDENT=1: peak unread_resident_bytes (#318), column 7 when the sampler carries it
  local pr=""; [ -n "${RESIDENT:-}" ] && pr=" peak_unread_resident=$(awk -F, 'NR>1&&$7+0>r{r=$7+0}END{printf "%.0f", r}' "$OUT/$tag.samples.csv")"
  echo "CELL $tag agg_wall=$agg rmin=$wmin rmax=$wmax spread=$(echo "scale=3; $wmax/$wmin" | bc)" \
       "peak_committed=${pk% *} peak_window=${pk#* } peak_rss_GB=$(awk '{printf "%.2f", $1*1024/1e9}' "$OUT/$tag.rsskb" 2>/dev/null)$pr flags=${xf[*]:-none}"
  cat "$OUT/$tag.met"
  umount_wait
}

echo "=== gate 5f-P2  $(date -u +%FT%TZ)  reps=$REPS ==="
echo "  B=$B md5 $(md5sum "$B" | cut -c1-12)   readers=${NR:-${#OBJS[@]}}  prefix=$PREFIX"
echo "  objects: $(printf '%s\n' "${OBJS[@]}" | sort -u | wc -l) distinct of ${#OBJS[@]}  first=${OBJS[0]}"
for rep in $(seq 1 "$REPS"); do
  # Parse "LABEL:flag flag" groups: a token containing ':' opens a new arm, the rest are
  # that arm's flags. Word splitting on $ARMS is intended.
  lbl=""; flags=()
  for tok in $ARMS; do
    case "$tok" in
      *:*) [ -n "$lbl" ] && run_cell "$lbl" "$rep" "${flags[@]}"
           lbl=${tok%%:*}; flags=(); rest=${tok#*:}
           [ -n "$rest" ] && flags+=("$rest") ;;
      *)   flags+=("$tok") ;;
    esac
  done
  [ -n "$lbl" ] && run_cell "$lbl" "$rep" "${flags[@]}"
done
echo "=== done $(date -u +%FT%TZ) ==="
