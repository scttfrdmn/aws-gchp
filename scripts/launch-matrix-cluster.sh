#!/bin/bash
# launch-matrix-cluster.sh — render the matrix template for an instance type and create the cluster.
# Usage: launch-matrix-cluster.sh <instance-type> <cluster-name> [maxcount]
set -euo pipefail
IT="$1"; NAME="$2"; MAX="${3:-4}"
TPL="$(dirname "$0")/../parallelcluster/configs/bench-matrix-use2.template.yaml"
OUT="/tmp/${NAME}.yaml"
sed -e "s/@INSTANCE_TYPE@/${IT}/" -e "s/@MAXCOUNT@/${MAX}/" "$TPL" > "$OUT"
echo "rendered: $OUT (instance=$IT max=$MAX)"
echo "=== dry-run ==="
{ AWS_PROFILE=aws uv run pcluster create-cluster --cluster-name "$NAME" \
  --cluster-configuration "$OUT" --region us-east-2 --dryrun true 2>&1 \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('msg:',d.get('message','?'));[print(' ',m.get('level'),m.get('type')) for m in d.get('validationMessages',d.get('configurationValidationErrors',[]))]" ; } || true
echo "=== create ==="
AWS_PROFILE=aws uv run pcluster create-cluster --cluster-name "$NAME" \
  --cluster-configuration "$OUT" --region us-east-2 2>&1 \
  | python3 -c "import sys,json;d=json.load(sys.stdin);c=d.get('cluster',{});print('status:',c.get('clusterStatus', d.get('message','?')))" || true
