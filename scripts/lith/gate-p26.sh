#!/bin/bash
# 5f-P26 (lith#337): netns gateway rig -- Q2 K0 A/B, #410 idle-client ladder, Q3 N streaming clients. Pre-registered.
G=/scratch/lith-gates; OUT=$G/p26; mkdir -p "$OUT"; BR=br337; SRV=10.250.0.1; NFSP=12049; MP=15000
B111=$G/v1110/lith_linux_arm64; B112=$G/v1120/lith_linux_arm64; BM=$G/lith-main-337; BP=$G/lith-pr410
EXP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07; SM=/scratch/mnt/p26s; NMAX=47
OPTS="vers=3,proto=tcp,port=$NFSP,mountport=$NFSP,mountproto=tcp,nolock,ro"
obj() { printf 'GEOSFP.201907%02d.A3dyn.025x03125.nc' "$1"; }
cleanup() { sudo umount -l "$SM" 2>/dev/null; sudo pkill -f "serve nfs $EXP" 2>/dev/null
  for i in $(seq 1 $NMAX); do sudo ip netns del n337-$i 2>/dev/null; done; sudo ip link del $BR 2>/dev/null
  echo "cleanup done: netns=$(ip netns list | grep -c n337) bridge=$(ip link show $BR 2>/dev/null | grep -c $BR)"; }
trap cleanup EXIT
sudo ip link add $BR type bridge && sudo ip addr add $SRV/24 dev $BR && sudo ip link set $BR up
for i in $(seq 1 $NMAX); do ns=n337-$i; sudo ip netns add $ns; sudo ip link add v337h$i type veth peer name v337c$i
  sudo ip link set v337c$i netns $ns; sudo ip link set v337h$i master $BR up
  sudo ip netns exec $ns ip addr add 10.250.0.$((10 + i))/24 dev v337c$i; sudo ip netns exec $ns ip link set v337c$i up; sudo ip netns exec $ns ip link set lo up; done
sudo mkdir -p "$SM"
serve() { MP=$((MP + 1)); sudo pkill -f "serve nfs $EXP" 2>/dev/null; sleep 1
  sudo "$1" serve nfs "$EXP" --listen "$SRV:$NFSP" --metrics ":$MP" --no-sign-request --nic-gbps 50 --log-level info > "$OUT/$2.serve.log" 2>&1 &
  for _ in $(seq 1 60); do curl -s --max-time 1 "localhost:$MP/metrics" | grep -q '^lith_' && break; sleep 1; done; }
sampler() { rm -f "$OUT/$1.stop"; ( while [ ! -f "$OUT/$1.stop" ]; do curl -s --max-time 1 "localhost:$MP/metrics" | awk -v t="$(date +%s.%N)" '
  /^lith_prefetch_pressure /{p=$2} /^lith_prefetch_pressure_held_total /{h=$2} /^lith_s3_bytes_total /{b=$2} /^lith_nfs_clients /{c=$2}
  END{printf "%s,%s,%s,%s,%s\n", t, (p==""?"NA":p), (h==""?0:h), b, c}' >> "$OUT/$1.ts.csv"; sleep 0.5; done ) & SPID=$!; }
finish() { sleep 1; curl -s "localhost:$MP/metrics" > "$OUT/$1.final.prom"; touch "$OUT/$1.stop"; wait $SPID 2>/dev/null
  awk '/^lith_s3_bytes_total /{b=$2} /^lith_prefetch_issued_total /{i=$2} /^lith_prefetch_used_total /{u=$2} /^lith_prefetch_pressure_held_total /{h=$2} /^lith_nfs_clients /{c=$2}
    /^lith_s3_requests_total.*op="get"/{g+=$2} END{printf "s3_GB=%.3f GETs=%d issued=%d used=%d held=%d nfs_clients=%s", b/1e9, g, i, u, h, c}' "$OUT/$1.final.prom"
  awk -F, '$2!="NA"{if($2>p)p=$2} END{printf " peak_pressure=%s", (p==""?"NA":sprintf("%.3f",p))}' "$OUT/$1.ts.csv"; }
idle_cell() { local tag=$1 k=$2 bin=$3 i; serve "$bin" "$tag"
  for i in $(seq 1 "$k"); do sudo ip netns exec n337-$i sh -c "mkdir -p /tmp/m$i && mount -t nfs -o $OPTS $SRV:/ /tmp/m$i && umount /tmp/m$i" 2>>"$OUT/$tag.idle.err"; done
  sudo mount -t nfs -o "$OPTS" "$SRV:/" "$SM"; sampler "$tag"
  local t0; t0=$(date +%s.%N); dd if="$SM/$(obj 1)" of=/dev/null bs=1M status=none; local w; w=$(echo "$(date +%s.%N) - $t0" | bc)
  sudo umount "$SM"; printf "CELL %s wall=%.2fs MB/s=%.0f " "$tag" "$w" "$(echo "3776.834855 / $w" | bc -l)"; finish "$tag"; echo; }
stream_cell() { local tag=$1 n=$2 bin=$3 i; serve "$bin" "$tag"; sampler "$tag"; rm -f "$OUT/$tag.walls"
  local t0 pids=(); t0=$(date +%s.%N)
  for i in $(seq 1 "$n"); do sudo ip netns exec n337-$i sh -c "mkdir -p /tmp/m$i && mount -t nfs -o $OPTS $SRV:/ /tmp/m$i && s=\$(date +%s.%N) && dd if=/tmp/m$i/$(obj $i) of=/dev/null bs=1M status=none && echo $i \$(echo \"\$(date +%s.%N) - \$s\" | bc) >> $OUT/$tag.walls; umount /tmp/m$i" 2>>"$OUT/$tag.err" & pids+=($!); done
  wait "${pids[@]}"; local w; w=$(echo "$(date +%s.%N) - $t0" | bc)
  awk -v t="$tag" -v w="$w" -v n="$n" '{x=$2+0; if(c==0||x<mn)mn=x; if(x>mx)mx=x; c++} END{printf "CELL %s streams=%d/%d wall=%.1fs agg_MB/s=%.0f spread=%.2f ", t, c, n, w, n*3776.834855/w, mx/mn}' "$OUT/$tag.walls"
  finish "$tag"; awk -F, 'NR==1{t0=$1} {T=$1; h[NR]=$3; ts[NR]=$1} END{H=h[NR]; c20=0; for(i=1;i<=NR;i++) if(ts[i]-t0<=0.2*(T-t0)) c20=h[i]; printf " held_in_first20pct=%s/%s", c20, H}' "$OUT/$tag.ts.csv"; echo; }
echo "=== gate 5f-P26 $(date -u +%FT%TZ) v111=$(md5sum $B111|cut -c1-12) v112=$(md5sum $B112|cut -c1-12) main=$(md5sum $BM|cut -c1-12) pr410=$(md5sum $BP|cut -c1-12)"
echo "--- Part A (Q2)"; for r in 1 2 3 4 5; do idle_cell A-v111-$r 0 $B111; idle_cell A-v112-$r 0 $B112; done
echo "--- Part B (#410 ladder)"; for r in 1 2; do for k in 0 7 47; do idle_cell B-K$k-main-$r $k $BM; idle_cell B-K$k-pr410-$r $k $BP; done; done
echo "--- Part C (Q3 streaming)"; for r in 1 2; do for n in 8 16; do stream_cell C-S$n-main-$r $n $BM; stream_cell C-S$n-pr410-$r $n $BP; done; done
echo "=== done $(date -u +%FT%TZ)"
