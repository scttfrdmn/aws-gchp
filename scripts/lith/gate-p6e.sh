#!/bin/bash
# Gate 5f-P6e (lith#313 / #316): the 48-rank GCHP gauges, upstream's "discriminator between
# #313 and #316". gate-streams-gchp2.sh (5f-P3b) with four changes, everything else identical:
#   1. lith-318 (35daae9): adds lith_prefetch_low_coverage_total + unread_resident_bytes.
#   2. MEMC=stock is not offered; MEMC is per daemon and is the arm variable (2GB, 64GB).
#   3. The met mount carries --pf-trace, because the coverage rejection that holds same-object
#      readers (prefetch.go:436) increments no counter (5f-P6b); the trace is the only record.
#   4. The sampler records unread_resident, low_coverage and evicted_unread per mount.
# Predictions E1-E4 are pre-registered in data/lith-gates/inregion-streams.txt "GATE 5f-P6e".
#
# ---- 5f-P3b header follows ----
# Gate 5f-P3b (lith#301 ask 2 / #311 / #312): 5f-P3 answered the handle-count question at
# 6 and 12 ranks and the answer raised a sharper one. The stream divisor gives the met mount
# NOTHING at 12 ranks (window 2 under both binaries) while lifting the quiet mounts 5-8 -> 29-119,
# so whether #311 helps GCHP is entirely a question of WHERE THE BYTES ARE -- which 5f-P3 failed
# to record. This run adds per-mount byte accounting and an OLD/NEW A/B at fixed rank count.
# Predictions and falsifiers are pre-registered in data/lith-gates/inregion-streams.txt.
#
# Original 5f-P3 header follows, because the mounts, indexes and run dir are unchanged.
#
# On a real GCHP mount, how many of the open DESCRIPTORS are established sequential STREAMS?
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
LITH=${LITH:-$GATES/lith-318}
SRC=${SRC:-/scratch/gchp_lith_TransportTracers}
RD=${RD:-/scratch/gchp_p6e_TT}
OUT=${OUT:-$GATES/p6e}
PYX=${PYX:-/scratch/ncenv/bin/python}
RANKS=${RANKS:-48}
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
  pkill -f "lith-3[0-9][0-9] mount" >/dev/null 2>&1
  sleep 2
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
      --mem-cache $MEMC --metrics ":9210" --pf-trace "$OUT/met.trace.csv" --daemon
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2015/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
      --index-file "$GATES/idx/merra2-2015.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9211" --daemon
  "$LITH" mount s3://gcgrid/HEMCO /input-lith/HEMCO \
      --index-file "$GATES/idx/hemco.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9212" --daemon
  "$LITH" mount s3://gcgrid/CHEM_INPUTS /input-lith/CHEM_INPUTS \
      --index-file "$GATES/idx/cheminp.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9213" --daemon
  "$LITH" mount s3://gcgrid/GEOSCHEM_RESTARTS /input-lith/GEOSCHEM_RESTARTS \
      --index-file "$GATES/idx/restarts.lithidx" --no-sign-request --nic-gbps $NIC \
      --mem-cache $MEMC --metrics ":9214" --daemon
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
WANT = ("lith_open_handles", "lith_streaming_handles", "lith_readahead_window_blocks",
        "lith_s3_bytes_total", "lith_prefetch_unread_resident_bytes",
        "lith_prefetch_low_coverage_total", "lith_prefetch_evicted_unread_total")
f = open(out, "w")
f.write("t,mount,open_handles,streaming_handles,window_blocks,s3_bytes,unread_resident,low_coverage,evicted_unread\n")
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
            if len(p) >= 2 and p[0] in WANT:
                v[p[0]] = p[1]
        if all(w in v for w in (WANT[0], WANT[2], WANT[3])):
            f.write("%.2f,%s,%s,%s,%s,%s,%s,%s,%s\n" % (time.time() - t0, name,
                    v[WANT[0]], v.get(WANT[1], "-1"), v[WANT[2]], v[WANT[3]],
                    v.get(WANT[4], "-1"), v.get(WANT[5], "-1"), v.get(WANT[6], "-1")))
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

say "--- final per-mount metrics (P1/P3: where the bytes are, and whether the burst reaches GCHP)"
{ set -- $NAMES
  for p in $PORTS; do
    curl -s --max-time 5 "http://localhost:$p/metrics" | grep -v '^#' | grep -E \
      '^lith_(s3_bytes_total|s3_requests_total|distinct_bytes_read|prefetch_issued_total|prefetch_used_total|prefetch_uncovered_total|prefetch_evicted_unread_total|prefetch_low_coverage_total|prefetch_unread_resident_bytes|readahead_window_blocks|open_handles|streaming_handles) ' \
      | awk -v m="$1" '{printf "MET %s %s %s\n", m, $1, $2}'
    shift
  done
} | tee "$OUT/final.met"
$PYX - "$OUT/final.met" <<'PY2'
import sys, collections
d = collections.defaultdict(dict)
for ln in open(sys.argv[1]):
    p = ln.split()
    if len(p) == 4 and p[0] == "MET":
        d[p[1]][p[2]] = float(p[3])
tot = sum(v.get("lith_s3_bytes_total", 0) for v in d.values()) or 1
print("  %-16s %10s %7s %8s %9s %9s" % ("mount", "GB", "share", "requests", "uncovered", "evicted"))
for m, v in d.items():
    print("  %-16s %10.3f %6.1f%% %8d %9d %9d" % (m, v.get("lith_s3_bytes_total",0)/1e9,
          100*v.get("lith_s3_bytes_total",0)/tot, v.get("lith_s3_requests_total",0),
          v.get("lith_prefetch_uncovered_total",0), v.get("lith_prefetch_evicted_unread_total",0)))
print("  TOTAL %.3f GB   evicted_unread across all mounts: %d"
      % (tot/1e9, sum(v.get("lith_prefetch_evicted_unread_total",0) for v in d.values())))
PY2

say "--- input phase in time (t at which each mount reached 99% of its final bytes)"
$PYX - "$OUT/handles.csv" <<'PY3'
import csv, sys, collections
rows = list(csv.DictReader(open(sys.argv[1])))
by = collections.defaultdict(list)
for r in rows:
    by[r["mount"]].append((float(r["t"]), float(r.get("s3_bytes") or 0)))
for m, v in by.items():
    fin = max(b for _, b in v)
    if fin <= 0:
        print("  %-16s no bytes" % m); continue
    t99 = min(t for t, b in v if b >= 0.99 * fin)
    print("  %-16s final %.3f GB   99%% reached at %6.1f s   mean %.0f MB/s to that point"
          % (m, fin/1e9, t99, fin/1e6/max(t99, 1e-9)))
PY3

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

say "--- E3/E4: peak unread_resident / tier per mount (tier = --mem-cache $MEMC)"
$PYX - "$OUT/handles.csv" "$MEMC" <<'PY4'
import csv, sys, collections
tier = float(sys.argv[2].rstrip("GB")) * 1e9   # lith parses GB as 1e9 (tier 8.2557 GB = 2 x 4127829504 on c7g)
pk = collections.defaultdict(lambda: [0.0, 0, 0])
for r in csv.DictReader(open(sys.argv[1])):
    p = pk[r["mount"]]
    p[0] = max(p[0], float(r["unread_resident"])); p[1] = max(p[1], int(float(r["low_coverage"])))
    p[2] = max(p[2], int(float(r["evicted_unread"])))
print("  %-16s %14s %8s %12s %9s" % ("mount", "peak_resident", "/tier", "low_coverage", "evicted"))
for m, (r, c, e) in pk.items():
    print("  %-16s %14.0f %8.3f %12d %9d" % (m, r, r / tier, c, e))
PY4

say "--- E2: same-object concurrency and per-handle coverage on the met mount (from --pf-trace)"
$PYX - "$OUT/met.trace.csv" <<'PY5'
import csv, sys, collections, statistics as st
rows = [r for r in csv.DictReader(l for l in open(sys.argv[1]) if not l.startswith("#"))]
rows.sort(key=lambda r: int(r["seq"]))
by = collections.defaultdict(list)
for r in rows:
    by[r["fh"]].append(r)
key = {fh: v[0]["key"] for fh, v in by.items()}
def cov(rs):
    iv = sorted((int(r["off"]), int(r["off"]) + int(r["len"])) for r in rs)
    lo, hi = iv[0][0], max(e for _, e in iv)
    u = 0; ce = lo
    for a, b in iv:
        if b > ce: u += b - max(a, ce); ce = b
    return u / max(hi - lo, 1)
meds = {}
for fh, v in by.items():
    cs = [cov(v[max(0, i - 15):i + 1]) for i in range(2, len(v))]
    if cs: meds[fh] = st.median(cs)
hk = collections.defaultdict(set)
for fh, k in key.items(): hk[k].add(fh)
# Concurrency is assessed by READS, not opens: handles of one object whose read seqs interleave.
multi = set()
for k, fhs in hk.items():
    if len(fhs) < 2: continue
    spans = sorted((int(by[f][0]["seq"]), int(by[f][-1]["seq"]), f) for f in fhs)
    for i in range(len(spans) - 1):
        if spans[i + 1][0] < spans[i][1]: multi.update((spans[i][2], spans[i + 1][2]))
single = [meds[f] for f in meds if f not in multi]
mul = [meds[f] for f in meds if f in multi]
fin = collections.Counter(by[f][-1]["state_after"] for f in by)
print("  trace rows %d, handles %d, objects %d, objects with >1 handle %d" %
      (len(rows), len(by), len(hk), sum(1 for v in hk.values() if len(v) > 1)))
print("  handles with an interleaving same-object sibling: %d   others: %d" % (len(mul), len(single)))
for name, xs in (("interleaved", mul), ("solo", single)):
    if xs:
        xs = sorted(xs)
        print("  %-11s median-coverage per handle: min %.3f med %.3f max %.3f  frac<0.5 %.2f  (n=%d)" %
              (name, xs[0], xs[len(xs)//2], xs[-1], sum(x < 0.5 for x in xs) / len(xs), len(xs)))
print("  final states: %s" % dict(fin))
PY5

clean_lith
say "=== done $(date -u +%FT%TZ)"
