#!/bin/bash
# gchp-pgtest-run.sh — run a C180 2-node GCHP run in a NAMED queue with a chosen transport,
# for the PG/EFA ablation. Measures GCHP-internal Avg throughput (sim-completion-detect; the
# pnc4 checkpoint is killed, not waited on). Run on the head node.
#
# Usage: gchp-pgtest-run.sh <queue> <transport>
#   queue     = pg | nopg | tcp   (SLURM partition)
#   transport = efa | tcp         (efa: force ofi/efa; tcp: force tcp, exclude efa)
set -uo pipefail
QUEUE=$1; TRANSPORT=$2
STACK=/sw
GCHP_BIN="${STACK}/gchp-14.7.1/bin/gchp"
SCRATCH="/scratch"
SRC="${SCRATCH}/GCHP"
CRD_DIR="${SRC}/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/run/GCHP"
CS_RES=180; NODES=2; RPN=60; TOTAL=$((NODES*RPN)); DAYS=1
RUNDIR="${SCRATCH}/gchp_c180"     # shared run dir (created once); each run resets cap_restart

# one-time run-dir create
mkdir -p ~/.geoschem
printf 'export GC_DATA_ROOT=/input\nexport GC_USER_REGISTERED=true\n' > ~/.geoschem/config
if [[ ! -f "${RUNDIR}/setCommonRunSettings.sh" ]]; then
  command -v expect >/dev/null 2>&1 || sudo dnf install -y expect
  command -v git    >/dev/null 2>&1 || sudo dnf install -y git
  mkdir -p "$SCRATCH"
  if [[ ! -f "${CRD_DIR}/createRunDir.sh" ]]; then
    cd "$SCRATCH"; [[ -d "$SRC" ]] || git clone --depth 1 --branch 14.7.1 https://github.com/geoschem/GCHP.git
    cd "$SRC"; git submodule update --init --depth 1 src/GCHP_GridComp/GEOSChem_GridComp/geos-chem
  fi
  TMP="${SCRATCH}/gchp_merra2_TransportTracers"; rm -rf "$TMP"
  EXP=$(mktemp); cat > "$EXP" <<EOF
#!/usr/bin/expect -f
set timeout 600
cd ${CRD_DIR}
spawn ./createRunDir.sh
expect "Choose simulation type:" { send "2\r" }
expect "Choose meteorology source:" { send "1\r" }
expect "Enter path where the run directory will be created:" { send "${SCRATCH}\r" }
expect "Enter run directory name" { send "\r" }
expect "track run directory changes with git" { send "n\r" }
expect eof
EOF
  expect "$EXP"; rm -f "$EXP"; mv "$TMP" "$RUNDIR"
fi
cd "$RUNDIR"

# restart + reset start date
RST=$(ls /input/GEOSCHEM_RESTARTS/GC_*/GEOSChem.Restart.TransportTracers.20190101_0000z.c${CS_RES}.nc4 2>/dev/null | head -1)
mkdir -p Restarts; ln -sf "$RST" "Restarts/GEOSChem.Restart.20190101_0000z.c${CS_RES}.nc4"
echo "20190101 000000" > cap_restart
SC=setCommonRunSettings.sh
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${TOTAL}/" "$SC"
sed -i "s/^NUM_NODES=.*/NUM_NODES=${NODES}/" "$SC"
sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${RPN}/" "$SC"
sed -i "s/^CS_RES=.*/CS_RES=${CS_RES}/" "$SC"
sed -i "s/^Run_Duration=.*/Run_Duration=\"00000001 000000\"/" "$SC"
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: YES/" GCHP.rc
ln -sf "$GCHP_BIN" "${RUNDIR}/gchp"

TAG="${QUEUE}_${TRANSPORT}"
# transport env: efa forces ofi/efa; tcp forces the tcp btl/mtl and excludes efa
if [[ "$TRANSPORT" == "efa" ]]; then
  TENV='export FI_PROVIDER=efa; export OMPI_MCA_mtl_ofi_provider_include=efa'
else
  # Force NON-EFA without breaking MAPL/ESMF one-sided (RMA) + THREAD_MULTIPLE: keep the normal
  # PML/BTL/MTL stack, just steer libfabric AWAY from the efa provider so ofi uses tcp/sockets.
  # (Heavy-handed pml=ob1 + btl=tcp breaks osc/pt2pt — MAPL needs the threaded one-sided path.)
  TENV='export FI_PROVIDER=tcp; export OMPI_MCA_mtl_ofi_provider_exclude=efa'
fi

cat > "${RUNDIR}/gchp_${TAG}.slurm" <<EOF
#!/bin/bash
#SBATCH --job-name=pg-${TAG}
#SBATCH --partition=${QUEUE}
#SBATCH --nodes=${NODES}
#SBATCH --ntasks=${TOTAL}
#SBATCH --ntasks-per-node=${RPN}
#SBATCH --time=00:40:00
#SBATCH --output=slurm-${TAG}-%j.log
#SBATCH --exclusive
set -e
cd "\$SLURM_SUBMIT_DIR"
source ${STACK}/gchp-env.sh
export PATH="${STACK}/libfabric-1.22.0/bin:\$PATH"
ulimit -s unlimited 2>/dev/null
${TENV}
source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh
set +e
RUNLOG=gchp_${TAG}.log
END_MARK="GCHP Date: 2019/01/02  Time: 00:00:00"
t0=\$(date +%s)
mpirun -n ${TOTAL} ./gchp > \${RUNLOG} 2>&1 &
MPI=\$!
DONE=0
while kill -0 \$MPI 2>/dev/null; do
  if grep -aq "\${END_MARK}" \${RUNLOG} 2>/dev/null; then DONE=1; t1=\$(date +%s); sleep 3; kill -TERM \$MPI 2>/dev/null; sleep 2; kill -KILL \$MPI 2>/dev/null; break; fi
  sleep 2
done
[[ \$DONE -eq 0 ]] && t1=\$(date +%s)
wait \$MPI 2>/dev/null
ELAPSED=\$((t1-t0))
FINAL=\$(grep -a "\${END_MARK}" \${RUNLOG} 2>/dev/null | tail -1)
AVG=\$(echo "\$FINAL" | sed 's/.*\[Avg Tot Run\]://' | grep -oE "[0-9]+\.[0-9]+" | head -1)
# confirm transport actually used (grep the ofi provider line)
PROV=\$(grep -a "mtl_ofi_component" \${RUNLOG} 2>/dev/null | grep -oE "provider: [a-z0-9]+" | head -1)
echo "RESULT_PGTEST tag=${TAG} queue=${QUEUE} transport=${TRANSPORT} elapsed=\${ELAPSED} internalAvg=\${AVG:-NA} provider=\${PROV:-none} done=\${DONE}"
EOF
echo "submit: sbatch ${RUNDIR}/gchp_${TAG}.slurm"
echo "TAG=${TAG}"
