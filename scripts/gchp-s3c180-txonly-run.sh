#!/bin/bash
# gchp-s3c180-txonly-run.sh — C180 off-node with the worker pool on a SEPARATE cluster (no co-located
# workers). This removes the LAST oversubscription: on the co-located runs, 48 ranks + 48 workers filled
# the node (NIC-starved on m9g, CPU-starved on r8gn). Here the transport node runs ONLY the 48 ranks;
# chemistry is served by a separate c7g worker fleet pulling from chemq/<JOBID>/. Uses a FIXED jobid
# shared with the worker cluster (start-s3-worker-pool.sh JOBID).
#
# Transport node still needs boto3 (the rank-side crs3 sidecar PUTs/GETs) -> offline install kept.
# Usage: gchp-s3c180-txonly-run.sh <ranks> <mode> <fixed_jobid> [dur]
#   mode=normal|baseline    (baseline = inline on-node reference, no S3, jobid ignored)
set -uo pipefail
STACK=/sw; SRC=/scratch/gchp-instr/GCHP-decoupled
BIN=$SRC/build/bin/gchp; RUNBASE=/scratch
BUCKET=gchp-shared-storage-us-east-1
RANKS=${1:-48}; MODE=${2:-normal}; JOBID=${3:?need a fixed jobid shared with the worker cluster}; DUR=${4:-00000000 002000}
TOTAL=$RANKS; RPN=$RANKS; TAG="c180tx_r${RANKS}_${MODE}_j${JOBID}"; RUNDIR=$RUNBASE/gchp_$TAG
[ -x "$BIN" ] || { echo "FAIL: no decoupled gchp"; exit 1; }

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

R=$(ls /input/GEOSCHEM_RESTARTS/GC_*/GEOSChem.Restart.fullchem.20190101_0000z.c180.nc4 2>/dev/null | sort -V | tail -1)
[ -n "$R" ] || { echo "FAIL: no C180 fullchem restart in /input"; exit 1; }
mkdir -p Restarts; ln -sf "$R" Restarts/GEOSChem.Restart.20190101_0000z.c180.nc4
rm -f Restarts/gcchem_internal_checkpoint*
echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$TOTAL/; s/^NUM_NODES=.*/NUM_NODES=1/; s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/; s/^CS_RES=.*/CS_RES=180/; s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=ON/; s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
sed -i "s/^Run_Duration=.*/Run_Duration=\"$DUR\"/" setCommonRunSettings.sh
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
#SBATCH --time=01:30:00
#SBATCH --output=slurm-$TAG-%j.log
#SBATCH --exclusive
cd "\$SLURM_SUBMIT_DIR"
source $STACK/gchp-env.sh
ulimit -s unlimited 2>/dev/null
source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh
srun --ntasks-per-node=1 --ntasks=1 sudo mount -o remount,size=550G /dev/shm 2>&1 | tail -1

# FIXED jobid shared with the SEPARATE worker cluster (NOT SLURM_JOB_ID)
export GCHP_JOBID=$JOBID
export GCHP_CHEM_DEADLINE_S=900
DUMPDIR=/scratch/s3c180tx_dump_${TAG}
if [ "\${GCHP_C180_DUMP:-0}" = "1" ]; then rm -rf "\$DUMPDIR"; mkdir -p "\$DUMPDIR"; export GCHP_DUMP_CHEM=\$DUMPDIR; echo "GCHP_DUMP_CHEM ON (debug)"; fi

if [ "$REMOTE" = "1" ]; then
  export GCHP_USE_REMOTE_CHEM=1
  export GCHP_CHEM_TRANSPORT=s3
  export GCHP_CHEM_NWORKERS=1
  export GCHP_CHEM_S3_BUCKET=$BUCKET
  export GCHP_CHEM_TMPDIR=/scratch/s3c180tx_tmp_$JOBID; mkdir -p \$GCHP_CHEM_TMPDIR
  export GCHP_CHEM_S3_SIDECAR=/scratch/crs3_sidecar.py
  # boto3 for the RANK-side sidecar (transport node still PUTs/GETs). Offline install (no PyPI route).
  BOTO3_LIB=/scratch/boto3lib
  if ! PYTHONPATH="\$BOTO3_LIB" python3 -c "import boto3" 2>/dev/null; then
    mkdir -p \$BOTO3_LIB /scratch/boto3whl
    aws s3 cp s3://$BUCKET/chemq/bootstrap/boto3-aarch64-py39.tgz /scratch/boto3whl/b.tgz --region us-east-1 --only-show-errors
    tar xzf /scratch/boto3whl/b.tgz -C /scratch/boto3whl
    python3 -m pip install --no-index --find-links /scratch/boto3whl --target \$BOTO3_LIB boto3 >/scratch/boto3_offline_install.log 2>&1
  fi
  export PYTHONPATH="\$BOTO3_LIB\${PYTHONPATH:+:\$PYTHONPATH}"
  B3=\$(python3 -c 'import boto3;print(boto3.__version__)' 2>&1 | tail -1)
  echo "sidecar=\$GCHP_CHEM_S3_SIDECAR boto3=\$B3 (TRANSPORT-ONLY; workers on SEPARATE cluster, jobid=$JOBID)"
  case "\$B3" in [0-9]*) : ;; *) echo "FATAL: boto3 unavailable -> sidecar dies. Aborting."; exit 3 ;; esac
  # sweep stale keys for this fixed jobid so a re-run starts clean
  aws s3 rm s3://$BUCKET/chemq/$JOBID/ --recursive >/dev/null 2>&1
  echo "=== NO local pool. Chemistry served by the SEPARATE worker cluster via chemq/$JOBID ==="
else
  echo "=== BASELINE: remote OFF (inline in-process solve) ==="
fi

rm -f Restarts/gcchem_internal_checkpoint* 2>/dev/null
echo "=== mpirun -n $TOTAL gchp (REMOTE=$REMOTE TRANSPORT=s3 TX-ONLY jobid=$JOBID) ==="
t0=\$(date +%s)
mpirun -n $TOTAL \${PYTHONPATH:+-x PYTHONPATH} ./gchp > gchp_$TAG.log 2>&1
MPIRC=\$?; t1=\$(date +%s)
echo "RUN_DONE exit=\$MPIRC wall=\$(( t1 - t0 ))s"

echo "=== THROUGHPUT (GCHP-internal RUN d/d) ==="
grep -a 'GCHP Date' gchp_$TAG.log 2>/dev/null | tail -2
TP=\$(grep -a 'GCHP Date' gchp_$TAG.log 2>/dev/null | tail -1 | sed 's/.*\[Avg Tot Run\]://' | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "RESULT_C180TX_THROUGHPUT tag=$TAG mode=$MODE dd=\${TP:-NA}"
echo "=== checkpoint MD5 (== baseline 9ea1a39d?) ==="
CKPT=Restarts/gcchem_internal_checkpoint
if [ -f "\$CKPT" ] && [ ! -L "\$CKPT" ]; then
  echo "RESULT_C180TX_MD5 tag=$TAG md5=\$(md5sum "\$CKPT" | awk '{print \$1}') bytes=\$(stat -c%s "\$CKPT")"
else echo "RESULT_C180TX_MD5 tag=$TAG NO_CHECKPOINT"; fi
echo "=== fallback/error check ==="
grep -acE 'in-process fallback|crs3_.*failed|TIMEOUT' gchp_$TAG.log | xargs echo '  fallback/err lines ='
echo "RESULT_C180TX_DONE tag=$TAG mpirc=\$MPIRC wall=\$(( t1 - t0 ))s"
SL

JID=$(sbatch --parsable run_$TAG.slurm)
echo "SUBMITTED $TAG slurm=$JID jobid=$JOBID (mode=$MODE). START WORKERS: start-s3-worker-pool.sh $JOBID 48"
