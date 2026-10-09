#!/bin/bash
# launch-spawn-plumb.sh — 2x c7g.large spawn --mpi plumbing check (no EFA). Estimate unless --go.
# spawn creates/repairs SG spawn-mpi-$NAME itself (0.118.0, #681) — deliberately NOT pre-created here.
set -euo pipefail
NAME=${NAME:-gchp-spawn-plumb}
BUCKET=gchp-shared-storage-us-east-1
SCRIPT=s3://$BUCKET/spawn/spawn-plumb-run.sh
RESULTS=s3://$BUCKET/spawn/results/
export AWS_PROFILE=${AWS_PROFILE:-aws}
CMD="sudo RESULTS=$RESULTS bash -c 'aws s3 cp $SCRIPT /tmp/spawn-plumb-run.sh --only-show-errors && bash /tmp/spawn-plumb-run.sh'"
ARGS=(launch "$NAME" --instance-type c7g.large --region us-east-1
      --count 2 --job-array-name "$NAME" --mpi --mpi-processes-per-node 1
      --s3-read $BUCKET --s3-write $BUCKET --ttl 30m --on-complete terminate
      --key-name aws-gchp --tag Project=GCHP-Benchmark --tag Benchmark=spawn-plumb
      --command "$CMD")
spawn "${ARGS[@]}" --estimate-only
[[ ${1:-} == --go ]] && spawn "${ARGS[@]}" || printf 'dry run; to launch:\n  %s --go\n' "$0"
