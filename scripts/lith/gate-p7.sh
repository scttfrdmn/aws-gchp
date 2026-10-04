#!/bin/bash
# Gate 5f-P7 (lith#320): what holds prefetch_committed above unread_resident with nothing in
# flight? Pre-registered in data/lith-gates/inregion-streams.txt before any cell ran.
#
# P6c/P6d compared PEAK committed with PEAK unread_resident, taken separately. Here both are read
# on the SAME scrape as lith_fill_inflight, after the readers exit and the fills settle, so an
# in-flight explanation and an accounting leak make different predictions:
#
#   F    1 dd bs=1M, one whole object
#   FX   F with --max-readahead 1 (demand races the prefetch frontier often)
#   H    python reader: first 1024 MiB, handle held 20 s, close, 15 s more
#   M3   3 dd on 3 distinct objects
#
# Head node, in-region; ~40 GB of GETs, ~$0.003.
set -u

G=${G:-/scratch/lith-gates}
OUT=${OUT:-$G/p7}
MNT=${MNT:-/scratch/mnt/p7}
B=${B:-$G/lith-main}
PYX=${PYX:-/scratch/ncenv/bin/python}
PREFIX=${PREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}
MEMC=${MEMC:-16GB}
REPS=${REPS:-2}
SETTLE=${SETTLE:-20}
PORT_BASE=${PORT_BASE:-9950}
ARMS=${ARMS:-"F FX H M3"}
mkdir -p "$OUT" "$MNT"

KEYS="prefetch_committed_bytes prefetch_unread_resident_bytes fill_inflight prefetch_issued_total prefetch_used_total prefetch_uncovered_total prefetch_evicted_unread_total read_straddle_total open_handles"

cat > "$OUT/sampler.py" <<'PY'
import os, sys, time, urllib.request
url, out, hz, stop = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
WANT = ["lith_" + k for k in sys.argv[5].split()]
f = open(out, "w")
f.write("t," + ",".join(w[5:] for w in WANT) + "\n")
t0 = time.time()
while not os.path.exists(stop):
    try:
        body = urllib.request.urlopen(url, timeout=2).read().decode()
    except Exception:
        time.sleep(1.0 / hz); continue
    v = {}
    for ln in body.splitlines():
        p = ln.split()
        if len(p) >= 2 and p[0] in WANT:
            v[p[0]] = p[1]
    f.write("%.3f,%s\n" % (time.time() - t0, ",".join(v.get(w, "NA") for w in WANT)))
    f.flush()
    time.sleep(1.0 / hz)
PY

cat > "$OUT/holdread.py" <<'PY'
import sys, time
path, mib, hold = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
fd = open(path, "rb", buffering=0)
for _ in range(mib):
    fd.read(1 << 20)
open(sys.argv[4], "w").close()          # "read done, holding"
time.sleep(hold)
fd.close()
PY

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

# snap LABEL: one scrape, every key on one line, plus G = committed - unread_resident
snap() {
  curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | awk -v keys="$KEYS" -v lbl="$1" '
    BEGIN{n=split(keys,K," "); for(i=1;i<=n;i++) want["lith_" K[i]]=K[i]}
    ($1 in want){v[want[$1]]=$2}
    END{c=v["prefetch_committed_bytes"]; r=v["prefetch_unread_resident_bytes"]
        K_=v["prefetch_issued_total"]-v["prefetch_used_total"]-v["prefetch_evicted_unread_total"]
        printf "  SNAP %-10s G_MiB=%.1f committed_MiB=%.1f resident_MiB=%.1f inflight=%s K=%d U=%s issued=%s used=%s evicted=%s straddle=%s open=%s\n",
          lbl, (c-r)/1048576, c/1048576, r/1048576, v["fill_inflight"], K_, v["prefetch_uncovered_total"],
          v["prefetch_issued_total"], v["prefetch_used_total"], v["prefetch_evicted_unread_total"],
          v["read_straddle_total"], v["open_handles"]}'
}

N=0
run_cell() {
  local arm=$1 rep=$2 tag="$1-$2" xf=() objs=() rp=() i
  case "$arm" in
    F|H) objs=(GEOSFP.20190701.A3dyn.025x03125.nc) ;;
    FX)  objs=(GEOSFP.20190701.A3dyn.025x03125.nc); xf=(--max-readahead 1) ;;
    M3)  objs=(GEOSFP.201907{01..03}.A3dyn.025x03125.nc) ;;
    *) echo "unknown arm $arm"; return 1 ;;
  esac
  N=$((N + 1)); PORT=$((PORT_BASE + N))
  rm -f "$OUT/$tag".*
  umount_wait
  "$B" mount "$PREFIX" "$MNT" --metrics ":$PORT" --mem-cache "$MEMC" --log-level info "${xf[@]}" \
      > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; }
  $PYX "$OUT/sampler.py" "http://127.0.0.1:$PORT/metrics" "$OUT/$tag.samples.csv" 5 \
      "$OUT/$tag.stop" "$KEYS" > "$OUT/$tag.sampler.log" 2>&1 &
  local spid=$!
  local t0; t0=$(date +%s.%N)
  echo "CELL $tag flags=${xf[*]:-none} objects=${#objs[@]}"
  if [ "$arm" = H ]; then
    $PYX "$OUT/holdread.py" "$MNT/${objs[0]}" 1024 20 "$OUT/$tag.held" &
    local hp=$!
    for _ in $(seq 1 600); do [ -f "$OUT/$tag.held" ] && break; sleep 0.1; done
    echo "  read 1024 MiB in $(echo "$(date +%s.%N) - $t0" | bc) s; holding"
    sleep 1;  snap "held+1s"
    sleep 17; snap "held+18s"
    wait "$hp"; echo "  closed"
    sleep 1;  snap "closed+1s"
    sleep 14; snap "closed+15s"
  else
    for o in "${objs[@]}"; do
      ( dd if="$MNT/$o" of=/dev/null bs=1M status=none 2>> "$OUT/$tag.dderr" ) &
      rp+=($!)
    done
    wait "${rp[@]}"
    echo "  readers done in $(echo "$(date +%s.%N) - $t0" | bc) s"
    snap "exit+0s"
    sleep 5; snap "exit+5s"
    sleep $((SETTLE - 5)); snap "exit+${SETTLE}s"
  fi
  touch "$OUT/$tag.stop"; wait "$spid" 2>/dev/null
  [ -s "$OUT/$tag.dderr" ] && head -2 "$OUT/$tag.dderr"
  # Simultaneous difference over the whole run: max G, and max G among scrapes with inflight 0
  awk -F, 'NR==1{for(i=1;i<=NF;i++)c[$i]=i; next}
    {g=$c["prefetch_committed_bytes"]-$c["prefetch_unread_resident_bytes"]; if(g>m)m=g
     if($c["fill_inflight"]==0 && g>m0)m0=g
     pc=$c["prefetch_committed_bytes"]; if(pc>PC)PC=pc; pr=$c["prefetch_unread_resident_bytes"]; if(pr>PR)PR=pr}
    END{printf "  SERIES max_G_MiB=%.1f max_G_at_inflight0_MiB=%.1f peak_committed-peak_resident_MiB=%.1f rows=%d\n", m/1048576, m0/1048576, (PC-PR)/1048576, NR-1}' \
    "$OUT/$tag.samples.csv"
  umount_wait
}

echo "=== gate 5f-P7  $(date -u +%FT%TZ)  B=$(md5sum "$B" | cut -c1-12)  memc=$MEMC reps=$REPS"
for rep in $(seq 1 "$REPS"); do
  for a in $ARMS; do run_cell "$a" "$rep"; done
done
echo "=== done $(date -u +%FT%TZ)"
