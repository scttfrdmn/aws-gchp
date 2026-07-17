#!/bin/bash
# gchp-phase4-mn-run.sh — Decoupled-Chemistry Phase 4 M>N runner + gate.
#
# Generalizes gchp-phase1b-run.sh to K workers PER rank (M = RANKS*K > N = RANKS).
# Each rank's NCELL_local cells are split into K contiguous [lo,hi) slices; the K
# co-located workers solve them concurrently on otherwise-idle cores. Extra workers
# attach the SAME per-rank shm segments (zero-copy) -> they cost CORES, not RAM, which
# is the whole point (C180 fullchem is memory-bound at 48 ranks with 144 idle cores).
#
# Two uses:
#   (A) GATE 3 byte-identity at C24: K>1 checkpoint MD5 MUST equal the K=1 / inline
#       baseline (fullchem is per-cell independent -> any contiguous partition is
#       bit-identical, absent a double-failure; nfail2x is reported so it's never silent).
#   (B) speedup demo at C90 fullchem: N ranks, K workers each -> wall-clock chem-tier
#       speedup vs the stock in-process solve.
#
# Usage:
#   gchp-phase4-mn-run.sh <ranks> <workers_per_rank> [cs] [mode]
#     ranks            : 6 or 12 (C24 gate) or e.g. 48 (C90 demo)
#     workers_per_rank : K (>=1). K=1 reduces to the proven 1:1 path.
#     cs               : 24 (default, gate) | 90 (demo)
#     mode             : normal | baseline (remote OFF, in-process solve)
#
# Binaries: /scratch/gchp-instr/GCHP-decoupled/build/bin/{gchp,kpp_worker}
#   (built via CHEM_BACKEND=decoupled BUILD_WORKER=1 build-instrumented-gchp.sh,
#    AFTER the M>N patch is re-staged to s3://.../instr/decoupled-geos-chem.patch).
set -uo pipefail
STACK=/sw
BK=decoupled
SRC=/scratch/gchp-instr/GCHP-$BK
BIN=$SRC/build/bin/gchp
WORKER=$SRC/build/bin/kpp_worker
RUNBASE=/scratch

RANKS=${1:-6}
K=${2:-1}                    # workers per rank (M = RANKS*K)
CS=${3:-24}
MODE=${4:-normal}            # normal | baseline
[[ "$K" =~ ^[0-9]+$ ]] && [ "$K" -ge 1 ] || { echo "FAIL: workers_per_rank K must be >=1"; exit 1; }

# layout: TOTAL_CORES=RANKS must be divisible by 6; keep the proven C24 gate topos.
case "$CS" in
  24) case "$RANKS" in
        6)  NX=1; NY=6  ;;
        12) NX=2; NY=6  ;;
        *)  echo "FAIL: C24 gate uses RANKS in {6,12}"; exit 1 ;;
      esac ;;
  90) # C90 demo: let GCHP auto-layout (AutoUpdate_NXNY=ON) for RANKS (e.g. 48)
      NX=0; NY=0 ;;
  *) echo "FAIL: cs must be 24 (gate) or 90 (demo)"; exit 1 ;;
esac
RPN=$RANKS                   # single node: ranks-per-node == ranks
TOTAL=$RANKS
MTASK=$(( RANKS * K ))       # total worker tasks to co-launch
TAG="c${CS}p4_r${RANKS}_k${K}_${MODE}"
RUNDIR=$RUNBASE/gchp_$TAG

[ -x "$BIN" ]    || { echo "FAIL: no decoupled gchp at $BIN"; exit 1; }
[ -x "$WORKER" ] || { echo "FAIL: no kpp_worker at $WORKER"; exit 1; }

# ---- run dir (createRunDir C<cs> fullchem MERRA-2) ----
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

# ---- settings ----
R=$(ls /input/GEOSCHEM_RESTARTS/GC_*/GEOSChem.Restart.fullchem.20190101_0000z.c${CS}.nc4 2>/dev/null | sort -V | tail -1)
mkdir -p Restarts; ln -sf "$R" Restarts/GEOSChem.Restart.20190101_0000z.c${CS}.nc4
rm -f Restarts/gcchem_internal_checkpoint*
echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$TOTAL/; s/^NUM_NODES=.*/NUM_NODES=1/; s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/; s/^CS_RES=.*/CS_RES=$CS/; s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
if [ "$CS" = "24" ]; then
  # C24 gate: fixed layout, short 10-min (1 chem step), o-server OFF (1 node)
  sed -i "s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/; s/^NX=.*/NX=$NX/; s/^NY=.*/NY=$NY/" setCommonRunSettings.sh
  sed -i 's/^Run_Duration=.*/Run_Duration="00000000 001000"/' setCommonRunSettings.sh
  SHMG=48
else
  # C90 demo: auto-layout, 2 simulated hours (matches the matrix fullchem window)
  sed -i "s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=ON/" setCommonRunSettings.sh
  sed -i 's/^Run_Duration=.*/Run_Duration="00000000 020000"/' setCommonRunSettings.sh
  SHMG=200
fi
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: NO/" GCHP.rc 2>/dev/null || true
grep -q '^overwrite_checkpoint:' GCHP.rc || echo 'overwrite_checkpoint: .true.' >> GCHP.rc
sed -i "s/domains_stack_size = [0-9]*/domains_stack_size = 64000000/" input.nml 2>/dev/null || true
grep -q "MAPL_ENABLE_TIMERS" CAP.rc 2>/dev/null && sed -i "s/^MAPL_ENABLE_TIMERS:.*/MAPL_ENABLE_TIMERS: YES/" CAP.rc || echo "MAPL_ENABLE_TIMERS: YES" >> CAP.rc
ln -sf "$BIN" "$RUNDIR/gchp"

REMOTE=1; [ "$MODE" = "baseline" ] && REMOTE=0

cat > run_$TAG.slurm <<SL
#!/bin/bash
#SBATCH --job-name=$TAG
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=$TOTAL
#SBATCH --ntasks-per-node=$RPN
#SBATCH --cpus-per-task=1
#SBATCH --time=00:40:00
#SBATCH --output=slurm-$TAG-%j.log
#SBATCH --exclusive
cd "\$SLURM_SUBMIT_DIR"
source $STACK/gchp-env.sh
export FI_PROVIDER=efa
ulimit -s unlimited 2>/dev/null
source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh

srun --ntasks-per-node=1 --ntasks=1 sudo mount -o remount,size=${SHMG}G /dev/shm 2>&1 | tail -1

export GCHP_JOBID=\$SLURM_JOB_ID
export GCHP_CHEM_DEADLINE_S=120

DUMPDIR=/scratch/p4_dump_${TAG}
rm -rf "\$DUMPDIR"; mkdir -p "\$DUMPDIR"
export GCHP_DUMP_CHEM=\$DUMPDIR

SRUN_WPID=""
if [ "$REMOTE" = "1" ]; then
  export GCHP_USE_REMOTE_CHEM=1
  export GCHP_CHEM_NWORKERS=$K            # ranks read this -> fan out K slices
  rm -f /dev/shm/gchp_\${GCHP_JOBID}_* /dev/shm/sem.gchp_\${GCHP_JOBID}_* 2>/dev/null
  # Co-launch M = RANKS*K worker tasks. Task t -> rank = t / K, subrank = t mod K.
  # Both ranks and workers key the SAME per-rank stem /gchp_<jobid>_r<rank>; subrank
  # selects the worker's slice slot. --overlap shares the node with the mpirun step.
  echo "=== co-launching $MTASK kpp_worker (=$TOTAL ranks x $K workers) via srun --overlap ==="
  cat > worker_launch.sh <<'WL'
#!/bin/bash
source /sw/gchp-env.sh 2>/dev/null
export GCHP_CHEM_RANK=\$(( SLURM_PROCID / KVAL ))
export GCHP_CHEM_SUBRANK=\$(( SLURM_PROCID % KVAL ))
exec WORKER_BIN_PLACEHOLDER --service
WL
  sed -i "s|KVAL|$K|g; s|WORKER_BIN_PLACEHOLDER|$WORKER|" worker_launch.sh
  chmod +x worker_launch.sh
  # oversubscribe: M worker tasks + N mpirun ranks share \$RANKS physical... no —
  # workers run on the IDLE cores (node has more cores than ranks). --overlap +
  # --ntasks=$MTASK lets Slurm place them; the box has RANKS + up to (cores-RANKS)
  # free cores, which is exactly the M>N idle-core budget.
  srun --overlap --nodes=1 --ntasks=$MTASK --ntasks-per-node=$MTASK \\
       --output=worker_%t.log --export=ALL \\
       ./worker_launch.sh &
  SRUN_WPID=\$!
  sleep 3
else
  echo "=== BASELINE run: remote OFF (in-process Phase-0 solve) ==="
fi

rm -f Restarts/gcchem_internal_checkpoint* 2>/dev/null
echo "=== mpirun -n $TOTAL gchp (REMOTE=$REMOTE K=$K MODE=$MODE) ==="
t0=\$(date +%s)
mpirun -n $TOTAL --mca mtl_ofi_provider_include efa ./gchp > gchp_$TAG.log 2>&1
MPIRC=\$?
t1=\$(date +%s)
echo "RUN_DONE exit=\$MPIRC wall=\$(( t1 - t0 ))s"

if [ -n "\$SRUN_WPID" ]; then
  for i in \$(seq 1 20); do kill -0 \$SRUN_WPID 2>/dev/null || break; sleep 1; done
  kill -9 \$SRUN_WPID 2>/dev/null
  pkill -9 -f "kpp_worker --service" 2>/dev/null
fi

echo "=== RESULT: checkpoint MD5 (PRIMARY gate) ==="
CKPT=Restarts/gcchem_internal_checkpoint
if [ -f "\$CKPT" ] && [ ! -L "\$CKPT" ]; then
  echo "RESULT_P4_CAP tag=$TAG cap_restart=\$(cat cap_restart 2>/dev/null)"
  echo "RESULT_P4_MD5 tag=$TAG k=$K file=gcchem_internal_checkpoint md5=\$(md5sum "\$CKPT" | awk '{print \$1}') bytes=\$(stat -c%s "\$CKPT" 2>/dev/null)"
else
  echo "RESULT_P4_MD5 tag=$TAG k=$K NO_CHECKPOINT_FOUND"
fi
echo "=== RESULT: internal throughput (demo) ==="
grep -a "GCHP Date" gchp_$TAG.log | tail -1
echo "=== RESULT: handoff cost + fan-out ==="
grep -a "PHASE1B HANDOFF" gchp_$TAG.log | head -2
echo "=== RESULT: double-failure count (byte-identity caveat) ==="
grep -ahE "failed twice|cells failed" worker_*.log gchp_$TAG.log 2>/dev/null | head
echo "=== worker exit lines ==="
grep -ahE "exit after|ATTACHED ok|attach FAIL|control seg NEVER|MECHANISM MISMATCH" worker_*.log 2>/dev/null | head -20
echo "RESULT_P4_DONE tag=$TAG k=$K mpirc=\$MPIRC"
SL

JID=$(sbatch --parsable run_$TAG.slurm)
echo "SUBMITTED $TAG job=$JID  (RANKS=$RANKS K=$K M=$MTASK CS=$CS MODE=$MODE REMOTE=$REMOTE)"
echo "When done:  grep -aE 'RESULT_P4_MD5|RUN_DONE|failed twice|RESULT_P4_DONE' $RUNDIR/slurm-$TAG-*.log"
