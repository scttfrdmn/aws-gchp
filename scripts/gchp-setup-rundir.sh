#!/bin/bash
#
# gchp-setup-rundir.sh — one-command GCHP run directory setup on a deployed cluster.
#
# Codifies the verified procedure from docs/RUNNING-GCHP.md: clone GCHP source,
# create an official run directory via createRunDir.sh, configure it for a given
# resolution/duration, and link the prebuilt binary from the mounted stack.
# NO GCHP recompilation.
#
# Usage:
#   ./gchp-setup-rundir.sh [--arch x86_64|aarch64] [--cs-res 24] [--days 1] [--cores 48]
#
# Defaults: arch auto-detected, C24, 1 day, 48 cores (single node), MERRA-2 TransportTracers.
# Run this on the cluster HEAD NODE.

set -euo pipefail

# ----- defaults -----
ARCH=""
CS_RES=24
DAYS=1
CORES=48
GCHP_VERSION="14.7.1"
STACK_VERSION="gchp14.7.1-validated"
SCRATCH="/fsx/scratch"

# ----- parse args -----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)    ARCH="$2"; shift 2 ;;
        --cs-res)  CS_RES="$2"; shift 2 ;;
        --days)    DAYS="$2"; shift 2 ;;
        --cores)   CORES="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ----- detect arch if not given -----
if [[ -z "$ARCH" ]]; then
    case "$(uname -m)" in
        x86_64)        ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) echo "ERROR: cannot detect arch from $(uname -m); pass --arch" >&2; exit 1 ;;
    esac
fi

STACK="/fsx/stacks/${ARCH}/${STACK_VERSION}"
GCHP_BIN="${STACK}/gchp-${GCHP_VERSION}/bin/gchp"
SRC="${SCRATCH}/GCHP"
CRD_DIR="${SRC}/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/run/GCHP"

echo "=== GCHP run dir setup: arch=${ARCH} C${CS_RES} ${DAYS}d ${CORES} cores ==="

# ----- sanity: stack + binary present -----
[[ -d "$STACK" ]]    || { echo "ERROR: stack not found at $STACK" >&2; exit 1; }
[[ -f "$GCHP_BIN" ]] || { echo "ERROR: gchp binary not found at $GCHP_BIN" >&2; exit 1; }
[[ -d /input ]]      || { echo "ERROR: /input (GEOS-Chem data) not mounted" >&2; exit 1; }

# ----- one-time: geoschem config (skip interactive registration) -----
mkdir -p ~/.geoschem
cat > ~/.geoschem/config <<EOF
export GC_DATA_ROOT=/input
export GC_USER_REGISTERED=true
EOF

# ----- ensure tools -----
command -v expect >/dev/null 2>&1 || sudo dnf install -y expect
command -v git    >/dev/null 2>&1 || sudo dnf install -y git

# ----- clone GCHP source + geos-chem submodule (holds createRunDir.sh + templates) -----
mkdir -p "$SCRATCH"
if [[ ! -f "${CRD_DIR}/createRunDir.sh" ]]; then
    echo "--- cloning GCHP ${GCHP_VERSION} source ---"
    cd "$SCRATCH"
    [[ -d "$SRC" ]] || git clone --depth 1 --branch "$GCHP_VERSION" https://github.com/geoschem/GCHP.git
    cd "$SRC"
    git submodule update --init --depth 1 src/GCHP_GridComp/GEOSChem_GridComp/geos-chem
fi
[[ -f "${CRD_DIR}/createRunDir.sh" ]] || { echo "ERROR: createRunDir.sh missing after clone" >&2; exit 1; }

# ----- create run dir via createRunDir.sh (MERRA-2 TransportTracers) -----
# Gotcha 1: must run from the script's own dir (it derives paths via pwd).
# Gotcha 2: GC_USER_REGISTERED above skips the hanging registration prompt.
RUNDIR="${SCRATCH}/gchp_merra2_TransportTracers"
if [[ -d "$RUNDIR" ]]; then
    echo "--- run dir already exists: $RUNDIR (reusing) ---"
else
    echo "--- creating run directory ---"
    EXP=$(mktemp)
    cat > "$EXP" <<EOF
#!/usr/bin/expect -f
set timeout 300
cd ${CRD_DIR}
spawn ./createRunDir.sh
expect "Choose simulation type:"        { send "2\r" }
expect "Choose meteorology source:"      { send "1\r" }
expect "Enter path where the run directory will be created:" { send "${SCRATCH}\r" }
expect "Enter run directory name"        { send "\r" }
expect "track run directory changes with git" { send "n\r" }
expect eof
EOF
    expect "$EXP"
    rm -f "$EXP"
fi
[[ -f "${RUNDIR}/setCommonRunSettings.sh" ]] || { echo "ERROR: run dir incomplete (no setCommonRunSettings.sh)" >&2; exit 1; }

# ----- configure resolution / duration / cores -----
cd "$RUNDIR"
SC="setCommonRunSettings.sh"
# Run_Duration uses a YYYYMMDD HHMMSS span. This helper only sets whole days in the
# DD field, so it's valid for 1-28 days. For longer spans edit Run_Duration by hand
# (e.g. "00000100 000000" = 1 month).
if (( DAYS < 1 || DAYS > 28 )); then
    echo "ERROR: --days must be 1-28 (DD field). For months, edit Run_Duration manually." >&2
    exit 1
fi
printf -v DUR '%08d 000000' "$DAYS"   # YYYYMMDD field; days in the DD position
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${CORES}/"           "$SC"
sed -i "s/^NUM_NODES=.*/NUM_NODES=1/"                      "$SC"
sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${CORES}/" "$SC"
sed -i "s/^CS_RES=.*/CS_RES=${CS_RES}/"                    "$SC"
sed -i "s/^Run_Duration=.*/Run_Duration=\"${DUR}\"/"       "$SC"

# ----- link prebuilt binary (replaces 'make install' — no recompile) -----
ln -sf "$GCHP_BIN" "${RUNDIR}/gchp"

# ----- generate a ready-to-submit SLURM script -----
cat > "${RUNDIR}/gchp.slurm" <<EOF
#!/bin/bash
#SBATCH --job-name=gchp-c${CS_RES}
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=${CORES}
#SBATCH --time=02:00:00
#SBATCH --output=gchp-slurm-%j.log
#SBATCH --exclusive
set -e
cd "\$SLURM_SUBMIT_DIR"
source ${STACK}/gchp-env.sh          # relocatable: sets OPAL_PREFIX/PMIX_PREFIX
ulimit -s unlimited 2>/dev/null
source setCommonRunSettings.sh
source setRestartLink.sh
source checkRunSettings.sh
set +e
start_str=\$(sed 's/ /_/g' cap_restart)
log=gchp.\${start_str:0:13}z.log
time mpirun -n ${CORES} ./gchp 2>&1 | tee \${log}
EOF

echo ""
echo "✅ Run directory ready: ${RUNDIR}"
echo "   Resolution: C${CS_RES}   Duration: ${DAYS} day(s)   Cores: ${CORES}"
echo "   Binary:     ${GCHP_BIN}"
echo ""
echo "Submit with:"
echo "   cd ${RUNDIR} && sbatch gchp.slurm"
echo ""
echo "Verify success after the run:"
echo "   cat cap_restart                              # date should advance"
echo "   ls -lh Restarts/gcchem_internal_checkpoint   # ~55M restart written"
echo "   (a benign double-free SIGABRT at finalization is expected; results are valid)"
