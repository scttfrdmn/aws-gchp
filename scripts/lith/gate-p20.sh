#!/bin/bash
# 5f-P20 (lith#314): lith RSS vs Go GC target with a full tier. Pre-registered in inregion-streams.txt.
G=/scratch/lith-gates; B=$G/v1120/lith_linux_arm64; OUT=$G/p20; MNT=/scratch/mnt/p20; PORT=13600
P=s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07; mkdir -p "$OUT"; sudo mkdir -p "$MNT"
arm() { local tag=$1; shift; PORT=$((PORT + 1))
  sudo systemd-run --scope -p MemoryMax=24G --unit "p20-$tag" "$B" mount "$P" "$MNT" --metrics ":$PORT" --nic-gbps 50 \
      --log-level warn --no-sign-request --mem-cache 10GB "$@" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do sudo mountpoint -q "$MNT" && break; sleep 1; done
  sudo mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -3 "$OUT/$tag.mount.log"; return 1; }
  rm -f "$OUT/$tag.stop"
  ( while [ ! -f "$OUT/$tag.stop" ]; do
      curl -s --max-time 2 "http://127.0.0.1:$PORT/metrics" | awk -v t="$(date +%s.%N)" '
        /^process_resident_memory_bytes /{r=$2} /^go_memstats_next_gc_bytes /{n=$2} /^go_memstats_heap_inuse_bytes /{u=$2}
        /^go_memstats_heap_idle_bytes /{i=$2} /^lith_prefetch_committed_bytes /{c=$2} /^lith_prefetch_unread_resident_bytes /{q=$2}
        END{if (r) printf "%s,%s,%s,%s,%s,%s,%s\n", t, r, n, u, i, c, q}' >> "$OUT/$tag.csv"; sleep 1; done ) & local sp=$!
  local t0 rp=() d; t0=$(date +%s.%N)
  for d in $(seq -w 1 16); do sudo dd if="$MNT/GEOSFP.201907$d.A3dyn.025x03125.nc" of=/dev/null bs=1M status=none & rp+=($!); done
  wait "${rp[@]}"; local w; w=$(echo "$(date +%s.%N) - $t0" | bc); sleep 2
  touch "$OUT/$tag.stop"; wait $sp; sudo fusermount3 -u "$MNT"; sleep 3
  awk -F, -v t="$tag" -v w="$w" 'BEGIN{G=1e9} {if($2>r)r=$2; if($3>n)n=$3; if($4>u)u=$4; if($5>i)i=$5; d=$6-$7; if(d>cd)cd=d; if($6>c)c=$6}
    END{printf "ARM %s wall=%.1fs | peak RSS %.2f GB  next_gc %.2f GB  heap_inuse %.2f  heap_idle %.2f  committed %.2f  (committed-unread) %.2f GB | RSS/next_gc %.2f  next_gc/tier %.2f\n",
      t, w, r/G, n/G, u/G, i/G, c/G, cd/G, r/n, n/10e9}' "$OUT/$tag.csv"
  grep -iE "oom|killed|memory" "$OUT/$tag.mount.log" | head -2; }
echo "=== gate 5f-P20 $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12) tier=10GB cap=24G"
arm D; arm G0 --readahead-evidence-ratio -1; arm G0P --readahead-evidence-ratio -1 --prefetch-pressure-max -1
echo "=== done $(date -u +%FT%TZ)"
