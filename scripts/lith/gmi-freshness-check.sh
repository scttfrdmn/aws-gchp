#!/bin/bash
# The 5 GMI aliases landed in gcgrid 2026-09-12; /input FSx was created 2026-06-28
# with AutoImportPolicy NONE. Does lith, reading live S3, serve them? If yes, the
# freshness argument stops being an inference about snapshots and becomes the reason
# the FSx arm cannot run fullchem at all.
set -u
GATES=/scratch/lith-gates; LITH=$GATES/lith-1.1.2
pkill -f "[l]ith-1.1.2 mount" 2>/dev/null; sudo umount -f /mnt/gmichk 2>/dev/null; sleep 2
sudo mkdir -p /mnt/gmichk; sudo chown ec2-user:ec2-user /mnt/gmichk
# Fresh index: a stale index would hide new objects just like a stale FSx does, so
# build it now rather than reuse the gate-4 HEMCO index.
$LITH index build s3://gcgrid/HEMCO/GMI/v2015-02 --no-sign-request \
  --index-file /tmp/gmi.lithidx >/dev/null 2>&1
setsid nohup $LITH mount s3://gcgrid/HEMCO/GMI/v2015-02 /mnt/gmichk \
  --index-file /tmp/gmi.lithidx --no-sign-request --mem-cache 2GB \
  --metrics :9330 > $GATES/gmichk.log 2>&1 < /dev/null &
sleep 8
mountpoint -q /mnt/gmichk || { echo "MOUNT FAILED"; tail -5 $GATES/gmichk.log; exit 1; }
for a in IPMN NPMN RIPA RIPB RIPD PMN RIP; do
  f=/mnt/gmichk/gmi.clim.$a.geos5.2x25.nc
  if [ -e "$f" ]; then
    # size + an actual NetCDF header read: presence in a listing is not readability
    sz=$(stat -c %s "$f")
    hdr=$(dd if="$f" bs=4 count=1 2>/dev/null | od -c | head -1 | grep -oE 'C   D   F|H   D   F' | head -1)
    printf "  %-6s PRESENT  %10d B  magic=%s\n" "$a" "$sz" "${hdr:-UNREADABLE}"
  else
    printf "  %-6s ABSENT\n" "$a"
  fi
done
sudo umount -f /mnt/gmichk 2>/dev/null; pkill -f "[l]ith-1.1.2 mount"
