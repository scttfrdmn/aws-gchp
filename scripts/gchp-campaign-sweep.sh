#!/bin/bash
# gchp-campaign-sweep.sh — outer orchestrator for the scaling campaign (runs on the LOCAL machine).
#
# The missing outer loop over gchp-matrix-run.sh. Takes a cell list, and PER INSTANCE:
#   1. launch one us-east-1 cluster (launch-matrix-cluster.sh, arch-aware)
#   2. wait for CREATE_COMPLETE + sync gchp-matrix-run.sh to the head node
#   3. for each (res,nodes,rpn,mech) cell on that instance: submit, poll, scrape RESULT lines
#      into a local log; the FIRST cell of a new resolution gets --warmup (warm the FSx cache)
#   4. tear the cluster down (keep the 3 standing FSx)
# After the sweep, append the collected RESULT logs to benchmarks.json via append_benchmark.py.
#
# Cells file: whitespace/CSV lines "instance res nodes rpn mech" (# comments ok), grouped by instance.
# Cheapest-instance-first ordering is the caller's responsibility (order the file).
#
# Usage:
#   gchp-campaign-sweep.sh --cells cells.txt [--arch-map "m9g:aarch64,c7a:x86_64,..."] [--dry-run]
#
# This does NOT auto-append during the run (keeps cluster time minimal); it saves each cell's
# slurm log to ./campaign-logs/, and prints the append_benchmark.py commands to run afterward.
set -uo pipefail
KEY="$HOME/.ssh/aws-gchp.pem"
REGION=us-east-1
TPL="parallelcluster/configs/bench-matrix-use1.template.yaml"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$HERE/../campaign-logs"; mkdir -p "$LOGDIR"
CELLS=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cells) CELLS="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done
[[ -f "$CELLS" ]] || { echo "need --cells <file>"; exit 1; }

# arch inference from instance-family prefix
arch_of(){ case "$1" in m9g*|c8g*|c8gn*|c7g*|hpc7g*) echo aarch64 ;; *) echo x86_64 ;; esac; }

pcl(){ AWS_PROFILE=aws timeout 90 ~/.local/bin/pcluster "$@" --region "$REGION" 2>/dev/null; }
head_ip(){ pcl describe-cluster --cluster-name "$1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('headNode',{}).get('publicIpAddress',''))" 2>/dev/null; }
cl_status(){ pcl describe-cluster --cluster-name "$1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('clusterStatus',''))" 2>/dev/null; }
ssh_h(){ local ip="$1"; shift; ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=45 -o ServerAliveInterval=15 ec2-user@"$ip" "$@"; }

# distinct instances, in file order
INSTANCES=$(awk '!/^#/ && NF {print $1}' "$CELLS" | awk '!seen[$0]++')

for INST in $INSTANCES; do
  ARCH=$(arch_of "$INST"); NAME="gchp-sw-${INST%%.*}"
  # max nodes needed for this instance across its cells
  MAXN=$(awk -v i="$INST" '!/^#/ && $1==i {print $3}' "$CELLS" | sort -rn | head -1)
  echo "############ INSTANCE $INST (arch=$ARCH, maxnodes=$MAXN, cluster=$NAME) ############"
  if [[ $DRY -eq 1 ]]; then
    echo "[dry-run] would: launch-matrix-cluster.sh $INST $NAME $MAXN --region $REGION --template $TPL --arch $ARCH"
    awk -v i="$INST" '!/^#/ && $1==i {print "  cell:", $0}' "$CELLS"
    continue
  fi
  bash "$HERE/launch-matrix-cluster.sh" "$INST" "$NAME" "$MAXN" --region "$REGION" --template "$TPL" --arch "$ARCH"
  # wait for CREATE_COMPLETE (capacity for the HEAD node is easy; compute scales at submit)
  for _ in $(seq 1 40); do st=$(cl_status "$NAME"); [[ "$st" == CREATE_COMPLETE || "$st" == CREATE_FAILED ]] && break; sleep 40; done
  [[ "$(cl_status "$NAME")" == CREATE_COMPLETE ]] || { echo ">>> $NAME did not create (status=$(cl_status "$NAME")); skipping instance"; continue; }
  IP=$(head_ip "$NAME"); echo "head=$IP"
  scp -i "$KEY" -o StrictHostKeyChecking=no "$HERE/gchp-matrix-run.sh" ec2-user@"$IP":~/ >/dev/null 2>&1

  prev_res=""
  awk -v i="$INST" '!/^#/ && $1==i {print $2, $3, $4, $5}' "$CELLS" | while read -r RES NODES RPN MECH; do
    WARM=""; [[ "$RES" != "$prev_res" ]] && WARM="--warmup"; prev_res="$RES"
    TAG="c${RES}_n${NODES}x${RPN}_${MECH}"
    echo "=== cell $INST $TAG $WARM ==="
    # generate + submit
    OUT=$(ssh_h "$IP" "source /sw/gchp-env.sh 2>/dev/null; bash ~/gchp-matrix-run.sh --cs-res $RES --nodes $NODES --ranks-per-node $RPN --mechanism $MECH $WARM 2>&1 | grep -aE 'RUNDIR=|SLURM='")
    RD=$(echo "$OUT" | sed -n 's/^RUNDIR=//p'); SL=$(echo "$OUT" | sed -n 's/^SLURM=//p')
    [[ -n "$RD" && -n "$SL" ]] || { echo "  cell setup failed: $OUT"; continue; }
    JID=$(ssh_h "$IP" "cd $RD && sbatch --parsable $SL" 2>/dev/null | tail -1)
    echo "  job=$JID"
    [[ "$JID" =~ ^[0-9]+$ ]] || { echo "  submit failed (JID=$JID)"; continue; }
    # poll (compute node powers up on demand; up to ~40 min)
    for _ in $(seq 1 60); do q=$(ssh_h "$IP" "squeue -j $JID -h 2>/dev/null | wc -l"); [[ "$q" == "0" ]] && break; sleep 40; done
    # collect the slurm log locally. The run script names its output slurm-<RUNTAG>-<jobid>.log where
    # RUNTAG = c<RES>_n<NODES>x<RPN> (NO mech suffix — see gchp-matrix-run.sh:150,159). We have the
    # exact JID from sbatch --parsable, so fetch the exact file rather than glob (the old glob added a
    # _tt suffix and stripped the leading c, matching nothing -> empty logs even when the run succeeded).
    RUNTAG="c${RES}_n${NODES}x${RPN}"
    LF="$LOGDIR/slurm-${INST%%.*}-${TAG}.log"
    ssh_h "$IP" "cat $RD/slurm-${RUNTAG}-${JID}.log 2>/dev/null" > "$LF" 2>/dev/null
    [[ -s "$LF" ]] || ssh_h "$IP" "cat \$(ls -t $RD/slurm-${RUNTAG}-*.log 2>/dev/null | head -1) 2>/dev/null" > "$LF" 2>/dev/null
    if [[ -s "$LF" ]]; then grep -aE "RESULT_|RUN_STATUS" "$LF" | sed 's/^/  /' | head; else echo "  WARNING: empty log harvested for $RUNTAG job $JID"; fi
    echo "  saved -> $LF  (append with: python3 -m gchp_aws.append_benchmark --log $LF --instance $INST --mechanism ${MECH/tt/transporttracers})"
  done

  echo ">>> tearing down $NAME"
  pcl delete-cluster --cluster-name "$NAME" >/dev/null 2>&1
done
echo "############ SWEEP DONE. logs in $LOGDIR. Append the good ones to benchmarks.json, then re-run pytest + calculator. ############"
