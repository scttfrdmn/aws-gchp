#!/bin/bash
# Gate 5i part C: measure perHandleWindow as a function of OPEN HANDLE COUNT, at the
# capture's own --mem-cache settings.
#
# Why this matters beyond the trace format. perHandleWindow() is
#     clamp(budgetBlocks / open_handles, 2, --max-readahead)
# so --max-readahead is only in play while budgetBlocks/open_handles exceeds it, and the
# FLOOR takes over once the handle count is large. The capture had 598 open handles on the
# met mount and 6,272 on HEMCO. If the share floors out at 2 blocks there, then every
# policy arm in this campaign that moved --max-readahead (223 -> 56 in gate 5b, and the
# coverage/evidence variants) was adjusting a bound that was never binding -- which would
# be a mechanism for gate 5b's "hit rate is INVARIANT to a 4x window cut".
#
# Measure B by inverting the formula: with H handles held open simultaneously,
# max_window = clamp(B/H, 2, 223), so B = H * max_window wherever it is unclamped.
set -u
BIN=/scratch/lith-gates/lith-271
MNT=/mnt/lith-256
MET=9207
OBJ=AEIC.nc
OUT=/scratch/lith-gates/gate5i
mkdir -p $OUT

umount_wait() {
  fusermount3 -u $MNT 2>/dev/null
  for i in $(seq 1 30); do mountpoint -q $MNT || return 0; sleep 0.5; done
  fusermount3 -uz $MNT 2>/dev/null; sleep 1
}

# <mem-cache> <handles>
probe() {
  local mc=$1 H=$2 name="w-${mc}-${H}"
  umount_wait
  rm -f $OUT/$name.csv
  $BIN mount s3://gcgrid/HEMCO/AEIC/v2015-01 $MNT --pf-trace $OUT/$name.csv \
    --metrics :$MET --nic-gbps 50 --mem-cache $mc --log-level warn > $OUT/$name.mount.log 2>&1 &
  for i in $(seq 1 40); do mountpoint -q $MNT && break; sleep 0.5; done
  mountpoint -q $MNT || { echo "$name MOUNT FAILED"; tail -3 $OUT/$name.mount.log; return 1; }
  python3 $OUT/manyfd.py $MNT/$OBJ $H 4 > /dev/null 2>&1
  umount_wait
  python3 - "$OUT/$name.csv" "$mc" "$H" <<'PY'
import csv, sys
path, mc, H = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = []
with open(path) as fh:
    hdr = None
    for line in fh:
        if line.startswith("#"):
            continue
        if hdr is None:
            hdr = next(csv.reader([line])); continue
        rows.append(dict(zip(hdr, next(csv.reader([line])))))
if not rows:
    print(f"  mem-cache={mc:>5}  handles={H:<4} NO ROWS"); raise SystemExit
mw = sorted({int(r["max_window"]) for r in rows})
fhs = len({r["fh"] for r in rows})
lo, hi = mw[0], mw[-1]
note = "CLAMPED at floor 2" if hi == 2 else ("at --max-readahead ceiling" if hi == 223 else f"implies budget ~{hi*H} blocks")
print(f"  mem-cache={mc:>5}  handles_requested={H:<4} handles_seen={fhs:<4} "
      f"max_window={lo}..{hi}  {note}")
PY
}

echo "################ gate 5i part C -- perHandleWindow vs open handles, \$0"
echo "# formula: clamp(budgetBlocks / open_handles, 2, 223); block_size 8 MiB"
for mc in 24GB 32GB; do
  echo "== --mem-cache $mc  (capture used 24GB for met, 32GB for HEMCO)"
  for H in 1 8 64 256; do probe $mc $H; done
done
