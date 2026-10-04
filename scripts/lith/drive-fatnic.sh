#!/bin/bash
# Drives gates 5f-F1 (#239 slab vs stated NIC) and 5f-F2 (#313 distinct-object ladder) on a
# c8gn.48xlarge at STOCK defaults. Pre-registration: data/lith-gates/inregion-streams.txt,
# "GATE 5f-F". Objects: data/lith-gates/fatnic-a3dyn-objects.txt (July 2019 first).
set -u
G=${G:-/home/ec2-user/g}
TOK=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
echo "######## box $(curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-type)  MemTotal $(awk '/MemTotal/{print $2}' /proc/meminfo) kB  nproc $(nproc)"
LD_LIBRARY_PATH=$G/lib G=$G "$G/gate-slab-nic.sh"
mapfile -t ALL < <(awk '{print $1}' "$G/fatnic-a3dyn-objects.txt")
for n in 8 32 64 112; do
  echo "######## ARM L$n  $(date -u +%FT%TZ)"
  OUT=$G/f2-L$n MNT=$G/mnt-f2 B=$G/lith-315 PYX=python3 SAMPLER=$G/sampler.py REPS=2 \
    ARMS="L$n:" PREFIX=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019 \
    OBJLIST="${ALL[*]:0:$n}" PORT_BASE=$((9700 + n)) NICG=auto "$G/gate-streams2.sh"
  sudo dmesg 2>/dev/null | grep -iE "out of memory|oom-kill" | tail -2
done
echo "######## FATNIC DONE $(date -u +%FT%TZ)"
