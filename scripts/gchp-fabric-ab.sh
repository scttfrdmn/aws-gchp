#!/bin/bash
# gchp-fabric-ab.sh — Measurement 1: EFA-vs-TCP A/B for C180 fullchem on a deployed cluster.
# Runs the SAME run dir twice per node count: (a) EFA/ofi default, (b) forced TCP.
# Captures FV3 stock FMS timers (COMM_TRACER=tracer halo, tracer_2d=transport compute, DYN_CORE)
# + MAPL component report. Timing comes from those internal reports, NEVER wall-clock around the
# checkpoint. The run watcher kills mpirun at sim-completion so a pnc4 hang can't block the A/B.
#
# Usage (head node): gchp-fabric-ab.sh <nodes> <fabric:efa|tcp>
# Env (Part B shard probe, optional): GCHP_INSTR_SHARD=1 GCHP_INSTR_LOCAL=/scratch/shardprobe
#   (S3 column intentionally OFF this pass: do NOT set GCHP_INSTR_S3 — avoids 240 CLI forks.)
set -uo pipefail
NODES=$1; FABRIC=$2; CS=${3:-90}     # grid resolution (default C90 — fits hpc7g 128GB; C180 fullchem OOMs)
STACK=/sw
GCHP_BIN=/scratch/gchp-instr/GCHP/build/bin/gchp
RUNDIR=/scratch/gchp_c${CS}_fullchem
RPN=60; TOTAL=$((NODES*RPN))
TAG="c${CS}fc_n${NODES}_${FABRIC}"

cd "$RUNDIR" || { echo "FAIL: run dir $RUNDIR missing"; exit 1; }
echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${TOTAL}/"           setCommonRunSettings.sh
sed -i "s/^NUM_NODES=.*/NUM_NODES=${NODES}/"               setCommonRunSettings.sh
sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${RPN}/" setCommonRunSettings.sh
sed -i "s/^CS_RES=.*/CS_RES=${CS}/"                        setCommonRunSettings.sh
sed -i 's/^Run_Duration=.*/Run_Duration="00000001 000000"/' setCommonRunSettings.sh
# EXPLICIT layout (AutoUpdate_NXNY mis-picks -> FV3 'pe_end not in pelist'). Per-grid valid layouts:
if [ "$CS" = "180" ]; then
  case "$TOTAL" in
    60)  NX=5;  NY=12 ;; 120) NX=5;  NY=24 ;; 240) NX=10; NY=24 ;;
    *) echo "FAIL: no preset C180 layout for $TOTAL"; exit 1 ;;
  esac
else  # C90
  case "$TOTAL" in
    60)  NX=5;  NY=12 ;; 120) NX=10; NY=12 ;;
    *) echo "FAIL: no preset C90 layout for $TOTAL (C90 clean layouts: 60,120 only)"; exit 1 ;;
  esac
fi
sed -i "s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/" setCommonRunSettings.sh
sed -i "s/^NX=.*/NX=${NX}/" setCommonRunSettings.sh
sed -i "s/^NY=.*/NY=${NY}/" setCommonRunSettings.sh
# Allow MAPL to bootstrap species absent from the (older GC_14.0.0) restart — the 14.7.1 fullchem
# mechanism has species (e.g. ACO3) the 2019 restart lacks. REQUIRED=1 aborts on the first miss;
# =0 zero-initializes them. Fine for a PERFORMANCE/fabric benchmark (not validating chemistry).
sed -i "s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
echo "[fabric-ab] C180 layout: ${NODES}n x ${RPN} = ${TOTAL} cores, NX=${NX} NY=${NY}"
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: YES/" GCHP.rc 2>/dev/null || true
ln -sf "$GCHP_BIN" "$RUNDIR/gchp"

# --- fabric selection: the auditable bit. EFA = ofi:efa default. TCP = force ob1/tcp, exclude efa. ---
if [ "$FABRIC" = "tcp" ]; then
  FABRIC_MCA='--mca pml ob1 --mca btl tcp,self --mca mtl ^ofi --mca btl_tcp_if_include ens5'
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

# CRITICAL: source the run-dir settings scripts so the edited NX/NY/cores/duration propagate
# INTO GCHP.rc / CAP.rc. Without this, GCHP reads stale resource files (the FV3 'pe_end not in
# pelist' failure). Mirrors the validated matrix run-script order. set +e around them: they may
# emit benign nonzero on info checks.
set +e
source setCommonRunSettings.sh
source setRestartLink.sh
source checkRunSettings.sh
set -e

# SHARED-MEMORY FIX: MAPL uses MPI_Win_allocate_shared for on-node species/tracer windows.
# hpc7g default /dev/shm (~36GB) is too small for C180 fullchem -> 'help-opal-shmem-mmap / target
# full' abort during init. Enlarge /dev/shm to 64GB on EVERY allocated node (128GB RAM) before
# mpirun. srun -> all nodes; sudo is available on PC compute nodes.
echo "=== enlarging /dev/shm to 64G on all nodes ==="
srun --ntasks-per-node=1 --ntasks=${NODES} sudo mount -o remount,size=64G /dev/shm 2>&1 | tail -2
srun --ntasks-per-node=1 --ntasks=${NODES} bash -c 'echo "\$(hostname) /dev/shm: \$(df -h /dev/shm | tail -1 | awk "{print \\\$2}")"' 2>&1

# --- PROVE the fabric: print provider + verbose ofi/btl selection into the log ---
echo "=== FABRIC=${FABRIC} ; MCA flags: ${FABRIC_MCA} ==="
echo "=== fi_info efa availability on this node ==="
fi_info -p efa 2>&1 | grep -E "provider|fabric" | head -4 || echo "fi_info: no efa (expected if tcp-forced env)"
RUNLOG=gchp_${TAG}.log
END_MARK="GCHP Date: 2019/01/02  Time: 00:00:00"

mpirun -n ${TOTAL} ${FABRIC_MCA} --mca mtl_base_verbose 10 --mca btl_base_verbose 10 \
       ./gchp > \${RUNLOG} 2>&1 &
MPI=\$!
DONE=0
while kill -0 \$MPI 2>/dev/null; do
  if grep -aq "\${END_MARK}" \${RUNLOG} 2>/dev/null; then
     DONE=1; sleep 3; kill -TERM \$MPI 2>/dev/null; sleep 2; kill -KILL \$MPI 2>/dev/null; break
  fi
  sleep 2
done
wait \$MPI 2>/dev/null

# --- harvest: prove fabric, then pull stock FV3 timers + MAPL component split from the log ---
echo "RESULT_FABRIC_PROOF tag=${TAG}"
grep -aE "mtl:ofi:provider|select.*(efa|tcp|sockets)|btl: tcp|provider: efa|provider: tcp" \${RUNLOG} | head -6
echo "RESULT_TIMERS tag=${TAG} (FV3 FMS report — COMM_TRACER=tracer halo, tracer_2d=transport, DYN_CORE=acoustic)"
grep -aE "COMM_TRACER|tracer_2d|DYN_CORE|COMM_TOTAL|Total runtime" \${RUNLOG} | tail -20
echo "RESULT_THROUGHPUT tag=${TAG} (GCHP internal Avg d/d, final step)"
grep -a "\${END_MARK}" \${RUNLOG} | tail -1 | sed 's/.*\[Avg Tot Run\]://' | grep -oE "[0-9]+\.[0-9]+" | head -3
echo "RESULT_DONE tag=${TAG} sim_completed=\${DONE}"
EOF

JID=$(sbatch --parsable "$RUNDIR/run_${TAG}.slurm")
echo "SUBMITTED ${TAG} job=$JID"
