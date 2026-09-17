#!/bin/bash
# gchp-fabric-ab-tt.sh — Measurement 1 (EFA-vs-TCP A/B), TransportTracers edition.
#
# Why TransportTracers, not fullchem: TT IS tracer advection and nothing else (no KPP, no 250-species
# chemistry state, no GMI/emissions input tree). That makes it (a) the PUREST possible probe of the
# load-bearing fabric number — FV3's COMM_TRACER halo — undiluted by chemistry wall-time, and (b)
# memory-light enough to fit C180 on hpc7g (128GB/node) where C180 fullchem OOMs. The matrix already
# proved C180 TT runs clean at 2 nodes. Restart: native GC_14.7.0 C180 TT (no missing-species).
#
# Runs the SAME run dir twice per node count: (a) EFA/ofi default, (b) forced TCP. Captures FV3 stock
# FMS timers (COMM_TRACER=tracer halo, tracer_2d=transport compute, DYN_CORE=acoustic flow solver) +
# the MAPL component report. Timing is read from those internal reports, NEVER wall-clock around the
# brittle checkpoint. A watcher kills mpirun at sim-completion so a pnc4 checkpoint hang can't block.
#
# Usage (head node): gchp-fabric-ab-tt.sh <nodes> <fabric:efa|tcp> [CS=180]
set -uo pipefail
NODES=$1; FABRIC=$2; CS=${3:-180}
STACK=/sw
GCHP_BIN=/scratch/gchp-instr/GCHP/build/bin/gchp
RUNDIR=/scratch/gchp_tt
RPN=60; TOTAL=$((NODES*RPN))
TAG="c${CS}tt_n${NODES}_${FABRIC}"

cd "$RUNDIR" || { echo "FAIL: run dir $RUNDIR missing"; exit 1; }
echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${TOTAL}/"             setCommonRunSettings.sh
sed -i "s/^NUM_NODES=.*/NUM_NODES=${NODES}/"                 setCommonRunSettings.sh
sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${RPN}/" setCommonRunSettings.sh
sed -i "s/^CS_RES=.*/CS_RES=${CS}/"                          setCommonRunSettings.sh
sed -i 's/^Run_Duration=.*/Run_Duration="00000001 000000"/' setCommonRunSettings.sh
# EXPLICIT layout (AutoUpdate_NXNY mis-picks -> FV3 'pe_end not in pelist'). Valid C180 layouts:
if [ "$CS" = "180" ]; then
  case "$TOTAL" in
    60)  NX=5;  NY=12 ;; 120) NX=5;  NY=24 ;; 240) NX=10; NY=24 ;;
    *) echo "FAIL: no preset C180 layout for $TOTAL cores"; exit 1 ;;
  esac
elif [ "$CS" = "90" ]; then
  case "$TOTAL" in
    60)  NX=5;  NY=12 ;; 120) NX=10; NY=12 ;;
    *) echo "FAIL: no preset C90 layout for $TOTAL cores"; exit 1 ;;
  esac
else
  echo "FAIL: no preset layout table for C$CS"; exit 1
fi
sed -i "s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/" setCommonRunSettings.sh
sed -i "s/^NX=.*/NX=${NX}/" setCommonRunSettings.sh
sed -i "s/^NY=.*/NY=${NY}/" setCommonRunSettings.sh
# TT C180 restart is version-matched (GC_14.7.0), so species are present; keep =0 for safety only.
sed -i "s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
echo "[fabric-ab-tt] C${CS} TT: ${NODES}n x ${RPN} = ${TOTAL} cores, NX=${NX} NY=${NY}"
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: YES/" GCHP.rc 2>/dev/null || true
ln -sf "$GCHP_BIN" "$RUNDIR/gchp"

# Measurement 2/3: pass the shard-probe env through to the SLURM body if the harness was invoked
# with GCHP_INSTR_SHARD=1. Local write dir on Lustre scratch; S3 deliberately OFF.
if [ "${GCHP_INSTR_SHARD:-0}" = "1" ]; then
  SHARD_DIR=/scratch/gchp_tt/shardprobe_${TAG}
  mkdir -p "$SHARD_DIR"
  SHARD_ENV="export GCHP_INSTR_SHARD=1; export GCHP_INSTR_LOCAL=$SHARD_DIR"
  # The shard probe is hooked in MAPL_StateRecord, which fires ONLY on the periodic RECORD alarm.
  # That alarm is created only if RECORD_FREQUENCY: is set (it's commented out by default -> probe
  # never fires, even when enabled). Set it to ring once mid-run (every 12h sim time = 43200s) so
  # the probe records a real superstep boundary alongside the collective checkpoint path.
  if grep -qE "^#?RECORD_FREQUENCY:" GCHP.rc; then
    sed -i "s/^#\?RECORD_FREQUENCY:.*/RECORD_FREQUENCY: 120000/" GCHP.rc
    sed -i "s/^#\?RECORD_REF_DATE:.*/RECORD_REF_DATE: 20190101/" GCHP.rc
    sed -i "s/^#\?RECORD_REF_TIME:.*/RECORD_REF_TIME: 000000/" GCHP.rc
    echo "[fabric-ab-tt] RECORD_FREQUENCY enabled (120000 = 12h) so the RecordAlarm fires the probe"
  fi
  # CRITICAL: mpirun does NOT propagate the SLURM-shell env to ranks on remote nodes (orted spawns
  # them fresh). Without -x, node-2 ranks never see GCHP_INSTR_SHARD -> probe silently no-ops there.
  SHARD_X="-x GCHP_INSTR_SHARD -x GCHP_INSTR_LOCAL"
  echo "[fabric-ab-tt] SHARD PROBE ON -> $SHARD_DIR (S3 OFF), forwarding via mpirun -x"
else
  SHARD_ENV="# shard probe OFF"
  SHARD_X=""
fi

# --- fabric selection: the auditable bit. Three modes, all printed into the log verbatim:
#   efa     : ofi/efa default (osc/rdma rides EFA — GCHP's intended path)
#   tcp     : force ob1/tcp, exclude ofi/efa. OpenMPI's one-sided then falls to osc/pt2pt, which
#             does NOT support MPI_THREAD_MULTIPLE -> MAPL's MPI_Win_create aborts at init.
#   tcprdma : same TCP transport but force the RDMA one-sided component (--mca osc rdma) to ride the
#             tcp btl. The fair "make TCP work" attempt: does osc/rdma-over-tcp satisfy MAPL's
#             thread-multiple window requirement? If this ALSO aborts, "GCHP needs an RDMA fabric
#             for multi-node" is airtight (not merely a pt2pt-default artifact).
if [ "$FABRIC" = "tcp" ]; then
  FABRIC_MCA='--mca pml ob1 --mca btl tcp,self --mca mtl ^ofi --mca btl_tcp_if_include ens5'
  FABRIC_ENV='export FI_PROVIDER=tcp; export OMPI_MCA_mtl_ofi_provider_exclude=efa'
elif [ "$FABRIC" = "tcprdma" ]; then
  FABRIC_MCA='--mca pml ob1 --mca btl tcp,self --mca mtl ^ofi --mca osc rdma --mca btl_tcp_if_include ens5'
  FABRIC_ENV='export FI_PROVIDER=tcp; export OMPI_MCA_mtl_ofi_provider_exclude=efa'
else
  FABRIC_MCA='--mca mtl_ofi_provider_include efa'
  FABRIC_ENV='export FI_PROVIDER=efa; export OMPI_MCA_mtl_ofi_provider_include=efa'
fi

cat > "$RUNDIR/run_${TAG}.slurm" <<EOF
#!/bin/bash
#SBATCH --job-name=${TAG}
#SBATCH --partition=compute
#SBATCH --nodes=${NODES}
#SBATCH --ntasks=${TOTAL}
#SBATCH --ntasks-per-node=${RPN}
#SBATCH --time=00:50:00
#SBATCH --output=slurm-${TAG}-%j.log
#SBATCH --exclusive
set -e
cd "\$SLURM_SUBMIT_DIR"
source ${STACK}/gchp-env.sh
export PATH="${STACK}/libfabric-1.22.0/bin:\$PATH"
ulimit -s unlimited 2>/dev/null
${FABRIC_ENV}

# Measurement 2/3 shard probe (default OFF). Enabled only when the harness is invoked with
# GCHP_INSTR_SHARD=1 in the environment. Writes each rank's INTERNAL state to a LOCAL file on
# Lustre scratch (NO collective, NO barrier) and times serialize/write. S3 column stays OFF
# (GCHP_INSTR_S3 intentionally unset) to avoid 120 per-rank aws-cli forks.
${SHARD_ENV}

# CRITICAL: source the run-dir settings scripts so the edited NX/NY/cores/duration propagate INTO
# GCHP.rc / CAP.rc. Without this, GCHP reads stale resource files (the FV3 'pe_end not in pelist'
# failure). set +e: they may emit benign nonzero on info checks.
set +e
source setCommonRunSettings.sh
source setRestartLink.sh
source checkRunSettings.sh
set -e

# MAPL uses MPI_Win_allocate_shared for on-node windows; enlarge /dev/shm to 64GB on every node
# (TT is far lighter than fullchem, but keep the headroom; 64G of 128G leaves RAM for the model).
echo "=== enlarging /dev/shm to 64G on all nodes ==="
srun --ntasks-per-node=1 --ntasks=${NODES} sudo mount -o remount,size=64G /dev/shm 2>&1 | tail -2

echo "=== FABRIC=${FABRIC} ; MCA flags: ${FABRIC_MCA} ==="
echo "=== fi_info efa availability on this node ==="
fi_info -p efa 2>&1 | grep -E "provider|fabric" | head -4 || echo "fi_info: no efa (expected if tcp-forced)"
RUNLOG=gchp_${TAG}.log
END_MARK="GCHP Date: 2019/01/02  Time: 00:00:00"
# FMS clock summary + MAPL component report print at FINALIZE, AFTER the end-of-run checkpoint.
# So we must NOT kill at the END_MARK — that severs exactly the timer reports we came for. Instead:
# once the last timestep is seen, give finalize a generous GRACE for the (brittle pnc4) checkpoint
# to complete and the reports to print. Kill ONLY if the checkpoint hangs past GRACE — and that kill
# is itself Measurement-2 evidence ("collective checkpoint did not return"). The fabric numbers are
# internal FMS/MAPL clocks accumulated DURING the run, so letting the checkpoint finish never
# contaminates them (timing is read from the report, never wall-clocked around the checkpoint).
GRACE=360

mpirun -n ${TOTAL} ${FABRIC_MCA} ${SHARD_X} --mca mtl_base_verbose 10 --mca btl_base_verbose 10 \
       ./gchp > \${RUNLOG} 2>&1 &
MPI=\$!
DONE=0; ENDSEEN=0; WAITED=0; CKPT_HANG=0
while kill -0 \$MPI 2>/dev/null; do
  if [ \$ENDSEEN -eq 0 ] && grep -aq "\${END_MARK}" \${RUNLOG} 2>/dev/null; then
     ENDSEEN=1; DONE=1
     echo "=== END_MARK seen; entering finalize grace (\${GRACE}s) to capture timer reports ==="
  fi
  if [ \$ENDSEEN -eq 1 ]; then
     WAITED=\$((WAITED+3))
     if [ \$WAITED -ge \$GRACE ]; then
        echo "=== CHECKPOINT_HANG: finalize did not return within \${GRACE}s after END_MARK — killing (Measurement-2 evidence) ==="
        CKPT_HANG=1; kill -TERM \$MPI 2>/dev/null; sleep 3; kill -KILL \$MPI 2>/dev/null; break
     fi
  fi
  sleep 3
done
wait \$MPI 2>/dev/null
echo "=== finalize: ENDSEEN=\${ENDSEEN} CKPT_HANG=\${CKPT_HANG} grace_waited=\${WAITED}s ==="

echo "RESULT_FABRIC_PROOF tag=${TAG}"
grep -aE "mtl:ofi:provider|select.*(efa|tcp|sockets)|btl: tcp|provider: efa|provider: tcp" \${RUNLOG} | head -6
echo "RESULT_TIMERS tag=${TAG} (FV3 FMS report — COMM_TRACER=tracer halo, tracer_2d=transport, DYN_CORE=acoustic)"
grep -aE "COMM_TRACER|tracer_2d|DYN_CORE|COMM_TOTAL|Total runtime" \${RUNLOG} | tail -25
echo "RESULT_MAPLTIMER tag=${TAG} (MAPL component report — DYNAMICS vs GCHPchem vs IO)"
grep -aE "Times for|DYNAMICS|GCHPchem|GCHPctmEnv|GCHP " \${RUNLOG} | tail -25
echo "RESULT_THROUGHPUT tag=${TAG} (GCHP internal Avg, final step)"
grep -a "\${END_MARK}" \${RUNLOG} | tail -1
echo "RESULT_SHARDPROBE tag=${TAG} (Measurement 2/3 — per-rank independent INTERNAL write, if enabled)"
grep -aE "SHARDPROBE tag=" \${RUNLOG} | head -130
echo "RESULT_DONE tag=${TAG} sim_completed=\${DONE} ckpt_hang=\${CKPT_HANG}"
EOF

JID=$(sbatch --parsable "$RUNDIR/run_${TAG}.slurm")
echo "SUBMITTED ${TAG} job=$JID"
