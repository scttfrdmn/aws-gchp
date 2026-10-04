#!/bin/bash
# run-m9g-fullchem-cells.sh — drive the Phase-3 m9g fullchem cells on an already-created 1c cluster.
# Like the TT hole-fill but for the full m9g fullchem set (all on ONE cluster). Each cell: generate +
# submit via gchp-matrix-run.sh --mechanism fullchem, poll to completion, harvest the slurm log to
# campaign-logs/. Fullchem cells default to 2 SIMULATED HOURS (driver handles duration + backstop).
#
# Usage: run-m9g-fullchem-cells.sh <cluster-name> "<cells>"
#   cells = semicolon-separated "res:nodes:rpn" (e.g. "24:1:96;180:1:48;180:2:96")
# ssh uses -n throughout (avoid the stdin-drain bug). Poll is generous (fullchem 2h-sim + node spinup).
set -uo pipefail
KEY="$HOME/.ssh/aws-gchp.pem"; REGION=us-east-1
NAME="${1:?need cluster-name}"; CELLS="${2:?need cells 'res:nodes:rpn;...'}"
HERE="$(cd "$(dirname "$0")" && pwd)"; LOGDIR="$HERE/../campaign-logs"; mkdir -p "$LOGDIR"
pcl(){ AWS_PROFILE=aws timeout 90 ~/.local/bin/pcluster "$@" --region "$REGION" 2>/dev/null; }
IP=$(pcl describe-cluster --cluster-name "$NAME" | python3 -c "import sys,json;print(json.load(sys.stdin).get('headNode',{}).get('publicIpAddress',''))")
[[ -n "$IP" ]] || { echo "no head IP for $NAME"; exit 1; }
sshn(){ ssh -n -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=45 -o ServerAliveInterval=15 ec2-user@"$IP" "$@"; }
echo "head=$IP"
scp -i "$KEY" -o StrictHostKeyChecking=no "$HERE/gchp-matrix-run.sh" ec2-user@"$IP":~/ >/dev/null 2>&1 && echo "driver copied"

prev_res=""
IFS=';' read -ra CELL_ARR <<< "$CELLS"
for cell in "${CELL_ARR[@]}"; do
  IFS=':' read -r RES NODES RPN <<< "$cell"
  WARM=""; [[ "$RES" != "$prev_res" ]] && WARM="--warmup"; prev_res="$RES"
  TAG="c${RES}_n${NODES}x${RPN}"
  echo "=== m9g fullchem cell C${RES} ${NODES}N x${RPN} ${WARM} ==="
  OUT=$(sshn "source /sw/gchp-env.sh 2>/dev/null; bash ~/gchp-matrix-run.sh --cs-res $RES --nodes $NODES --ranks-per-node $RPN --mechanism fullchem $WARM 2>&1 | grep -aE 'RUNDIR=|SLURM='")
  RD=$(echo "$OUT" | sed -n 's/^RUNDIR=//p'); SL=$(echo "$OUT" | sed -n 's/^SLURM=//p')
  [[ -n "$RD" && -n "$SL" ]] || { echo "  SETUP FAILED: $OUT"; continue; }
  JID=$(sshn "cd $RD && sbatch --parsable $SL" | tail -1)
  echo "  job=$JID (rundir=$RD)"
  [[ "$JID" =~ ^[0-9]+$ ]] || { echo "  submit failed: $JID"; continue; }
  # poll: node spinup (~5-10min) + fullchem 2-sim-hr window (C180 ~25 wall-min; slower at coarse decomp)
  for _ in $(seq 1 90); do q=$(sshn "squeue -j $JID -h 2>/dev/null | wc -l"); [[ "$q" == "0" ]] && break; sleep 40; done
  LF="$LOGDIR/slurm-${NAME#gchp-}-${TAG}_fc.log"
  sshn "cat $RD/slurm-${TAG}-${JID}.log 2>/dev/null" > "$LF" 2>/dev/null
  [[ -s "$LF" ]] || sshn "cat \$(ls -t $RD/slurm-${TAG}-*.log 2>/dev/null | head -1)" > "$LF" 2>/dev/null
  if [[ -s "$LF" ]]; then grep -aE "RESULT_|RUN_STATUS|INTERNAL_THROUGHPUT" "$LF" | sed 's/^/    /'; else echo "    WARNING: empty log for $TAG job $JID"; fi
  echo "  saved -> $LF"
done
echo "=== m9g fullchem cells done for $NAME ==="
