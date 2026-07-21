#!/bin/bash
# gchp-s3c90-derisk-run.sh — C90 off-node de-risk with the REWRITTEN boto3-sidecar transport.
# Purpose: the prior C90 Amdahl sweep (campaign-logs/c90-amdahl-sweep.CORRECTED.txt) found a FLAT
# ~125-128 d/d null "handoff dominates" -- but that used the OLD per-object aws shim. This re-runs
# C90 fullchem off-node with the NEW persistent-boto3 sidecar to see whether the ~600-1000x faster
# handoff lets throughput move, and to measure the real per-superstep handoff cost at C90's ~10x
# larger per-slice state than C24. Single node, CO-LOCATED worker pool (correctness + producer-side
# sidecar throughput is what matters here; off-node scheduling was already proven at C24).
#
# Usage: gchp-s3c90-derisk-run.sh <ranks> <nworkers_per_rank> [mode]  mode=normal|baseline
set -uo pipefail
STACK=/sw; SRC=/scratch/gchp-instr/GCHP-decoupled
BIN=$SRC/build/bin/gchp; WORKER=$SRC/build/bin/kpp_worker; RUNBASE=/scratch
BUCKET=gchp-shared-storage-us-east-1
S3WORKER=~/s3_chem_worker.py
RANKS=${1:-48}; K=${2:-4}; MODE=${3:-normal}
TOTAL=$RANKS; RPN=$RANKS; TAG="c90s3_r${RANKS}_k${K}_${MODE}"; RUNDIR=$RUNBASE/gchp_$TAG
POOL=$(( RANKS * K ))   # co-located worker pool sized to total slices/step
[ -x "$BIN" ] || { echo "FAIL: no decoupled gchp"; exit 1; }
[ -f "$S3WORKER" ] || { echo "FAIL: no s3_chem_worker.py on head"; exit 1; }

# --- run dir (C90 fullchem, AutoUpdate NX/NY ON) ---
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

# --- GMI overlay (fullchem) ---
GMI_OVL=/scratch/gmi_ovl/GMI/v2015-02; mkdir -p "$GMI_OVL"
for f in /input/HEMCO/GMI/v2015-02/gmi.clim.*.nc; do ln -sf "$f" "$GMI_OVL/$(basename "$f")" 2>/dev/null; done
for a in IPMN NPMN RIPA RIPB RIPD; do [ -e "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" ] || aws s3 cp "s3://$BUCKET/gmi-aliases/v2015-02/gmi.clim.$a.geos5.2x25.nc" "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" --region us-east-1 --only-show-errors; done
if [ -L HcoDir ] || [ ! -e HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc ]; then
  rm -f HcoDir; mkdir -p HcoDir/GMI
  for e in /input/HEMCO/*; do [ "$(basename "$e")" = "GMI" ] || ln -sf "$e" "HcoDir/$(basename "$e")"; done
  for v in /input/HEMCO/GMI/*; do bn=$(basename "$v"); if [ "$bn" = "v2015-02" ]; then ln -sf "$GMI_OVL" HcoDir/GMI/v2015-02; else ln -sf "$v" "HcoDir/GMI/$bn"; fi; done
fi

# --- settings: C90 fullchem, 1 sim-hr (kill-at-sim-end reads GCHP-internal Avg; enough supersteps
#     to average the handoff), o-server OFF, 384GB box so /dev/shm 200G + 64M stack ---
R=$(ls /input/GEOSCHEM_RESTARTS/GC_*/GEOSChem.Restart.fullchem.20190101_0000z.c90.nc4 2>/dev/null | sort -V | tail -1)
mkdir -p Restarts; ln -sf "$R" Restarts/GEOSChem.Restart.20190101_0000z.c90.nc4
rm -f Restarts/gcchem_internal_checkpoint*
echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$TOTAL/; s/^NUM_NODES=.*/NUM_NODES=1/; s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/; s/^CS_RES=.*/CS_RES=90/; s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=ON/; s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
sed -i 's/^Run_Duration=.*/Run_Duration="00000000 010000"/' setCommonRunSettings.sh
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: NO/" GCHP.rc 2>/dev/null || true
grep -q '^overwrite_checkpoint:' GCHP.rc || echo 'overwrite_checkpoint: .true.' >> GCHP.rc
sed -i "s/domains_stack_size = [0-9]*/domains_stack_size = 64000000/" input.nml 2>/dev/null || true
ln -sf "$BIN" "$RUNDIR/gchp"

REMOTE=1; [ "$MODE" = "baseline" ] && REMOTE=0

cat > run_$TAG.slurm <<SL
#!/bin/bash
#SBATCH --job-name=$TAG
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=$TOTAL
#SBATCH --ntasks-per-node=$RPN
#SBATCH --time=00:50:00
#SBATCH --output=slurm-$TAG-%j.log
#SBATCH --exclusive
cd "\$SLURM_SUBMIT_DIR"
source $STACK/gchp-env.sh
ulimit -s unlimited 2>/dev/null
source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh
srun --ntasks-per-node=1 --ntasks=1 sudo mount -o remount,size=200G /dev/shm 2>&1 | tail -1

export GCHP_JOBID=\$SLURM_JOB_ID
export GCHP_CHEM_DEADLINE_S=600
DUMPDIR=/scratch/s3c90_dump_${TAG}; rm -rf "\$DUMPDIR"; mkdir -p "\$DUMPDIR"; export GCHP_DUMP_CHEM=\$DUMPDIR

WPOOL_PID=""
if [ "$REMOTE" = "1" ]; then
  export GCHP_USE_REMOTE_CHEM=1
  export GCHP_CHEM_TRANSPORT=s3
  export GCHP_CHEM_NWORKERS=$K
  export GCHP_CHEM_S3_BUCKET=$BUCKET
  export GCHP_CHEM_TMPDIR=/scratch/s3c90_tmp_\${GCHP_JOBID}; mkdir -p \$GCHP_CHEM_TMPDIR
  export GCHP_CHEM_S3_SIDECAR=/scratch/crs3_sidecar.py
  python3 -c "import boto3" 2>/dev/null || (sudo dnf install -y python3-pip >/dev/null 2>&1; sudo python3 -m pip install --quiet boto3 >/dev/null 2>&1)
  echo "sidecar=\$GCHP_CHEM_S3_SIDECAR boto3=\$(python3 -c 'import boto3;print(boto3.__version__)' 2>&1|tail -1)"
  aws s3 rm s3://$BUCKET/chemq/\${GCHP_JOBID}/ --recursive >/dev/null 2>&1
  echo "=== launching CO-LOCATED S3 worker pool ($POOL workers) for jobid \$GCHP_JOBID ==="
  for w in \$(seq 1 $POOL); do
    python3 $S3WORKER --bucket $BUCKET --jobid \$GCHP_JOBID --worker-bin $WORKER --claim-ttl 300 > /scratch/s3c90worker_\${w}.log 2>&1 &
  done
  WPOOL_PID="\$(jobs -p)"
  sleep 2
else
  echo "=== BASELINE: remote OFF (inline in-process solve) ==="
fi

rm -f Restarts/gcchem_internal_checkpoint* 2>/dev/null
echo "=== mpirun -n $TOTAL gchp (REMOTE=$REMOTE TRANSPORT=s3 K=$K POOL=$POOL) ==="
t0=\$(date +%s)
mpirun -n $TOTAL ./gchp > gchp_$TAG.log 2>&1
MPIRC=\$?; t1=\$(date +%s)
echo "RUN_DONE exit=\$MPIRC wall=\$(( t1 - t0 ))s"
[ -n "\$WPOOL_PID" ] && kill \$WPOOL_PID 2>/dev/null; pkill -f s3_chem_worker 2>/dev/null

echo "=== THROUGHPUT (GCHP-internal Avg d/d) ==="
grep -a 'GCHP Date' gchp_$TAG.log 2>/dev/null | tail -1
TP=\$(grep -a 'GCHP Date' gchp_$TAG.log 2>/dev/null | tail -1 | sed 's/.*\[Avg Tot Run\]://' | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "RESULT_C90_THROUGHPUT tag=$TAG mode=$MODE dd=\${TP:-NA}"

echo "=== HANDOFF COST (sidecar vs old per-object shim) ==="
grep -aE '### PHASE1B HANDOFF|CHEMREMOTE handoff' gchp_$TAG.log 2>/dev/null | tail -6

echo "=== checkpoint MD5 (== C90 baseline?) ==="
CKPT=Restarts/gcchem_internal_checkpoint
if [ -f "\$CKPT" ] && [ ! -L "\$CKPT" ]; then
  echo "RESULT_C90_MD5 tag=$TAG k=$K md5=\$(md5sum "\$CKPT" | awk '{print \$1}') bytes=\$(stat -c%s "\$CKPT")"
else echo "RESULT_C90_MD5 tag=$TAG NO_CHECKPOINT"; fi
if ls "\$DUMPDIR"/chemdump_golden_*.bin >/dev/null 2>&1; then
  echo "RESULT_C90_GOLDENSET tag=$TAG md5=\$(md5sum "\$DUMPDIR"/chemdump_golden_*.bin|awk '{print \$1}'|sort|md5sum|awk '{print \$1}')"
fi
echo "=== fallback/error check ==="
grep -acE 'in-process fallback|crs3_.*failed|TIMEOUT' gchp_$TAG.log | xargs echo '  fallback/err lines ='
echo "RESULT_C90_DONE tag=$TAG mpirc=\$MPIRC wall=\$(( t1 - t0 ))s"
SL

JID=$(sbatch --parsable run_$TAG.slurm)
echo "SUBMITTED $TAG job=$JID (RANKS=$RANKS K=$K MODE=$MODE POOL=$POOL TRANSPORT=s3)"
echo "grep: RESULT_C90_THROUGHPUT|RESULT_C90_MD5|PHASE1B HANDOFF $RUNDIR/slurm-$TAG-*.log"
