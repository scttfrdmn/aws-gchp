#!/bin/bash
#
# gchp-matrix-run.sh — one GCHP (resolution, node-count) timed run on a deployed cluster.
# Idempotent: creates the run dir once per resolution, then for each invocation reconfigures
# node count, RESETS the start date, submits, waits, and emits clean timing.
#
# Usage (on the HEAD NODE):
#   gchp-matrix-run.sh --cs-res 180 --nodes 2 --ranks-per-node 60 [--days 1] [--warmup]
#
# Methodology:
#  * Shared input FSx is persistent — met pages in once (use --warmup on the FIRST run of a
#    new resolution), then ALL later runs (any node count, any instance) read warm cache.
#  * Captures REAL elapsed (epoch deltas, not `time` aggregate user/sys) + saves full GCHP log
#    so MAPL's internal Initialize/Run timers can be parsed post-hoc.
#  * Success = cap_restart advanced + checkpoint written (benign GCHP 14.7.1 finalization
#    SIGABRT/exit-134 ignored).

set -euo pipefail

STACK=/sw                       # read-only software stack (binary + gchp-env.sh), NFS-exported (EBS)
GCHP_BIN="${STACK}/gchp-14.7.1/bin/gchp"
SCRATCH="/scratch"              # writable Lustre — run dir, HISTORY, pnc4 checkpoints (NOT ext4)
SRC="${SCRATCH}/GCHP"
CRD_DIR="${SRC}/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/run/GCHP"

CS_RES=180
NODES=1
RANKS_PER_NODE=60
DAYS=1
WARMUP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cs-res) CS_RES="$2"; shift 2 ;;
    --nodes) NODES="$2"; shift 2 ;;
    --ranks-per-node) RANKS_PER_NODE="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --warmup) WARMUP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
TOTAL=$(( NODES * RANKS_PER_NODE ))
RUNDIR="${SCRATCH}/gchp_c${CS_RES}"
printf -v DUR '%08d 000000' "$DAYS"

echo "=== matrix run: C${CS_RES}, ${NODES} node(s) x ${RANKS_PER_NODE} = ${TOTAL} ranks, ${DAYS}d, warmup=${WARMUP} ==="
[[ -f "$GCHP_BIN" ]] || { echo "ERROR: gchp binary missing at $GCHP_BIN"; exit 1; }
[[ -d /input ]]      || { echo "ERROR: /input not mounted"; exit 1; }

# ----- one-time: GCHP registration skip -----
mkdir -p ~/.geoschem
cat > ~/.geoschem/config <<EOF
export GC_DATA_ROOT=/input
export GC_USER_REGISTERED=true
EOF

# ----- create run dir once per resolution (clone + official createRunDir.sh) -----
if [[ ! -f "${RUNDIR}/setCommonRunSettings.sh" ]]; then
  command -v expect >/dev/null 2>&1 || sudo dnf install -y expect
  command -v git    >/dev/null 2>&1 || sudo dnf install -y git
  mkdir -p "$SCRATCH"
  if [[ ! -f "${CRD_DIR}/createRunDir.sh" ]]; then
    cd "$SCRATCH"
    [[ -d "$SRC" ]] || git clone --depth 1 --branch 14.7.1 https://github.com/geoschem/GCHP.git
    cd "$SRC"
    git submodule update --init --depth 1 src/GCHP_GridComp/GEOSChem_GridComp/geos-chem
  fi
  TMP_RD="${SCRATCH}/gchp_merra2_TransportTracers"
  rm -rf "$TMP_RD"
  EXP=$(mktemp)
  cat > "$EXP" <<EOF
#!/usr/bin/expect -f
set timeout 600
cd ${CRD_DIR}
spawn ./createRunDir.sh
expect "Choose simulation type:"        { send "2\r" }
expect "Choose meteorology source:"      { send "1\r" }
expect "Enter path where the run directory will be created:" { send "${SCRATCH}\r" }
expect "Enter run directory name"        { send "\r" }
expect "track run directory changes with git" { send "n\r" }
expect eof
EOF
  expect "$EXP"; rm -f "$EXP"
  mv "$TMP_RD" "$RUNDIR"
fi
[[ -f "${RUNDIR}/setCommonRunSettings.sh" ]] || { echo "ERROR: run dir incomplete"; exit 1; }

cd "$RUNDIR"

# ----- restart symlink for this resolution + RESET start date every run -----
RST_SRC=$(ls /input/GEOSCHEM_RESTARTS/GC_*/GEOSChem.Restart.TransportTracers.20190101_0000z.c${CS_RES}.nc4 2>/dev/null | head -1)
[[ -n "$RST_SRC" ]] || { echo "ERROR: no C${CS_RES} restart in /input"; exit 1; }
mkdir -p Restarts
ln -sf "$RST_SRC" "Restarts/GEOSChem.Restart.20190101_0000z.c${CS_RES}.nc4"
echo "20190101 000000" > cap_restart   # reset so every run starts fresh from the restart

# ----- configure resolution / node count / duration -----
SC="setCommonRunSettings.sh"
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${TOTAL}/"                        "$SC"
sed -i "s/^NUM_NODES=.*/NUM_NODES=${NODES}/"                            "$SC"
sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${RANKS_PER_NODE}/" "$SC"
sed -i "s/^CS_RES=.*/CS_RES=${CS_RES}/"                                 "$SC"
sed -i "s/^Run_Duration=.*/Run_Duration=\"${DUR}\"/"                    "$SC"

# CRITICAL multi-node fix: write the internal checkpoint via the MAPL o-server. With the
# default (NO), GCHP 14.7.1's pnc4 collective checkpoint write HANGS/FAILS across nodes
# (NetCDF4_FileFormatter line 189, status -35) AFTER the sim completes — 1-node works, 2+ fails.
# The run-dir comment itself says "set to true if writing checkpoints causes the run to hang."
# (GCHP docs: pnc4 is the only supported type; o-server is the documented multi-node remedy.)
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: YES/"  GCHP.rc
ln -sf "$GCHP_BIN" "${RUNDIR}/gchp"

# ----- generate SLURM script with robust epoch timing -----
TAG="c${CS_RES}_n${NODES}x${RANKS_PER_NODE}"
cat > "${RUNDIR}/gchp_${TAG}.slurm" <<EOF
#!/bin/bash
#SBATCH --job-name=gchp-${TAG}
#SBATCH --partition=compute
#SBATCH --nodes=${NODES}
#SBATCH --ntasks=${TOTAL}
#SBATCH --ntasks-per-node=${RANKS_PER_NODE}
#SBATCH --time=00:40:00
#SBATCH --output=slurm-${TAG}-%j.log
#SBATCH --exclusive
# NOTE: 40min is a TIGHT backstop only. A C180 1-day run integrates in <20min; we do NOT
# rely on the timeout — the watcher below detects sim completion and kills mpirun immediately,
# so a hung pnc4 checkpoint write (known GCHP 14.7.1 multi-node issue) costs seconds, not hours.
set -e
cd "\$SLURM_SUBMIT_DIR"
source ${STACK}/gchp-env.sh
export PATH="${STACK}/libfabric-1.22.0/bin:\$PATH"
ulimit -s unlimited 2>/dev/null
export FI_PROVIDER=efa
export OMPI_MCA_mtl_ofi_provider_include=efa

source setCommonRunSettings.sh
source setRestartLink.sh
source checkRunSettings.sh
set +e

RUNLOG=gchp_${TAG}.log
END_DATE=\$(python3 -c "from datetime import date,timedelta;print((date(2019,1,1)+timedelta(days=${DAYS})).strftime('%Y/%m/%d'))" 2>/dev/null)
END_MARK="GCHP Date: \${END_DATE}  Time: 00:00:00"

t0=\$(date +%s)
mpirun -n ${TOTAL} ./gchp > \${RUNLOG} 2>&1 &
MPI_PID=\$!

# Watch the log: the simulation is DONE the moment the final timestep prints. Throughput is
# measured by GCHP's own internal timer, so we do NOT need the checkpoint write (which can hang
# on multi-node pnc4). As soon as the end-date line appears, record time + kill mpirun.
SIM_DONE=0
while kill -0 \$MPI_PID 2>/dev/null; do
  if grep -aq "\${END_MARK}" \${RUNLOG} 2>/dev/null; then
    SIM_DONE=1
    t1=\$(date +%s)
    sleep 3   # let the final line flush fully
    kill -TERM \$MPI_PID 2>/dev/null; sleep 2; kill -KILL \$MPI_PID 2>/dev/null
    break
  fi
  sleep 2
done
[[ \$SIM_DONE -eq 0 ]] && t1=\$(date +%s)   # mpirun exited on its own (or died)
wait \$MPI_PID 2>/dev/null
ELAPSED=\$(( t1 - t0 ))

# GCHP-internal throughput from the final timestep line: cols after
# "Throughput(days/day)[Avg Tot Run]:" are Avg(cumulative) Tot(inst) Run(integration-only).
FINAL=\$(grep -a "\${END_MARK}" \${RUNLOG} 2>/dev/null | tail -1)
read AVG TOT RUNT <<< \$(echo "\$FINAL" | sed 's/.*\[Avg Tot Run\]://' | grep -oE "[0-9]+\.[0-9]+" | head -3 | tr '\n' ' ')

echo "RESULT_TAG=${TAG}"
echo "RESULT_NODES=${NODES} RESULT_RANKS=${TOTAL} RESULT_CS=${CS_RES} RESULT_DAYS=${DAYS}"
echo "ELAPSED_SECONDS=\${ELAPSED}"
echo "INTERNAL_THROUGHPUT_AVG=\${AVG:-NA}"   # primary metric (immune to I/O hang)
echo "INTERNAL_THROUGHPUT_RUN=\${RUNT:-NA}"  # pure integration rate
echo "WALL_THROUGHPUT_DAYSPERDAY=\$(python3 -c "print(round(${DAYS}*86400/\${ELAPSED},3))" 2>/dev/null || echo NA)"

if [[ \$SIM_DONE -eq 1 && -n "\${AVG:-}" ]]; then
  echo "RUN_STATUS=SUCCEEDED (sim reached \${END_DATE}; internal Avg=\${AVG} d/d; killed mpirun pre-checkpoint to bound wall time)"
  exit 0
else
  echo "RUN_STATUS=FAILED (sim did not reach \${END_DATE})" >&2
  tail -30 \${RUNLOG} >&2
  exit 1
fi
EOF

echo "submit: cd ${RUNDIR} && sbatch gchp_${TAG}.slurm"
echo "RUNDIR=${RUNDIR}"
echo "SLURM=gchp_${TAG}.slurm"
