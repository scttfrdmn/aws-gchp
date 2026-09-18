#!/bin/bash
# lith#250 arm: the SUB-CHUNK case. Upstream names extent-level reads (#118) as a
# legitimate source of >1x that is not waste -- two ranks wanting different 64 KiB
# extents of the same 1 MiB chunk each fetch their own extents. My earlier arms
# split at 8 MiB, i.e. never inside a chunk, so they could not see this.
#
# Here two clients read DISJOINT ALTERNATE 64 KiB extents of one object, so every
# 1 MiB chunk is wanted by BOTH clients but no single extent is wanted twice. This
# also captures the trio upstream asked for -- lith_s3_bytes_total,
# lith_distinct_bytes_read, lith_cache_misses_total -- which the 2-node TOPOLOGY
# probe never scraped.
set -u -o pipefail
GATES=/scratch/lith-gates
LITH=$GATES/lith-1.1.2
PFX=s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07
IDX=$GATES/idx/merra2-201907.lithidx
PORT=20490; MET=9320; A=/mnt/gwA; B=/mnt/gwB; P=${P:-8}
FILE=${FILE:-MERRA2.20190701.A1.05x0625.nc4}
EXT=$((64*1024))
OUT=$GATES/coalesce-probe.txt
exec > >(tee -a "$OUT") 2>&1
echo; echo "### coalesce EXTENT arm $(date -u +%FT%TZ)  64 KiB extents inside 1 MiB chunks"
cleanup(){ sudo umount -f $A 2>/dev/null; sudo umount -f $B 2>/dev/null; pkill -f "[l]ith-1.1.2 serve" 2>/dev/null; sleep 2; }
trap cleanup EXIT
cleanup; sudo mkdir -p $A $B
start_gw(){ pkill -f "[l]ith-1.1.2 serve" 2>/dev/null; sleep 2
  setsid nohup $LITH serve nfs "$PFX" --index-file "$IDX" --no-sign-request \
    --mem-cache 8GB --nic-gbps 7.5 --listen :${PORT} --metrics :${MET} \
    > $GATES/coalesce-gw.log 2>&1 < /dev/null &
  for i in $(seq 20); do ss -ltn "sport = :${PORT}" 2>/dev/null | grep -q LISTEN && break; sleep 1; done
  ss -ltn "sport = :${PORT}" | grep -q LISTEN || { echo "  GATEWAY FAILED"; exit 1; }; }
mnt(){ sudo mount -t nfs -o "vers=3,proto=tcp,port=${PORT},mountport=${PORT},nolock,ro,nosharecache" localhost:/ "$1"; }
m(){ curl -s --max-time 5 http://localhost:${MET}/metrics | awk -v k="$1" 'index($0,k)==1 {print $NF; exit}'; }
rd(){ xargs -P "$P" -a "$1" -L1 sh -c 'dd if="$0" bs=64K skip="$1" count=1 of=/dev/null 2>/dev/null'; }

start_gw; mnt $A >/dev/null
SZ=$(stat -c %s "$A/$FILE"); N=$(( (SZ + EXT - 1) / EXT ))
: > /tmp/ex.all; : > /tmp/ex.A; : > /tmp/ex.B
for i in $(seq 0 $((N-1))); do
  echo "$A/$FILE $i" >> /tmp/ex.all
  if [ $((i % 2)) -eq 0 ]; then echo "$A/$FILE $i" >> /tmp/ex.A; else echo "$B/$FILE $i" >> /tmp/ex.B; fi
done
echo "  file: $FILE  $(awk -v s=$SZ 'BEGIN{printf "%.1f", s/2^20}') MiB  extents=${N} (A=$(wc -l < /tmp/ex.A) B=$(wc -l < /tmp/ex.B), disjoint)"
sudo umount -f $A 2>/dev/null

report(){ printf '%-24s wall=%6.2fs  nfs_read=%8.1f MB  distinct=%8.1f MB  s3=%8.1f MB  s3/distinct=%.3fx  cache_miss=%s\n' \
  "$1" "$2" "$3" "$4" "$5" "$(awk -v a=$5 -v b=$4 'BEGIN{if(b>0) print a/b; else print 0}')" "$6"; }

arm(){ # $1 label, $2 listA, $3 listB|-
  start_gw; mnt $A >/dev/null; [ "$3" != "-" ] && mnt $B >/dev/null
  sudo sysctl -q vm.drop_caches=3
  local n0 d0 b0 t0 t1 pa pb
  n0=$(m lith_nfs_read_bytes_total); d0=$(m lith_distinct_bytes_read); b0=$(m lith_s3_bytes_total)
  t0=$(date +%s.%N)
  rd "$2" & pa=$!
  if [ "$3" != "-" ]; then rd "$3" & pb=$!; wait $pa $pb; else wait $pa; fi
  t1=$(date +%s.%N)
  report "$1" "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" \
    "$(awk -v a=${n0:-0} -v b=$(m lith_nfs_read_bytes_total) 'BEGIN{print (b-a)/1e6}')" \
    "$(awk -v a=${d0:-0} -v b=$(m lith_distinct_bytes_read) 'BEGIN{print (b-a)/1e6}')" \
    "$(awk -v a=${b0:-0} -v b=$(m lith_s3_bytes_total) 'BEGIN{print (b-a)/1e6}')" \
    "$(m lith_cache_misses_total)"
  sudo umount -f $A 2>/dev/null; sudo umount -f $B 2>/dev/null
}

arm "EX-one-client-all"    /tmp/ex.all -
arm "EX-two-DISJOINT-64K"  /tmp/ex.A /tmp/ex.B
