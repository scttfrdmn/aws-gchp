#!/bin/bash
# 5f-P6d: upstream's resident-unread threshold (#313) on the four c8gn cells nearest the edge.
set -u
G=${G:-/home/ec2-user/g}
mapfile -t ALL < <(awk '{print $1}' "$G/fatnic-a3dyn-objects.txt")
lad() { # nic n
  echo "######## ARM L$2 nic=$1  $(date -u +%FT%TZ)"
  OUT=$G/p6d-L$2-$1 MNT=$G/mnt-p6d B=$G/lith-318 PYX=python3 SAMPLER=$G/sampler.py REPS=2 \
    ARMS="L$2n$1:" PREFIX=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019 RESIDENT=1 \
    OBJLIST="${ALL[*]:0:$2}" PORT_BASE=$((9000 + $2 + ${1/auto/0})) NICG=$1 "$G/gate-streams2.sh"
  grep -ho '"msg":"prefetch bounds".*' "$G/p6d-L$2-$1"/*-1.mount.log | head -1
  sudo dmesg 2>/dev/null | grep -iE "out of memory|oom-kill" | tail -2
}
lad auto 64; lad auto 112; lad 600 32; lad 600 64
echo "######## P6D DONE $(date -u +%FT%TZ)"
