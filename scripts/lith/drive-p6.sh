#!/bin/bash
# 5f-P6b/c on the head node, lith main 35daae9 (#318). Pre-registration: inregion-streams.txt.
G=/scratch/lith-gates
echo "######## P6b $(date -u +%FT%TZ)"
B=$G/lith-318 OUT=$G/p6b MNT=/scratch/mnt/p6 REPS=2 PORT_BASE=9650 ARMS="T1 T2 T4 T16 T16D" $G/gate-p6b.sh
FP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07
M2=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/01
D375=$(for d in $(seq -w 1 16); do printf "GEOSFP.201907%s.A3dyn.025x03125.nc " $d; done)
M043=$(for d in $(seq -w 1 16); do printf "MERRA2.201901%s.A3cld.05x0625.nc4 " $d; done)
M122=$(for d in $(seq -w 1 16); do printf "MERRA2.201901%s.A3dyn.05x0625.nc4 " $d; done)
run() { echo "######## P6c ARM $1  $(date -u +%FT%TZ)"
  RESIDENT=1 OUT=$G/p6c-$1 MNT=/scratch/mnt/p6 B=$G/lith-318 REPS=2 ARMS="$1:" PREFIX=$2 \
    OBJLIST="$3" PORT_BASE=$4 NICG=50 SAMPLER=$G/sampler-p6.py $G/gate-p6c.sh; }
run M043 $M2 "$M043" 9610
run M122 $M2 "$M122" 9620
run D375 $FP "$D375" 9630
echo "######## P6 DONE $(date -u +%FT%TZ)"
