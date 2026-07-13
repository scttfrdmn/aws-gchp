#!/bin/bash
# gchp-phase1b-run.sh — Decoupled-Chemistry Phase 1b live-shm-handoff runner + gate.
#
# Runs C24 fullchem with the chemistry SOLVE handed to co-located kpp_worker
# processes over POSIX shared memory (env GCHP_USE_REMOTE_CHEM=1), then reports
# the restart-file MD5 so it can be compared against the Phase-0 baseline
# (decoupled==inline==mpi). Because the handoff is zero-copy and the worker runs
# the same integrator/flags proven bit-identical in Phase 1a, the checkpoint MUST
# be byte-identical to Phase 0. Also prints the ### PHASE1B HANDOFF line
# (post->done wall per superstep).
#
# Modes:
#   bash gchp-phase1b-run.sh 1      # single-rank identity (core gate)
#   bash gchp-phase1b-run.sh 12     # full 12-rank identity gate
#   bash gchp-phase1b-run.sh 12 kill1  # fallback proof: kill one worker mid-run
#   bash gchp-phase1b-run.sh 1 baseline # build a Phase-0 baseline (remote OFF)
#
# Assumes the decoupled+worker binaries at
#   /scratch/gchp-instr/GCHP-decoupled/build/bin/{gchp,kpp_worker}
# (built via CHEM_BACKEND=decoupled BUILD_WORKER=1 build-instrumented-gchp.sh).
set -uo pipefail
STACK=/sw
BK=decoupled
SRC=/scratch/gchp-instr/GCHP-$BK
BIN=$SRC/build/bin/gchp
WORKER=$SRC/build/bin/kpp_worker
RUNBASE=/scratch

RANKS=${1:-6}
MODE=${2:-normal}          # normal | kill1 | baseline
# GCHP requires TOTAL_CORES divisible by 6 (the 6 cubed-sphere faces), so the
# smallest valid decomposition is 6 ranks (NX=1,NY=6). That is our "small" gate.
case "$RANKS" in
  6)  NX=1; NY=6;  RPN=6  ;;   # smallest valid GCHP layout (isolates the boundary)
  12) NX=2; NY=6;  RPN=12 ;;   # the Phase-1a topology (full identity gate)
  *)  echo "FAIL: pick RANKS in {6,12} (C24; TOTAL_CORES must be divisible by 6)"; exit 1 ;;
esac
TOTAL=$RANKS
TAG="c24p1b_r${RANKS}_${MODE}"
RUNDIR=$RUNBASE/gchp_$TAG

[ -x "$BIN" ]    || { echo "FAIL: no decoupled gchp at $BIN"; exit 1; }
[ -x "$WORKER" ] || { echo "FAIL: no kpp_worker at $WORKER"; exit 1; }

# ---- run dir (createRunDir C24 fullchem MERRA-2), robust expect dispatch ----
if [ ! -f "$RUNDIR/setCommonRunSettings.sh" ]; then
  CRD=$(find "$SRC" -path "*/run/GCHP/createRunDir.sh" 2>/dev/null | head -1)
  mkdir -p ~/.geoschem; printf 'export GC_DATA_ROOT=/input\nexport GC_USER_REGISTERED=true\n' > ~/.geoschem/config
  command -v expect >/dev/null || sudo dnf install -y expect >/dev/null 2>&1
  EXP=$(mktemp); cat > "$EXP" <<XPCT
#!/usr/bin/expect -f
set timeout 900
cd [lindex \$argv 0]
spawn ./createRunDir.sh
expect {
  -re "path for ExtData"                     { send "/input\r"; exp_continue }
  -re "Choose simulation type:"              { send "1\r"; exp_continue }
  -re "additional simulation option"         { send "1\r"; exp_continue }
  -re "Choose meteorology source:"           { send "1\r"; exp_continue }
  -re "Enter path where the run directory"   { send "$RUNBASE\r"; exp_continue }
  -re "Enter run directory name"             { send "gchp_$TAG\r"; exp_continue }
  -re "track run directory changes with git" { send "n\r"; exp_continue }
  -re "build the KPP-Standalone Box Model"   { send "n\r"; exp_continue }
  eof
}
XPCT
  expect "$EXP" "$(dirname "$CRD")" > /tmp/crd_$TAG.log 2>&1; rm -f "$EXP"
  [ -f "$RUNDIR/setCommonRunSettings.sh" ] || { echo "FAIL createRunDir"; tail -20 /tmp/crd_$TAG.log; exit 1; }
fi
cd "$RUNDIR"

# ---- GMI aliases overlay (fullchem needs them; /input read-only) ----
GMI_OVL=/scratch/gmi_ovl/GMI/v2015-02; mkdir -p "$GMI_OVL"
for f in /input/HEMCO/GMI/v2015-02/gmi.clim.*.nc; do ln -sf "$f" "$GMI_OVL/$(basename "$f")" 2>/dev/null; done
for a in IPMN NPMN RIPA RIPB RIPD; do [ -e "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" ] || aws s3 cp "s3://gchp-shared-storage-us-east-1/gmi-aliases/v2015-02/gmi.clim.$a.geos5.2x25.nc" "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" --region us-east-1 --only-show-errors; done
if [ -L HcoDir ] || [ ! -e HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc ]; then
  rm -f HcoDir; mkdir -p HcoDir/GMI
  for e in /input/HEMCO/*; do [ "$(basename "$e")" = "GMI" ] || ln -sf "$e" "HcoDir/$(basename "$e")"; done
  for v in /input/HEMCO/GMI/*; do bn=$(basename "$v"); if [ "$bn" = "v2015-02" ]; then ln -sf "$GMI_OVL" HcoDir/GMI/v2015-02; else ln -sf "$v" "HcoDir/GMI/$bn"; fi; done
fi

# ---- settings: C24 fullchem, SHORT (10 min = 1 chem step), o-server OFF ----
R=/input/GEOSCHEM_RESTARTS/GC_14.7.0/GEOSChem.Restart.fullchem.20190101_0000z.c24.nc4
mkdir -p Restarts; ln -sf "$R" Restarts/GEOSChem.Restart.20190101_0000z.c24.nc4
echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$TOTAL/; s/^NUM_NODES=.*/NUM_NODES=1/; s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/; s/^CS_RES=.*/CS_RES=24/; s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/; s/^NX=.*/NX=$NX/; s/^NY=.*/NY=$NY/; s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
sed -i 's/^Run_Duration=.*/Run_Duration="00000000 001000"/' setCommonRunSettings.sh
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: NO/" GCHP.rc 2>/dev/null || true
sed -i "s/domains_stack_size = [0-9]*/domains_stack_size = 64000000/" input.nml 2>/dev/null || true
ln -sf "$BIN" "$RUNDIR/gchp"

# remote ON unless building a baseline
REMOTE=1; [ "$MODE" = "baseline" ] && REMOTE=0

cat > run_$TAG.slurm <<SL
#!/bin/bash
#SBATCH --job-name=$TAG
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=$TOTAL
#SBATCH --ntasks-per-node=$RPN
#SBATCH --time=00:30:00
#SBATCH --output=slurm-$TAG-%j.log
#SBATCH --exclusive
cd "\$SLURM_SUBMIT_DIR"
source $STACK/gchp-env.sh
export FI_PROVIDER=efa
ulimit -s unlimited 2>/dev/null
source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh

# generous /dev/shm: the 6 shipped buffers per rank are shm-backed at C24.
# RCONST_1D dominates (NREACT*NCELL_TOTAL*8). Give plenty of headroom.
srun --ntasks-per-node=1 --ntasks=1 sudo mount -o remount,size=48G /dev/shm 2>&1 | tail -1

export GCHP_JOBID=\$SLURM_JOB_ID
export GCHP_CHEM_DEADLINE_S=120

WPIDS=()
if [ "$REMOTE" = "1" ]; then
  export GCHP_USE_REMOTE_CHEM=1
  # sweep any stale objects for this job id (should be none)
  rm -f /dev/shm/gchp_\${GCHP_JOBID}_* /dev/shm/sem.gchp_\${GCHP_JOBID}_* 2>/dev/null
  echo "=== co-launching $TOTAL kpp_worker --service processes ==="
  for r in \$(seq 0 \$((TOTAL-1))); do
    GCHP_CHEM_RANK=\$r GCHP_JOBID=\$GCHP_JOBID $WORKER --service > worker_\${r}.log 2>&1 &
    WPIDS+=(\$!)
  done
else
  echo "=== BASELINE run: remote OFF (in-process Phase-0 solve) ==="
fi

# fallback proof: kill one worker ~8s in, while the run is going
if [ "$MODE" = "kill1" ] && [ \${#WPIDS[@]} -gt 0 ]; then
  ( sleep 8; echo "=== [kill1] killing worker rank 0 pid \${WPIDS[0]} ==="; kill -9 \${WPIDS[0]} 2>/dev/null ) &
fi

echo "=== mpirun -n $TOTAL gchp (REMOTE=$REMOTE MODE=$MODE) ==="
mpirun -n $TOTAL --mca mtl_ofi_provider_include efa ./gchp > gchp_$TAG.log 2>&1
MPIRC=\$?
echo "RUN_DONE exit=\$MPIRC"

# reap workers; the sentinel (Chem_Remote_Final) exits them, but guard w/ kill.
if [ \${#WPIDS[@]} -gt 0 ]; then
  for i in \$(seq 1 20); do
    still=0; for p in \${WPIDS[@]}; do kill -0 \$p 2>/dev/null && still=1; done
    [ \$still -eq 0 ] && break; sleep 1
  done
  for p in \${WPIDS[@]}; do kill -9 \$p 2>/dev/null; done
fi

echo "=== RESULT: restart MD5 (compare vs Phase-0 baseline) ==="
CKPT=\$(ls -t Restarts/GEOSChem.Restart.*z.c24.nc4 2>/dev/null | grep -v 20190101_0000z | head -1)
[ -z "\$CKPT" ] && CKPT=\$(ls -t Restarts/*.nc4 2>/dev/null | head -1)
if [ -n "\$CKPT" ]; then
  echo "RESULT_P1B_MD5 tag=$TAG file=\$(basename \$CKPT) md5=\$(md5sum "\$CKPT" | awk '{print \$1}')"
else
  echo "RESULT_P1B_MD5 tag=$TAG NO_CHECKPOINT_FOUND"
fi
echo "=== RESULT: handoff cost ==="
grep -a "PHASE1B HANDOFF" gchp_$TAG.log | head -2
echo "=== RESULT: remote/fallback markers ==="
grep -aE "buffers are SHM-backed|Chem_Remote_Init: rank|worker timeout/err|in-process fallback" gchp_$TAG.log | head -10
echo "=== worker exit lines ==="
grep -aE "exit after|attach OK|attach FAIL" worker_*.log 2>/dev/null | head -20
echo "RESULT_P1B_DONE tag=$TAG mpirc=\$MPIRC"
SL

JID=$(sbatch --parsable run_$TAG.slurm)
echo "SUBMITTED $TAG job=$JID  (RANKS=$RANKS MODE=$MODE REMOTE=$REMOTE)"
echo "When done:  grep -aE 'RESULT_P1B_MD5|PHASE1B HANDOFF|RESULT_P1B_DONE' $RUNDIR/slurm-$TAG-*.log"
echo "Baseline to match: run once with MODE=baseline (remote OFF) OR reuse the Phase-0 C24 md5."
