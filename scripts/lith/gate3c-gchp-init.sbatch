#!/bin/bash
#SBATCH --job-name=gate3c-lith-ab
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=01:30:00
#SBATCH --output=/scratch/lith-gates/gate3c-%j.log
#
# GATE 3c — the integration run: a real GCHP init, /input (FSx Lustre) vs lith.
#
# Gate 3/3b measured single-file read shapes on the head node. This runs the actual
# model, so ExtData/HEMCO/pFIO issue the reads instead of a benchmark harness, and
# 48 MPI ranks hit one FUSE mount concurrently — the concurrency question no
# head-node measurement can answer, and the biggest single risk to the proposal.
#
# Four runs, in this order:
#   1  fsx  cold   /input as imported (most files still HSM-released)
#   2  fsx  warm   repeat — this is what our lfs hsm_restore pre-hydration buys
#   3  lith cold   fresh mounts
#   4  lith warm   repeat on the same mounts
#
# The two run directories differ ONLY in where input comes from (three symlinks
# plus HEMCO_Config.rc's ROOT); verified with diff -rq. Everything else — binary,
# config, restart, resolution, rank count — is identical.
#
# Every line of model output is timestamped with elapsed seconds so init phases can
# be extracted afterwards; no log markers are guessed at here.
#
# Also captures, for scttfrdmn/lith#237: what lith's IMDS size table estimates for
# m9g.48xlarge (authoritative DescribeInstanceTypes baseline: 100.0 Gbps), and
# whether cold amplification keeps tracking the stated NIC baseline on a fat pipe —
# at 7.5 Gbps a 110 MB hyperslab pulled 382 MB, at 15 it pulled 654 MB.
# NOTE: deliberately NOT `set -u`. GCHP's own setCommonRunSettings.sh dereferences
# unset positionals (line 578: "$4"), so sourcing it under `set -u` aborts the run
# before mpirun is ever reached. Caught on a 6-rank head-node dry run, not here.
set -o pipefail

GATES=/scratch/lith-gates
FSX_RUN=/scratch/gchp_merra2_TransportTracers
LITH_RUN=/scratch/gchp_lith_TransportTracers
RANKS=48
NIC=100                     # m9g.48xlarge baseline per DescribeInstanceTypes
RESULTS=${GATES}/gate3c-results.txt
# Pin the binary explicitly on shared scratch rather than trusting whatever the
# node bootstrap installed. The compute node's rpm is still v1.1.0 (the cluster's
# OnNodeConfigured predates the release); v1.1.1 carries the #237 NIC-detection
# fix. sha256-verified against the release checksums.txt when staged.
LITH=${GATES}/lith-1.1.1

say() { echo "=== $* ==="; }
stamp() { awk -v t0="$(date +%s.%N)" '{printf "%8.2f  %s\n", systime()-t0, $0; fflush()}'; }

exec > >(tee -a "$RESULTS") 2>&1

say "node facts"
TOK=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ITYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-type)
echo "instance:  $ITYPE   host: $(hostname)   cores: $(nproc)"
echo "lith:      $("$LITH" version 2>&1 | head -1)  [node rpm: $(lith version 2>&1|head -1)]"
free -g | head -2

say "lith#237 datapoint: IMDS estimate on a 100 Gbps node (authoritative baseline 100.0)"
# The #237 fix shipped in v1.1.1, so this comes from the release binary, not the
# branch build (lith-238) used for the original hardware confirmation.
"$LITH" doctor s3://gcgrid --no-sign-request 2>&1 | grep -iE "nic|parts-max|WARN" || true

# ---------------------------------------------------------------- lith mounts
mount_lith() {
  say "mounting lith prefixes (--nic-gbps ${NIC})"
  for d in GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 \
           HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
    mkdir -p "/input-lith/${d}"
  done
  # Each mount is prefix-scoped with its own index. MERRA2 is mounted at the
  # .../2019/01 leaf so the index stays 217 keys; MetDir points at the MERRA2
  # parent, which is a real directory, so ExtData's MetDir/%y4/%m2/... resolves
  # through the mountpoint.
  #
  # 2015/01 is mounted as well, and is not optional: ExtData.rc has exactly one
  # date-pinned met reference, the constant-field file
  # MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4, which the simulation year does
  # not template over. Without it GCHP aborts in ExtDataGridCompMod.F90:1942
  # ("File ... not found") ~9 s into init. Two small indexes beat one index over
  # the whole multi-year MERRA2 tree.
  #
  # --mem-cache is bounded explicitly on every mount. Its default is 25% of system
  # memory PER DAEMON, so four mounts default to capping 100% of the box — on a
  # 768 GB m9g that is 192 GB apiece. GCHP wants that memory. This is a real
  # multi-mount gotcha, not a tuning preference.
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/01 /input-lith/GEOS_0.5x0.625/MERRA2/2019/01 \
       --index-file "${GATES}/idx/merra2.lithidx"  --no-sign-request --nic-gbps $NIC \
       --mem-cache 32GB --metrics ":9110" --daemon
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2015/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
       --index-file "${GATES}/idx/merra2-2015.lithidx" --no-sign-request --nic-gbps $NIC \
       --mem-cache 4GB --metrics ":9111" --daemon
  "$LITH" mount s3://gcgrid/HEMCO /input-lith/HEMCO \
       --index-file "${GATES}/idx/hemco.lithidx"   --no-sign-request --nic-gbps $NIC --mem-cache 8GB --metrics ":9112" --daemon
  "$LITH" mount s3://gcgrid/CHEM_INPUTS /input-lith/CHEM_INPUTS \
       --index-file "${GATES}/idx/cheminp.lithidx" --no-sign-request --nic-gbps $NIC --mem-cache 8GB --metrics ":9113" --daemon
  "$LITH" mount s3://gcgrid/GEOSCHEM_RESTARTS /input-lith/GEOSCHEM_RESTARTS \
       --index-file "${GATES}/idx/restarts.lithidx" --no-sign-request --nic-gbps $NIC --mem-cache 8GB --metrics ":9114" --daemon
  sleep 5
  mount | grep -c fuse.lith
  # prove the model's four entry points resolve
  ls -L "${LITH_RUN}/MetDir/2019/01/MERRA2.20190101.A1.05x0625.nc4" \
        "${LITH_RUN}/gchp_restart.nc4" >/dev/null && echo "lith paths resolve OK"
}
umount_lith() {
  for m in /input-lith/GEOS_0.5x0.625/MERRA2/2019/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
           /input-lith/HEMCO /input-lith/CHEM_INPUTS /input-lith/GEOSCHEM_RESTARTS; do
    fusermount3 -u "$m" >/dev/null 2>&1
  done
}

# ---------------------------------------------------------------- one GCHP run
# A successful GCHP run advances cap_restart and writes a checkpoint, so the run
# dir MUST be reset before each repetition or the next run starts from the wrong
# date and reads different met files.
reset_rundir() {
  cd "$1" || exit 1
  echo "20190101 000000" > cap_restart
  rm -f Restarts/gcchem_internal_checkpoint* OutputDir/*.nc4 2>/dev/null
}

gchp_run() {  # gchp_run LABEL RUNDIR
  local label="$1" dir="$2" log="${GATES}/gate3c-${1}.log"
  say "RUN ${label}  (${dir})"
  reset_rundir "$dir"
  # gchp-env.sh already exports OPAL_PREFIX and PMIX_PREFIX for the relocated stack,
  # and they are NOT the same prefix — PMIx is a separate install (/sw/pmix-5.0.3).
  # Overriding PMIX_PREFIX to the OpenMPI prefix makes mpirun die instantly with a
  # "no-plugins" help-file error. Do not set them here.
  source /sw/gchp-env.sh
  ulimit -s unlimited 2>/dev/null
  source setCommonRunSettings.sh >/dev/null 2>&1
  source setRestartLink.sh
  source checkRunSettings.sh >/dev/null 2>&1

  # WHY A WATCHDOG INSTEAD OF `wait`: GCHP 14.7.1 finishes the simulation, writes
  # gcchem_internal_checkpoint, writes cap_restart — and then throws
  # "double free or corruption (!prev)" on most ranks inside _dl_fini (i.e. in
  # library destructors, after main() has returned) and leaves some ranks spinning
  # forever. Waiting on mpirun therefore never returns. Measured on the head node:
  # the model's own work was 100% complete before the first abort message.
  # So: poll for the completion evidence GCHP itself writes, then kill.
  local t0 t1 deadline=3600
  t0=$(date +%s.%N)
  mpirun -n "$RANKS" ./gchp 2>&1 | stamp > "$log" &
  local pipe_pid=$!

  local done_at="" i=0
  while (( i < deadline )); do
    if [[ -s cap_restart ]] && [[ "$(awk '{print $1}' cap_restart)" != "20190101" ]] \
       && [[ -s Restarts/gcchem_internal_checkpoint ]]; then
      done_at=$(date +%s.%N); break
    fi
    kill -0 "$pipe_pid" 2>/dev/null || break   # died without completing
    sleep 1; ((i++))
  done
  t1=${done_at:-$(date +%s.%N)}
  pkill -9 -f "$dir/gchp" 2>/dev/null
  kill -9 "$pipe_pid" 2>/dev/null
  wait "$pipe_pid" 2>/dev/null
  sleep 2

  # Init cost is the number this gate is about, and it is separable: the first
  # "GCHP Date" line is the first completed timestep, so everything before it is
  # startup + ExtData/HEMCO/restart reads. stamp() put elapsed seconds on column 1.
  local init_s sim_end_s
  init_s=$(grep -m1 "GCHP Date" "$log" | awk '{print $1}')
  sim_end_s=$(grep "GCHP Date" "$log" | tail -1 | awk '{print $1}')

  local after; after=$(awk '{print $1}' cap_restart 2>/dev/null)
  local verdict=FAILED
  [[ -n "$done_at" ]] && verdict=SUCCEEDED
  printf 'RESULT %-10s init=%ss  sim_end=%ss  to_completion=%.1fs  cap_restart->%s  %s\n' \
    "$label" "${init_s:-NA}" "${sim_end_s:-NA}" \
    "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "${after:-NA}" "$verdict"
  echo "  log: $log ($(wc -l < "$log" 2>/dev/null) lines)"
}

# EVERY mount gets its own metrics port. On the 6-rank head-node dry run only the
# MERRA2 mount was instrumented, which under-reports total S3 traffic for the run
# by whatever HEMCO, CHEM_INPUTS and the restart moved.
PORTS="9110:merra2-2019 9111:merra2-2015 9112:hemco 9113:chem-inputs 9114:restarts"
metrics_dump() {
  say "lith metrics after $1"
  for pp in $PORTS; do
    local port=${pp%%:*} name=${pp##*:}
    echo "-- ${name} (:${port})"
    curl -s --max-time 5 "http://localhost:${port}/metrics" \
      | grep -E "^lith_(s3_bytes_total|distinct_bytes_read|cache_misses_total|fill_runs_total|prefetch_(issued|used|uncovered|evicted_unread)_total|sibling_prefetch(_unread)?_total|s3_requests_total|read_straddle_total)" \
      | grep -v bucket
  done
}

# ------------------------------------------------------- honest FSx cold state
# /input's met files came back "exists archived" (already hydrated) from earlier
# gate work, so a cold FSx measurement is not available by simply not touching
# them. lfs hsm_release restores it: the file stays, its local blocks are freed,
# and the contents are re-fetched from s3://gcgrid on next read. This is safe and
# reversible here because /input is a read-only S3-backed import — nothing is
# deleted, and the authoritative copy is the public RODA bucket.
#
# Only the MET files are released. Identifying HEMCO's exact working set is not
# worth the risk of releasing the wrong thing, so HEMCO/CHEM_INPUTS stay warm on
# the FSx side. That biases the comparison IN FSX'S FAVOUR, which makes any lith
# advantage reported here a conservative floor rather than a best case.
MET_FSX=(/input/GEOS_0.5x0.625/MERRA2/2019/01/MERRA2.2019010[12].*.nc4
         /input/GEOS_0.5x0.625/MERRA2/2015/01/MERRA2.20150101.CN.05x0625.nc4)
fsx_release() {
  say "releasing FSx met blocks to force a genuine cold read"
  local n=0
  for f in "${MET_FSX[@]}"; do
    [[ -f "$f" ]] || continue
    lfs hsm_release "$f" 2>/dev/null && ((n++))
  done
  echo "released $n files"
  echo "state check (want 'released exists archived'):"
  lfs hsm_state "${MET_FSX[0]}" 2>&1
}
fsx_state() { say "FSx HSM state $1"; lfs hsm_state "${MET_FSX[@]}" 2>&1 \
  | awk '{print $NF, $0}' | grep -oE "released|archived" | sort | uniq -c; }

# ---------------------------------------------------------------- the four runs
fsx_release
fsx_state "before fsx-cold"
gchp_run fsx-cold  "$FSX_RUN"
fsx_state "after fsx-cold (everything read should now be archived+resident)"
gchp_run fsx-warm  "$FSX_RUN"

mount_lith
gchp_run lith-cold "$LITH_RUN"
metrics_dump lith-cold
gchp_run lith-warm "$LITH_RUN"
metrics_dump lith-warm
umount_lith

say "done — results in $RESULTS"
