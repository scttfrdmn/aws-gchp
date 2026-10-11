#!/bin/bash
# Gate 5f-P3 (lith#301 ask 2 / #312): on a real GCHP mount, how many of the open
# DESCRIPTORS are established sequential STREAMS?
#
# Upstream's ask, and the one they called cheap and decisive:
#
#   "lith_streaming_handles vs lith_open_handles on a production mount. Expect ~48 against
#    ~288. If streams come out near 288, then most of those descriptors establish and idle,
#    and the residual is the dominant term rather than a footnote."
#
# Why this cannot be answered by the synthetic arms, even though they were run first: 5f-P
# arm B showed that a handle doing ONE 4 KiB pread and then idling contributes 0 to
# streaming_handles -- 255 of them and the divisor stayed at 0. But a real netCDF open is not
# one pread. It is a superblock read, a B-tree walk, and then scattered metadata, which has
# enough reads in it to plausibly establish and enough discontiguity to plausibly not. Only
# the real library on the real files decides, so this runs GCHP.
#
# WHAT IS MEASURED, and the honest limit on it: this box is a 16-core c7g.4xlarge head node,
# so this is 6 ranks, not the 48 that produced the ~288 figure. The quantity that transfers is
# the RATIO -- what fraction of the descriptors GCHP holds open are simultaneously established
# streams -- because that is a property of how the netCDF layer reads a file, not of how many
# ranks do it. The absolute counts here will be ~1/8 of the production ones and are reported
# as such. A 6-rank head-node dry run is the same configuration gate 3c used to catch its
# pre-flight failures, so the path is proven.
#
# Run directory: a COPY of the validated 48-rank TT run dir, with the three official
# rank knobs set to 6 via setCommonRunSettings.sh and validated by checkRunSettings.sh.
# Nothing is hand-edited in GCHP.rc, CAP.rc or HISTORY.rc -- per the project rule, the setup
# scripts own those files. If checkRunSettings.sh objects, this script stops.
#
# Deliberately NOT `set -u`, for the reason gate 3c recorded and I then walked into again:
# GCHP's own setCommonRunSettings.sh dereferences $4, so sourcing it under `set -u` aborts the
# sourcing shell at line 578 with "unbound variable" and the run never starts. Every variable
# here uses ${VAR:-default}, so -u buys nothing anyway.

GATES=${GATES:-/scratch/lith-gates}
LITH=${LITH:-$GATES/lith-311}
SRC=${SRC:-/scratch/gchp_lith_TransportTracers}
RD=${RD:-/scratch/gchp_streams_TT}
OUT=${OUT:-$GATES/gate-streams-gchp}
PYX=${PYX:-/scratch/ncenv/bin/python}
RANKS=${RANKS:-6}
NIC=${NIC:-50}
HZ=${HZ:-2}
DEADLINE=${DEADLINE:-900}
MEMC=${MEMC:-2GB}      # per daemon; 5 daemons on a 33 GB box that also runs the model

PORTS="9210 9211 9212 9213 9214"
NAMES="merra2-201901 merra2-201501 hemco cheminputs restarts"

mkdir -p "$OUT"

say() { echo "[$(date -u +%H:%M:%S)] $*"; }

clean_lith() {
  for m in /input-lith/GEOS_0.5x0.625/MERRA2/2019/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
           /input-lith/HEMCO /input-lith/CHEM_INPUTS /input-lith/GEOSCHEM_RESTARTS; do
    fusermount3 -u "$m" >/dev/null 2>&1
  done
  pkill -f "lith-311 mount" >/dev/null 2>&1
  sleep ${TL:+8}${TL:-2}   # P21: give --timeline-csv time to write at unmount
  local left; left=$(mount | grep -c fuse.lith)
  say "  stale fuse.lith mounts after cleanup: $left"
}

mount_lith() {
  for d in GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 \
           HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
    sudo mkdir -p "/input-lith/${d}"
  done
  sudo chown -R "$(id -u):$(id -g)" /input-lith
  # Same five prefix-scoped mounts and the same indexes gate 3c used. --mem-cache is bounded
  # on every one: the default is 25% of system memory PER DAEMON, so five daemons would cap
  # 125% of this box and GCHP needs that memory. Note the consequence for the window -- a
  # 2 GB tier means a 1 GB prefetch budget, so budgetBlocks is 128 at 8 MiB rather than the
  # 492 of the synthetic arms. The HANDLE COUNTS are what this gate is for; the window is
  # reported but is budget-scaled to this box and is not comparable to production.
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/01 /input-lith/GEOS_0.5x0.625/MERRA2/2019/01 \
      --index-file "$GATES/idx/merra2.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9210" ${TL:+--timeline-csv $OUT/tl-9210.csv} --daemon
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2015/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
      --index-file "$GATES/idx/merra2-2015.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9211" ${TL:+--timeline-csv $OUT/tl-9211.csv} --daemon
  "$LITH" mount s3://gcgrid/HEMCO /input-lith/HEMCO \
      --index-file "$GATES/idx/hemco.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9212" ${TL:+--timeline-csv $OUT/tl-9212.csv} --daemon
  "$LITH" mount s3://gcgrid/CHEM_INPUTS /input-lith/CHEM_INPUTS \
      --index-file "$GATES/idx/cheminp.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9213" ${TL:+--timeline-csv $OUT/tl-9213.csv} --daemon
  "$LITH" mount s3://gcgrid/GEOSCHEM_RESTARTS /input-lith/GEOSCHEM_RESTARTS \
      --index-file "$GATES/idx/restarts.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9214" ${TL:+--timeline-csv $OUT/tl-9214.csv} --daemon
  sleep 6
  local n alive=0 p
  n=$(mount | grep -c fuse.lith)
  for p in $PORTS; do
    curl -s --max-time 4 "http://localhost:$p/metrics" | grep -q '^lith_' && alive=$((alive + 1))
  done
  say "  fuse.lith mounts: $n   daemons answering: $alive/5"
  # Counting mount entries is not evidence that OUR daemons serve them -- gate 3c's job 13
  # fooled itself exactly that way. Each daemon proves itself on its own metrics port.
  [ "$n" -eq 5 ] && [ "$alive" -eq 5 ] || { say "  MOUNTS NOT HEALTHY -- refusing to run"; return 1; }
}

prep_rundir() {
  rm -rf "$RD"
  cp -a "$SRC" "$RD" || return 1
  cd "$RD" || return 1
  # The three rank knobs are independent; TOTAL_CORES is NOT derived from the other two, and
  # getting that wrong is how an earlier job died. Set all three, then let the official
  # scripts compute the layout and validate it.
  sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$RANKS/" setCommonRunSettings.sh
  sed -i "s/^NUM_NODES=.*/NUM_NODES=1/" setCommonRunSettings.sh
  sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RANKS/" setCommonRunSettings.sh
  echo "20190101 000000" > cap_restart
  # The checkpoint lives in Restarts/, and a stale one makes the pnc4 create fail NC_EEXIST
  # (NetCDF4_FileFormatter.F90:189, status -35) at the END of an otherwise good run. Banked.
  rm -f gcchem_internal_checkpoint Restarts/gcchem_internal_checkpoint*
  source /sw/gchp-env.sh
  ulimit -s unlimited 2>/dev/null
  source ./setCommonRunSettings.sh > "$OUT/setcommon.log" 2>&1
  source ./setRestartLink.sh >> "$OUT/setcommon.log" 2>&1
  source ./checkRunSettings.sh > "$OUT/checkrun.log" 2>&1
  if grep -qiE "^ *ERROR|must equal" "$OUT/checkrun.log"; then
    say "  checkRunSettings.sh OBJECTED -- stopping rather than guessing:"
    grep -iE "^ *ERROR|must equal" "$OUT/checkrun.log" | head -5
    return 1
  fi
  say "  layout: NX=$(awk '/^NX:/{print $2}' GCHP.rc) NY=$(awk '/^NY:/{print $2}' GCHP.rc)" \
      "CS_RES=$(awk '/^CS_RES:/{print $2}' GCHP.rc) ranks=$RANKS"
}

cat > "$OUT/sampler.py" <<'PY'
# One row per mount per tick: the two handle counts and the window they produce.
import os, sys, time, urllib.request
out, hz, stop = sys.argv[1], float(sys.argv[2]), sys.argv[3]
targets = [a.split("=", 1) for a in sys.argv[4:]]     # name=url
WANT = ("lith_open_handles", "lith_streaming_handles", "lith_readahead_window_blocks")
OPT = ("lith_streaming_handles_idle_1s", "lith_streaming_handles_idle_5s", "lith_streaming_handles_idle_30s",
       "lith_streaming_handles_measured")   # #404 (main); written as NA when absent
f = open(out, "w")
f.write("t,mount,open_handles,streaming_handles,window_blocks,idle1,idle5,idle30,measured\n")
t0 = time.time()
while not os.path.exists(stop):
    for name, url in targets:
        try:
            body = urllib.request.urlopen(url, timeout=2).read().decode()
        except Exception:
            continue
        v = {}
        for ln in body.splitlines():
            if ln.startswith("#"):
                continue
            p = ln.split()
            if len(p) >= 2 and (p[0] in WANT or p[0] in OPT):
                v[p[0]] = p[1]
        if len(v) == len(WANT):
            f.write("%.2f,%s,%s,%s,%s,%s\n" % (time.time() - t0, name,
                    v[WANT[0]], v[WANT[1]], v[WANT[2]], ",".join(v.get(o, "NA") for o in OPT)))
    f.flush()
    time.sleep(1.0 / hz)
f.close()
PY

say "=== gate 5f-P3  $(date -u +%FT%TZ)  ranks=$RANKS  lith=$(md5sum "$LITH" | cut -c1-12)"
free -g | head -2

clean_lith
mount_lith || exit 1
prep_rundir || { clean_lith; exit 1; }

rm -f "$OUT/stop"
tg=()
set -- $NAMES
for p in $PORTS; do tg+=("$1=http://127.0.0.1:$p/metrics"); shift; done
$PYX "$OUT/sampler.py" "$OUT/handles.csv" "$HZ" "$OUT/stop" "${tg[@]}" \
    > "$OUT/sampler.log" 2>&1 &
spid=$!

say "launching mpirun -n $RANKS ./gchp"
cd "$RD" || exit 1
mpirun -n "$RANKS" ./gchp > "$OUT/gchp.log" 2>&1 &
mpid=$!

# GCHP 14.7.1 throws "double free or corruption" in library destructors AFTER main() returns
# and leaves ranks spinning, so waiting on mpirun never returns. Poll for the evidence the
# model itself writes. For THIS gate the interesting window is init plus the first steps --
# that is when ExtData and HEMCO open their files -- so a timeout is a valid outcome, not a
# failure, and is reported as one.
t0=$(date +%s); done_at=""
while :; do
  now=$(date +%s); el=$((now - t0))
  if [ -s "$RD/cap_restart" ] && [ "$(awk '{print $1}' "$RD/cap_restart")" != "20190101" ]; then
    done_at=$el; say "  cap_restart advanced at ${el}s"; break
  fi
  # Every input read is finished once the checkpoint write begins, and that is the only thing
  # this gate measures -- so break there rather than waiting on an output path that aborts and
  # leaves ranks spinning. This is the banked lesson from the hpc6id throughput work: take the
  # measurement from the model's own log and stop waiting on the checkpoint.
  if grep -q "write file: Restarts/gcchem_internal_checkpoint" "$OUT/gchp.log" 2>/dev/null; then
    say "  checkpoint write reached at ${el}s -- all input reads complete, stopping"; break
  fi
  if ! kill -0 "$mpid" 2>/dev/null; then say "  mpirun exited at ${el}s"; break; fi
  [ "$el" -ge "$DEADLINE" ] && { say "  deadline ${DEADLINE}s reached (expected: init is what matters)"; break; }
  sleep 5
done

touch "$OUT/stop"; wait "$spid" 2>/dev/null
pkill -f "mpirun -n $RANKS ./gchp" >/dev/null 2>&1
pkill -x gchp >/dev/null 2>&1
sleep 3

say "--- GCHP progress markers"
grep -cE "AGCM Date" "$OUT/gchp.log" 2>/dev/null | awk '{print "  heartbeat lines: " $1}'
grep -iE "ERROR|forrtl|not found" "$OUT/gchp.log" 2>/dev/null | head -3

say "--- per-mount handle counts (max and median over the run)"
$PYX - "$OUT/handles.csv" <<'PY'
import csv, statistics as st, sys
rows = list(csv.DictReader(open(sys.argv[1])))
by = {}
for r in rows:
    by.setdefault(r["mount"], []).append(
        (int(float(r["open_handles"])), int(float(r["streaming_handles"])),
         int(float(r["window_blocks"]))))
print("  %-16s %6s %6s %6s %6s %6s  %s" % ("mount", "oh_max", "oh_med",
      "sh_max", "sh_med", "win_min", "sh/oh at oh_max"))
toh = tsh = 0
for m, v in by.items():
    oh = [x[0] for x in v]; sh = [x[1] for x in v]; wn = [x[2] for x in v]
    i = oh.index(max(oh))
    print("  %-16s %6d %6d %6d %6d %6d  %.3f" % (m, max(oh), st.median(oh), max(sh),
          st.median(sh), min(wn), (sh[i] / oh[i]) if oh[i] else float("nan")))
    toh += max(oh); tsh += max(sh)
print("  %-16s %6d %31s %.3f" % ("TOTAL(peaks)", toh, tsh, (tsh / toh) if toh else float("nan")))
print("  samples: %d over %.0f s" % (len(rows), float(rows[-1]["t"]) if rows else 0))
PY

clean_lith
say "=== done $(date -u +%FT%TZ)"
