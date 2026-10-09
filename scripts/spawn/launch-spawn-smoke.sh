#!/bin/bash
# launch-spawn-smoke.sh — 2-node EFA C24 TransportTracers smoke on spawn (no ParallelCluster).
# Prints the launch command and the live cost estimate; launches ONLY with --go.
#
# spawn >= 0.118.0 creates/repairs SG spawn-mpi-$NAME with all-protocol self rules (#681), so no
# pre-created SG is needed. Use a FRESH NAME per launch: the RunInstances ClientToken is derived from
# the job-array name (spawn#691), so reusing one fails IdempotentParameterMismatch.
set -euo pipefail

NAME=${NAME:-gchp-spawn-smoke-$(date -u +%m%d%H%M)}
ITYPE=${ITYPE:-c8g.48xlarge}
NODES=${NODES:-2}
RPN=${RPN:-24}                 # C24 at 48 ranks = the validated single-node layout, split over 2 nodes
TTL=${TTL:-1h}
REGION=us-east-1
BUCKET=gchp-shared-storage-us-east-1
BUNDLE=s3://$BUCKET/spawn/bundle-c24tt/
RESULTS=s3://$BUCKET/spawn/results/
SCRIPT=s3://$BUCKET/spawn/gchp-spawn-run.sh
export AWS_PROFILE=${AWS_PROFILE:-aws}

CMD="sudo BUNDLE=$BUNDLE RESULTS=$RESULTS RPN=$RPN NODES=$NODES bash -c 'aws s3 cp $SCRIPT /tmp/gchp-spawn-run.sh --only-show-errors && bash /tmp/gchp-spawn-run.sh'"
ARGS=(launch "$NAME" --instance-type "$ITYPE" --region $REGION
      --count "$NODES" --job-array-name "$NAME" --mpi --efa --skip-mpi-install
      --mpi-processes-per-node "$RPN" --volume-size 100
      --s3-read $BUCKET --s3-write $BUCKET
      --ttl "$TTL" --on-complete terminate
      --key-name aws-gchp --tag Project=GCHP-Benchmark --tag Benchmark=spawn-smoke
      --command "$CMD")

spawn "${ARGS[@]}" --estimate-only
if [[ ${1:-} == --go ]]; then
  spawn "${ARGS[@]}"
else
  printf 'dry run; to launch:\n  %s --go\n' "$0"
fi
