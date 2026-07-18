#!/bin/bash
# start-s3-worker-pool.sh — run on the SEPARATE worker cluster's head. Launches an elastic pool of
# s3_chem_worker.py across the compute node(s) via srun, pulling the staged kpp_worker binary.
# The pool polls s3://<bucket>/chemq/<jobid>/ for slices — the transport cluster (a DIFFERENT cluster)
# PUTs them. No EFA, no co-scheduling, no shared allocation: pure S3 decoupling.
#
# Usage (on the worker-cluster head):  start-s3-worker-pool.sh <transport_jobid> <nworkers_total>
set -uo pipefail
BUCKET=gchp-shared-storage-us-east-1
JOBID="${1:?need the transport cluster's GCHP_JOBID (the chemq/<jobid> prefix)}"
NW="${2:-64}"                        # total worker processes across the pool
WORKER=/scratch/kpp_worker; POOL=/scratch/s3_chem_worker.py
# pull staged artifacts (once)
aws s3 cp s3://$BUCKET/phase-c/kpp_worker      $WORKER --region us-east-1 --only-show-errors && chmod +x $WORKER
aws s3 cp s3://$BUCKET/phase-c/s3_chem_worker.py $POOL  --region us-east-1 --only-show-errors
[ -x "$WORKER" ] || { echo "FAIL: no kpp_worker"; exit 1; }

cat > /scratch/pool_task.sh <<EOF
#!/bin/bash
source /sw/gchp-env.sh 2>/dev/null
# each srun task runs ONE worker; the fleet self-balances via the S3 claim lease
python3 $POOL --bucket $BUCKET --jobid $JOBID --worker-bin $WORKER --claim-ttl 300 --idle-exit 30
EOF
chmod +x /scratch/pool_task.sh
echo "=== launching $NW S3 workers (jobid=$JOBID) on the SEPARATE worker cluster ==="
# --idle-exit 30 -> pool self-terminates ~30s after work drains (so the demo cluster scales down)
srun --partition=pool --ntasks=$NW --output=/scratch/poolw_%t.log /scratch/pool_task.sh &
echo "pool launched (pid $!); logs /scratch/poolw_*.log"
