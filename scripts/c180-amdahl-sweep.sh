#!/bin/bash
# c180-amdahl-sweep.sh — Phase C2 throughput headline. Runs C90 fullchem on the transport cluster
# and sweeps the SEPARATE worker-fleet size, recording internal throughput (d/d) at each point to
# show where off-node chemistry plateaus vs the on-node 2.23x cap / 3.78x Amdahl ceiling.
# Run from the LOCAL machine (drives both cluster heads). Each point: clean chemq, start the pool at
# size P on the worker cluster, run the transport job, record throughput.
#
# Usage: c180-amdahl-sweep.sh   (edits at top: TXIP/PIP from /tmp, sweep sizes)
set -uo pipefail
KEY=~/.ssh/aws-gchp.pem
TXIP=$(cat /tmp/c180tx-ip.txt); PIP=$(cat /tmp/s3poolc180-ip.txt)
BUCKET=gchp-shared-storage-us-east-1
OUT=campaign-logs/c180-amdahl-sweep.results.txt; : > "$OUT"
sshn(){ ssh -n -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=45 -o ServerAliveInterval=30 ec2-user@"$1" "$2"; }

# C90 transport ranks: N=48 (fits 384GB, leaves cores; off-node fleet is the lever). K slices/rank
# so total slices/step = 48*K; size the pool to those.
RANKS=48; K=4    # 192 slices/step -> sweep pools that can chew them
poll_tx(){ for _ in $(seq 1 60); do q=$(sshn "$TXIP" "squeue -h 2>/dev/null|wc -l"); [[ "$q" == 0 ]] && return; sleep 40; done; }

run_point(){  # $1=label(on-node|P<cores>)  $2=poolsize(0 for on-node baseline)
  local LABEL="$1"; local POOL="$2"; local JOB="c180swp_${LABEL}"   # separate: ${LABEL} in JOB needs LABEL already set (set -u)
  echo "=== SWEEP POINT: $LABEL (pool=$POOL) ==="
  aws s3 rm s3://$BUCKET/chemq/$JOB/ --recursive >/dev/null 2>&1
  if [[ "$POOL" -gt 0 ]]; then
    sshn "$PIP" "pkill -f s3_chem_worker 2>/dev/null; nohup bash ~/start-s3-worker-pool.sh $JOB $POOL > /scratch/pool_$JOB.log 2>&1 & echo pool-up-$POOL"
    sshn "$TXIP" "source /sw/gchp-env.sh 2>/dev/null; bash ~/gchp-s3demo-run.sh $RANKS $K 180 $JOB 2>&1 | grep -aE 'SUBMITTED|FAIL'"
  else
    # on-node baseline: run the C24-gate-style inline (remote OFF) at C90 via the demo runner's baseline path
    sshn "$TXIP" "source /sw/gchp-env.sh 2>/dev/null; GCHP_BASELINE=1 bash ~/gchp-s3demo-run.sh $RANKS $K 180 $JOB 2>&1 | grep -aE 'SUBMITTED|FAIL'"
  fi
  poll_tx
  local RD=/scratch/gchp_c180demo_r${RANKS}_k${K}_j${JOB}
  # capture BOTH Avg (col1, ramp-dragged) and RUN (col3, instantaneous integration rate = the
  # compute-tier metric). C90 sweep mistakenly reported Avg; RUN is what shows a real speedup.
  local TRIPLE=$(sshn "$TXIP" "grep -a 'GCHP Date' $RD/gchp_*.log 2>/dev/null | tail -1 | sed 's/.*\[Avg Tot Run\]://' | grep -oE '[0-9]+\.[0-9]+' | head -3 | tr '\n' ' '")
  local TP_AVG=$(echo "$TRIPLE" | awk '{print $1}'); local TP=$(echo "$TRIPLE" | awk '{print $3}')
  local SIMT=$(sshn "$TXIP" "grep -a 'GCHP Date' $RD/gchp_*.log 2>/dev/null | tail -1 | grep -oE 'Time: [0-9:]+' | head -1")
  local FB=$(sshn "$TXIP" "grep -acE 'fallback|TIMEOUT' \$(ls -t $RD/slurm-*.log|head -1) 2>/dev/null")
  local MD=$(sshn "$TXIP" "grep -aoE 'RESULT_DEMO_MD5.*md5=[a-f0-9]+' \$(ls -t $RD/slurm-*.log|head -1) 2>/dev/null | grep -oE 'md5=[a-f0-9]+'")
  echo "RESULT_SWEEP label=$LABEL pool=$POOL RUN_dd=${TP:-NA} Avg_dd=${TP_AVG:-NA} reached=${SIMT:-?} fallback=${FB:-NA} $MD" | tee -a "$OUT"
  sshn "$PIP" "pkill -f s3_chem_worker 2>/dev/null" >/dev/null 2>&1
}

run_point on-node 0        # inline baseline (the reference)
for P in 96 192 384; do run_point "P${P}" "$P"; done
echo "=== C90 AMDAHL SWEEP DONE ==="; cat "$OUT"
