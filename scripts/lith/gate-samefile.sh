#!/bin/bash
# Gate 5f-P5: do concurrent readers of the SAME object ever establish as streams?
#
# 5f-P4 arm S375 put 16 dd readers on one 3.76 GB object and found streaming_handles = 0,
# prefetch_committed_bytes = 0 and every read uncovered, at ~5 MB/s -- against ~110 MB/s per
# reader when the same 16 readers each have their own object. So the chunk-dedup bound I
# offered upstream holds only vacuously: nothing prefetches at all.
#
# Hypothesis, from the code, NOT yet measured: lith opens with FOPEN_KEEP_CACHE (fs.go:663,
# 727), so the kernel page cache for an inode is shared across descriptors. A block one
# reader pulls in is served to the others from page cache and never reaches lith, so each
# handle sees a stream full of holes, the byte-gap gate keeps it Random, and no handle ever
# prefetches. GCHP is this shape: many ranks reading the same met file.
#
# The decision observable is --pf-trace (fh, gap, state_before, state_after), so every cell
# is traced. The causal intervention is iflag=direct: O_DIRECT bypasses the shared page cache,
# so every read reaches lith on its own handle. If the hypothesis is right, T16D establishes
# and T16 does not, on the same object, same binary, same flags.
#
#   T1    1 reader                         baseline: one handle on one object establishes
#   T2    2 readers, same object
#   T4    4 readers, same object
#   T16   16 readers, same object          the S375 shape, shortened
#   T16D  16 readers, same object, O_DIRECT  the intervention
#   T16X  16 readers, 16 distinct objects  control: distinct objects establish (5f-P2)
#
# Each reader reads LEN_MB from offset 0. Head node, in-region; ~$0.01.
set -u

G=${G:-/scratch/lith-gates}
OUT=${OUT:-$G/p5}
MNT=${MNT:-/scratch/mnt/p5}
B=${B:-$G/lith-315}
PYX=${PYX:-/scratch/ncenv/bin/python}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}
LEN_MB=${LEN_MB:-512}
REPS=${REPS:-2}
PORT_BASE=${PORT_BASE:-9850}
ARMS=${ARMS:-"T1 T2 T4 T16 T16D T16X"}

ONE=GEOSFP.20190701.A3dyn.025x03125.nc
mkdir -p "$OUT" "$MNT"

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
run_cell() {
  local arm=$1 rep=$2 tag="$1-$2" nr objs=() ddx=() i
  case "$arm" in
    T1) nr=1 ;; T2) nr=2 ;; T4) nr=4 ;; T16|T16D|T16X) nr=16 ;;
    *) echo "unknown arm $arm"; return 1 ;;
  esac
  for ((i = 0; i < nr; i++)); do
    if [ "$arm" = T16X ]; then objs+=("$(printf 'GEOSFP.201907%02d.A3dyn.025x03125.nc' $((i + 1)))")
    else objs+=("$ONE"); fi
  done
  [ "$arm" = T16D ] && ddx=(iflag=direct)

  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag".*
  umount_wait
  "$B" mount "$PREFIX" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level info \
      --pf-trace "$OUT/$tag.trace.csv" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; }

  # streaming_handles peak, sampled -- the gauge upstream's divisor reads
  ( while [ ! -f "$OUT/$tag.stop" ]; do
      curl -s --max-time 2 "http://127.0.0.1:$PORT/metrics" \
        | awk '/^lith_streaming_handles /{print $2}'
      sleep 0.2
    done > "$OUT/$tag.sh" ) &
  local spid=$!

  local t0 t1 rp=()
  t0=$(date +%s.%N)
  for ((i = 0; i < nr; i++)); do
    ( dd if="$MNT/${objs[$i]}" of=/dev/null bs=1M count="$LEN_MB" status=none "${ddx[@]}" \
        2>> "$OUT/$tag.dderr" ) &
    rp+=($!)
  done
  wait "${rp[@]}"
  t1=$(date +%s.%N)
  touch "$OUT/$tag.stop"; wait "$spid" 2>/dev/null

  local met
  met=$(curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | awk '
    /^lith_s3_bytes_total /{b=$2} /^lith_prefetch_uncovered_total /{u=$2}
    /^lith_prefetch_used_total /{h=$2} /^lith_prefetch_issued_total /{s=$2}
    END{printf "s3_GB=%.3f issued=%d used=%d uncovered=%d", b/1e9, s, h, u}')
  local shmax; shmax=$(sort -g "$OUT/$tag.sh" | tail -1)
  umount_wait
  echo "CELL $tag readers=$nr distinct=$(printf '%s\n' "${objs[@]}" | sort -u | wc -l)" \
       "wall=$(echo "$t1 - $t0" | bc) sh_max=${shmax:-NA} $met" \
       "dderr=$(wc -l < "$OUT/$tag.dderr" 2>/dev/null || echo 0)"
  [ -s "$OUT/$tag.dderr" ] && head -2 "$OUT/$tag.dderr"
  # The decision, per handle: how many of its reads arrived with a hole in front of them,
  # and what state the detector ended in.
  $PYX - "$OUT/$tag.trace.csv" <<'PY'
import csv, sys, collections
rows = [r for r in csv.DictReader(l for l in open(sys.argv[1]) if not l.startswith("#"))]
by = collections.defaultdict(list)
for r in rows:
    by[r["fh"]].append(r)
holes = [sum(1 for r in v if int(r["gap"]) > 0) / len(v) for v in by.values()]
final = collections.Counter(v[-1]["state_after"] for v in by.values())
gaps = collections.Counter(int(r["gap"]) for r in rows if int(r["gap"]) > 0)
seq = sum(1 for r in rows if r["state_after"].lower().startswith("seq"))
print("  trace: %d rows over %d handles   reads-with-hole/handle: min %.2f med %.2f max %.2f"
      % (len(rows), len(by), min(holes), sorted(holes)[len(holes)//2], max(holes)))
print("  final state per handle: %s   rows in Sequential: %.1f%%"
      % (dict(final), 100.0 * seq / max(len(rows), 1)))
print("  commonest positive gaps (bytes x count): %s" % gaps.most_common(4))
PY
}

echo "=== gate 5f-P5  $(date -u +%FT%TZ)  B=$(md5sum "$B" | cut -c1-12)  len=${LEN_MB}MB reps=$REPS"
for rep in $(seq 1 "$REPS"); do
  for a in $ARMS; do run_cell "$a" "$rep"; done
done
echo "=== done $(date -u +%FT%TZ)"
