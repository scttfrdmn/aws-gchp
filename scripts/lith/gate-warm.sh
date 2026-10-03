#!/bin/bash
# Gate 5f-P9g (lith#284): does a WARM mount keep the 0.50 s whole-read intercept P9f found on cold
# mounts? Pre-registered in data/lith-gates/inregion-streams.txt before any cell ran.
#
# One mount per (arm, rep). On it, in order: a cold primer object (unscored, measures the cold
# intercept), then three objects read whole with dd, each the mount's first touch of THAT object
# but not the mount's first open. Arm order alternates by rep (ABBA) so first-run bias cancels.
set -u

G=${G:-/scratch/lith-gates}
OUT=${OUT:-$G/p9g}
MNT=${MNT:-/scratch/mnt/p9g}
B=${B:-$G/lith-324}
PYX=${PYX:-/scratch/ncenv/bin/python}
READER=${READER:-$G/p9c-dd.py}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07}
PRIMER=${PRIMER:-MERRA2.20190701.A3mstE.05x0625.nc4}
OBJS=${OBJS:-"MERRA2.20190701.A3mstC.05x0625.nc4 MERRA2.20190701.A3cld.05x0625.nc4 MERRA2.20190701.I3.05x0625.nc4"}
REPS=${REPS:-6}
PORT_BASE=${PORT_BASE:-10300}
mkdir -p "$OUT" "$MNT"

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

s3bytes() { curl -s "http://127.0.0.1:$PORT/metrics" | awk '/^lith_s3_bytes_total /{print $2}'; }

N=0
run_mount() {
  local ratio=$1 rep=$2 tag="W$1-$2" o b0 b1 rd i=0
  N=$((N + 1)); PORT=$((PORT_BASE + N))
  umount_wait
  "$B" mount "$PREFIX" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn \
      --readahead-evidence-ratio "$ratio" --pf-trace "$OUT/$tag.trace.csv" \
      > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; }
  for o in "$PRIMER" $OBJS; do
    b0=$(s3bytes)
    rd=$($PYX "$READER" "$MNT/$o" 2>&1)
    b1=$(s3bytes)
    echo "CELL $tag pos=$i $([ $i = 0 ] && echo cold || echo warm) obj=$o $rd s3_MB=$(echo "scale=1; ($b1 - $b0)/1000000" | bc)"
    i=$((i + 1))
  done
  umount_wait
}

echo "=== gate 5f-P9g  $(date -u +%FT%TZ)  B=$(md5sum "$B" | cut -c1-12)  primer=$PRIMER"
for rep in $(seq 1 "$REPS"); do
  if [ $((rep % 2)) = 1 ]; then run_mount 0 "$rep"; run_mount 4 "$rep"
  else run_mount 4 "$rep"; run_mount 0 "$rep"; fi
done
echo "=== done $(date -u +%FT%TZ)"
