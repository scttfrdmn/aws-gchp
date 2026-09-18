#!/bin/bash
# Prepare the C24 fullchem A/B: the last open gate is whether GCHP's fullchem read
# pattern gets CORRECT BYTES through lith, and the test is a byte-identical
# checkpoint against an FSx-served run of the same run directory.
#
# All of this runs on the head node so no compute-node time is spent on setup.
set -u
RD=/scratch/gchp_lith_fullchem
GATES=/scratch/lith-gates
LITH=$GATES/lith-1.1.2

echo "=== 1. binary ==="
# The validated stack's binary carries both mechanisms (224 fullchem symbols AND
# TransportTracers), so fullchem needs no separate build -- same image the TT run
# dirs use, byte-for-byte.
cp -n /sw/gchp-14.7.1/bin/gchp $RD/gchp && chmod +x $RD/gchp
ls -l $RD/gchp | awk '{print "  "$5" bytes"}'
md5sum $RD/gchp /sw/gchp-14.7.1/bin/gchp | sed 's/^/  /'

echo "=== 2. run settings: 1 node, and the fullchem restart-species fix ==="
# Require_Species_in_Restart=1 makes 14.7.1 fullchem ABORT on gcgrid restarts, which
# are missing species the current mechanism expects (SPC_ACO3 and friends). This is a
# recorded, previously diagnosed trap, not a guess.
sed -i 's/^NUM_NODES=2$/NUM_NODES=1/' $RD/setCommonRunSettings.sh
sed -i 's/^Require_Species_in_Restart=1$/Require_Species_in_Restart=0/' $RD/setCommonRunSettings.sh
grep -nE '^NUM_NODES=|^NUM_CORES_PER_NODE=|^Require_Species_in_Restart=|^Run_Duration=' $RD/setCommonRunSettings.sh | sed 's/^/  /'

echo "=== 3. GMI overlay for the FSx arm ==="
# /input cannot serve the 5 GMI aliases fullchem needs (FSx snapshot predates them),
# so the CONTROL arm needs the overlay hack. Building it here is itself the measurement
# of what lith deletes: a 3-level symlink farm plus ~495 MB of duplicated objects.
OVL=/scratch/hemco-ovl
t0=$(date +%s)
rm -rf $OVL; mkdir -p $OVL/GMI/v2015-02
for e in /input/HEMCO/*; do [ "$(basename "$e")" = GMI ] || ln -s "$e" $OVL/; done
for e in /input/HEMCO/GMI/*; do [ "$(basename "$e")" = v2015-02 ] || ln -s "$e" $OVL/GMI/; done
for e in /input/HEMCO/GMI/v2015-02/*; do ln -s "$e" $OVL/GMI/v2015-02/; done
# the 5 aliases come from live S3 via lith, since they exist nowhere on Lustre
sudo mkdir -p /mnt/gmisrc; sudo chown ec2-user:ec2-user /mnt/gmisrc
$LITH mount s3://gcgrid/HEMCO/GMI/v2015-02 /mnt/gmisrc --index-file /tmp/gmi.lithidx \
  --no-sign-request --mem-cache 2GB --daemon >/dev/null 2>&1
sleep 6
n=0
for a in IPMN NPMN RIPA RIPB RIPD; do
  cp /mnt/gmisrc/gmi.clim.$a.geos5.2x25.nc $OVL/GMI/v2015-02/gmi.clim.$a.geos5.2x25.nc && n=$((n+1))
done
fusermount3 -u /mnt/gmisrc 2>/dev/null
echo "  overlay built in $(( $(date +%s) - t0 ))s: $n real copies, $(du -sh --apparent-size $OVL/GMI/v2015-02 2>/dev/null | cut -f1) in the leaf"
echo "  symlinks: $(find $OVL -maxdepth 3 -type l | wc -l)   real files: $(find $OVL -maxdepth 3 -type f | wc -l)"
for a in IPMN NPMN RIPA RIPB RIPD; do
  f=$OVL/GMI/v2015-02/gmi.clim.$a.geos5.2x25.nc
  printf "  %-6s %s %s\n" "$a" "$(stat -c %s "$f" 2>/dev/null || echo MISSING)" "$([ -f "$f" ] && echo real || echo BAD)"
done

echo "=== 4. lith mount targets ==="
for d in GEOS_0.5x0.625/MERRA2/2019/07 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
  sudo mkdir -p "/input-lith/${d}"; done
sudo chown -R ec2-user:ec2-user /input-lith 2>/dev/null
ls -d /input-lith/*/ | sed 's/^/  /'

echo "=== 5. indexes needed ==="
for i in merra2-201907 merra2-2015 hemco cheminp restarts; do
  f=$GATES/idx/$i.lithidx
  printf "  %-16s %s\n" "$i" "$([ -s "$f" ] && stat -c %s "$f" || echo MISSING)"
done
