#!/bin/bash
# 5f-P42 (lith#314): does `--memory-limit auto` (PR #431) keep the configuration that OOM-killed lith on this 33 GB head
# node alive? R-TIER exactly: --mem-cache 20GB --prefetch-budget 4.127829504GB --nic-gbps 50, one mount of GEOS-FP
# 2019/07, 16 concurrent dd of 16 A3dyn objects (~60 GB) to fill the tier. No cgroup cap (the budget must be the box),
# no GOMEMLIMIT in the environment. Safety: lith's oom_score_adj = 1000, so if the box does OOM the kernel takes lith
# (as it did both times before) and nothing else. 1 Hz scrape of RSS, next_gc, GC pause sum/count, gomemlimit.
G=/scratch/lith-gates; B=${B:?set B to the tagged binary}; OUT=${OUT:-$G/p42}; MNT=/scratch/mnt/p42; PORT=13700
P=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07; mkdir -p "$OUT" "$MNT"; REPS=${REPS:-2}
arm() { local tag=$1; shift; PORT=$((PORT + 1)); rm -f "$OUT/$tag.stop" "$OUT/$tag.csv"
  env -u GOMEMLIMIT "$B" mount "$P" "$MNT" --metrics ":$PORT" --nic-gbps 50 --log-level warn --no-sign-request \
      ${MEMC---mem-cache 20GB} --prefetch-budget 4.127829504GB "$@" > "$OUT/$tag.mount.log" 2>&1 & local lp=$!
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -3 "$OUT/$tag.mount.log"; return 1; }
  local pid; pid=$(pgrep -f "[l]ith_linux_arm64 mount $P $MNT" | head -1); echo 1000 | sudo tee /proc/$pid/oom_score_adj > /dev/null
  pgrep -a -f "[l]ith_linux_arm64 mount $P $MNT" | cut -c1-260 > "$OUT/$tag.args.txt"
  curl -s "http://127.0.0.1:$PORT/metrics" | grep -E "^go_gc_gomemlimit_bytes|^lith_memory" > "$OUT/$tag.start.txt"
  ( while [ ! -f "$OUT/$tag.stop" ]; do
      curl -s --max-time 2 "http://127.0.0.1:$PORT/metrics" | awk -v t="$(date +%s.%N)" '
        /^process_resident_memory_bytes /{r=$2} /^go_memstats_next_gc_bytes /{n=$2} /^go_gc_duration_seconds_sum /{s=$2}
        /^go_gc_duration_seconds_count /{c=$2} /^go_gc_gomemlimit_bytes /{l=$2} /^lith_prefetch_committed_bytes /{k=$2}
        END{if (r) printf "%s,%s,%s,%s,%s,%s,%s\n", t, r, n, s, c, l, k}' >> "$OUT/$tag.csv"
      awk '/MemAvailable/{printf "%s\n", $2*1024}' /proc/meminfo | sed "s/^/$(date +%s.%N),/" >> "$OUT/$tag.memavail.csv"; sleep 1; done ) & local sp=$!
  local t0 rp=() d; t0=$(date +%s.%N)
  for d in $(seq -w 1 16); do dd if="$MNT/GEOSFP.201907$d.A3dyn.025x03125.nc" of=/dev/null bs=1M status=none & rp+=($!); done
  wait "${rp[@]}"; local w; w=$(echo "$(date +%s.%N) - $t0" | bc); sleep 2
  local alive=yes; kill -0 $lp 2>/dev/null || alive=NO
  touch "$OUT/$tag.stop"; wait $sp; fusermount3 -u "$MNT" 2>/dev/null; sleep 3
  awk -F, -v t="$tag" -v w="$w" -v a="$alive" 'BEGIN{G=1e9} {if($2>r)r=$2; if($3>n)n=$3; s=$4; c=$5; l=$6; if($7>k)k=$7}
    END{printf "ARM %s wall=%.1fs alive_at_end=%s | peak RSS %.2f GB  peak next_gc %.2f GB  gomemlimit %.2f GB  GC pause total %.2f s over %d cycles  peak committed %.2f GB\n",
      t, w, a, r/G, n/G, l/G, s, c, k/G}' "$OUT/$tag.csv"
  awk -F, 'NR==1||$2<m{m=$2} END{printf "  MemAvailable floor %.2f GB\n", m/1e9}' "$OUT/$tag.memavail.csv"
  sudo dmesg | grep -iE "oom-kill|Killed process" | tail -2 | sed 's/^/  dmesg: /'; }
echo "=== gate 5f-P42 $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12) tier=20GB MemTotal=$(awk '/MemTotal/{printf "%.2f GB", $2*1024/1e9}' /proc/meminfo)"
for r in $(seq 1 "$REPS"); do arm ${ARM:-A}-$r; done
echo "=== done $(date -u +%FT%TZ)"
