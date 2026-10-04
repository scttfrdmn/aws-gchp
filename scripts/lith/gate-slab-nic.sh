#!/bin/bash
# Gate 5f-F1 (lith#239): does readahead amplification on a HYPERSLAB reader keep tracking the
# stated NIC bandwidth at the top of the range, while wall has already saturated?
#
# #239 measured on c7g.4xlarge (v1.1.0): A3dyn /U one time slice, 110 MB of a 3.5 GB file --
# --nic-gbps 15 -> 6.0x amplification, 7.5 -> 3.5x, wall indistinguishable. It has been open
# waiting for a high-bandwidth datapoint. This runs the same slab on a 600 Gbps box at
# stated bandwidths 7.5 / 15 / 50 / 100 and at stock detection (auto).
#
# One reader, one slab, fresh mount per cell (cold tier, cold page cache). slabread is the
# H5Dread harness linked against the GCHP stack's HDF5 1.14.0 (scripts/lith/slabread.c).
set -u

G=${G:-/home/ec2-user/g}
OUT=${OUT:-$G/f1}
MNT=${MNT:-$G/mnt-f1}
B=${B:-$G/lith-315}
SLAB=${SLAB:-$G/slabread}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}
OBJ=${OBJ:-GEOSFP.20190701.A3dyn.025x03125.nc}
DSET=${DSET:-/U}
START=${START:-0,0,0,0}
COUNT=${COUNT:-1,72,721,1152}
NICS=${NICS:-"7.5 15 50 100 auto"}
REPS=${REPS:-3}
PORT_BASE=${PORT_BASE:-9900}
mkdir -p "$OUT" "$MNT"

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
echo "=== gate 5f-F1  $(date -u +%FT%TZ)  B=$(md5sum "$B" | cut -c1-12)  $OBJ $DSET $START/$COUNT"
for rep in $(seq 1 "$REPS"); do
  for nic in $NICS; do
    tag="N$nic-$rep"; N=$((N + 1)); PORT=$((PORT_BASE + N))
    nicf=(--nic-gbps "$nic"); [ "$nic" = auto ] && nicf=()
    umount_wait
    "$B" mount "$PREFIX" "$MNT" --metrics ":$PORT" "${nicf[@]}" --log-level info \
        > "$OUT/$tag.mount.log" 2>&1 &
    for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
    mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; continue; }
    t0=$(date +%s.%N)
    sr=$("$SLAB" "$MNT/$OBJ" "$DSET" "$START" "$COUNT" 2>&1)
    t1=$(date +%s.%N)
    # Let in-flight prefetch land before reading the byte counters: amplification is what
    # the window COMMITTED, not what had arrived when the reader returned.
    sleep 5
    met=$(curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | awk '
      /^lith_s3_bytes_total /{b=$2} /^lith_distinct_bytes_read /{d=$2}
      /^lith_readahead_window_blocks /{w=$2} /^lith_prefetch_issued_total /{s=$2}
      /^lith_prefetch_evicted_unread_total /{e=$2}
      END{printf "s3_MB=%.1f distinct_MB=%.1f amp=%.2f window=%d issued=%d evicted=%d",
          b/1e6, d/1e6, (d>0?b/d:0), w, s, e}')
    nicsrc=$(grep -o '"msg":"nic bandwidth"[^}]*' "$OUT/$tag.mount.log" | head -1)
    echo "CELL $tag wall=$(echo "$t1 - $t0" | bc) slab=[$sr] $met"
    echo "  $nicsrc"
    grep -o '"msg":"prefetch bounds".*' "$OUT/$tag.mount.log" | head -1 | sed 's/^/  /'
    umount_wait
  done
done
echo "=== done $(date -u +%FT%TZ)"
