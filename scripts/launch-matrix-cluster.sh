#!/bin/bash
# launch-matrix-cluster.sh — render a matrix template for an instance type and create the cluster.
#
# Usage:
#   launch-matrix-cluster.sh <instance-type> <cluster-name> [maxcount] \
#       [--region us-east-1] [--template <path>] [--arch aarch64|x86_64]
#
# Defaults preserve the original us-east-2 behavior. For the us-east-1 campaign:
#   launch-matrix-cluster.sh c8g.48xlarge gchp-mtx-c8g 2 \
#       --region us-east-1 --template parallelcluster/configs/bench-matrix-use1.template.yaml --arch aarch64
set -euo pipefail

IT="$1"; NAME="$2"; MAX="${3:-4}"
shift 3 2>/dev/null || true
REGION="us-east-2"
TPL="$(dirname "$0")/../parallelcluster/configs/bench-matrix-use2.template.yaml"
ARCH="x86_64"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --template) TPL="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# arch -> bootstrap script name (the @ARCH_BOOTSTRAP@ placeholder in the use1 template)
case "$ARCH" in
  aarch64) BOOT="sync-stack-arm.sh" ;;
  x86_64)  BOOT="sync-stack-x86.sh" ;;
  *) echo "bad --arch $ARCH (want aarch64|x86_64)" >&2; exit 1 ;;
esac

OUT="/tmp/${NAME}.yaml"
sed -e "s/@INSTANCE_TYPE@/${IT}/" -e "s/@MAXCOUNT@/${MAX}/" -e "s/@ARCH_BOOTSTRAP@/${BOOT}/" "$TPL" > "$OUT"
echo "rendered: $OUT (instance=$IT max=$MAX region=$REGION arch=$ARCH boot=$BOOT)"

echo "=== dry-run ==="
{ AWS_PROFILE=aws uv run pcluster create-cluster --cluster-name "$NAME" \
  --cluster-configuration "$OUT" --region "$REGION" --dryrun true 2>&1 \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('msg:',d.get('message','?'));[print(' ',m.get('level'),m.get('type')) for m in d.get('validationMessages',d.get('configurationValidationErrors',[]))]" ; } || true

echo "=== create ==="
AWS_PROFILE=aws uv run pcluster create-cluster --cluster-name "$NAME" \
  --cluster-configuration "$OUT" --region "$REGION" 2>&1 \
  | python3 -c "import sys,json;d=json.load(sys.stdin);c=d.get('cluster',{});print('status:',c.get('clusterStatus', d.get('message','?')))" || true
