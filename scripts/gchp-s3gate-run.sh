#!/bin/bash
# gchp-s3gate-run.sh — Phase C2 S3 byte-identity GATE on a deployed cluster.
# Runs C24 fullchem with GCHP_CHEM_TRANSPORT=s3: ranks PUT slice inputs to S3, an elastic pool of
# s3_chem_worker.py processes (co-located here for the GATE) GET/solve/PUT back, ranks poll+GET.
# Reports checkpoint MD5 -> must equal the Phase-4 baseline dd532a95539327633dddc98ba0a76897.
#
# Usage: gchp-s3gate-run.sh <ranks> <nworkers> [mode]
#   ranks=6|12, nworkers=K slices/rank, mode=normal|baseline
set -uo pipefail
STACK=/sw; SRC=/scratch/gchp-instr/GCHP-decoupled
BIN=$SRC/build/bin/gchp; WORKER=$SRC/build/bin/kpp_worker; RUNBASE=/scratch
BUCKET=gchp-shared-storage-us-east-1
S3WORKER=~/s3_chem_worker.py
RANKS=${1:-6}; K=${2:-2}; MODE=${3:-normal}
case "$RANKS" in 6) NX=1;NY=6;; 12) NX=2;NY=6;; *) echo "RANKS 6|12"; exit 1;; esac
TOTAL=$RANKS; RPN=$RANKS; TAG="c24s3_r${RANKS}_k${K}_${MODE}"; RUNDIR=$RUNBASE/gchp_$TAG
[ -x "$BIN" ] || { echo "FAIL: no decoupled gchp"; exit 1; }
[ -f "$S3WORKER" ] || { echo "FAIL: no s3_chem_worker.py on head"; exit 1; }

# --- run dir (C24 fullchem) ---
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

# --- settings: C24 fullchem, 10-min (1 chem step), o-server OFF ---
R=$(ls /input/GEOSCHEM_RESTARTS/GC_*/GEOSChem.Restart.fullchem.20190101_0000z.c24.nc4 2>/dev/null | sort -V | tail -1)
mkdir -p Restarts; ln -sf "$R" Restarts/GEOSChem.Restart.20190101_0000z.c24.nc4
rm -f Restarts/gcchem_internal_checkpoint*
echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$TOTAL/; s/^NUM_NODES=.*/NUM_NODES=1/; s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/; s/^CS_RES=.*/CS_RES=24/; s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/; s/^NX=.*/NX=$NX/; s/^NY=.*/NY=$NY/; s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
sed -i 's/^Run_Duration=.*/Run_Duration="00000000 001000"/' setCommonRunSettings.sh
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
#SBATCH --time=00:40:00
#SBATCH --output=slurm-$TAG-%j.log
#SBATCH --exclusive
cd "\$SLURM_SUBMIT_DIR"
source $STACK/gchp-env.sh
ulimit -s unlimited 2>/dev/null
source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh
srun --ntasks-per-node=1 --ntasks=1 sudo mount -o remount,size=48G /dev/shm 2>&1 | tail -1

export GCHP_JOBID=\$SLURM_JOB_ID
export GCHP_CHEM_DEADLINE_S=300           # S3 round-trip is ~seconds; generous
DUMPDIR=/scratch/s3g_dump_${TAG}; rm -rf "\$DUMPDIR"; mkdir -p "\$DUMPDIR"; export GCHP_DUMP_CHEM=\$DUMPDIR

WPOOL_PID=""
if [ "$REMOTE" = "1" ]; then
  export GCHP_USE_REMOTE_CHEM=1
  export GCHP_CHEM_TRANSPORT=s3
  export GCHP_CHEM_NWORKERS=$K
  export GCHP_CHEM_S3_BUCKET=$BUCKET
  export GCHP_CHEM_TMPDIR=/scratch/s3g_tmp_\${GCHP_JOBID}; mkdir -p \$GCHP_CHEM_TMPDIR
  # NEW TRANSPORT: persistent boto3 sidecar (re-gate the rewritten chem_remote_s3, not the old
  # per-object aws fallback). Ensure boto3 + the sidecar script are present on this compute node.
  export GCHP_CHEM_S3_SIDECAR=/scratch/crs3_sidecar.py
  python3 -c "import boto3" 2>/dev/null || (sudo dnf install -y python3-pip >/dev/null 2>&1; sudo python3 -m pip install --quiet boto3 >/dev/null 2>&1)
  echo "sidecar=\$GCHP_CHEM_S3_SIDECAR boto3=\$(python3 -c 'import boto3;print(boto3.__version__)' 2>&1|tail -1)"
  # sweep any stale chemq keys for this jobid
  aws s3 rm s3://$BUCKET/chemq/\${GCHP_JOBID}/ --recursive >/dev/null 2>&1
  # ELASTIC WORKER POOL: for the GATE, launch a handful of workers on THIS node (proves the
  # S3 path byte-identical). They GET/solve/PUT independently -- no MPI, no co-scheduling.
  # (In the full demo these run on a SEPARATE cluster; here co-located just to prove correctness.)
  echo "=== launching S3 worker pool (8 workers) for jobid \$GCHP_JOBID ==="
  for w in \$(seq 1 8); do
    python3 $S3WORKER --bucket $BUCKET --jobid \$GCHP_JOBID --worker-bin $WORKER --claim-ttl 300 > /scratch/s3worker_\${w}.log 2>&1 &
  done
  WPOOL_PID="\$(jobs -p)"
  sleep 2
else
  echo "=== BASELINE: remote OFF (in-process solve) ==="
fi

rm -f Restarts/gcchem_internal_checkpoint* 2>/dev/null
echo "=== mpirun -n $TOTAL gchp (REMOTE=$REMOTE TRANSPORT=s3 K=$K) ==="
t0=\$(date +%s)
mpirun -n $TOTAL ./gchp > gchp_$TAG.log 2>&1
MPIRC=\$?; t1=\$(date +%s)
echo "RUN_DONE exit=\$MPIRC wall=\$(( t1 - t0 ))s"
# stop the worker pool
[ -n "\$WPOOL_PID" ] && kill \$WPOOL_PID 2>/dev/null; pkill -f s3_chem_worker 2>/dev/null

echo "=== RESULT: checkpoint MD5 (== baseline dd532a95539327633dddc98ba0a76897 ?) ==="
CKPT=Restarts/gcchem_internal_checkpoint
if [ -f "\$CKPT" ] && [ ! -L "\$CKPT" ]; then
  echo "RESULT_S3_MD5 tag=$TAG k=$K md5=\$(md5sum "\$CKPT" | awk '{print \$1}') bytes=\$(stat -c%s "\$CKPT")"
else echo "RESULT_S3_MD5 tag=$TAG NO_CHECKPOINT"; fi
echo "=== S3 transport markers ==="
grep -aE "Init\[s3\]|transport=|in-process fallback|crs3_|TIMEOUT" gchp_$TAG.log | head -10
echo "=== worker pool activity ==="
grep -ahE "solved|up:" /scratch/s3worker_*.log 2>/dev/null | tail -10
echo "RESULT_S3_DONE tag=$TAG mpirc=\$MPIRC"
SL

JID=$(sbatch --parsable run_$TAG.slurm)
echo "SUBMITTED $TAG job=$JID (RANKS=$RANKS K=$K MODE=$MODE TRANSPORT=s3)"
echo "grep: RESULT_S3_MD5|RUN_DONE $RUNDIR/slurm-$TAG-*.log"
