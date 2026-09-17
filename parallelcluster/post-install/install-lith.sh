#!/bin/bash
# Install lith v1.1.0 (aarch64) on an Amazon Linux 2023 ParallelCluster node.
#
# WHY THIS VERSION: v1.1.0 is the first release carrying both fixes that came out
# of our gcgrid measurements (scttfrdmn/lith#210) —
#   #213 gap-aware sequential classification  (metadata over-read  -72%/-92%)
#   #229 no broad fetch until the pattern tiles (HDF5 hyperslab 92.5x -> 6.3x)
# Neither is in v1.0.1. Do NOT float this to "latest": the read path is still
# moving under M17, and the campaign has to cite a fixed version per run.
#
# Runs as root via CustomActions/OnNodeConfigured on both head and compute nodes.
# gcgrid is public (RODA), so lith reads it with --no-sign-request and needs no
# credentials; the node IAM role is not used for /input at all.
set -euo pipefail

LITH_VERSION="1.1.0"
LITH_RPM="lith_${LITH_VERSION}_linux_arm64.rpm"
LITH_SHA256="ca11ae1a8da90be12be709425bba0f05abb6571bb229847767158c28eaf941af"
LITH_URL="https://github.com/scttfrdmn/lith/releases/download/v${LITH_VERSION}/${LITH_RPM}"

log() { echo "[install-lith $(date -u +%H:%M:%S)] $*"; }

if command -v lith >/dev/null 2>&1 && lith --version 2>/dev/null | grep -q "${LITH_VERSION}"; then
    log "lith ${LITH_VERSION} already present, skipping"
    exit 0
fi

# FUSE3 is required by the mount path and is not in the base AL2023 AMI.
log "installing fuse3"
dnf install -y fuse3 >/dev/null

log "downloading ${LITH_RPM}"
cd /tmp
curl -fsSL -o "${LITH_RPM}" "${LITH_URL}"

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
log "lith $(lith --version 2>&1 | head -1) installed; mountpoint /input-lith ready"
