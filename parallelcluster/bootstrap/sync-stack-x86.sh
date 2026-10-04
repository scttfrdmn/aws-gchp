#!/bin/bash
# Head-node OnNodeConfigured (us-east-1, x86_64): sync validated x86_64 GCHP 14.7.1 stack to /sw.
# Mirror of sync-stack-arm.sh for the AMD/Intel instances (c7a/c8a/c7i/c8i). Upload to
# s3://gchp-shared-storage-us-east-1/bootstrap/sync-stack-x86.sh before launching an x86 cluster.
set -euo pipefail
DEST=/sw
SRC=s3://gchp-shared-storage-us-east-1/stacks/x86_64/gchp14.7.1-validated/
echo "[sync-stack-x86] $(date) syncing $SRC -> $DEST"
mkdir -p "$DEST"
aws s3 sync "$SRC" "$DEST/" --region us-east-1 --only-show-errors
find "$DEST" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -exec chmod +x {} + 2>/dev/null || true
chmod +x "$DEST"/*.sh 2>/dev/null || true
# f951/cc1 exec-bit can drop on S3 sync (known); restore for any in-place recompiles.
chmod -R +x "$DEST"/gcc-12.2.0/libexec 2>/dev/null || true
echo "[sync-stack-x86] done: $(du -sh $DEST 2>/dev/null | cut -f1); gchp=$(ls $DEST/gchp-14.7.1/bin/gchp 2>/dev/null || echo MISSING)"
