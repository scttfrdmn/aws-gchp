#!/bin/bash
# 5f-F amendment: the 600 Gbps derivation, then the rest of the stock (auto=50) ladder.
set -u
G=${G:-/home/ec2-user/g}
LD_LIBRARY_PATH=$G/lib G=$G OUT=$G/f1b NICS=600 PORT_BASE=9950 "$G/gate-slab-nic.sh"
mapfile -t ALL < <(awk '{print $1}' "$G/fatnic-a3dyn-objects.txt")
lad() { # nic n
  echo "######## ARM L$2 nic=$1  $(date -u +%FT%TZ)"
  OUT=$G/f2-L$2-$1 MNT=$G/mnt-f2 B=$G/lith-315 PYX=python3 SAMPLER=$G/sampler.py REPS=2 \
    ARMS="L$2n$1:" PREFIX=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019 \
    OBJLIST="${ALL[*]:0:$2}" PORT_BASE=$((9000 + $2 + ${1/auto/0})) NICG=$1 "$G/gate-streams2.sh"
  sudo dmesg 2>/dev/null | grep -iE "out of memory|oom-kill" | tail -2
}
for n in 8 32 64 112; do lad 600 $n; done
for n in 64 112; do lad auto $n; done
echo "######## FATNIC2 DONE $(date -u +%FT%TZ)"
