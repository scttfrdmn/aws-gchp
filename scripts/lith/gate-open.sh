#!/bin/bash
# Gate 5f-P9h (lith#284): where does the ~0.47 s per-open whole-read intercept go? Reads it off
# --timeline-csv (#70), which since #331 carries a kind=open row per handle open, instead of
# fitting it. Pre-registered in data/lith-gates/inregion-streams.txt before any cell ran.
#
# One mount per (ratio, rep), ABBA by rep. Per mount: dd A3mstC whole (cold), then dd A3cld whole
# (warm mount, new object), so each mount yields two opens. The CSV is written on unmount.
set -u

G=${G:-/scratch/lith-gates}
OUT=${OUT:-$G/p9h}
MNT=${MNT:-/scratch/mnt/p9h}
B=${B:-$G/lith-331}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07}
OBJS=${OBJS:-"MERRA2.20190701.A3mstC.05x0625.nc4 MERRA2.20190701.A3cld.05x0625.nc4"}
REPS=${REPS:-3}
PORT_BASE=${PORT_BASE:-10400}
mkdir -p "$OUT" "$MNT"

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
run_mount() {
  local ratio=$1 rep=$2 tag="O$1-$2" o t0 t1
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag".*
  umount_wait
  "$B" mount "$PREFIX" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level info \
      --readahead-evidence-ratio "$ratio" --timeline-csv "$OUT/$tag.timeline.csv" \
      > "$OUT/$tag.mount.log" 2>&1 &
  local lpid=$!
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; }
  for o in $OBJS; do
    # Epoch stamps around dd, so the timeline's open row can be placed against the syscall.
    t0=$(date +%s.%N)
    dd if="$MNT/$o" of=/dev/null bs=1M status=none
    t1=$(date +%s.%N)
    echo "CELL $tag obj=$o dd_start=$t0 dd_end=$t1 wall=$(echo "$t1 - $t0" | bc)"
  done
  umount_wait
  for _ in $(seq 1 40); do kill -0 "$lpid" 2>/dev/null || break; sleep 0.25; done
  echo "  timeline rows: $(wc -l < "$OUT/$tag.timeline.csv" 2>/dev/null || echo MISSING)"
}

echo "=== gate 5f-P9h  $(date -u +%FT%TZ)  B=$(md5sum "$B" | cut -c1-12)"
for rep in $(seq 1 "$REPS"); do
  if [ $((rep % 2)) = 1 ]; then run_mount 0 "$rep"; run_mount 4 "$rep"
  else run_mount 4 "$rep"; run_mount 0 "$rep"; fi
done
echo "=== done $(date -u +%FT%TZ)"
