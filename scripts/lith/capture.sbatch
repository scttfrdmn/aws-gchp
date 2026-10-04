#!/bin/bash
#SBATCH --job-name=lith-pfcapture
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/scratch/lith-gates/capture-%j.log
#
# THE CAPTURE — the deliverable upstream has been waiting for (scttfrdmn/lith#256, #267).
#
# Question 10 of the campaign, unanswered since gate 5b: HEMCO's prefetch waste is
# unreachable by any flag (eight policies, ~1.23 GB demand floor constant), and gate 5f
# found the mechanism (a per-handle cold-start granularity tax at fs.go:778-786). What is
# still not known is WHICH HANDLES waste, i.e. whether anything observable in a handle's
# FIRST FEW READS predicts whether its prefetch is subsequently read. That needs a real
# GCHP read trace from both mounts, scored offline. This job produces it.
#
# WHY NOW AND NOT BEFORE. Gate 5g drove upstream's scorer on banked ground truth and found
# three defects that would each have voided this job's verdict — chiefly a follow-through
# denominator 12.3x the mount's own counter (no EOF clamp), which made prefetch look
# worthless on BOTH mounts. Gate 5h verified the fix (c922cc7): 215 replayed decisions
# against a live issued of 182. The scorer was the cheap half; it is now sound, so the
# expensive half is worth buying.
#
# ARMS. Two traced replicates, because the pre-registered rule requires fitting on one arm
# and testing on another, plus one untraced control on the SAME binary:
#
#   a   met + HEMCO served by c922cc7, both with --pf-trace
#   b   identical to a (the out-of-sample arm)
#   c   met + HEMCO served by c922cc7, NO --pf-trace
#
# ARM c IS NOT OPTIONAL, and it is the arm this design adds. `lith mount --help` says of
# --pf-trace: "Unbounded, and serialized under one mutex, so it adds a global lock to every
# read: for characterization, not production." With 48 ranks on one mount that is a real
# perturbation risk, and it is confounded with the binary change (267b vs the 1.1.3 release
# that produced every banked number). Arm c separates them: if c reproduces the banked
# defaults and a/b do not, the tracing lock moved it; if c also differs, the binary did.
# Without c, a traced trace could be unrepresentative of the untraced run it claims to
# describe and nothing in the job would say so.
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
#     quantity it named.)
#  P6 THE RULE, agreed in writing with upstream before either side had data: SEPARATION iff
#     a feature of a handle's first k<=8 reads predicts per-handle BYTE follow-through at
#     Spearman |rho| >= 0.5, fit on arm a and tested on arm b. NO SEPARATION iff |rho| <
#     0.5 AND rank-sum AUC < 0.7. Scoring is done offline by lith-pfreplay after the job;
#     nothing in this script computes the verdict, so the arms cannot be tuned to it.
#
# WHAT THIS SCRIPT WILL NOT DO: guess. Every mount command below is gate 5's, byte for
# byte, except the two --pf-trace additions and the binary on met+HEMCO. The run directory
# is the official one (createRunDir.sh, gate 3c) and is not edited here beyond
# point_at/reset_rundir, both inherited unchanged from the gate 5b harness.
#
# NOTE: deliberately NOT `set -u` — GCHP's setCommonRunSettings.sh dereferences unset
# positionals and aborts before mpirun under it (diagnosed on a head-node dry run).
set -o pipefail

GATES=/scratch/lith-gates
RD=/scratch/gchp_lith_fullchem
CAP=${GATES}/capture              # traces land here (FSx, so readable from the head node)
LITH=${GATES}/lith-1.1.3          # release: the three control mounts, as in gate 5
LITH267=${GATES}/lith-267b        # pr/267 = c922cc7: met + HEMCO
RANKS=48
START=20190701
EXPECT_SGMT="00000001 000000"
RESULTS=${GATES}/capture-results.txt
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
[[ -x "$LITH267" ]] || { echo "  FAIL $LITH267 missing"; fail=1; }
# The capture is worthless off a binary that cannot emit `size`: gate 5h measured that a
# size-less trace reports follow-through 1.000 where the truth is 0.052 AND drops the most
# wasteful handles out of the population entirely. Demand the column, not the flag.
if [[ -x "$LITH267" ]]; then
  "$LITH267" mount --help 2>&1 | grep -q -- --pf-trace \
    || { echo "  FAIL $LITH267 has no --pf-trace — wrong commit built"; fail=1; }
  echo "  267b sha256: $(sha256sum "$LITH267" | awk '{print $1}')"
  echo "  267b version: $("$LITH267" version 2>&1 | head -1) (unstamped local build of pr/267 = c922cc7)"
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
  echo "  met   binary: $(basename $LITH267)  trace: [${mt:-none}]"
  echo "  hemco binary: $(basename $LITH267)  trace: [${ht:-none}]"
  # --mem-cache is bounded on EVERY mount: the default is 25% of system memory PER DAEMON,
  # so five mounts would default to capping 125% of the box. Values are gate 5's.
  "$LITH267" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 \
    --index-file "${GATES}/idx/merra2-201907.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 24GB --metrics ":9110" ${mt} --daemon
  # 2015/01 is NOT optional: ExtData.rc has exactly one date-pinned met reference, the
  # constant-field MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4, which does not template
  # over the simulation year. Without it GCHP aborts ~9 s into init.
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2015/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
    --index-file "${GATES}/idx/merra2-2015.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 4GB --metrics ":9111" --daemon
  "$LITH267" mount s3://gcgrid/HEMCO /input-lith/HEMCO \
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
      if [[ -f "$t" ]]; then echo "  trace created: $t"
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
  local label="$1" log="${GATES}/capture-${1}.log"
  say "RUN ${label}"
  reset_rundir
  source /sw/gchp-env.sh              # exports OPAL_PREFIX and PMIX_PREFIX; do not override
  ulimit -s unlimited 2>/dev/null
  # Do NOT discard these scripts' output: a previous job died here with nothing in the log
  # because >/dev/null swallowed setCommonRunSettings.sh's own diagnostic. The official
  # tooling says exactly what is wrong; capture and surface it.
  local setup="${GATES}/capture-${label}-setup.log"
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
echo "  pfreplay-267b -issued <sum of that class's issued> -out handles.csv \\"
echo "     met/a=met-a.csv met/b=met-b.csv hemco/a=hemco-a.csv hemco/b=hemco-b.csv"
echo "Read the denominator-sanity and vs-live lines before anything below them."
