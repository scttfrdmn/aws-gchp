#!/bin/bash
#SBATCH --job-name=lith-pfcapture2
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/scratch/lith-gates/capture2-%j.log
#
# THE SECOND CAPTURE — same question, on a trace format that can answer it
# (scttfrdmn/lith#256, #267, #271, #272).
#
# Question 10 of the campaign, unanswered since gate 5b: HEMCO's prefetch waste is
# unreachable by any flag (eight policies, ~1.23 GB demand floor constant), and gate 5f
# found the mechanism (a per-handle cold-start granularity tax at fs.go:778-786). What is
# still not known is WHICH HANDLES waste, i.e. whether anything observable in a handle's
# FIRST FEW READS predicts whether its prefetch is subsequently read. That needs a real
# GCHP read trace from both mounts, scored offline. This job produces it.
#
# WHY A SECOND ONE. The first capture (2026-09-18) ran correctly and its md5 gate held,
# but its verdict was UNEVALUABLE and the follow-up gate found why: the trace could not be
# put back in decision order (rows are appended outside the lock) and it did not record the
# window the mount actually applied. met is 74.5% row REORDERING and HEMCO is 94% a missing
# `perHandleWindow` column — both properties of the FORMAT, not of the workload. lith#271
# added `seq` (allocated inside w.mu) and `max_window` (the per-handle share actually in
# force), and gate 5i verified on live mounts that seq is load-bearing: 0.36% of rows are
# out of decision order on a contended handle, 10.94% at 256 handles.
#
# WHY IT IS WORTH BUYING NOW, rather than waiting for lith#272's fix to merge. #272 is a
# 9-line sort in cmd/lith-pfreplay; it changes not one byte of what the MOUNT writes. The
# trace format is on merged main (36e79f0), scoring is offline, free and re-runnable on a
# banked trace, and I verified #273 (the fix) against my own contended-handle trace
# as-written: fidelity OK, replay decisions 96 = exactly 1.00x the mount's own column.
# So the expensive half no longer depends on the cheap half landing first.
#
# ARMS. Two traced replicates, because the pre-registered rule requires fitting on one arm
# and testing on another, plus one untraced control on the SAME binary:
#
#   a   met + HEMCO served by merged main (36e79f0), both with --pf-trace
#   b   identical to a (the out-of-sample arm)
#   c   met + HEMCO served by merged main, NO --pf-trace
#
# ARM c IS NOT OPTIONAL, and it is the arm this design adds. `lith mount --help` says of
# --pf-trace: "Unbounded, and serialized under one mutex, so it adds a global lock to every
# read: for characterization, not production." With 48 ranks on one mount that is a real
# perturbation risk, and it is confounded with the binary change (main vs the 1.1.3 release
# that produced every banked number). Arm c separates them: if c reproduces the banked
# defaults and a/b do not, the tracing lock moved it; if c also differs, the binary did.
# Without c, a traced trace could be unrepresentative of the untraced run it claims to
# describe and nothing in the job would say so. Capture 1 measured the lock at +0.5%/+1.6%
# wall, so P3 below is scored as a REPEAT, not a fresh prediction.
#
# PRE-REGISTERED, BEFORE THE JOB RAN:
#
#  P1 CORRECTNESS. md5(gcchem_internal_checkpoint) == f3dd15b2191bbce63dadcbfc100196a6 in
#     all three arms (the control banked across 12 previous arms). A diagnostic flag must
#     not change the bytes the model reads. FALSIFIER: any mismatch — and that would be a
#     far bigger finding than the waste question.
#  P2 ARM c REPRODUCES THE RELEASE. HEMCO s3_bytes/distinct within the n=6 defaults null
#     of 2.440x +/- 0.022 (banked defaults arms: 8.89-9.10 GB over 3.697-3.699 GB, issued
#     4533-4838; met distinct 3.2543-3.2548 GB, issued 2946-2948). FALSIFIER: outside it
#     => c922cc7 is not behaviour-neutral and every comparison to banked numbers is void.
#  P3 TRACING COSTS WALL TIME. Banked to_completion is 381-393s across 14 arms. I predict
#     a/b are SLOWER than c (one global mutex across 48 ranks' reads), and state the
#     prediction so that "tracing is free" is falsifiable: if a/b wall is within 2% of c,
#     the documented global lock is not measurable at this rank count.
#  P4 TRACING DOES NOT CHANGE THE BYTES FETCHED. HEMCO s3_bytes in a/b within +/-2% of c.
#     FALSIFIER: >5% => the lock reorders reads enough to change fetch decisions, so the
#     captured traces do not describe an untraced run, and that caveat governs the verdict.
#  P5 THE FLOOR. cold_net_waste_bytes summed over HEMCO handles is 1.0-1.4 GB.
#     FALSIFIER: < 0.5 GB. (Pre-registered on #256 before the netting existed; gate 5h
#     established net == gross on scatter-shaped handles, so this is now scored on the
#     quantity it named. Capture 1's per-handle figure was 8431 MiB > the mount's whole
#     5.32 GB budget, which is the double-counting a SHARED-CACHE replay exists to remove.)
#  P6 THE RULE, agreed in writing with upstream before either side had data: SEPARATION iff
#     a feature of a handle's first k<=8 reads predicts per-handle BYTE follow-through at
#     Spearman |rho| >= 0.5, fit on arm a and tested on arm b. NO SEPARATION iff |rho| <
#     0.5 AND rank-sum AUC < 0.7. Scoring is done offline by lith-pfreplay after the job;
#     nothing in this script computes the verdict, so the arms cannot be tuned to it.
#     CAVEAT CARRIED FORWARD, not resolved by this job: capture 1 showed met is read by 598
#     handles over 12 keys (49.8 handles/key, 0 sole readers), so a PER-HANDLE denominator
#     double-counts a shared cache. This job makes the rule evaluable w.r.t. ORDER and
#     WINDOW; the unit question is answered by a shared-cache replay, which is offline work.
#  P7 THE WINDOW WAS AT THE FLOOR — pre-registered in gate 5i, before this job, and
#     falsifiable by the very column #271 added. perHandleWindow = clamp(budgetBlocks /
#     open_handles, 2, --max-readahead), and budgetBlocks measured ~1424 @24GB / ~1880 @32GB
#     (~46% of --mem-cache). At capture 1's 598 met / 6,272 HEMCO open handles the share is
#     2.38 / 0.30, so I predict max_window reads 2 on essentially every HEMCO row and 2-3 on
#     met with a brief higher tail early, while few handles are open.
#     FALSIFIER: values near 223. If falsified, --max-readahead WAS binding and gate 5b's
#     invariance to a 4x window cut needs another explanation. Scored in-job by
#     capture2-seqcheck.py, which is written before the job and does not gate it.
#
# ACCEPTANCE CHECK ON THE TRACE ITSELF (upstream's, asked for on #256; costs nothing at
# capture time): `seq` strictly increasing within every fh. That is what says the trace is
# orderable, hence scoreable. It REPLACES upstream's original gap-self-consistency
# criterion, which gate 5i showed is not a validity test at all — it measures the mount's
# own lastReadEnd read-modify-write race (gap is read before the lock and stored after), it
# survives sorting by seq and even rises, and the trace records it faithfully. Gating on it
# would reject a correct trace. It is still recorded, so the retirement stays auditable.
#
# WHAT THIS SCRIPT WILL NOT DO: guess. Every mount command below is gate 5's, byte for
# byte, except the two --pf-trace additions and the binary on met+HEMCO. --max-readahead
# and --mem-cache are NOT touched even though P7 says the window is pinned: this capture's
# job is to record what the defaults do, and changing a knob here would make its trace
# incomparable to the 14 banked arms. Moving the budget is a separate, later gate.
# The run directory is the official one (createRunDir.sh, gate 3c), not edited here beyond
# point_at/reset_rundir, both inherited unchanged from the gate 5b harness.
#
# NOTE: deliberately NOT `set -u` — GCHP's setCommonRunSettings.sh dereferences unset
# positionals and aborts before mpirun under it (diagnosed on a head-node dry run).
set -o pipefail

GATES=/scratch/lith-gates
RD=/scratch/gchp_lith_fullchem
CAP=${GATES}/capture2             # traces land here (FSx, so readable from the head node)
                                  # NOT ${GATES}/capture: capture 1's traces are banked
                                  # ground truth and several gates cite them. Never
                                  # overwrite the evidence a previous verdict rests on.
LITH=${GATES}/lith-1.1.3          # release: the three control mounts, as in gate 5
LITHTR=${GATES}/lith-271          # merged main 36e79f0 (#271): met + HEMCO, the traced pair
SEQCHECK=${GATES}/capture2-seqcheck.py
RANKS=48
START=20190701
EXPECT_SGMT="00000001 000000"
RESULTS=${GATES}/capture2-results.txt
ARMLIST=${ARMLIST:-a,b,c}
# SUBMIT AS `ARMLIST=a,b,c sbatch --export=ALL <this>`, NEVER
# `sbatch --export=ALL,ARMLIST=a,b,c` — sbatch splits --export on COMMAS and would set
# ARMLIST=a then try to export variables named b and c. That silently dropped two arms of
# a previous job and nothing in the log said so.
MAXTRACE_GB=8                     # --pf-trace is documented "Unbounded"; stop if it runs away

mkdir -p "$CAP"
exec > >(tee -a "$RESULTS") 2>&1
say()   { echo; echo "=== $* ==="; }
stamp() { awk -v t0="$(date +%s.%N)" '{printf "%8.2f  %s\n", systime()-t0, $0; fflush()}'; }

say "node facts $(date -u +%FT%TZ)  job ${SLURM_JOB_ID:-none}  arms ${ARMLIST}"
TOK=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
ITYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
echo "instance: ${ITYPE}  host: $(hostname)  cores: $(nproc)  mem: $(free -g | awk '/Mem:/{print $2}') GiB"
echo "/dev/shm: $(df -h /dev/shm | awk 'NR==2{print $2" size, "$4" avail"}')"
echo "/scratch:  $(df -h /scratch | awk 'NR==2{print $4" avail"}')"
NIC=$(case "$ITYPE" in m9g.48xlarge) echo 100;; c8g.48xlarge) echo 50;; *) echo 50;; esac)
echo "--nic-gbps ${NIC}   (banked gate-5/5b numbers were all taken at 50)"

# ---------------------------------------------------------------- preflight
say "preflight"
fail=0
[[ -x "$RD/gchp" ]] || { echo "  FAIL no executable $RD/gchp"; fail=1; }
grep -q '^NUM_NODES=1$' "$RD/setCommonRunSettings.sh" || { echo "  FAIL NUM_NODES != 1"; fail=1; }
grep -q "^TOTAL_CORES=${RANKS}\$" "$RD/setCommonRunSettings.sh" || { echo "  FAIL TOTAL_CORES != ${RANKS} (a THIRD independent knob)"; fail=1; }
grep -q '^Require_Species_in_Restart=0$' "$RD/setCommonRunSettings.sh" || { echo "  FAIL Require_Species_in_Restart != 0 (fullchem aborts on gcgrid restarts)"; fail=1; }
grep -q "^Run_Duration=\"${EXPECT_SGMT}\"\$" "$RD/setCommonRunSettings.sh" \
  || { echo "  FAIL Run_Duration != ${EXPECT_SGMT} (\"YYYYMMDD HHmmSS\"; 00000100 is a MONTH)"; fail=1; }
for i in merra2-201907 merra2-2015 hemco cheminp restarts; do
  [[ -s "$GATES/idx/$i.lithidx" ]] || { echo "  FAIL missing index $i"; fail=1; }
done
[[ -x "$LITH"    ]] || { echo "  FAIL release binary $LITH missing"; fail=1; }
[[ -x "$LITHTR" ]] || { echo "  FAIL $LITHTR missing"; fail=1; }
[[ -s "$SEQCHECK" ]] || { echo "  FAIL $SEQCHECK missing (the acceptance check)"; fail=1; }
# Gate 5h: a size-less trace reports follow-through 1.000 where the truth is 0.052 AND drops
# the most wasteful handles out of the population entirely. The follow-up gate: without
# `seq` the rows are in the wrong order, and without `max_window` the replay runs a static
# cap the mount never applied. All three columns are demanded — the flag is not evidence
# the columns exist, and this is the check that made capture 1's trace unscoreable.
if [[ -x "$LITHTR" ]]; then
  "$LITHTR" mount --help 2>&1 | grep -q -- --pf-trace \
    || { echo "  FAIL $LITHTR has no --pf-trace — wrong commit built"; fail=1; }
  echo "  traced-mount sha256: $(sha256sum "$LITHTR" | awk '{print $1}')"
  echo "  traced-mount version: $("$LITHTR" version 2>&1 | head -1) (local build of merged main = 36e79f0, #271)"
fi
# The release binary must NOT know --pf-trace, or the control mounts are not controls.
"$LITH" mount --help 2>&1 | grep -q -- --pf-trace \
  && { echo "  FAIL control binary $LITH also knows --pf-trace"; fail=1; } \
  || echo "  control binary does not know --pf-trace (as expected)"
(( fail )) && { echo "PREFLIGHT FAILED — not spending node time"; exit 1; }
echo "  all preflight checks passed"

# ---------------------------------------------------------------- input layers
PORTS="9110:merra2-2019-07 9111:merra2-2015 9112:hemco 9113:chem-inputs 9114:restarts"
MNTS="/input-lith/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
      /input-lith/HEMCO /input-lith/CHEM_INPUTS /input-lith/GEOSCHEM_RESTARTS"

clean_stale_lith() {
  # `lith mount --daemon` detaches, so daemons SURVIVE scancel and survive the job that
  # created them: daemonizing escapes the Slurm cgroup. A previous job inherited another's
  # five mounts, counted them as success, and ran GCHP against dead daemons.
  local m
  for m in $MNTS; do fusermount3 -u "$m" >/dev/null 2>&1; done
  pkill -f "lith-[0-9a-z.]+ mount" >/dev/null 2>&1
  sleep 3
  for m in $MNTS; do mountpoint -q "$m" && fusermount3 -uz "$m" >/dev/null 2>&1; done
  sleep 2
  local left; left=$(mount | grep -c fuse.lith)
  echo "  stale fuse.lith mounts after cleanup: ${left}"
  (( left == 0 )) || { mount | grep fuse.lith | sed 's/^/    /'; return 1; }
}

mount_lith() {   # mount_lith <arm>
  local arm=$1 mt ht
  # Mountpoints MUST be created on the node that runs the job: /input-lith is node-local
  # (unlike /scratch and /input, which are FSx), so head-node prep does not exist here.
  local d
  for d in GEOS_0.5x0.625/MERRA2/2019/07 GEOS_0.5x0.625/MERRA2/2015/01 \
           HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
    sudo mkdir -p "/input-lith/${d}"
  done
  sudo chown -R "$(id -u):$(id -g)" /input-lith
  # --pf-trace only on the two mounts the question is about. Unset for arm c, and unquoted
  # on purpose so that an empty value adds no argument at all.
  if [[ "$arm" == c ]]; then mt=""; ht="";
  else mt="--pf-trace ${CAP}/met-${arm}.csv"; ht="--pf-trace ${CAP}/hemco-${arm}.csv"; fi
  echo "  met   binary: $(basename $LITHTR)  trace: [${mt:-none}]"
  echo "  hemco binary: $(basename $LITHTR)  trace: [${ht:-none}]"
  # --mem-cache is bounded on EVERY mount: the default is 25% of system memory PER DAEMON,
  # so five mounts would default to capping 125% of the box. Values are gate 5's.
  "$LITHTR" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 \
    --index-file "${GATES}/idx/merra2-201907.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 24GB --metrics ":9110" ${mt} --daemon
  # 2015/01 is NOT optional: ExtData.rc has exactly one date-pinned met reference, the
  # constant-field MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4, which does not template
  # over the simulation year. Without it GCHP aborts ~9 s into init.
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2015/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
    --index-file "${GATES}/idx/merra2-2015.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 4GB --metrics ":9111" --daemon
  "$LITHTR" mount s3://gcgrid/HEMCO /input-lith/HEMCO \
    --index-file "${GATES}/idx/hemco.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 32GB --metrics ":9112" ${ht} --daemon
  "$LITH" mount s3://gcgrid/CHEM_INPUTS /input-lith/CHEM_INPUTS \
    --index-file "${GATES}/idx/cheminp.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 8GB --metrics ":9113" --daemon
  "$LITH" mount s3://gcgrid/GEOSCHEM_RESTARTS /input-lith/GEOSCHEM_RESTARTS \
    --index-file "${GATES}/idx/restarts.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 8GB --metrics ":9114" --daemon
  sleep 6
  local n; n=$(mount | grep -c fuse.lith)
  echo "  fuse.lith mounts: ${n}"
  # Counting mount entries is NOT evidence that OUR daemons serve them. Ask each one.
  local alive=0 pp port
  for pp in $PORTS; do
    port=${pp%%:*}
    curl -s --max-time 4 "http://localhost:${port}/metrics" | grep -q '^lith_' && alive=$((alive+1))
  done
  echo "  daemons answering on their metrics ports: ${alive}/5"
  (( n == 5 && alive == 5 )) || { echo "  MOUNTS NOT HEALTHY — refusing to run GCHP"; return 1; }

  # THE SILENT-NOTHING GUARD. Measured on the head node at $0 before this job: with
  # --daemon, an unwritable --pf-trace path still MOUNTS SUCCESSFULLY, and the
  # `level=ERROR "prefetch trace disabled: cannot create file"` goes to
  # /tmp/lith-<uid>-mount.log rather than anywhere the job sees. So the one failure mode
  # that costs a full run and produces nothing is both non-fatal AND invisible in exactly
  # the mode a capture uses. Asked upstream for fatal-at-mount (#264); until then, prove
  # the files exist HERE, before mpirun, not afterwards.
  if [[ "$arm" != c ]]; then
    local t miss=0
    for t in "${CAP}/met-${arm}.csv" "${CAP}/hemco-${arm}.csv"; do
      if [[ -f "$t" ]]; then
        echo "  trace created: $t"
        # And it must carry the COLUMNS, checked here rather than discovered offline after
        # the node is gone. The header is the first non-# line; at mount time the file is
        # config comment + header and nothing else, which is exactly enough.
        local hdr c
        hdr=$(grep -m1 -v '^#' "$t" 2>/dev/null)
        for c in seq max_window size; do
          case ",${hdr}," in
            *",${c},"*) ;;
            *) echo "  TRACE MISSING COLUMN '${c}' (header: ${hdr:-<none>})"; miss=1;;
          esac
        done
        grep -m1 '^#' "$t" | sed 's/^/    trace config: /'
      else echo "  TRACE NOT CREATED: $t"; miss=1; fi
    done
    grep -h "prefetch trace" /tmp/lith-*-mount.log 2>/dev/null | tail -3 | sed 's/^/    mountlog: /'
    (( miss )) && { echo "  REFUSING to run GCHP — the capture would produce nothing"; return 1; }
  fi
  return 0
}

umount_lith() {
  # A plain `fusermount3 -u` is not enough between arms: the busiest mount is the last one
  # 48 dying ranks had open, and a leftover mount means the next arm's reads go somewhere
  # other than where the log says. Retry, then fall back to LAZY (-uz).
  local m i
  for m in $MNTS; do
    for i in 1 2 3; do
      mountpoint -q "$m" || break
      fusermount3 -u "$m" >/dev/null 2>&1 || { sleep 2; fusermount3 -uz "$m" >/dev/null 2>&1; }
      sleep 1
    done
  done
}

point_at_lith() {
  local root=/input-lith
  ln -sfn "${root}/GEOS_0.5x0.625/MERRA2" "$RD/MetDir"
  ln -sfn "${root}/CHEM_INPUTS"           "$RD/ChemDir"
  ln -sfn "${root}/HEMCO"                 "$RD/HcoDir"
  # HEMCO_Config.rc carries the ONE absolute input path in the run directory (`ROOT:`) and
  # HEMCO field paths are built from it, so the symlink alone does not redirect HEMCO.
  # ExtData.rc by contrast is fully relative (1772 ./HcoDir refs, zero absolute paths).
  sed -i -E "s|^(ROOT: *).*|\1${root}/HEMCO|" "$RD/HEMCO_Config.rc"
  local r tgt suf
  for r in "$RD"/Restarts/GEOSChem.Restart.*.nc4; do
    tgt=$(readlink "$r") || continue
    suf=${tgt#/input-lith}; suf=${suf#/input}
    ln -sfn "${root}${suf}" "$r"
  done
  echo "  MetDir -> $(readlink "$RD/MetDir")   HcoDir -> $(readlink "$RD/HcoDir")"
  echo "  HEMCO ROOT -> $(awk '/^ROOT:/{print $2}' "$RD/HEMCO_Config.rc")"
  # Prove the model's entry points resolve through this layer BEFORE paying for mpirun.
  # -L follows the link; a broken chain fails here, not 60 s into init.
  ls -L "$RD/MetDir/2019/07/MERRA2.20190701.A1.05x0625.nc4" \
        "$RD/MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4" \
        "$RD/HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc" \
        "$RD/Restarts/GEOSChem.Restart.${START}_0000z.c24.nc4" >/dev/null \
    && echo "  entry points resolve OK" || { echo "  ENTRY POINTS DO NOT RESOLVE"; return 1; }
}

reset_rundir() {
  cd "$RD" || exit 1
  echo "${START} 000000" > cap_restart
  # A pre-existing gcchem_internal_checkpoint is the NC_EEXIST bug long misread as a
  # multi-node pnc4 collective hang. Not cosmetic.
  rm -f Restarts/gcchem_internal_checkpoint* OutputDir/*.nc4 2>/dev/null
}

gchp_run() {  # gchp_run <arm>
  local label="$1" log="${GATES}/capture2-${1}.log"
  say "RUN ${label}"
  reset_rundir
  source /sw/gchp-env.sh              # exports OPAL_PREFIX and PMIX_PREFIX; do not override
  ulimit -s unlimited 2>/dev/null
  # Do NOT discard these scripts' output: a previous job died here with nothing in the log
  # because >/dev/null swallowed setCommonRunSettings.sh's own diagnostic. The official
  # tooling says exactly what is wrong; capture and surface it.
  local setup="${GATES}/capture2-${label}-setup.log"
  source setCommonRunSettings.sh > "$setup" 2>&1
  source setRestartLink.sh       >> "$setup" 2>&1
  source checkRunSettings.sh     >> "$setup" 2>&1
  if grep -qiE "^ *ERROR|must equal" "$setup"; then
    echo "  GCHP SETUP REJECTED THE CONFIGURATION:"; grep -iE "ERROR|must equal" "$setup" | sed 's/^/    /'
    printf 'RESULT %-4s SETUP-REJECTED\n' "$label"; return 1
  fi
  echo "  layout: NX=$(awk '/^NX:/{print $2}' GCHP.rc) NY=$(awk '/^NY:/{print $2}' GCHP.rc) ranks=${RANKS}"
  echo "  at launch: HcoDir -> $(readlink HcoDir)  HEMCO ROOT -> $(awk '/^ROOT:/{print $2}' HEMCO_Config.rc)"

  # WATCHDOG, NOT `wait`: GCHP 14.7.1 completes the simulation, writes the checkpoint and
  # cap_restart, and THEN throws "double free or corruption" in library destructors after
  # main() returns, leaving ranks spinning forever. Waiting on mpirun never returns. Poll
  # for the completion evidence GCHP itself writes.
  local t0 t1 deadline=3000
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
  else
    echo "  --- last 25 log lines (failure) ---"; tail -25 "$log" | sed 's/^/  /'
  fi
  # P1: the correctness gate, against the md5 banked across 12 previous arms.
  local gate="CHECKPOINT-MISMATCH"
  [[ "$ck" == f3dd15b2191bbce63dadcbfc100196a6 ]] && gate="md5-OK"
  printf 'RESULT %-4s init=%ss sim_end=%ss to_completion=%.1fs cap_restart->%s md5=%s %s %s\n' \
    "$label" "${init_s:-NA}" "${sim_end_s:-NA}" \
    "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "${after:-NA}" "$ck" "$gate" "$verdict"
}

metrics_dump() {  # metrics_dump <arm>
  say "lith metrics after arm $1"
  local pp port name
  for pp in $PORTS; do
    port=${pp%%:*}; name=${pp##*:}
    echo "-- ${name} (:${port})"
    curl -s --max-time 5 "http://localhost:${port}/metrics" \
      | grep -E "^lith_(s3_bytes_total|distinct_bytes_read|cache_misses_total|fill_runs_total|fill_bytes_total|s3_requests_total|read_straddle_total|prefetch_[a-z_]+)" \
      | grep -v '^#' | sed 's/^/   /' | tee "${CAP}/$1-${name}.metrics"
  done
  # The number lith-pfreplay needs for its denominator-sanity line, per mount, recorded
  # while the daemons are still alive — it cannot be recovered after unmount.
  local mi hi
  mi=$(awk '/^ *lith_prefetch_issued_total/{print $2}' "${CAP}/$1-merra2-2019-07.metrics" 2>/dev/null)
  hi=$(awk '/^ *lith_prefetch_issued_total/{print $2}' "${CAP}/$1-hemco.metrics" 2>/dev/null)
  echo "ISSUED ${1} met=${mi:-NA} hemco=${hi:-NA}"
  printf 'met=%s\nhemco=%s\n' "${mi:-NA}" "${hi:-NA}" > "${CAP}/$1.issued"
}

# ---------------------------------------------------------------- arms
for arm in ${ARMLIST//,/ }; do
  say "ARM ${arm}"
  clean_stale_lith || { echo "  cannot reach a clean mount state — skipping arm ${arm}"; continue; }
  mount_lith "$arm" || { echo "  mount stage failed — skipping arm ${arm}"; umount_lith; continue; }
  point_at_lith    || { echo "  layer wiring failed — skipping arm ${arm}"; umount_lith; continue; }
  gchp_run "$arm"
  metrics_dump "$arm"
  if [[ "$arm" != c ]]; then
    for t in "${CAP}/met-${arm}.csv" "${CAP}/hemco-${arm}.csv"; do
      echo "TRACE $(basename "$t") bytes=$(stat -c%s "$t" 2>/dev/null) rows=$(grep -vc '^#' "$t" 2>/dev/null)"
    done
    # THE ACCEPTANCE CHECK, run while the node is still paid for, so an unscoreable trace is
    # known now and not after a week of offline analysis. It also scores P7. It does NOT
    # compute the verdict of P6 and cannot: it never looks at follow-through.
    say "trace acceptance, arm ${arm}"
    python3 "$SEQCHECK" "${CAP}/met-${arm}.csv" "${CAP}/hemco-${arm}.csv" \
      || echo "  TRACE UNSCOREABLE for arm ${arm} — see above (the run itself is still valid)"
  fi
  umount_lith
  # --pf-trace is documented "Unbounded". Stop rather than fill a shared filesystem.
  used=$(du -sBG "$CAP" 2>/dev/null | awk '{gsub("G","",$1); print $1+0}')
  echo "  capture dir: ${used} GiB"
  (( used > MAXTRACE_GB )) && { echo "  TRACES EXCEED ${MAXTRACE_GB} GiB — stopping before the next arm"; break; }
done

clean_stale_lith
say "capture complete $(date -u +%FT%TZ)"
ls -la "$CAP"/*.csv "$CAP"/*.issued 2>/dev/null | sed 's/^/  /'
echo
echo "Scoring is deliberately NOT done here. Offline, per the agreed rule:"
echo "  pfreplay-273 -issued <sum of that class's issued> -out handles.csv \\"
echo "     met/a=met-a.csv met/b=met-b.csv hemco/a=hemco-a.csv hemco/b=hemco-b.csv"
echo "Use a scorer that SORTS BY seq (lith#272/#273). On main's scorer as merged, a fresh"
echo "met trace still mismatches and met's handles are still excluded — that is the known"
echo "replay defect, NOT a finding about this trace."
echo "Read the denominator-sanity and vs-live lines before anything below them."
echo "Per-handle follow-through remains the WRONG UNIT on met (0/598 sole readers); the"
echo "shared-cache replay is the one with an answer. This job supplies its input."
