#!/bin/bash
# gchp-s3demo-run.sh — Phase C2 DEMO: transport-only GCHP run whose chemistry is served by a
# SEPARATE worker cluster (no co-located pool). Uses a FIXED jobid so both clusters agree on the
# chemq/<jobid>/ prefix. Run on the TRANSPORT cluster head; start the pool on the worker cluster
# with the SAME jobid (start-s3-worker-pool.sh <jobid> <nworkers>).
#
# Usage: gchp-s3demo-run.sh <ranks> <nworkers_per_rank> <cs> <fixed_jobid>
set -uo pipefail
STACK=/sw; SRC=/scratch/gchp-instr/GCHP-decoupled
BIN=$SRC/build/bin/gchp; RUNBASE=/scratch; BUCKET=gchp-shared-storage-us-east-1
RANKS=${1:-6}; K=${2:-2}; CS=${3:-24}; JOBID=${4:?need a fixed jobid shared with the worker cluster}
BASELINE=${GCHP_BASELINE:-0}   # 1 = inline on-node reference (no S3); baked into the SLURM script below
case "$CS" in 24) case "$RANKS" in 6) NX=1;NY=6;; 12) NX=2;NY=6;; *) echo "C24 RANKS 6|12";exit 1;;esac; DUR='00000000 001000'; SHMG=48;;
              90)  NX=0;NY=0; DUR='00000000 020000'; SHMG=200;;
              180) NX=0;NY=0; DUR='00000000 020000'; SHMG=550;;   # C180 fullchem: 550G /dev/shm (proven Phase-3)
              *) echo "cs 24|90|180";exit 1;; esac
TOTAL=$RANKS; RPN=$RANKS; TAG="c${CS}demo_r${RANKS}_k${K}_j${JOBID}"; RUNDIR=$RUNBASE/gchp_$TAG
[ -x "$BIN" ] || { echo "FAIL: no gchp"; exit 1; }

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
  [ -f "$RUNDIR/setCommonRunSettings.sh" ] || { echo "FAIL createRunDir"; exit 1; }
fi
cd "$RUNDIR"
GMI_OVL=/scratch/gmi_ovl/GMI/v2015-02; mkdir -p "$GMI_OVL"
for f in /input/HEMCO/GMI/v2015-02/gmi.clim.*.nc; do ln -sf "$f" "$GMI_OVL/$(basename "$f")" 2>/dev/null; done
for a in IPMN NPMN RIPA RIPB RIPD; do [ -e "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" ] || aws s3 cp "s3://$BUCKET/gmi-aliases/v2015-02/gmi.clim.$a.geos5.2x25.nc" "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" --region us-east-1 --only-show-errors; done
if [ -L HcoDir ] || [ ! -e HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc ]; then
  rm -f HcoDir; mkdir -p HcoDir/GMI
  for e in /input/HEMCO/*; do [ "$(basename "$e")" = "GMI" ] || ln -sf "$e" "HcoDir/$(basename "$e")"; done
  for v in /input/HEMCO/GMI/*; do bn=$(basename "$v"); if [ "$bn" = "v2015-02" ]; then ln -sf "$GMI_OVL" HcoDir/GMI/v2015-02; else ln -sf "$v" "HcoDir/GMI/$bn"; fi; done
fi
R=$(ls /input/GEOSCHEM_RESTARTS/GC_*/GEOSChem.Restart.fullchem.20190101_0000z.c${CS}.nc4 2>/dev/null | sort -V | tail -1)
mkdir -p Restarts; ln -sf "$R" Restarts/GEOSChem.Restart.20190101_0000z.c${CS}.nc4
rm -f Restarts/gcchem_internal_checkpoint*; echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$TOTAL/; s/^NUM_NODES=.*/NUM_NODES=1/; s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/; s/^CS_RES=.*/CS_RES=$CS/; s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
[ "$CS" = 24 ] && sed -i "s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/; s/^NX=.*/NX=$NX/; s/^NY=.*/NY=$NY/" setCommonRunSettings.sh || sed -i "s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=ON/" setCommonRunSettings.sh
sed -i "s/^Run_Duration=.*/Run_Duration=\"$DUR\"/" setCommonRunSettings.sh
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: NO/" GCHP.rc 2>/dev/null || true
grep -q '^overwrite_checkpoint:' GCHP.rc || echo 'overwrite_checkpoint: .true.' >> GCHP.rc
sed -i "s/domains_stack_size = [0-9]*/domains_stack_size = 64000000/" input.nml 2>/dev/null || true
ln -sf "$BIN" "$RUNDIR/gchp"

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
cd "\$SLURM_SUBMIT_DIR"; source $STACK/gchp-env.sh; ulimit -s unlimited 2>/dev/null
source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh
srun --ntasks-per-node=1 --ntasks=1 sudo mount -o remount,size=${SHMG}G /dev/shm 2>&1 | tail -1
# FIXED jobid (shared with the worker cluster) -- NOT SLURM_JOB_ID
export GCHP_JOBID=$JOBID
# GCHP_BASELINE=1 (from the caller's env) -> INLINE on-node solve (the sweep's reference point):
# leave GCHP_USE_REMOTE_CHEM unset so fullchem runs its in-process loop. Otherwise -> S3 off-node.
if [ "$BASELINE" != "1" ]; then
  export GCHP_USE_REMOTE_CHEM=1 GCHP_CHEM_TRANSPORT=s3 GCHP_CHEM_NWORKERS=$K
  export GCHP_CHEM_S3_BUCKET=$BUCKET GCHP_CHEM_DEADLINE_S=600
  export GCHP_CHEM_TMPDIR=/scratch/s3demo_tmp_$JOBID; mkdir -p \$GCHP_CHEM_TMPDIR
  # PERSISTENT boto3 SIDECAR (the throughput fix): each rank spawns crs3_sidecar.py once ->
  # no per-object aws fork. Ensure boto3 + the script are present on this compute node.
  export GCHP_CHEM_S3_SIDECAR=/scratch/crs3_sidecar.py
  srun --ntasks-per-node=1 --ntasks=\$SLURM_NNODES bash -c 'python3 -c "import boto3" 2>/dev/null || (sudo dnf install -y python3-pip >/dev/null 2>&1; sudo python3 -m pip install --quiet boto3 >/dev/null 2>&1)'
  echo "sidecar=\$GCHP_CHEM_S3_SIDECAR boto3=\$(python3 -c 'import boto3;print(boto3.__version__)' 2>&1 | tail -1)"
else
  echo "=== ON-NODE BASELINE: GCHP_USE_REMOTE_CHEM unset -> inline solve ==="
fi
DUMPDIR=/scratch/s3demo_dump_$JOBID; rm -rf "\$DUMPDIR"; mkdir -p "\$DUMPDIR"; export GCHP_DUMP_CHEM=\$DUMPDIR
# NOTE: NO local worker pool here -- chemistry is served by the SEPARATE worker cluster.
echo "=== transport run: chemistry served by SEPARATE cluster via chemq/$JOBID (no local pool) ==="
t0=\$(date +%s); mpirun -n $TOTAL ./gchp > gchp_$TAG.log 2>&1; MPIRC=\$?; t1=\$(date +%s)
echo "RUN_DONE exit=\$MPIRC wall=\$(( t1-t0 ))s"
CKPT=Restarts/gcchem_internal_checkpoint
[ -f "\$CKPT" ] && [ ! -L "\$CKPT" ] && echo "RESULT_DEMO_MD5 tag=$TAG md5=\$(md5sum "\$CKPT"|awk '{print \$1}') bytes=\$(stat -c%s "\$CKPT")" || echo "RESULT_DEMO_MD5 tag=$TAG NO_CHECKPOINT"
if ls "\$DUMPDIR"/chemdump_golden_*.bin >/dev/null 2>&1; then
  echo "RESULT_DEMO_GOLDENSET tag=$TAG md5=\$(md5sum "\$DUMPDIR"/chemdump_golden_*.bin|awk '{print \$1}'|sort|md5sum|awk '{print \$1}')"
fi
echo "=== fallback/error check ==="; grep -acE 'in-process fallback|crs3_.*failed|TIMEOUT' gchp_$TAG.log | xargs echo '  fallback/err lines ='
echo "RESULT_DEMO_DONE tag=$TAG mpirc=\$MPIRC wall=\$(( t1-t0 ))s"
SL
JID=$(sbatch --parsable run_$TAG.slurm)
echo "SUBMITTED $TAG job=$JID jobid=$JOBID (START THE WORKER POOL NOW: start-s3-worker-pool.sh $JOBID <nworkers>)"
