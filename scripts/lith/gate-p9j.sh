#!/bin/bash
# Gate 5f-P9j (lith#349): the TTFB floor under real GCHP load. Pre-registered in
# data/lith-gates/inregion-streams.txt. Same mounts, indexes, run dir and official setup scripts as
# gate-streams-gchp.sh (5f-P3); the differences are the binary (v1.5.0), the rank count (12 = max on
# this 16-core head node) and a sampler that records the TTFB histogram + lith_s3_inflight per mount.
# C1 (idle) is scripts/lith/p9i-seq.sh with OUT=$OUT/idle. Not `set -u`: setCommonRunSettings.sh
# dereferences $4 (see gate-streams-gchp.sh).
GATES=${GATES:-/scratch/lith-gates}
LITH=${LITH:-$GATES/v150/lith_linux_arm64}
SRC=${SRC:-/scratch/gchp_lith_TransportTracers}
RD=${RD:-/scratch/gchp_p9j_TT}
OUT=${OUT:-$GATES/p9j}
PYX=${PYX:-/scratch/ncenv/bin/python}
RANKS=${RANKS:-12}
REPS=${REPS:-2}
HZ=${HZ:-2}
DEADLINE=${DEADLINE:-1200}
MEMC=${MEMC:-2GB}
PORTS="9210 9211 9212 9213 9214"
NAMES="merra2-201901 merra2-201501 hemco cheminputs restarts"
MNTS="GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS"
IDX="merra2 merra2-2015 hemco cheminp restarts"
mkdir -p "$OUT"
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

clean_lith() {
  for m in $MNTS; do fusermount3 -u "/input-lith/$m" >/dev/null 2>&1; done
  pkill -f "lith_linux_arm64 mount s3://gcgrid" >/dev/null 2>&1
  sleep 2; say "  stale fuse.lith mounts after cleanup: $(mount | grep -c fuse.lith)"
}

mount_lith() {
  local m i p alive=0; set -- $IDX; p=9210
  # mkdir + chown every mount point BEFORE the first mount: a chown -R after a mount descends into
  # the FUSE mount, which root cannot traverse without allow_other (harmless "Permission denied").
  for m in $MNTS; do sudo mkdir -p "/input-lith/$m"; done
  sudo chown -R "$(id -u):$(id -g)" /input-lith
  for m in $MNTS; do
    "$LITH" mount "s3://gcgrid/$m" "/input-lith/$m" --index-file "$GATES/idx/$1.lithidx" \
        --no-sign-request --nic-gbps 50 --mem-cache "$MEMC" --metrics ":$p" --daemon
    shift; p=$((p + 1))
  done
  sleep 6
  for p in $PORTS; do curl -s --max-time 4 "http://localhost:$p/metrics" | grep -q '^lith_' && alive=$((alive + 1)); done
  say "  fuse.lith mounts: $(mount | grep -c fuse.lith)  daemons answering: $alive/5"
  [ "$(mount | grep -c fuse.lith)" -eq 5 ] && [ "$alive" -eq 5 ]
}

prep_rundir() {
  rm -rf "$RD"; cp -a "$SRC" "$RD" || return 1; cd "$RD" || return 1
  sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$RANKS/" setCommonRunSettings.sh
  sed -i "s/^NUM_NODES=.*/NUM_NODES=1/" setCommonRunSettings.sh
  sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RANKS/" setCommonRunSettings.sh
  echo "20190101 000000" > cap_restart
  rm -f gcchem_internal_checkpoint Restarts/gcchem_internal_checkpoint*
  source /sw/gchp-env.sh; ulimit -s unlimited 2>/dev/null
  source ./setCommonRunSettings.sh > "$OUT/setcommon.log" 2>&1
  source ./setRestartLink.sh >> "$OUT/setcommon.log" 2>&1
  source ./checkRunSettings.sh > "$OUT/checkrun.log" 2>&1
  if grep -qiE "^ *ERROR|must equal" "$OUT/checkrun.log"; then
    say "  checkRunSettings.sh OBJECTED:"; grep -iE "^ *ERROR|must equal" "$OUT/checkrun.log" | head -5; return 1
  fi
  say "  layout: NX=$(awk '/^NX:/{print $2}' GCHP.rc) NY=$(awk '/^NY:/{print $2}' GCHP.rc) ranks=$RANKS"
}

cat > "$OUT/sampler.py" <<'PY'
# One row per mount per tick: cumulative TTFB histogram (le 0.025 / 0.06 / count), median, gauge, inflight.
import os, sys, time, urllib.request
out, hz, stop = sys.argv[1], float(sys.argv[2]), sys.argv[3]
targets = [a.split("=", 1) for a in sys.argv[4:]]
KEYS = {"lith_ttfb_seconds_bucket{le=\"0.025\"}": "le025", "lith_ttfb_seconds_bucket{le=\"0.06\"}": "le060",
        "lith_ttfb_seconds_count": "count", "lith_ttfb_median_seconds": "median",
        "lith_ttfb_measured": "measured", "lith_readahead_evidence_ratio": "gauge",
        "lith_s3_inflight": "inflight", "lith_s3_bytes_total": "s3bytes", "lith_open_handles": "open",
        "lith_ttfb_floor_seconds": "floor"}   # v1.6.0+; NA on older binaries
cols = list(KEYS.values())
f = open(out, "w"); f.write("t,mount," + ",".join(cols) + "\n"); t0 = time.time()
while not os.path.exists(stop):
    for name, url in targets:
        try: body = urllib.request.urlopen(url, timeout=2).read().decode()
        except Exception: continue
        v = {}
        for ln in body.splitlines():
            if ln.startswith("#"): continue
            k, _, val = ln.rpartition(" ")
            if k in KEYS: v[KEYS[k]] = val
        if len(v) >= len(cols) - 1:
            f.write("%.2f,%s,%s\n" % (time.time() - t0, name, ",".join(v.get(c, "NA") for c in cols)))
    f.flush(); time.sleep(1.0 / hz)
f.close()
PY

run_rep() {
  local rep=$1 R=$OUT/rep$rep; mkdir -p "$R"
  say "=== rep $rep"
  clean_lith; mount_lith || { say "MOUNTS NOT HEALTHY"; clean_lith; return 1; }
  prep_rundir || { clean_lith; return 1; }
  rm -f "$R/stop"; local tg=() p; set -- $NAMES
  for p in $PORTS; do tg+=("$1=http://127.0.0.1:$p/metrics"); shift; done
  $PYX "$OUT/sampler.py" "$R/ttfb.csv" "$HZ" "$R/stop" "${tg[@]}" > "$R/sampler.log" 2>&1 & local spid=$!
  cd "$RD" || return 1
  mpirun -n "$RANKS" ./gchp > "$R/gchp.log" 2>&1 & local mpid=$!
  local t0 el; t0=$(date +%s)
  while :; do
    el=$(( $(date +%s) - t0 ))
    [ "$(awk '{print $1}' "$RD/cap_restart")" != "20190101" ] && { say "  cap_restart advanced at ${el}s"; break; }
    grep -q "write file: Restarts/gcchem_internal_checkpoint" "$R/gchp.log" 2>/dev/null && { say "  checkpoint write reached at ${el}s"; break; }
    kill -0 "$mpid" 2>/dev/null || { say "  mpirun exited at ${el}s"; break; }
    [ "$el" -ge "$DEADLINE" ] && { say "  deadline ${DEADLINE}s"; break; }
    sleep 5
  done
  for p in $PORTS; do curl -s "http://127.0.0.1:$p/metrics" > "$R/final.$p.prom"; done
  touch "$R/stop"; wait "$spid" 2>/dev/null
  pkill -f "mpirun -n $RANKS ./gchp" >/dev/null 2>&1; pkill -x gchp >/dev/null 2>&1; sleep 3
  say "  timesteps: $(grep -c 'GCHP Date' "$R/gchp.log")"
  grep -iE "ERROR|forrtl" "$R/gchp.log" | head -3
  clean_lith
}

say "=== gate 5f-P9j  $(date -u +%FT%TZ)  ranks=$RANKS reps=$REPS lith=$(md5sum "$LITH" | cut -c1-12)"
for rep in $(seq 1 "$REPS"); do run_rep "$rep"; done
say "=== done $(date -u +%FT%TZ)"
