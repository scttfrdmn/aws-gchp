#!/bin/bash
# gchp-spawn-run.sh — one multi-node GCHP run on an ephemeral spawn MPI cohort (no ParallelCluster).
#
# Launched on EVERY node by `spawn launch --mpi --efa --command ...` (see launch-spawn-smoke.sh).
# spawn's MPI user-data provides: cluster placement group, private-IP peers file
# (/etc/spawn/job-array-peers.json -> /tmp/mpi-hostfile), root ssh keys. Everything else is here:
#
#   all nodes : wait for spawn MPI + EFA setup, sync the aarch64 stack from S3 to /sw, mount lith
#               over s3://gcgrid at /input-lith (same 5 prefix mounts + indexes as gate-streams-gchp)
#   node 0    : unpack the run dir onto local EBS, NFS-export /scratch, run mpirun over the
#               hostfile, upload results to S3, write /scratch/DONE
#   node > 0  : NFS-mount node 0's /scratch, wait for DONE
#
# Every node then exits, which fires spawn's --on-complete terminate. TTL is the backstop.
#
# WHY these choices (spawn source, 0.116.0 @528e038):
#   * spawn runs --command as the login user, BACKGROUNDED before its MPI/EFA user-data finishes,
#     so we must wait for /tmp/mpi-hostfile and a working EFA provider ourselves.
#   * spawn's keys are root's, and mpirun runs as root; lith is therefore mounted as root (a FUSE
#     mount is invisible to other users, root included, without allow_other).
#   * non-interactive ssh does not read /etc/profile.d, so remote orted gets the stack env from
#     /root/.bashrc.
#   * the default spawn MPI SG is TCP-only and EFA needs all protocols: the SG named
#     spawn-mpi-<job-array-name> must be pre-created with all-traffic self rules (spawn reuses it).
#
# Required env (passed via the --command string):
#   BUNDLE   s3 prefix holding rundir.tgz, idx/*.lithidx, lith (binary)
#   RESULTS  s3 prefix for outputs (one subdir per run)
#   RPN      MPI ranks per node (must equal spawn --mpi-processes-per-node)
# Optional: NODES (default: peer count), DAYS (1), TAG, STACK_S3, MEMC (2GB), NIC (50)
#
# NOT `set -u`: GCHP's setCommonRunSettings.sh dereferences $4, and sourcing it under -u aborts THIS
# shell with "unbound variable" -- no die(), no upload, and spawn's --on-complete terminates the node.
# That is how the first 0.120.0 smoke died (2026-10-05). Every variable here uses ${VAR:-...}.
set -o pipefail

STACK_S3=${STACK_S3:-s3://gchp-shared-storage-us-east-1/stacks/aarch64/gchp14.7.1-validated/}
DAYS=${DAYS:-1}
MEMC=${MEMC:-2GB}
NIC=${NIC:-50}
PEERS=/etc/spawn/job-array-peers.json
HOSTFILE=/tmp/mpi-hostfile
STACK=/sw
SCR=/scratch
RD=$SCR/rundir
LOG=/var/log/gchp-spawn-run.log
exec > >(tee -a "$LOG") 2>&1

say() { echo "[gchp-spawn $(date -u +%H:%M:%S)] $*"; }
# Whatever happens, leave evidence in S3 before the node terminates itself (--on-complete).
EXIT_DEST="${RESULTS%/}/${TAG:-c24tt}-exit-$(hostname -s)-$(date -u +%Y%m%dT%H%M%SZ)/"
upload_on_exit() {
  local rc=$?
  for f in "$LOG" /var/log/spawn-command.log "${RD:-/nonexistent}/setcommon.log" "${RD:-/nonexistent}"/gchp_*.log; do
    [[ -f $f ]] && aws s3 cp "$f" "$EXIT_DEST" --only-show-errors
  done
  echo "rc=$rc" | aws s3 cp - "${EXIT_DEST}exit-code.txt" --only-show-errors
}
trap upload_on_exit EXIT
die() { say "FATAL: $*"; exit 1; }
wait_for() {  # wait_for <seconds> <description> <test command...>
  local t=$1 what=$2; shift 2
  for ((i = 0; i < t; i += 5)); do "$@" >/dev/null 2>&1 && return 0; sleep 5; done
  die "timed out after ${t}s waiting for $what"
}

[[ $EUID -eq 0 ]] || die "run as root (spawn --command \"sudo -E bash ...\")"
: "${BUNDLE:?}" "${RESULTS:?}" "${RPN:?}"
LOG=${LOG:-/var/log/gchp-spawn-run.log}

# ---------- 1. spawn MPI setup ----------
dnf install -y -q fuse3 nfs-utils jq >/dev/null || die "dnf install"
wait_for 900 "spawn peers file + hostfile" test -s "$HOSTFILE"
wait_for 300 "root authorized_keys" test -s /root/.ssh/authorized_keys
MYIP=$(TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'); \
       curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
IDX=$(jq -r --arg ip "$MYIP" '.[] | select(.ip == $ip) | .index' "$PEERS")
NPEERS=$(jq length "$PEERS")
NODES=${NODES:-$NPEERS}
NODE0=$(jq -r '.[] | select(.index == 0) | .ip' "$PEERS")
[[ -n "$IDX" ]] || die "my ip $MYIP not in $PEERS"
[[ $NODES -eq $NPEERS ]] || die "NODES=$NODES but $NPEERS peers"
TOTAL=$((NODES * RPN))
TAG=${TAG:-c24tt_n${NODES}x${RPN}}
say "node index $IDX/$NPEERS ip $MYIP node0 $NODE0 tag $TAG"

# ---------- 2. software stack (same steps as bootstrap/sync-stack-arm.sh) ----------
mkdir -p "$STACK"
aws s3 sync "$STACK_S3" "$STACK/" --only-show-errors || die "stack sync"
find "$STACK" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -exec chmod +x {} + 2>/dev/null
chmod +x "$STACK"/*.sh 2>/dev/null
[[ -x $STACK/gchp-14.7.1/bin/gchp ]] || die "gchp binary missing after sync"
cat > /root/.gchp-env <<EOF
source $STACK/gchp-env.sh
export PATH=$STACK/libfabric-1.22.0/bin:\$PATH
EOF
grep -q gchp-env /root/.bashrc 2>/dev/null || sed -i '1i [ -f /root/.gchp-env ] && source /root/.gchp-env' /root/.bashrc
source /root/.gchp-env
# spawn --efa runs aws-efa-installer in its user-data; our libfabric needs its rdma-core/efa bits.
wait_for 1200 "EFA provider (fi_info -p efa)" fi_info -p efa
say "EFA: $(fi_info -p efa 2>/dev/null | grep -m1 -E 'domain' | xargs)"

# ---------- 3. lith over s3://gcgrid ----------
G=/opt/gchp-bundle
mkdir -p "$G"
aws s3 sync "$BUNDLE" "$G/" --only-show-errors || die "bundle sync"
install -m 755 "$G/lith" /usr/local/bin/lith
port=9210
for spec in "GEOS_0.5x0.625/MERRA2/2019/01 merra2" "GEOS_0.5x0.625/MERRA2/2015/01 merra2-2015" \
            "HEMCO hemco" "CHEM_INPUTS cheminp" "GEOSCHEM_RESTARTS restarts"; do
  set -- $spec
  mkdir -p "/input-lith/$1"
  lith mount "s3://gcgrid/$1" "/input-lith/$1" --index-file "$G/idx/$2.lithidx" --no-sign-request \
      --nic-gbps "$NIC" --mem-cache "$MEMC" --metrics ":$port" --daemon || die "lith mount $1"
  port=$((port + 1))
done
sleep 6
alive=0
for p in 9210 9211 9212 9213 9214; do
  curl -s --max-time 4 "http://localhost:$p/metrics" | grep -q '^lith_' && alive=$((alive + 1))
done
[[ $alive -eq 5 && $(mount | grep -c fuse.lith) -eq 5 ]] || die "lith mounts not healthy ($alive/5 daemons)"
say "lith: 5/5 mounts healthy"

# ---------- 4. shared run dir: node 0 exports its /scratch over NFS ----------
mkdir -p "$SCR"
if [[ $IDX -eq 0 ]]; then
  tar -xzf "$G/rundir.tgz" -C "$SCR" || die "rundir unpack"
  CIDR=$(TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'); \
         MAC=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/mac); \
         curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC/vpc-ipv4-cidr-block")
  mkdir -p /etc/exports.d
  echo "$SCR $CIDR(rw,sync,no_root_squash,no_subtree_check)" > /etc/exports.d/gchp.exports
  systemctl enable --now nfs-server >/dev/null 2>&1 || die "nfs-server"
  exportfs -ra
  touch "$SCR/.ready"
else
  wait_for 1800 "node 0 /scratch export" bash -c "showmount -e $NODE0 | grep -q $SCR"
  mount -t nfs -o vers=4.1,hard "$NODE0:$SCR" "$SCR" || die "nfs mount"
  wait_for 600 "node 0 run dir" test -f "$SCR/.ready"
fi
touch /tmp/gchp-node-ready

# ---------- 5. workers wait; node 0 runs ----------
if [[ $IDX -ne 0 ]]; then
  say "worker ready; waiting for $SCR/DONE"
  # If node 0 dies its hard NFS export hangs every stat here forever (seen 2026-10-05), so probe with
  # timeouts and give up after ~3 min of node 0 being unreachable.
  miss=0
  while ! timeout 10 test -f "$SCR/DONE"; do
    if timeout 5 bash -c "</dev/tcp/$NODE0/22" 2>/dev/null; then miss=0; else miss=$((miss + 1)); fi
    [[ $miss -ge 18 ]] && die "node 0 ($NODE0) unreachable for ~3 min; giving up"
    sleep 10
  done
  say "DONE seen: $(timeout 10 cat "$SCR/DONE")"
  exit 0
fi

for ip in $(awk '{print $1}' "$HOSTFILE"); do
  [[ $ip == "$MYIP" ]] && continue
  wait_for 3600 "peer $ip ready" ssh -o ConnectTimeout=5 -o BatchMode=yes "$ip" test -f /tmp/gchp-node-ready
done
say "all $NODES nodes ready"

cd "$RD" || die "no run dir"
# Same reconfiguration as gchp-matrix-run.sh / gate-streams-gchp prep_rundir: the three rank knobs
# are independent, the start date is reset, and a stale checkpoint makes the pnc4 create fail
# NC_EEXIST at the end of a good run.
SIMSECS=$((DAYS * 86400))
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${TOTAL}/"                  setCommonRunSettings.sh
sed -i "s/^NUM_NODES=.*/NUM_NODES=${NODES}/"                      setCommonRunSettings.sh
sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${RPN}/"      setCommonRunSettings.sh
sed -i "s/^Run_Duration=.*/Run_Duration=\"$(printf '%08d' "$DAYS") 000000\"/" setCommonRunSettings.sh
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: YES/" GCHP.rc
echo "20190101 000000" > cap_restart
rm -f gcchem_internal_checkpoint Restarts/gcchem_internal_checkpoint* ./*_checkpoint
ln -sf "$STACK/gchp-14.7.1/bin/gchp" ./gchp
ulimit -s unlimited
export FI_PROVIDER=efa
export OMPI_MCA_mtl_ofi_provider_include=efa
export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
source setCommonRunSettings.sh > setcommon.log 2>&1 || { cat setcommon.log; die "setCommonRunSettings"; }
source setRestartLink.sh >> setcommon.log 2>&1 || { cat setcommon.log; die "setRestartLink"; }
source checkRunSettings.sh >> setcommon.log 2>&1 || { cat setcommon.log; die "checkRunSettings"; }
cat setcommon.log

RUNLOG=gchp_${TAG}.log
END_STAMP=$(python3 -c "from datetime import datetime,timedelta;t=datetime(2019,1,1)+timedelta(seconds=${SIMSECS});print(t.strftime('%Y/%m/%d  Time: %H:%M:%S'))")
END_MARK="GCHP Date: ${END_STAMP}"
t0=$(date +%s)
mpirun -n "$TOTAL" --hostfile "$HOSTFILE" --map-by slot \
    -x PATH -x LD_LIBRARY_PATH -x FI_PROVIDER ./gchp > "$RUNLOG" 2>&1 &
MPI_PID=$!
# Throughput comes from GCHP's own timer, so stop at the final timestep (the multi-node checkpoint
# write is not part of the measurement) — same watcher as gchp-matrix-run.sh.
SIM_DONE=0
while kill -0 $MPI_PID 2>/dev/null; do
  if grep -aq "$END_MARK" "$RUNLOG" 2>/dev/null; then
    SIM_DONE=1; t1=$(date +%s); sleep 3
    kill -TERM $MPI_PID 2>/dev/null; sleep 2; kill -KILL $MPI_PID 2>/dev/null
    break
  fi
  sleep 2
done
[[ $SIM_DONE -eq 0 ]] && t1=$(date +%s)
wait $MPI_PID 2>/dev/null
FINAL=$(grep -a "$END_MARK" "$RUNLOG" 2>/dev/null | tail -1)
read -r AVG TOT RUNT <<< "$(echo "$FINAL" | sed 's/.*\[Avg Tot Run\]://' | grep -oE '[0-9]+\.[0-9]+' | head -3 | tr '\n' ' ')"
if [[ $SIM_DONE -eq 1 && -n ${AVG:-} ]]; then STATUS=SUCCEEDED; else STATUS=FAILED; tail -30 "$RUNLOG"; fi

ITYPE=$(TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'); \
        curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
cat > result.txt <<EOF
RESULT_TAG=${TAG}
RESULT_LAUNCHER=spawn
RESULT_INSTANCE=${ITYPE}
RESULT_NODES=${NODES} RESULT_RANKS=${TOTAL} RESULT_DAYS=${DAYS}
ELAPSED_SECONDS=$((t1 - t0))
INTERNAL_THROUGHPUT_AVG=${AVG:-NA}
INTERNAL_THROUGHPUT_RUN=${RUNT:-NA}
RUN_STATUS=${STATUS}
EOF
cat result.txt
DEST="${RESULTS%/}/${TAG}-$(date -u +%Y%m%dT%H%M%SZ)/"
for f in result.txt "$RUNLOG" setcommon.log "$LOG"; do aws s3 cp "$f" "$DEST" --only-show-errors; done
say "uploaded to $DEST"
echo "$STATUS $DEST" > "$SCR/DONE"
[[ $STATUS == SUCCEEDED ]]
