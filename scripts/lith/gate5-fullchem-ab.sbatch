#!/bin/bash
#SBATCH --job-name=gate5-fullchem-ab
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=01:30:00
#SBATCH --output=/scratch/lith-gates/gate5-%j.log
#
# GATE 5 — the last open question in the lith /input analysis: does GCHP's FULLCHEM
# read pattern get CORRECT BYTES through lith?
#
# Everything measured so far is TransportTracers. TT reads a handful of families
# through pFIO; fullchem reads 57 families, 485 objects, 30.2 GiB, including the
# HEMCO tree and CHEM_INPUTS, and it is the mechanism anyone actually runs. Gate 4
# showed the BYTES arrive faster (>=2.29x cold). It did not show they are the RIGHT
# bytes under the model's own concurrent hyperslab access — a benchmark harness
# reading whole files cannot answer that.
#
# THE TEST IS A BYTE-IDENTICAL CHECKPOINT, not a completion.
# "It ran and looked plausible" is not a correctness result: a FUSE layer that
# returned subtly wrong bytes would still produce a file. So both arms run the SAME
# run directory, 1 sim-day C24 fullchem, 48 ranks, and the gate passes only if
# md5(gcchem_internal_checkpoint) matches. Checkpoint MD5 is an established gate in
# this project (the decoupled-chemistry phases used it to prove byte-identity), so
# it is known to be stable run-to-run for identical configuration.
#
# WHY ONE RUN DIRECTORY AND NOT TWO
# The run dir reaches every input through four symlinks — MetDir, HcoDir, ChemDir,
# Restarts/*. Flipping those four is the whole difference between the arms, so
# binary, configs, resolution, rank count, restart and duration cannot drift. Gate 3c
# used two parallel run dirs and had to verify them with `diff -rq`; one dir removes
# that class of doubt entirely. `readlink` output is recorded per arm as proof of
# which layer actually served the run.
#
# ARM ORDER: lith first. It is the arm under test and the repeatable one. If the FSx
# control arm has a problem, the lith result still exists.
#
# THE CONTROL ARM NEEDS A HACK, AND THAT IS ITSELF A FINDING
# fullchem references five GMI aliases (IPMN/NPMN/RIPA/RIPB/RIPD) that landed in
# s3://gcgrid on 2026-09-12. /input is fs-0804c4d8e01897d21, created 2026-06-28 with
# AutoImportPolicy NONE — an S3-linked FSx is a point-in-time snapshot, so those
# objects are permanently invisible on Lustre. The FSx arm therefore CANNOT RUN
# without an overlay (226 symlinks + 472 MB of duplicated objects, prebuilt on the
# head node at /scratch/hemco-ovl). lith reads live S3 and needs none of it. The
# control is only obtainable by first building the thing lith deletes.
#
# NOTE: deliberately NOT `set -u`. GCHP's setCommonRunSettings.sh dereferences unset
# positionals, so sourcing it under `set -u` aborts before mpirun is reached
# (diagnosed on a head-node dry run during gate 3c, not here).
set -o pipefail

GATES=/scratch/lith-gates
RD=/scratch/gchp_lith_fullchem
OVL=/scratch/hemco-ovl              # FSx arm's HEMCO, prebuilt with the 5 GMI aliases
LITH=${GATES}/lith-1.1.2
RANKS=48
START=20190701                      # cap_restart's start date; the watchdog keys off it
# Run_Duration in setCommonRunSettings.sh is "YYYYMMDD HHmmSS", so the run directory's
# default "00000100 000000" is ONE MONTH, not one day. Job 12 ran fullchem happily for
# 254 timesteps and then projected 1.5 h per arm -- two arms could not fit the 1:30
# limit. Set to "00000001 000000". A 1-day checkpoint is exactly as decisive for
# byte-identity and ~30x cheaper.
EXPECT_SGMT="00000001 000000"
RESULTS=${GATES}/gate5-results.txt
# Either arm can be run alone. The per-arm checkpoint md5 is persisted to
# gate5-md5-<arm>.txt, so a lith-only rerun still gets a verdict against the FSx
# control instead of paying for it twice.
ARMS=${ARMS:-lith,fsx}

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
for a in IPMN NPMN RIPA RIPB RIPD; do
  [[ -f "$OVL/GMI/v2015-02/gmi.clim.$a.geos5.2x25.nc" ]] || { echo "  FAIL overlay missing $a"; fail=1; }
done
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
  pkill -f "lith-1.1.2 mount" >/dev/null 2>&1
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
  "$LITH" mount s3://gcgrid/HEMCO /input-lith/HEMCO \
    --index-file "${GATES}/idx/hemco.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 32GB --metrics ":9112" --daemon
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
  local label="$1" log="${GATES}/gate5-${1}.log"
  say "RUN ${label}"
  reset_rundir
  source /sw/gchp-env.sh              # exports OPAL_PREFIX and PMIX_PREFIX; do not override
  ulimit -s unlimited 2>/dev/null
  # Do NOT discard these scripts' output. Job 11 died here with nothing in the log
  # because `>/dev/null 2>&1` swallowed setCommonRunSettings.sh's own diagnostic
  # ("ERROR: TOTAL_CORES must equal NUM_NODES times NUM_CORES_PER_NODE") -- the
  # official tooling said exactly what was wrong and the harness hid it. Capture and
  # surface instead.
  local setup="${GATES}/gate5-${label}-setup.log"
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
    cp -f Restarts/gcchem_internal_checkpoint "${GATES}/gate5-ckpt-${label}.nc4" 2>/dev/null
  else
    echo "  --- last 25 log lines (failure) ---"; tail -25 "$log" | sed 's/^/  /'
  fi
  printf 'RESULT %-6s init=%ss sim_end=%ss to_completion=%.1fs cap_restart->%s md5=%s %s\n' \
    "$label" "${init_s:-NA}" "${sim_end_s:-NA}" \
    "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "${after:-NA}" "$ck" "$verdict"
  echo "$ck" > "${GATES}/gate5-md5-${label}.txt"
}

metrics_dump() {
  say "lith metrics after $1"
  for pp in $PORTS; do
    local port=${pp%%:*} name=${pp##*:}
    echo "-- ${name} (:${port})"
    curl -s --max-time 5 "http://localhost:${port}/metrics" \
      | grep -E "^lith_(s3_bytes_total|distinct_bytes_read|cache_misses_total|fill_runs_total|prefetch_(issued|used|uncovered)_total|s3_requests_total|read_straddle_total)" \
      | grep -v bucket | sed 's/^/   /'
  done
}

# ---------------------------------------------------------------- ARM 1: lith
say "ARM 1 — fullchem C24 through lith (live s3://gcgrid)"
if [[ ",${ARMS}," == *,lith,* ]]; then
  clean_stale_lith || { echo "ABORT: could not reach a clean mount state"; exit 1; }
  if mount_lith && point_at lith; then
    gchp_run lith
    metrics_dump lith
  else
    echo "ABORT: lith layer not usable — NOT running GCHP (a run against stale or dead"
    echo "       daemons produces a failure that looks like a correctness result)"
  fi
  umount_lith
else
  echo "  skipped (ARMS=${ARMS})"
fi

# ---------------------------------------------------------------- ARM 2: FSx control
say "ARM 2 — same run dir through FSx /input + GMI overlay"
if [[ ",${ARMS}," == *,fsx,* ]]; then
  # Stale lith mounts would also poison this arm: /input-lith paths are gone from the
  # run dir's symlinks, but a dead FUSE mount left behind can wedge later cleanup.
  clean_stale_lith >/dev/null 2>&1
  point_at fsx || { echo "ABORT: fsx entry points unresolved"; exit 1; }
  gchp_run fsx
else
  echo "  skipped (ARMS=${ARMS}) — reusing stored md5 from an earlier run"
fi

# ---------------------------------------------------------------- the gate
say "GATE 5 VERDICT"
L=$(cat "${GATES}/gate5-md5-lith.txt" 2>/dev/null)
F=$(cat "${GATES}/gate5-md5-fsx.txt" 2>/dev/null)
echo "  lith checkpoint md5: ${L:-NONE}"
echo "  fsx  checkpoint md5: ${F:-NONE}"
# "n/a" is what a non-completing arm writes. Job 13 reported "checkpoints DIFFER" --
# a correctness FAILURE -- when the truth was that the lith arm never ran. A harness
# must not be able to manufacture a scientific claim out of its own breakage.
[[ "$L" == "n/a" ]] && L=""
[[ "$F" == "n/a" ]] && F=""
if [[ -n "$L" && "$L" == "$F" ]]; then
  echo "  PASS — fullchem checkpoint is BYTE-IDENTICAL through lith and FSx."
elif [[ -n "$L" && -n "$F" && "$L" != "$F" ]]; then
  # A mismatch is a real finding, not a harness failure, and must not be smoothed
  # over: it would mean one layer served different bytes. Keep both checkpoints.
  echo "  FAIL — checkpoints DIFFER. Both kept at ${GATES}/gate5-ckpt-*.nc4 for diffing."
else
  echo "  INCONCLUSIVE — at least one arm did not complete; see RESULT lines above."
fi
grep -E "^RESULT" "$RESULTS" | tail -4
