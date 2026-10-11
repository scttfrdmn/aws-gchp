#!/bin/bash
L=/scratch/lith-gates/lith-main-412; M=/scratch/mnt/p30c; O=/scratch/sweep/p30c; mkdir -p $M $O
EXP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07; d=10; port=10600
echo "=== P30c $(date -u +%FT%TZ) lith=$(md5sum $L | cut -c1-12)"
for rep in 1 2; do for arm in R4 R2; do
  d=$((d + 1)); port=$((port + 1)); f=$(printf 'GEOSFP.201907%02d.A3dyn.025x03125.nc' $d); tag=$arm-$rep
  $L mount $EXP $M --no-sign-request --nic-gbps 15 --readahead-evidence-ratio ${arm:1} --metrics :$port --log-level warn > $O/$tag.mount.log 2>&1 &
  for i in $(seq 1 60); do sudo mountpoint -q $M && break; sleep 1; done
  sz=$(stat -c %s $M/$f); t0=$(date +%s.%N); dd if=$M/$f of=/dev/null bs=1M status=none; t1=$(date +%s.%N)
  s3=$(curl -s localhost:$port/metrics | awk '$1=="lith_s3_bytes_total"{print $2}')
  echo "CELL $tag file=$f size=$sz wall=$(echo "$t1 - $t0" | bc) MBps=$(echo "$sz / ($t1 - $t0) / 1000000" | bc) s3_over_size=$(awk -v a="$s3" -v b="$sz" "BEGIN{printf \"%.3f\", a/b}")"
  fusermount3 -u $M; for i in $(seq 1 30); do sudo mountpoint -q $M || break; sleep 1; done
done; done
echo "=== done $(date -u +%FT%TZ)"
