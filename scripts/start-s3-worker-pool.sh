#!/bin/bash
# start-s3-worker-pool.sh — run on the SEPARATE worker cluster's head. Launches an elastic pool of
# s3_chem_worker.py across the compute node(s), pulling the staged kpp_worker binary + boto3 wheels
# from S3. The pool polls s3://<bucket>/chemq/<jobid>/ for slices — the TRANSPORT cluster (a DIFFERENT
# cluster) PUTs them. No EFA, no co-scheduling, no shared allocation: pure S3 decoupling.
#
# Staging (chemq/bootstrap/ — the worker cluster's IAM is scoped to chemq/* only, NOT phase-c/):
#   s3://<bucket>/chemq/bootstrap/kpp_worker              (staged by the transport build)
#   s3://<bucket>/chemq/bootstrap/s3_chem_worker.py       (the boto3 worker)
#   s3://<bucket>/chemq/bootstrap/boto3-aarch64-py39.tgz  (offline boto3 wheels; no PyPI route)
#
# Usage (on the worker-cluster head):  start-s3-worker-pool.sh <transport_jobid> <nworkers_total>
set -uo pipefail
BUCKET=gchp-shared-storage-us-east-1
JOBID="${1:?need the shared chemq jobid prefix}"
NW="${2:-48}"                        # total worker processes across the pool
WORKER=/scratch/kpp_worker; POOL=/scratch/s3_chem_worker.py

# pull staged artifacts from chemq/bootstrap/ (chemq-scoped IAM can read these)
aws s3 cp s3://$BUCKET/chemq/bootstrap/kpp_worker         $WORKER --region us-east-1 --only-show-errors && chmod +x $WORKER
aws s3 cp s3://$BUCKET/chemq/bootstrap/s3_chem_worker.py  $POOL   --region us-east-1 --only-show-errors
[ -x "$WORKER" ] || { echo "FAIL: no kpp_worker (stage it to chemq/bootstrap/ from the transport build)"; exit 1; }
[ -f "$POOL" ]   || { echo "FAIL: no s3_chem_worker.py in chemq/bootstrap/"; exit 1; }

cat > /scratch/pool_task.sh <<EOF
#!/bin/bash
source /sw/gchp-env.sh 2>/dev/null
# boto3 for the worker (in-process client). Offline install from chemq/bootstrap wheels (no PyPI route).
BOTO3_LIB=/scratch/boto3lib
if ! PYTHONPATH="\$BOTO3_LIB" python3 -c "import boto3" 2>/dev/null; then
  mkdir -p \$BOTO3_LIB /scratch/boto3whl
  aws s3 cp s3://$BUCKET/chemq/bootstrap/boto3-aarch64-py39.tgz /scratch/boto3whl/b.tgz --region us-east-1 --only-show-errors
  tar xzf /scratch/boto3whl/b.tgz -C /scratch/boto3whl 2>/dev/null
  python3 -m pip install --no-index --find-links /scratch/boto3whl --target \$BOTO3_LIB boto3 >/scratch/boto3_offline_\${SLURM_PROCID:-0}.log 2>&1
fi
export PYTHONPATH="\$BOTO3_LIB\${PYTHONPATH:+:\$PYTHONPATH}"
B3=\$(python3 -c 'import boto3;print(boto3.__version__)' 2>&1 | tail -1)
case "\$B3" in [0-9]*) : ;; *) echo "FATAL worker \${SLURM_PROCID:-?}: boto3 unavailable (\$B3)"; exit 3 ;; esac
# each srun task runs ONE worker; the fleet self-balances via the S3 claim lease.
# --idle-exit 45 -> a worker exits ~45s after work drains (so the fleet scales down after the run).
python3 $POOL --bucket $BUCKET --jobid $JOBID --worker-bin $WORKER --claim-ttl 600 --idle-exit 45
EOF
chmod +x /scratch/pool_task.sh

echo "=== launching $NW S3 workers (jobid=$JOBID) across the SEPARATE worker fleet ==="
# spread NW tasks across whatever nodes the 'pool' partition brings up (MaxCount in the config)
srun --partition=pool --ntasks=$NW --output=/scratch/poolw_%t.log /scratch/pool_task.sh &
echo "pool launched (pid $!); logs /scratch/poolw_*.log ; boto3 offline logs /scratch/boto3_offline_*.log"
