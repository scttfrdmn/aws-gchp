#!/bin/bash
# gchp-s3c180-run.sh — C180 off-node THROUGHPUT test on m9g.48xl (768GB). The regime where off-node
# decoupling can beat the on-node cap: C180 fullchem chem ~= 74% of wall, so the per-superstep S3
# round-trip latency that capped C90 at 2.0x is amortized over far more chemistry compute. Uses the
# REWRITTEN transport: persistent boto3 sidecar (rank producer) + boto3 in-process worker (consumer).
#
# Co-location constraint (learned at C90): ranks + workers <= cores(192). 48 ranks + K*48 workers.
#   K=1 -> 48 slices/step, 48 workers = 96 procs (roomy). Bigger slices than C90 (C180 ~4x cells).
#
# Memory (proven Phase-3): C180 fullchem needs /dev/shm 550G + domains_stack_size 64M or SIGBUS at
# first KPP. Off-node rank still holds full grid state; decoupled heap buffers add ~O(slice). 768GB fits.
#
# Usage: gchp-s3c180-run.sh <ranks> <nworkers_per_rank> [mode] [dur]
#   mode=normal|baseline   dur="00000000 00MM00" (default 20 min = a couple chem supersteps)
set -uo pipefail
STACK=/sw; SRC=/scratch/gchp-instr/GCHP-decoupled
BIN=$SRC/build/bin/gchp; WORKER=$SRC/build/bin/kpp_worker; RUNBASE=/scratch
BUCKET=gchp-shared-storage-us-east-1
S3WORKER=~/s3_chem_worker.py
RANKS=${1:-48}; K=${2:-1}; MODE=${3:-normal}; DUR=${4:-00000000 002000}
TOTAL=$RANKS; RPN=$RANKS; TAG="c180s3_r${RANKS}_k${K}_${MODE}"; RUNDIR=$RUNBASE/gchp_$TAG
POOL=$(( RANKS * K ))
[ -x "$BIN" ] || { echo "FAIL: no decoupled gchp"; exit 1; }
[ -f "$S3WORKER" ] || { echo "FAIL: no s3_chem_worker.py on head"; exit 1; }
# guard the co-location constraint
if [ "$MODE" != "baseline" ] && [ $(( TOTAL + POOL )) -gt 192 ]; then
  echo "FAIL: ranks($TOTAL)+workers($POOL) > 192 cores -> would oversubscribe (C90 lesson)"; exit 1
fi

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

# --- settings: C180 fullchem, AutoUpdate NX/NY ON, o-server OFF ---
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
# C180 fullchem: 550G /dev/shm (proven Phase-3; SIGBUS at 1st KPP otherwise)
srun --ntasks-per-node=1 --ntasks=1 sudo mount -o remount,size=550G /dev/shm 2>&1 | tail -1

export GCHP_JOBID=\$SLURM_JOB_ID
export GCHP_CHEM_DEADLINE_S=900           # C180 slices are big; generous S3 round-trip budget
# GCHP_DUMP_CHEM (goldenset dump) is OFF at C180: it serialized 124G of per-rank state on top of the
# ~500G grid + decoupled heap buffers -> OOM-killed (exit 137) the first attempt on 768G. Byte-identity
# is already proven at C24+C90 (same kpp_worker binary, per-cell chemistry is resolution-independent);
# at C180 the checkpoint MD5 alone proves it. Set GCHP_DUMP_CHEM externally only for a debug run.
DUMPDIR=/scratch/s3c180_dump_${TAG}
if [ "\${GCHP_C180_DUMP:-0}" = "1" ]; then rm -rf "\$DUMPDIR"; mkdir -p "\$DUMPDIR"; export GCHP_DUMP_CHEM=\$DUMPDIR; echo "GCHP_DUMP_CHEM ON (debug)"; fi

WPOOL_PID=""
if [ "$REMOTE" = "1" ]; then
  export GCHP_USE_REMOTE_CHEM=1
  export GCHP_CHEM_TRANSPORT=s3
  export GCHP_CHEM_NWORKERS=$K
  export GCHP_CHEM_S3_BUCKET=$BUCKET
  export GCHP_CHEM_TMPDIR=/scratch/s3c180_tmp_\${GCHP_JOBID}; mkdir -p \$GCHP_CHEM_TMPDIR
  export GCHP_CHEM_S3_SIDECAR=/scratch/crs3_sidecar.py
  # boto3 on the compute node: this m9g node has NO internet route to PyPI (1c subnet, S3-gateway
  # only), so pip-from-PyPI fails ("Network is unreachable"). Install OFFLINE from a pre-staged wheel
  # bundle in S3 (reachable via the gateway endpoint) into a shared /scratch tree on PYTHONPATH.
  # HARD-VERIFY + ABORT: a missing boto3 => dead workers => ranks block forever (the stuck-run bug).
  BOTO3_LIB=/scratch/boto3lib
  if ! PYTHONPATH="\$BOTO3_LIB" python3 -c "import boto3" 2>/dev/null; then
    mkdir -p \$BOTO3_LIB /scratch/boto3whl
    # NOTE: under chemq/ (not bootstrap/) — the compute-node IAM is scoped to chemq/* only.
    aws s3 cp s3://$BUCKET/chemq/bootstrap/boto3-aarch64-py39.tgz /scratch/boto3whl/b.tgz --region us-east-1 --only-show-errors
    tar xzf /scratch/boto3whl/b.tgz -C /scratch/boto3whl
    python3 -m pip install --no-index --find-links /scratch/boto3whl --target \$BOTO3_LIB boto3 >/scratch/boto3_offline_install.log 2>&1
  fi
  export PYTHONPATH="\$BOTO3_LIB\${PYTHONPATH:+:\$PYTHONPATH}"
  B3=\$(python3 -c 'import boto3;print(boto3.__version__)' 2>&1 | tail -1)
  echo "sidecar=\$GCHP_CHEM_S3_SIDECAR boto3=\$B3 (PYTHONPATH=\$BOTO3_LIB)"
  case "\$B3" in
    [0-9]*) : ;;   # looks like a version -> good
    *) echo "FATAL: boto3 unavailable on compute node (\$B3) -> workers+sidecar would die, ranks block. Aborting."; exit 3 ;;
  esac
  aws s3 rm s3://$BUCKET/chemq/\${GCHP_JOBID}/ --recursive >/dev/null 2>&1
  echo "=== launching CO-LOCATED boto3 worker pool ($POOL workers) for jobid \$GCHP_JOBID ==="
  for w in \$(seq 1 $POOL); do
    python3 $S3WORKER --bucket $BUCKET --jobid \$GCHP_JOBID --worker-bin $WORKER --claim-ttl 600 > /scratch/s3c180worker_\${w}.log 2>&1 &
  done
  WPOOL_PID="\$(jobs -p)"
  sleep 2
else
  echo "=== BASELINE: remote OFF (inline in-process solve) ==="
fi

rm -f Restarts/gcchem_internal_checkpoint* 2>/dev/null
echo "=== mpirun -n $TOTAL gchp (REMOTE=$REMOTE TRANSPORT=s3 K=$K POOL=$POOL) ==="
t0=\$(date +%s)
# -x PYTHONPATH: propagate the offline boto3 tree to every rank so the sidecars they fork can import it.
mpirun -n $TOTAL \${PYTHONPATH:+-x PYTHONPATH} ./gchp > gchp_$TAG.log 2>&1
MPIRC=\$?; t1=\$(date +%s)
echo "RUN_DONE exit=\$MPIRC wall=\$(( t1 - t0 ))s"
[ -n "\$WPOOL_PID" ] && kill \$WPOOL_PID 2>/dev/null; pkill -f s3_chem_worker 2>/dev/null

echo "=== THROUGHPUT (GCHP-internal RUN d/d) ==="
grep -a 'GCHP Date' gchp_$TAG.log 2>/dev/null | tail -2
TP=\$(grep -a 'GCHP Date' gchp_$TAG.log 2>/dev/null | tail -1 | sed 's/.*\[Avg Tot Run\]://' | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "RESULT_C180_THROUGHPUT tag=$TAG mode=$MODE dd=\${TP:-NA}"

echo "=== memory high-water (768GB fit check) ==="
grep -aoE 'Mem Comm:Used' gchp_$TAG.log >/dev/null && grep -a 'GCHP Date' gchp_$TAG.log | tail -1 | grep -oE '[0-9.]+% :  [0-9.]+%'

echo "=== checkpoint MD5 (baseline vs off-node byte-identity) ==="
CKPT=Restarts/gcchem_internal_checkpoint
if [ -f "\$CKPT" ] && [ ! -L "\$CKPT" ]; then
  echo "RESULT_C180_MD5 tag=$TAG k=$K md5=\$(md5sum "\$CKPT" | awk '{print \$1}') bytes=\$(stat -c%s "\$CKPT")"
else echo "RESULT_C180_MD5 tag=$TAG NO_CHECKPOINT"; fi
if ls "\$DUMPDIR"/chemdump_golden_*.bin >/dev/null 2>&1; then
  echo "RESULT_C180_GOLDENSET tag=$TAG md5=\$(md5sum "\$DUMPDIR"/chemdump_golden_*.bin|awk '{print \$1}'|sort|md5sum|awk '{print \$1}')"
fi
echo "=== fallback/error check ==="
grep -acE 'in-process fallback|crs3_.*failed|TIMEOUT' gchp_$TAG.log | xargs echo '  fallback/err lines ='
echo "RESULT_C180_DONE tag=$TAG mpirc=\$MPIRC wall=\$(( t1 - t0 ))s"
SL

JID=$(sbatch --parsable run_$TAG.slurm)
echo "SUBMITTED $TAG job=$JID (RANKS=$RANKS K=$K MODE=$MODE POOL=$POOL TRANSPORT=s3 DUR='$DUR')"
