#!/bin/bash
# 5f-P6f on the head node, lith v1.7.0 (incl #320 credit fixes, #367 --prefetch-pressure-max).
# Pre-registration: data/lith-gates/inregion-streams.txt. Same cells as 5f-P6c (drive-p6.sh) plus D375 at 1.3.
G=/scratch/lith-gates; B=$G/v170/lith_linux_arm64
FP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07
M2=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/01
D375=$(for d in $(seq -w 1 16); do printf "GEOSFP.201907%s.A3dyn.025x03125.nc " $d; done)
M043=$(for d in $(seq -w 1 16); do printf "MERRA2.201901%s.A3cld.05x0625.nc4 " $d; done)
M122=$(for d in $(seq -w 1 16); do printf "MERRA2.201901%s.A3dyn.05x0625.nc4 " $d; done)
run() { echo "######## P6f ARM $1  $(date -u +%FT%TZ)"
  RESIDENT=1 PRESSURE=1 OUT=$G/p6f-$1 MNT=/scratch/mnt/p6 B=$B REPS=2 ARMS="$5" PREFIX=$2 \
    OBJLIST="$3" PORT_BASE=$4 NICG=50 SAMPLER=$G/sampler-p6f.py $G/gate-p6f.sh; }
run M043 $M2 "$M043" 9710 "M043:"
run M122 $M2 "$M122" 9720 "M122:"
run D375 $FP "$D375" 9730 "D375: D375P13:--prefetch-pressure-max 1.3"
echo "######## P6f DONE $(date -u +%FT%TZ)"
