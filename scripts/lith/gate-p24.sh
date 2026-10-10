#!/bin/bash
# 5f-P24 (lith#337): multi-client lith NFS gateway on ONE box via network namespaces. Pre-registered.
# Needs root (sudo). Cleans up every namespace, veth, the bridge and all mounts on exit.
G=/scratch/lith-gates; OUT=$G/p24; mkdir -p "$OUT"; BR=br337; SRV=10.250.0.1; NFSP=12049; MP=13900
B112=$G/v1120/lith_linux_arm64; B111=$G/v1110/lith_linux_arm64
EXP=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07; OBJ=GEOSFP.20190701.A3dyn.025x03125.nc; SM=/scratch/mnt/p24s
OPTS="vers=3,proto=tcp,port=$NFSP,mountport=$NFSP,mountproto=tcp,nolock,ro"; NMAX=47
cleanup() {
  sudo umount -l "$SM" 2>/dev/null; sudo pkill -f "serve nfs $EXP" 2>/dev/null
  for i in $(seq 1 $NMAX); do sudo ip netns del n337-$i 2>/dev/null; done
  sudo ip link del $BR 2>/dev/null; echo "cleanup done: netns=$(ip netns list 2>/dev/null | grep -c n337) bridge=$(ip link show $BR 2>/dev/null | grep -c $BR)"; }
trap cleanup EXIT
sudo ip link add $BR type bridge && sudo ip addr add $SRV/24 dev $BR && sudo ip link set $BR up
for i in $(seq 1 $NMAX); do
  ns=n337-$i; sudo ip netns add $ns; sudo ip link add v337h$i type veth peer name v337c$i
  sudo ip link set v337c$i netns $ns; sudo ip link set v337h$i master $BR up
  sudo ip netns exec $ns ip addr add 10.250.0.$((10 + i))/24 dev v337c$i; sudo ip netns exec $ns ip link set v337c$i up
  sudo ip netns exec $ns ip link set lo up
done
sudo mkdir -p "$SM"
cell() {  # cell TAG K BINARY
  local tag=$1 k=$2 bin=$3 i; MP=$((MP + 1))
  sudo pkill -f "serve nfs $EXP" 2>/dev/null; sleep 1
  sudo "$bin" serve nfs "$EXP" --listen "$SRV:$NFSP" --metrics ":$MP" --no-sign-request --nic-gbps 50 --log-level info > "$OUT/$tag.serve.log" 2>&1 &
  for _ in $(seq 1 60); do curl -s --max-time 1 "localhost:$MP/metrics" | grep -q '^lith_' && break; sleep 1; done
  for i in $(seq 1 "$k"); do  # idle clients: one MOUNT each, from their own IP, then unmount (registration persists)
    sudo ip netns exec n337-$i sh -c "mkdir -p /tmp/m337-$i && mount -t nfs -o $OPTS $SRV:/ /tmp/m337-$i && umount /tmp/m337-$i" 2>>"$OUT/$tag.idle.err"
  done
  sudo mount -t nfs -o "$OPTS" "$SRV:/" "$SM" || { echo "$tag stream mount FAILED"; return 1; }
  local nc; nc=$(curl -s "localhost:$MP/metrics" | awk '/^lith_nfs_clients /{print $2}')
  rm -f "$OUT/$tag.stop"
  ( while [ ! -f "$OUT/$tag.stop" ]; do curl -s --max-time 1 "localhost:$MP/metrics" | awk -v t="$(date +%s.%N)" '
      /^lith_prefetch_pressure /{p=$2} /^lith_prefetch_pressure_held_total /{h=$2} /^lith_readahead_window_blocks /{w=$2} /^lith_s3_bytes_total /{b=$2}
      END{printf "%s,%s,%s,%s,%s\n", t, p, h, w, b}' >> "$OUT/$tag.ts.csv"; sleep 0.5; done ) & local sp=$!
  local t0 t1; t0=$(date +%s.%N); dd if="$SM/$OBJ" of=/dev/null bs=1M status=none; t1=$(date +%s.%N)
  sleep 1; curl -s "localhost:$MP/metrics" > "$OUT/$tag.final.prom"; touch "$OUT/$tag.stop"; wait $sp
  sudo umount "$SM"
  local adm; adm=$(grep -oE '"msg":"(prefetch admission|prefetch bounds)".*' "$OUT/$tag.serve.log" | head -2 | cut -c1-200 | tr '\n' ' ')
  awk -F, -v t="$tag" -v nc="$nc" -v s="$(echo "$t1 - $t0" | bc)" 'NR==1{t0=$1} {if($2>p)p=$2; h=$3; if(w==""||$4<w)w=$4; if($4>wx)wx=$4} END{printf "CELL %s clients=%s wall=%.2fs MB/s=%.0f peak_pressure=%.3f held=%s window_min/max=%s/%s\n", t, nc, s, 3776.834855/s, p, h, w, wx}' "$OUT/$tag.ts.csv"
  echo "    $adm"; }
echo "=== gate 5f-P24 $(date -u +%FT%TZ) v112=$(md5sum "$B112" | cut -c1-12) v111=$(md5sum "$B111" | cut -c1-12)"
for r in 1 2; do cell K0-$r 0 "$B112"; cell K7-$r 7 "$B112"; cell K47-$r 47 "$B112"; cell K0v111-$r 0 "$B111"; done
echo "=== done $(date -u +%FT%TZ)"
