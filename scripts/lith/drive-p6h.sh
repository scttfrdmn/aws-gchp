#!/bin/bash
# 5f-P6h (lith#313): D375 on v1.7.0, region gate default vs forced off. Pre-registration: inregion-streams.txt.
G=/scratch/lith-gates; FP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07
D375=$(for d in $(seq -w 1 16); do printf "GEOSFP.201907%s.A3dyn.025x03125.nc " $d; done)
RESIDENT=1 PRESSURE=1 OUT=$G/p6h-D375 MNT=/scratch/mnt/p6 B=$G/v170/lith_linux_arm64 REPS=2 \
  ARMS="D375: D375G0:--readahead-evidence-ratio -1" PREFIX=$FP OBJLIST="$D375" PORT_BASE=9760 NICG=50 \
  SAMPLER=$G/sampler-p6f.py $G/gate-p6f.sh
echo "######## P6h DONE $(date -u +%FT%TZ)"
