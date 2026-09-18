#!/bin/bash
#SBATCH --job-name=gate5b-hemco-arms
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=01:30:00
#SBATCH --output=/scratch/lith-gates/gate5b-%j.log
#
# GATE 5b — WHICH lith mechanism whole-fetches HEMCO's 13 MB files? (scttfrdmn/lith#256)
#
# Gate 5 found fullchem byte-identical over lith AND found HEMCO amplifying 2.46x
# (9086.9 MB from S3 for a 3698.2 MB distinct set) against 1.21x on the met mount in
# the same job, with a prefetch hit rate of 783 used / 4750 issued / 7260 uncovered.
# Upstream's source analysis (#256): on a ~13 MB file the #229 coverage gate cannot
# discriminate -- a rank's own subdomain reads tile a span that IS most of the file --
# so the handle establishes and the window jumps straight to maxReadahead, which is
# NIC-derived and therefore many GB on a fat pipe. Whole file, every file, every step.
#
# TWO CANDIDATE MECHANISMS, NOT ONE. `lith doctor` resolves --parts-max (default
# "auto" = NIC baseline x first-byte latency) to 64 MiB at --nic-gbps 50 and 35 MiB at
# 7.5 -- BOTH far above a 13 MB file. So parts-max ALONE whole-fetches every HEMCO
# object on first read, independently of establishment or the readahead window. That
# also means upstream's proposed --nic-gbps 7.5 vs 50 arm CANNOT DISCRIMINATE: both
# rungs whole-fetch, so it would return flat and be misread as a refutation. Worse,
# --nic-gbps moves four things at once (inflight-bytes, the window, parts-max,
# coalesce-gap).
#
# So: cross the FILE-SIZE boundary with the direct knobs, one variable at a time.
#
#   A  defaults                            baseline on v1.1.3
#   B  --parts-max 0                       kills whole-file-on-first-read
#   C  --parts-max 0 --max-readahead 4     + caps the established window to 4 MiB << 13 MB
#
#   B collapses            -> parts-max is the mechanism
#   B flat, C collapses    -> the established window is, as upstream argued
#   both flat              -> neither; look at demand-read straddle (3062 on HEMCO)
#
# HYPOTHESIS 2 (prefetch-induced eviction) IS ALREADY EXCLUDED and is not an arm here:
# the HEMCO mount ran --mem-cache 32GB against 9.1 GB ever fetched, so there was never
# capacity pressure. I had reported 8GB to upstream; that was my misreading of my own
# harness (8GB is gate 3c's value) and is corrected on #256.
#
# ONLY THE HEMCO MOUNT CHANGES. Met, restart, CHEM_INPUTS and the 2015 CN mount keep
# gate 5's flags in every arm, so they are in-run controls: if met's 1.21x moves, the
# arm changed something it was not supposed to.
#
# CORRECTNESS IS STILL GATED, IN EVERY ARM. Each arm's checkpoint md5 is compared to
# gate 5's banked f3dd15b2191bbce63dadcbfc100196a6. A fetch-policy flag must not
# change the bytes the model reads; if one does, that is a far bigger finding than the
# amplification question and the arm table is the least of it.
#
# NOTE: deliberately NOT `set -u`. GCHP's setCommonRunSettings.sh dereferences unset
# positionals, so sourcing it under `set -u` aborts before mpirun is reached
# (diagnosed on a head-node dry run during gate 3c, not here).
set -o pipefail

GATES=/scratch/lith-gates
RD=/scratch/gchp_lith_fullchem
OVL=/scratch/hemco-ovl              # FSx arm's HEMCO, prebuilt with the 5 GMI aliases
LITH=${GATES}/lith-1.1.3   # v1.1.3, sha256-verified against the release checksums.txt
RANKS=48
START=20190701                      # cap_restart's start date; the watchdog keys off it
# Run_Duration in setCommonRunSettings.sh is "YYYYMMDD HHmmSS", so the run directory's
# default "00000100 000000" is ONE MONTH, not one day. Job 12 ran fullchem happily for
# 254 timesteps and then projected 1.5 h per arm -- two arms could not fit the 1:30
# limit. Set to "00000001 000000". A 1-day checkpoint is exactly as decisive for
# byte-identity and ~30x cheaper.
EXPECT_SGMT="00000001 000000"
RESULTS=${GATES}/gate5b-results.txt
# Any subset of arms can be run alone: ARMLIST=B sbatch ... . Each arm's checkpoint md5
# is persisted to gate5b-md5-<arm>.txt, so a partial rerun still gets a verdict against
# gate 5's banked control instead of paying for it again.

exec > >(tee -a "$RESULTS") 2>&1
say()   { echo; echo "=== $* ==="; }
stamp() { awk -v t0="$(date +%s.%N)" '{printf "%8.2f  %s\n", systime()-t0, $0; fflush()}'; }

say "node facts $(date -u +%FT%TZ)"
TOK=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
ITYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
echo "instance: ${ITYPE}  host: $(hostname)  cores: $(nproc)  mem: $(free -g | awk '/Mem:/{print $2}') GiB"
echo "/dev/shm: $(df -h /dev/shm | awk 'NR==2{print $2" size, "$4" avail"}')"
# C180 fullchem needed /dev/shm ~550 G and domains_stack_size 64M (SIGBUS at the
# first KPP call = tmpfs exhaustion). C24 has 56x fewer cells so the requirement is
# far smaller, but both values are REPORTED here so that if this job dies at the
# first chemistry step the cause is already in the log instead of needing a rerun.
# No domains_stack_size key exists in this run directory: the recorded C180 fix ADDS
# one, it is not a default. Left absent deliberately -- C24 has 56x fewer cells than
# the case that needed it, and CLAUDE.md's rule is not to change configuration we do
# not need to. If this job dies at the first KPP call with SIGBUS, that key is the
# first thing to add.
echo "domains_stack_size: $(awk '/^ *domains_stack_size/{print $2; f=1} END{if(!f) print "absent (GCHP default)"}' "$RD/GCHP.rc")"
NIC=$(case "$ITYPE" in m9g.48xlarge) echo 100;; c8g.48xlarge) echo 50;; *) echo 50;; esac)
echo "lith: $("$LITH" version 2>&1 | head -1)   --nic-gbps ${NIC}"

# ---------------------------------------------------------------- preflight
# Every check here is something that would otherwise fail AFTER mpirun starts, i.e.
# after the expensive part. Failing now costs seconds instead of a node-hour.
say "preflight"
fail=0
[[ -x "$RD/gchp" ]] || { echo "  FAIL no executable $RD/gchp"; fail=1; }
grep -q '^NUM_NODES=1$' "$RD/setCommonRunSettings.sh" || { echo "  FAIL NUM_NODES != 1"; fail=1; }
# TOTAL_CORES is a THIRD independent knob, not derived from the other two. Job 11
# died because it still said 96 after NUM_NODES went 2 -> 1.
grep -q "^TOTAL_CORES=${RANKS}\$" "$RD/setCommonRunSettings.sh" || { echo "  FAIL TOTAL_CORES != ${RANKS} (must equal NUM_NODES x NUM_CORES_PER_NODE)"; fail=1; }
grep -q '^Require_Species_in_Restart=0$' "$RD/setCommonRunSettings.sh" || { echo "  FAIL Require_Species_in_Restart != 0 (fullchem aborts on gcgrid restarts)"; fail=1; }
grep -q "^Run_Duration=\"${EXPECT_SGMT}\"\$" "$RD/setCommonRunSettings.sh" \
  || { echo "  FAIL Run_Duration != ${EXPECT_SGMT} (\"YYYYMMDD HHmmSS\"; 00000100 is a MONTH)"; fail=1; }
# No FSx arm here: the control md5 is banked from gate 5, so the GMI overlay is not
# needed and is not checked.
for i in merra2-201907 merra2-2015 hemco cheminp restarts; do
  [[ -s "$GATES/idx/$i.lithidx" ]] || { echo "  FAIL missing index $i"; fail=1; }
done
(( fail )) && { echo "PREFLIGHT FAILED — not spending node time"; exit 1; }
echo "  all preflight checks passed"

# ---------------------------------------------------------------- input layers
PORTS="9110:merra2-2019-07 9111:merra2-2015 9112:hemco 9113:chem-inputs 9114:restarts"

clean_stale_lith() {
  # `lith mount --daemon` detaches, so the daemons SURVIVE scancel and survive the job
  # that created them: daemonizing escapes the Slurm cgroup. Job 13 inherited job 12's
  # five mounts, could not create its own ("Permission denied" from mkdir/chown on live
  # FUSE mountpoints, then "daemon failed to start"), counted the stale mounts as
  # success, and ran GCHP against dead daemons -- it died in 10 s. Always start from a
  # known-clean state.
  for m in /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
           /input-lith/HEMCO /input-lith/CHEM_INPUTS /input-lith/GEOSCHEM_RESTARTS; do
    fusermount3 -u "$m" >/dev/null 2>&1
  done
  pkill -f "lith-1.1.[0-9] mount" >/dev/null 2>&1
  sleep 3
  local left; left=$(mount | grep -c fuse.lith)
  echo "  stale fuse.lith mounts after cleanup: ${left}"
  if (( left )); then
    # Do not paper over this: a leftover mount means the next arm's reads go somewhere
    # other than where the log says they do.
    mount | grep fuse.lith | sed 's/^/    /'
    return 1
  fi
}

mount_lith() {
  # The mountpoints MUST be created here, on the node that runs the job. /input-lith
  # is node-local (unlike /scratch and /input, which are FSx), so directories made
  # during head-node prep do not exist here -- job 10 died exactly this way:
  # "fusermount3: failed to access mountpoint /input-lith/CHEM_INPUTS".
  for d in GEOS_0.5x0.625/MERRA2/2019/07 GEOS_0.5x0.625/MERRA2/2015/01 \
           HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
    sudo mkdir -p "/input-lith/${d}"
  done
  sudo chown -R "$(id -u):$(id -g)" /input-lith
  # Prefix-scoped mounts, one index each, mirroring gate 3c. MERRA2 is mounted at the
  # 2019/07 leaf (the simulation month) and MetDir points at the MERRA2 parent, so
  # ExtData's MetDir/%y4/%m2/... resolves through the mountpoint.
  #
  # 2015/01 is NOT optional: ExtData.rc has exactly one date-pinned met reference,
  # the constant-field file MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4, which does
  # not template over the simulation year. Without it GCHP aborts in
  # ExtDataGridCompMod.F90:1942 about nine seconds into init.
  #
  # --mem-cache is bounded on every mount. The default is 25% of system memory PER
  # DAEMON, so five mounts would default to capping 125% of the box; GCHP wants that
  # memory for the model.
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 \
    --index-file "${GATES}/idx/merra2-201907.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 24GB --metrics ":9110" --daemon
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2015/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
    --index-file "${GATES}/idx/merra2-2015.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 4GB --metrics ":9111" --daemon
  # THE ONLY LINE THAT DIFFERS BETWEEN ARMS. $HEMCO_EXTRA is unquoted on purpose so
  # that an empty value adds no argument at all (arm A must be byte-identical in
  # configuration to gate 5 apart from the lith version).
  echo "  HEMCO arm flags: [${HEMCO_EXTRA:-<defaults>}]"
  "$LITH" mount s3://gcgrid/HEMCO /input-lith/HEMCO \
    --index-file "${GATES}/idx/hemco.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 32GB --metrics ":9112" ${HEMCO_EXTRA} --daemon
  "$LITH" mount s3://gcgrid/CHEM_INPUTS /input-lith/CHEM_INPUTS \
    --index-file "${GATES}/idx/cheminp.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 8GB --metrics ":9113" --daemon
  "$LITH" mount s3://gcgrid/GEOSCHEM_RESTARTS /input-lith/GEOSCHEM_RESTARTS \
    --index-file "${GATES}/idx/restarts.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 8GB --metrics ":9114" --daemon
  sleep 6
  local n; n=$(mount | grep -c fuse.lith)
  echo "  fuse.lith mounts: ${n}"
  # Counting mount entries is NOT sufficient evidence that OUR daemons are serving
  # them -- that is precisely how job 13 fooled itself. Prove each daemon we just
  # started is alive by asking its own metrics endpoint.
  local alive=0 pp port
  for pp in $PORTS; do
    port=${pp%%:*}
    curl -s --max-time 4 "http://localhost:${port}/metrics" | grep -q '^lith_' && alive=$((alive+1))
  done
  echo "  daemons answering on their metrics ports: ${alive}/5"
  (( n == 5 && alive == 5 )) || { echo "  MOUNTS NOT HEALTHY — refusing to run GCHP against them"; return 1; }
}

umount_lith() {
  for m in /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
           /input-lith/HEMCO /input-lith/CHEM_INPUTS /input-lith/GEOSCHEM_RESTARTS; do
    fusermount3 -u "$m" >/dev/null 2>&1
  done
}

# Point the run directory's four input symlinks at a layer. This is the ONLY thing
# that differs between arms.
point_at() {  # point_at lith|fsx
  local root
  case "$1" in
    lith) root=/input-lith ;;
    fsx)  root=/input ;;
    *) echo "  bad layer $1"; return 1 ;;
  esac
  ln -sfn "${root}/GEOS_0.5x0.625/MERRA2" "$RD/MetDir"
  ln -sfn "${root}/CHEM_INPUTS"           "$RD/ChemDir"
  # HEMCO: the FSx arm must use the overlay, because /input itself cannot serve the
  # five GMI aliases fullchem needs. The lith arm points straight at the real tree.
  local hco
  if [[ "$1" == fsx ]]; then hco=$OVL; else hco="${root}/HEMCO"; fi
  ln -sfn "$hco" "$RD/HcoDir"
  # HEMCO_Config.rc carries the ONE absolute input path in the run directory
  # (`ROOT:`), and HEMCO field paths are built from it, so the symlink alone does not
  # redirect HEMCO. ExtData.rc by contrast is fully relative — 1772 ./HcoDir refs and
  # zero absolute paths — so it follows the symlinks with no edit.
  sed -i -E "s|^(ROOT: *).*|\1${hco}|" "$RD/HEMCO_Config.rc"
  echo "  HEMCO ROOT -> $(awk '/^ROOT:/{print $2}' "$RD/HEMCO_Config.rc")"
  for r in "$RD"/Restarts/GEOSChem.Restart.*.nc4; do
    local tgt suf; tgt=$(readlink "$r") || continue
    # Strip whichever root is currently in the link, longest first, then re-root once.
    # Stripping both prefixes in separate ln calls would re-root an already-correct
    # path a second time and produce /input-lith/input/... — silently broken.
    suf=${tgt#/input-lith}; suf=${suf#/input}
    ln -sfn "${root}${suf}" "$r"
  done
  echo "  MetDir  -> $(readlink "$RD/MetDir")"
  echo "  HcoDir  -> $(readlink "$RD/HcoDir")"
  echo "  ChemDir -> $(readlink "$RD/ChemDir")"
  echo "  restart -> $(readlink "$RD/Restarts/GEOSChem.Restart.${START}_0000z.c24.nc4")"
  # Prove the model's entry points actually resolve through this layer before paying
  # for mpirun. -L follows the link; a broken chain fails here, not 60 s into init.
  ls -L "$RD/MetDir/2019/07/MERRA2.20190701.A1.05x0625.nc4" \
        "$RD/MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4" \
        "$RD/HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc" \
        "$RD/Restarts/GEOSChem.Restart.${START}_0000z.c24.nc4" >/dev/null \
    && echo "  entry points resolve OK" || { echo "  ENTRY POINTS DO NOT RESOLVE"; return 1; }
}

# ---------------------------------------------------------------- one run
reset_rundir() {
  cd "$RD" || exit 1
  echo "${START} 000000" > cap_restart
  # Stale checkpoints are not cosmetic: a pre-existing gcchem_internal_checkpoint is
  # the NC_EEXIST bug that was long misread as a multi-node pnc4 collective hang.
  rm -f Restarts/gcchem_internal_checkpoint* OutputDir/*.nc4 2>/dev/null
}

gchp_run() {  # gchp_run LABEL
  local label="$1" log="${GATES}/gate5b-${1}.log"
  say "RUN ${label}"
  reset_rundir
  source /sw/gchp-env.sh              # exports OPAL_PREFIX and PMIX_PREFIX; do not override
  ulimit -s unlimited 2>/dev/null
  # Do NOT discard these scripts' output. Job 11 died here with nothing in the log
  # because `>/dev/null 2>&1` swallowed setCommonRunSettings.sh's own diagnostic
  # ("ERROR: TOTAL_CORES must equal NUM_NODES times NUM_CORES_PER_NODE") -- the
  # official tooling said exactly what was wrong and the harness hid it. Capture and
  # surface instead.
  local setup="${GATES}/gate5b-${label}-setup.log"
  source setCommonRunSettings.sh > "$setup" 2>&1
  source setRestartLink.sh       >> "$setup" 2>&1
  source checkRunSettings.sh     >> "$setup" 2>&1
  if grep -qiE "^ *ERROR|must equal" "$setup"; then
    echo "  GCHP SETUP REJECTED THE CONFIGURATION:"; grep -iE "ERROR|must equal" "$setup" | sed 's/^/    /'
    printf 'RESULT %-6s SETUP-REJECTED\n' "$label"; return 1
  fi
  echo "  layout: NX=$(awk '/^NX:/{print $2}' GCHP.rc) NY=$(awk '/^NY:/{print $2}' GCHP.rc) ranks=${RANKS}"
  # Re-read the layer AFTER sourcing the GCHP setup scripts, in case any of them
  # rewrite the run directory. This line, not the one in point_at, is the proof of
  # which layer actually served the run.
  echo "  at launch: HcoDir -> $(readlink HcoDir)  MetDir -> $(readlink MetDir)  HEMCO ROOT -> $(awk '/^ROOT:/{print $2}' HEMCO_Config.rc)"

  # WATCHDOG, NOT `wait`: GCHP 14.7.1 completes the simulation, writes the checkpoint
  # and cap_restart, and THEN throws "double free or corruption" in library
  # destructors after main() returns, leaving ranks spinning forever. Waiting on
  # mpirun never returns. So poll for the completion evidence GCHP itself writes.
  local t0 t1 deadline=4200
  t0=$(date +%s.%N)
  mpirun -n "$RANKS" ./gchp 2>&1 | stamp > "$log" &
  local pipe_pid=$!
  local done_at="" i=0
  while (( i < deadline )); do
    if [[ -s cap_restart ]] && [[ "$(awk '{print $1}' cap_restart)" != "$START" ]] \
       && [[ -s Restarts/gcchem_internal_checkpoint ]]; then
      done_at=$(date +%s.%N); break
    fi
    kill -0 "$pipe_pid" 2>/dev/null || break
    sleep 2; ((i+=2))
  done
  t1=${done_at:-$(date +%s.%N)}
  pkill -9 -f "$RD/gchp" 2>/dev/null
  kill -9 "$pipe_pid" 2>/dev/null; wait "$pipe_pid" 2>/dev/null
  sleep 3

  local init_s sim_end_s after verdict=FAILED ck="n/a"
  init_s=$(grep -m1 "GCHP Date" "$log" | awk '{print $1}')
  sim_end_s=$(grep "GCHP Date" "$log" | tail -1 | awk '{print $1}')
  after=$(awk '{print $1}' cap_restart 2>/dev/null)
  if [[ -n "$done_at" ]]; then
    verdict=SUCCEEDED
    ck=$(md5sum Restarts/gcchem_internal_checkpoint | awk '{print $1}')
    cp -f Restarts/gcchem_internal_checkpoint "${GATES}/gate5b-ckpt-${label}.nc4" 2>/dev/null
  else
    echo "  --- last 25 log lines (failure) ---"; tail -25 "$log" | sed 's/^/  /'
  fi
  printf 'RESULT %-6s init=%ss sim_end=%ss to_completion=%.1fs cap_restart->%s md5=%s %s\n' \
    "$label" "${init_s:-NA}" "${sim_end_s:-NA}" \
    "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "${after:-NA}" "$ck" "$verdict"
  echo "$ck" > "${GATES}/gate5b-md5-${label}.txt"
}

metrics_dump() {
  say "lith metrics after $1"
  for pp in $PORTS; do
    local port=${pp%%:*} name=${pp##*:}
    echo "-- ${name} (:${port})"
    curl -s --max-time 5 "http://localhost:${port}/metrics" \
      | grep -E "^lith_(s3_bytes_total|distinct_bytes_read|cache_misses_total|fill_runs_total|s3_requests_total|read_straddle_total|prefetch_[a-z_]+|sibling_[a-z_]+|parts_[a-z_]+)" \
      | grep -v bucket | sed 's/^/   /'
  done
}

# Gate 5 reported lith_prefetch_evicted_unread_total as "absent from the scrape". It is
# not absent -- it exports as a plain 0 -- the gate's regex ENUMERATED prefetch counters
# and omitted it. Hence the family globs above: a diagnostic you filtered out looks
# exactly like a diagnostic that does not exist. Verified on v1.1.3 on the head node.

# The one number the arms are about, pulled straight from the HEMCO daemon.
hemco_ampl() {  # hemco_ampl LABEL
  local m; m=$(curl -s --max-time 5 http://localhost:9112/metrics)
  local s3 d iss used unc
  s3=$(  awk '/^lith_s3_bytes_total /{print $2}'          <<<"$m")
  d=$(   awk '/^lith_distinct_bytes_read /{print $2}'     <<<"$m")
  iss=$( awk '/^lith_prefetch_issued_total /{print $2}'   <<<"$m")
  used=$(awk '/^lith_prefetch_used_total /{print $2}'     <<<"$m")
  unc=$( awk '/^lith_prefetch_uncovered_total /{print $2}'<<<"$m")
  printf 'HEMCO %-4s s3=%.1fMB distinct=%.1fMB ampl=%.3fx prefetch_used=%s/%s uncovered=%s\n' \
    "$1" "$(awk -v x="$s3" 'BEGIN{print x/1e6}')" "$(awk -v x="$d" 'BEGIN{print x/1e6}')" \
    "$(awk -v a="$s3" -v b="$d" 'BEGIN{print (b>0)?a/b:0}')" "${used:-NA}" "${iss:-NA}" "${unc:-NA}"
}

# ---------------------------------------------------------------- the three arms
# Banked from gate 5 (job 13 fsx arm / job 14 lith arm, both v1.1.2). Every arm below
# must reproduce it.
BASE_MD5=f3dd15b2191bbce63dadcbfc100196a6
ARMLIST=${ARMLIST:-A,B,C}
SUMMARY=${GATES}/gate5b-summary.txt
: > "$SUMMARY"

arm_flags() {  # arm_flags A|B|C
  case "$1" in
    A) echo "" ;;
    B) echo "--parts-max 0" ;;
    C) echo "--parts-max 0 --max-readahead 4" ;;
    *) return 1 ;;
  esac
}

for arm in ${ARMLIST//,/ }; do
  HEMCO_EXTRA=$(arm_flags "$arm") || { echo "unknown arm $arm"; continue; }
  say "ARM ${arm} — HEMCO mount flags: [${HEMCO_EXTRA:-<defaults>}]"
  export HEMCO_EXTRA
  # A dead or inherited daemon serves nothing and looks like a mechanism result, so the
  # clean/verify/abort chain from gate 5 is kept exactly as-is on every arm.
  if clean_stale_lith && mount_lith && point_at lith; then
    gchp_run "$arm"
    metrics_dump "$arm"
    hemco_ampl "$arm" | tee -a "$SUMMARY"
  else
    echo "ABORT ARM ${arm}: lith layer not usable — NOT running GCHP (a run against"
    echo "      stale or dead daemons produces a failure that looks like a result)"
    echo "HEMCO ${arm}  NOT-RUN" >> "$SUMMARY"
  fi
  umount_lith
  sleep 3
done

# ---------------------------------------------------------------- the verdict
say "GATE 5b — HEMCO amplification by arm"
cat "$SUMMARY"

say "correctness: every arm must reproduce gate 5's checkpoint"
echo "  banked (gate 5, v1.1.2): ${BASE_MD5}"
bad=0
for arm in ${ARMLIST//,/ }; do
  m=$(cat "${GATES}/gate5b-md5-${arm}.txt" 2>/dev/null)
  # "n/a" is what a non-completing arm writes; treat it as MISSING, never as a
  # mismatch. A harness must not be able to manufacture a correctness claim out of its
  # own breakage (gate 5 job 13 did exactly that).
  [[ "$m" == "n/a" ]] && m=""
  if [[ -z "$m" ]]; then
    printf '  %-3s MISSING — arm did not complete\n' "$arm"; bad=1
  elif [[ "$m" == "$BASE_MD5" ]]; then
    printf '  %-3s %s  IDENTICAL\n' "$arm" "$m"
  else
    printf '  %-3s %s  *** DIFFERS FROM BANKED ***\n' "$arm" "$m"; bad=1
  fi
done
(( bad )) && echo "  NOTE: a fetch-policy flag changing the model's bytes, or an arm not"
(( bad )) && echo "        completing, outranks the amplification question. Read the RESULT lines."
grep -E "^RESULT" "$RESULTS" | tail -6
