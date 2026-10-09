#!/bin/bash
# spawn-plumb-run.sh — cheap 2-node plumbing check of the spawn 0.118.0 MPI path (no EFA, no GCHP).
# Run as root on every node by `spawn launch --mpi --command ...` (see launch-spawn-plumb.sh).
# Proves: user-data booted (#671), --command waited for MPI setup (#678: hostfile exists on entry),
# root ssh between members (#687), mpirun across the hostfile with spawn's yum OpenMPI.
# Node 0 writes result.txt to $RESULTS; the others exit after a short wait so --on-complete fires.
set -uo pipefail
: "${RESULTS:?}"
LOG=/var/log/spawn-plumb.log; exec > >(tee -a "$LOG") 2>&1
say() { echo "[plumb $(date -u +%H:%M:%S)] $*"; }
ENTRY_HOSTFILE=$([ -s /tmp/mpi-hostfile ] && echo present || echo MISSING)
say "entry: hostfile $ENTRY_HOSTFILE; gates: $(cat /run/spawn/required-gates 2>/dev/null | tr '\n' ' ')"
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
MYIP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
IDX=$(jq -r --arg ip "$MYIP" '.[] | select(.ip == $ip) | .index' /etc/spawn/job-array-peers.json)
say "index $IDX ip $MYIP"
if [[ $IDX -ne 0 ]]; then sleep 240; say "worker done"; exit 0; fi
export PATH=/usr/lib64/openmpi/bin:$PATH LD_LIBRARY_PATH=/usr/lib64/openmpi/lib:${LD_LIBRARY_PATH:-}
SSH=FAIL
for ip in $(awk '{print $1}' /tmp/mpi-hostfile); do
  [[ $ip == "$MYIP" ]] && continue
  for _ in $(seq 1 24); do ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$ip" true && { SSH=OK; break; }; sleep 5; done
done
MPI_OUT=$(timeout 120 mpirun --allow-run-as-root -np 2 --hostfile /tmp/mpi-hostfile --map-by node hostname 2>/tmp/mpirun.err)  # stdout only: ssh known-hosts warnings go to stderr
NDISTINCT=$(echo "$MPI_OUT" | sort -u | grep -vc '^$')
cat > /tmp/result.txt <<R
ENTRY_HOSTFILE=$ENTRY_HOSTFILE
HOSTFILE=$(tr '\n' ';' < /tmp/mpi-hostfile)
SSH_TO_PEER=$SSH
MPIRUN_OUTPUT=$(echo "$MPI_OUT" | tr '\n' ';')
DISTINCT_HOSTS=$NDISTINCT
VERDICT=$([[ $ENTRY_HOSTFILE == present && $SSH == OK && $NDISTINCT -eq 2 ]] && echo PASS || echo FAIL)
R
cat /tmp/result.txt
aws s3 cp /tmp/result.txt "${RESULTS%/}/plumb-$(date -u +%Y%m%dT%H%M%SZ)/result.txt" --only-show-errors
aws s3 cp "$LOG" "${RESULTS%/}/plumb-$(date -u +%Y%m%dT%H%M%SZ)/" --only-show-errors
