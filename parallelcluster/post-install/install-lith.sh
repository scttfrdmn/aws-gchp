#!/bin/bash
# Install lith v1.1.1 (aarch64) on an Amazon Linux 2023 ParallelCluster node.
#
# WHY THIS VERSION: the read-path fixes from our gcgrid measurements
# (scttfrdmn/lith#210) landed in v1.1.0 —
#   #213 gap-aware sequential classification  (metadata over-read  -72%/-92%)
#   #229 no broad fetch until the pattern tiles (HDF5 hyperslab 92.5x -> 6.3x)
# and v1.1.1 adds #237, which matters specifically on ParallelCluster: without it
# NIC detection fails on every PC node (DescribeInstanceTypes is denied by the
# node role), parts-max silently clamps to its 4 MiB floor, and `doctor` reports
# that state as healthy. We confirmed the fix on this cluster's hardware.
# Do NOT float this to "latest": the read path is still moving under M17, and the
# campaign has to cite a fixed version per run.
#
# Runs as root via CustomActions/OnNodeConfigured on both head and compute nodes.
# gcgrid is public (RODA), so lith reads it with --no-sign-request and needs no
# credentials; the node IAM role is not used for /input at all.
set -euo pipefail

LITH_VERSION="1.1.1"
LITH_RPM="lith_${LITH_VERSION}_linux_arm64.rpm"
LITH_SHA256="cf9956722fb86d6773eea6142c00e0158870e1690db19330a89f76c58eec5b7f"
# COMPUTE NODES HAVE NO INTERNET EGRESS. They get no public IP, and this VPC has
# no NAT gateway — only an S3 gateway endpoint (which is also why `dnf install
# fuse3` works here while github.com does not). Fetching the release directly
# from GitHub fails on a compute node with
#   curl: (28) Failed to connect to github.com port 443 after 136064 ms
# and, because this script runs under `set -e` as OnNodeConfigured, that failure
# powers the whole instance off ~4 min into bootstrap. So the artifact is
# mirrored into the project bucket and pulled over the S3 endpoint. That is also
# the better provenance story for a benchmark: the rpm is pinned in a bucket we
# control rather than re-fetched from a mutable release page.
# Mirror populated with:
#   curl -fsSL -o $LITH_RPM \
#     https://github.com/scttfrdmn/lith/releases/download/v1.1.1/$LITH_RPM
#   aws s3 cp $LITH_RPM s3://gchp-shared-storage-us-east-1/lith/$LITH_RPM
# sha256 verified against the release checksums.txt before upload and again below.
LITH_S3="s3://gchp-shared-storage-us-east-1/lith/${LITH_RPM}"
LITH_URL="https://github.com/scttfrdmn/lith/releases/download/v${LITH_VERSION}/${LITH_RPM}"

log() { echo "[install-lith $(date -u +%H:%M:%S)] $*"; }

if command -v lith >/dev/null 2>&1 && lith version 2>/dev/null | grep -q "${LITH_VERSION}"; then
    log "lith ${LITH_VERSION} already present, skipping"
    exit 0
fi

# FUSE3 is required by the mount path and is not in the base AL2023 AMI.
log "installing fuse3"
dnf install -y fuse3 >/dev/null

log "downloading ${LITH_RPM}"
cd /tmp
rm -f "${LITH_RPM}"
# S3 mirror first (works on both node roles, no egress needed). GitHub only as a
# fallback for a node that has internet but no bucket access, and with short
# timeouts so a no-egress node fails in seconds instead of stalling bootstrap for
# over two minutes before the instance kills itself.
if aws s3 cp "${LITH_S3}" "${LITH_RPM}" --only-show-errors; then
    log "fetched from S3 mirror"
elif curl -fsSL --connect-timeout 10 --max-time 120 -o "${LITH_RPM}" "${LITH_URL}"; then
    log "fetched from GitHub (S3 mirror unavailable)"
else
    log "FATAL: could not fetch ${LITH_RPM} from ${LITH_S3} or ${LITH_URL}"
    exit 1
fi

# Verify against the checksum published with the release. The release also ships
# a keyless cosign bundle (checksums.txt.bundle) and SLSA provenance; verifying
# those needs cosign on the node, which we deliberately do not install here —
# the pinned sha256 is the gate, and it is recorded in git.
log "verifying sha256"
echo "${LITH_SHA256}  ${LITH_RPM}" | sha256sum -c -

log "installing"
dnf install -y "./${LITH_RPM}" >/dev/null
rm -f "${LITH_RPM}"

# GCHP runs as ec2-user; lith mounts are created by that user, so no
# --allow-other and no /etc/fuse.conf change is needed. Left as a note because
# it is the first thing to reach for if a rank ever gets EACCES on the mount.

install -d -o ec2-user -g ec2-user /input-lith /var/lib/lith
log "lith $(lith version 2>&1 | head -1) installed; mountpoint /input-lith ready"
