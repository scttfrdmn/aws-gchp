#!/bin/bash
# Gate 5f-O (lith#301/#306): does byte admission hold the #55 invariant on the shape
# where the divisor's rationing was load-bearing?
#
# Upstream merged ceeb2b7: BlockStore.admitCommitted reserves a chunk's bytes against
# --prefetch-budget with a CAS and refuses what will not fit; perHandleWindow stops
# dividing by the open-descriptor count. They asked for ONE arm back -- 5f-M arm A, 16
# concurrent readers over 60 GB against an 8.256 GB tier -- because every check they have
# on the safety half is weaker than it: their fake-server sweep runs at 2.4-3.5x
# production memory pressure in a direction the network cannot produce, two of three
# cells of their own concurrent-reader measurement were NIC-suppressed, and
# TestPrefetchBudgetNoThrash passes at a 1:8 budget-to-tier ratio where their sweep
# showed the rationing barely matters.
#
# The regime change is real and worth stating: at 16 handles the divisor gave each one a
# window of 30 blocks (an equal SHARE, guaranteed), and admission gives each the full 223
# capped by a GLOBAL pool. Same realized total to 2.4% (4.027 vs 4.128 GB) by arithmetic,
# different allocation discipline -- share vs race.
#
# ARMS   16 concurrent readers, 16 distinct objects, default flags unless stated
#   OLD  52138ee  the divisor, with the #303/#304 gauges        window 30 expected
#   NEW  7a8b38e  byte admission (ceeb2b7 + #308 docs)          window 223 expected
#   POS  7a8b38e  --prefetch-budget 30GB, --mem-cache default   POSITIVE CONTROL
#
# POS exists because of trap 1, which is mine and applies to me: 5f-M arm A saturated
# this box's NIC at ~14 Gbps, and a NIC ceiling throttles DISPATCH, which SUPPRESSES
# thrash. A null in NEW is only worth having if this box can show thrash at all. POS
# raises the admission cap above the whole cache tier (30 GB > 8.256 GB) so prefetched
# chunks MUST be evicted unread if dispatch can ever outrun consumption here. If POS is
# also null, the box cannot reach the regime and NEW's null is bounded by that -- which
# is a result about the gate, and gets reported as one.
#
# Head node, in-region, already running: ~180 GB of GETs is ~$0.02 of requests.
set -u

OUT=${OUT:-/scratch/lith-gates/gate-admit}
MNT=${MNT:-/scratch/mnt/a}
PYX=${PYX:-/scratch/ncenv/bin/python}
REPS=${REPS:-3}
PORT_BASE=${PORT_BASE:-9800}
LOGLVL=${LOGLVL:-info}
HZ=${HZ:-10}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}

B_OLD=${B_OLD:-/scratch/lith-gates/lith-304}
B_NEW=${B_NEW:-/scratch/lith-gates/lith-306}

OBJS=(GEOSFP.201907{01..16}.A3dyn.025x03125.nc)

mkdir -p "$OUT" "$MNT"

cat > "$OUT/sampler.py" <<'PY'
# One process per cell, urllib not curl: the cadence must not be a fork storm.
import os, sys, time, urllib.request
url, out, hz, stop = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
WANT = ("lith_prefetch_committed_bytes", "lith_prefetch_budget_bytes",
        "lith_readahead_window_blocks", "lith_open_handles")
f = open(out, "w")
f.write("t,committed_bytes,budget_bytes,window_blocks,open_handles\n")
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
        f.write("%.3f,%s,%s,%s,%s\n" % (time.time() - t0, v[WANT[0]], v[WANT[1]],
                                        v[WANT[2]], v[WANT[3]]))
        f.flush()
    time.sleep(1.0 / hz)
f.close()
PY

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
run_cell() {
  local arm=$1 rep=$2 bin=$3; shift 3
  local xf=("$@")
  local tag="$arm-$rep"
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag.walls" "$OUT/$tag.stop"
  umount_wait
  "$bin" mount "$PREFIX" "$MNT" --metrics ":$PORT" --nic-gbps 50 \
      --log-level "$LOGLVL" "${xf[@]}" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  if ! mountpoint -q "$MNT"; then echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; fi

  # Sampler BEFORE the readers so the establishment transient is in the series.
  $PYX "$OUT/sampler.py" "http://127.0.0.1:$PORT/metrics" "$OUT/$tag.samples.csv" \
      "$HZ" "$OUT/$tag.stop" > "$OUT/$tag.sampler.log" 2>&1 &
  local spid=$!
  sleep 1

  local t0 t1 i; local rpids=()
  t0=$(date +%s.%N)
  for ((i = 0; i < ${#OBJS[@]}; i++)); do
    ( s=$(date +%s.%N)
      dd if="$MNT/${OBJS[$i]}" of=/dev/null bs=1M status=none
      e=$(date +%s.%N)
      echo "$i $(echo "$e - $s" | bc) $(stat -Lc%s "$MNT/${OBJS[$i]}")" >> "$OUT/$tag.walls" ) &
    rpids+=($!)
  done
  wait "${rpids[@]}"
  t1=$(date +%s.%N)

  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | grep -E \
    '^lith_(s3_bytes_total|s3_requests_total|distinct_bytes_read|prefetch_issued_total|prefetch_used_total|prefetch_uncovered_total|prefetch_evicted_unread_total|prefetch_refused_total|prefetch_deestablished_total|prefetch_window_halved_total|prefetch_committed_bytes|prefetch_budget_bytes|readahead_window_blocks|open_handles)' \
    | awk -v t="$tag" '{printf "MET %s %s %s\n", t, $1, $2}' > "$OUT/$tag.met"

  touch "$OUT/$tag.stop"; wait "$spid" 2>/dev/null

  local agg; agg=$(echo "$t1 - $t0" | bc)
  local tb;  tb=$(awk '{s+=$3}END{printf "%d", s}' "$OUT/$tag.walls" 2>/dev/null)
  local wmin wmax
  wmin=$(awk 'NR==1||$2<m{m=$2}END{printf "%.3f", m}' "$OUT/$tag.walls" 2>/dev/null)
  wmax=$(awk '$2>m{m=$2}END{printf "%.3f", m}' "$OUT/$tag.walls" 2>/dev/null)
  echo "CELL $tag readers=${#OBJS[@]} agg_wall=$agg bytes=${tb:-0} reader_wall_min=$wmin reader_wall_max=$wmax"
  cat "$OUT/$tag.met"
  umount_wait
}

echo "=== gate 5f-O  $(date -u +%FT%TZ)  reps=$REPS ==="
echo "  host: $(hostname) $(nproc) cores  MemTotal $(awk '/MemTotal/{printf "%.3f GB", $2/1e6}' /proc/meminfo)"
echo "  OLD=$B_OLD md5 $(md5sum "$B_OLD" | cut -c1-12)"
echo "  NEW=$B_NEW md5 $(md5sum "$B_NEW" | cut -c1-12)"
echo "  prefix: $PREFIX  objects: ${#OBJS[@]}"

for rep in $(seq 1 "$REPS"); do
  run_cell OLD "$rep" "$B_OLD"
  run_cell NEW "$rep" "$B_NEW"
  run_cell POS "$rep" "$B_NEW" --prefetch-budget 30GB
done
echo "=== done $(date -u +%FT%TZ) ==="
