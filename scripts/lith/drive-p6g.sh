#!/bin/bash
# 5f-P6g: 5f-P6d's four c8gn cells on lith v1.7.0 (#313 post-#320). Pre-registration: inregion-streams.txt.
set -u
G=${G:-/home/ec2-user/g}
mapfile -t ALL < <(awk '{print $1}' "$G/fatnic-a3dyn-objects.txt")
lad() { # nic n [arm-label extra-flags]
  local lbl=${3:-L$2n$1} extra=${4:-}
  echo "######## ARM $lbl nic=$1  $(date -u +%FT%TZ)"
  OUT=$G/p6g-$lbl MNT=$G/mnt-p6g B=$G/lith_linux_arm64 PYX=python3 SAMPLER=$G/sampler-p6f.py REPS=${REPS:-2} \
    ARMS="$lbl:$extra" PREFIX=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019 RESIDENT=1 PRESSURE=1 \
    OBJLIST="${ALL[*]:0:$2}" PORT_BASE=$((9000 + $2 + ${1/auto/0})) NICG=$1 "$G/gate-p6f.sh"
  grep -ho '"msg":"prefetch bounds".*' "$G/p6g-$lbl"/*-1.mount.log | head -1
  sudo dmesg 2>/dev/null | grep -iE "out of memory|oom-kill" | tail -2
}
T0=$(date +%s)
lad auto 64; lad auto 112; lad 600 32; lad 600 64
# Conditional third arm (pre-registered): only if a collapse stayed and we are under 60 min.
if grep -hE "lith_prefetch_evicted_unread_total [1-9][0-9]{3,}" "$G"/p6g-*/*.met >/dev/null 2>&1 \
   && [ $(( $(date +%s) - T0 )) -lt 3600 ]; then
  REPS=1 lad auto 112 L112P10 "--prefetch-pressure-max 1.0"
fi
echo "######## P6G DONE $(date -u +%FT%TZ)"
