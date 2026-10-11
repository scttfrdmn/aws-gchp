#!/bin/bash
# mapl46-x86-run.sh — GCHP#556 / MAPL PR#46 on x86_64, one ephemeral spawn instance (see launch-mapl46-x86.sh).
# Runs as root. Syncs the x86_64 stack to /sw, builds GCHP 14.7.1 three ways from one tree
# (scripts/build-gchp-mapl46.sh: stock, + PR #46, + MPI_Finalize before _exit), then runs the same
# head-node harness (scripts/gchp-mapl46-ab.sh) at 12 ranks with lith over gcgrid, and uploads everything.
# Pre-registered in data/gchp-mapl46/README.txt (addendum MN + X86).
set +e
BUCKET=gchp-shared-storage-us-east-1
BUNDLE=s3://$BUCKET/spawn/bundle-mapl46-x86/
RUNB=s3://$BUCKET/spawn/bundle-c24tt/
DEST=s3://$BUCKET/spawn/results/mapl46-x86-$(date -u +%Y%m%dT%H%M%SZ)/
W=/scratch/gchp-mapl46
LOG=/var/log/mapl46-x86.log
exec > >(tee -a "$LOG") 2>&1
say() { echo "[mapl46-x86 $(date -u +%H:%M:%S)] $*"; }
finish() {
  tar -C /scratch -czf /tmp/mapl46-x86-out.tgz gchp-mapl46/ab gchp-mapl46/ab.log gchp-mapl46/build.log \
      gchp-mapl46/pr46fin.patch gchp-mapl46/cmake.log gchp-mapl46/make-*.log 2>/dev/null
  aws s3 cp /tmp/mapl46-x86-out.tgz "$DEST" --only-show-errors
  aws s3 cp "$LOG" "$DEST" --only-show-errors
  say "uploaded to $DEST"
}
trap finish EXIT

say "instance $(TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'); curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type) $(uname -m) $(nproc) cpus"
dnf install -y -q git fuse3 expat-devel make perl m4 which diffutils >/dev/null || { say "dnf failed"; exit 1; }

mkdir -p /sw "$W" /scratch/lg/idx
aws s3 sync s3://$BUCKET/stacks/x86_64/gchp14.7.1-validated/ /sw/ --only-show-errors || { say "stack sync failed"; exit 1; }
find /sw -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -exec chmod +x {} + 2>/dev/null
chmod +x /sw/*.sh 2>/dev/null; chmod -R +x /sw/gcc-12.2.0/libexec 2>/dev/null
aws s3 sync "$BUNDLE" "$W/" --only-show-errors
aws s3 sync "${RUNB}idx/" /scratch/lg/idx/ --only-show-errors
aws s3 cp "${RUNB}rundir.tgz" /tmp/ --only-show-errors && tar -xzf /tmp/rundir.tgz -C /scratch
install -m 755 "$W/lith" /scratch/lg/lith
say "stack $(du -sh /sw | cut -f1)  lith $(/scratch/lg/lith --version 2>&1 | head -1)  rundir $(ls /scratch/rundir | wc -l) files"

cd "$W" && bash build-gchp-mapl46.sh > build.log 2>&1
grep -E "^\[build\]|FAIL|BUILD_DONE" build.log
grep -q BUILD_DONE build.log || { tail -40 build.log; exit 1; }

export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
cd "$W" && GATES=/scratch/lg LITH=/scratch/lg/lith SRC=/scratch/rundir RD=/scratch/gchp_mapl46_TT \
  ARMS="A B C P" REPS=2 bash gchp-mapl46-ab.sh > ab.log 2>&1
grep -E "CELL|first seen|done" ab.log
