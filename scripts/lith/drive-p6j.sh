#!/bin/bash
# 5f-P6j (lith#313): pressure-max 0.85 and 0.5 on gate-off D375, v1.8.0. Pre-registration: inregion-streams.txt.
G=/scratch/lith-gates; FP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07
D375=$(for d in $(seq -w 1 16); do printf "GEOSFP.201907%s.A3dyn.025x03125.nc " $d; done)
RESIDENT=1 PRESSURE=1 OUT=$G/p6j-D375 MNT=/scratch/mnt/p6 B=$G/v180/lith_linux_arm64 REPS=2 \
  ARMS="G0P085:--readahead-evidence-ratio -1 --prefetch-pressure-max 0.85 G0P05:--readahead-evidence-ratio -1 --prefetch-pressure-max 0.5" \
  PREFIX=$FP OBJLIST="$D375" PORT_BASE=9800 NICG=50 SAMPLER=$G/sampler-p6f.py $G/gate-p6f.sh
echo "######## P6j DONE $(date -u +%FT%TZ)"
