#!/bin/bash
#SBATCH --job-name=gate2-mount-vs-nfs
#SBATCH --partition=compute
#SBATCH --nodes=2
#SBATCH --ntasks=96
#SBATCH --ntasks-per-node=48
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=/scratch/lith-gates/gate2-%j.log
#
# GATE 2 — per-node lith mount vs one shared `lith serve nfs` gateway, 2 nodes.
#
# The hypothesis under test, from docs/lith-input-layer-analysis.md gate 2:
#   "Expect per-node mounts to win for 48-192-rank nodes, for the same reason the
#    S3-wide handoff beat shared Lustre by ~9x: no shared lock, and aggregate
#    bandwidth grows with readers."
#
# WHY THIS JOB ALSO MEASURES READ TOPOLOGY, AND WHY THAT MATTERS
# Gate 1 established by source inspection that GCHP does NOT read the same way on
# both of its two input paths:
#   - restarts: `amIRoot` reads, then ArrayScatter (base/NCIO.F90 ~2218-2290).
#     `NUM_READERS` (GCHP.rc:89, default 1) is the knob here, and GCHP.rc's own
#     comment says "try something from 6 to 24", so 24 is inside its stated range.
#   - ExtData, which is the BULK (~3.2 GB of met vs a 39 MB restart): pFIO, at
#     griddedio/GriddedIO.F90:1288, where ranks request subdomains and a reader
#     set serves them.
# I have NOT verified what sizes that pFIO reader set, so this job does not guess.
# Instead it collects `lith_s3_bytes_total` from EACH NODE SEPARATELY. If node 1
# fetches ~0 bytes, reads are centralised and the "aggregate bandwidth grows with
# readers" premise cannot bite at stock settings — which is itself the answer to
# gate 2, just not the predicted one. Measurement beats inference here.
#
# ARMS (stock config first, because that is what a user actually gets)
#   1 fsx-r1       /input Lustre, NUM_READERS=1   -- anchor AND 2-node smoke test
#   2 mount-r1     per-node FUSE mounts, both nodes have their own 5 daemons
#   3 nfs-r1       5 `lith serve nfs` on node 0; BOTH nodes mount from node 0
#   4 mount-r24    per-node FUSE, NUM_READERS=24
#   5 nfs-r24      shared gateway, NUM_READERS=24
#
# C24 TransportTracers at 96 ranks = NX=4, NY=24. That is not an invented layout:
# setCommonRunSettings.sh lists "(NX=4,NY=24) -> 96 cores at 4x4" as a GOOD
# example and puts c24's ceiling at 216 cores, so no new run directory is needed
# and AutoUpdate_NXNY=ON derives it. Only TOTAL_CORES/NUM_NODES change.
#
# Cost: 2 x c8g.48xlarge (~$7.68/hr ea) or 2 x m9g.48xlarge ($9.3926/hr ea).
# Budget ~45 min => ~$17-21.
set -o pipefail

GATES=/scratch/lith-gates
FSX_RUN=/scratch/gchp_merra2_TransportTracers
LITH_RUN=/scratch/gchp_lith_TransportTracers
RANKS=96
CORES_PER_NODE=48
# --nic-gbps is set from the instance type we actually get, because the queue lists
# two of them for capacity. Values are the authoritative per-card
# BaselineBandwidthInGbps from DescribeInstanceTypes, NOT the advertised "up to"
# peak — that distinction is the whole of lith#237. It is a lookup table rather
# than a live query because the compute node role cannot call
# DescribeInstanceTypes (it is denied; that denial is why `lith doctor` falls back
# to its imds-estimate here).
nic_for() {
  case "$1" in
    m9g.48xlarge)  echo 100 ;;
    c8g.48xlarge)  echo  50 ;;
    *)             echo   0 ;;   # 0 = let lith use its own fallback rather than lie
  esac
}
NIC=0   # set in preflight once the instance type is known
# Version-selectable: LITHVER=1.1.2 is the run that matters now. The nfs arms
# ABORTED GCHP at 4 s on 1.1.1 (lith#244, ESTALE on GETATTR at >=48 concurrent
# readers); 1.1.2 carries the go-nfs-client ReadOpaque short-read fix. Upstream
# verified it with single-host `dd` and cannot reproduce a real MPI client, so
# whether a 96-rank init survives one shared gateway is only answerable here.
LITHVER=${LITHVER:-1.1.1}
LITH=${GATES}/lith-${LITHVER}
RESULTS=${GATES}/gate2-results-${LITHVER}.txt

# Arms are selectable so a rerun after a harness bug does not re-buy arms that
# already have agreeing numbers. fsx-r1/mount-r1/mount-r24 were each measured in
# two separate jobs and reproduced to ~1 s, so re-running them is pure cost.
# NOTE `--export` takes a COMMA-SEPARATED LIST, so `--export=ALL,ARMS=a,b` sets
# ARMS=a and then treats `b` as its own variable name. That silently cost arm 5 in
# job 8. Quote it as a single item: --export=ALL,"ARMS=a,b".
# For the 1.1.2 re-run, mount-r1 IS re-bought on purpose: the mount-vs-gateway
# race never actually ran (the gateway aborted), and a same-job pair under
# identical node/temperature conditions is the only honest way to run it.
ARMS=${ARMS:-fsx-r1,mount-r1,nfs-r1,mount-r24,nfs-r24}
want() { [[ ",${ARMS}," == *",$1,"* ]]; }

say()  { echo; echo "=== $* ==="; }
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; }
stamp() { awk -v t0="$(date +%s.%N)" '{printf "%8.2f  %s\n", systime()-t0, $0; fflush()}'; }
exec > >(tee -a "$RESULTS") 2>&1

mapfile -t NODES < <(scontrol show hostnames "$SLURM_JOB_NODELIST")
N0=${NODES[0]}; N1=${NODES[1]}

# `-o BatchMode=yes` so a missing key fails fast instead of hanging on a prompt.
on()   { local h=$1; shift; ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
             -o ConnectTimeout=10 "$h" "$@"; }

# Starting a LONG-LIVED remote daemon needs -f. `lith mount --daemon` self-detaches
# so plain ssh returns, but `lith serve nfs` has no --daemon flag and must be
# backgrounded with `&` — and then ssh holds the channel open waiting on the
# remote shell and NEVER RETURNS, even though the gateway is up and listening.
# That cost job 6 eight minutes of two-node time with `serve nfs` already bound to
# :20490 and the harness stuck on the first of five servers. `-f` backgrounds ssh
# itself after auth; `timeout` is a second guarantee the loop cannot stall.
on_bg() { local h=$1; shift; timeout 20 ssh -f -n -o StrictHostKeyChecking=no \
              -o BatchMode=yes -o ConnectTimeout=10 "$h" "$@" || true; }
each() { for h in "${NODES[@]}"; do echo "  [$h] $(on "$h" "$@" 2>&1 | tr '\n' ' ')"; done; }

PREFIXES=(GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS)
IDXF=(merra2.lithidx merra2-2015.lithidx hemco.lithidx cheminp.lithidx restarts.lithidx)
# Bounded explicitly: --mem-cache defaults to 25% of system memory PER DAEMON, so
# five daemons would default to 125% of the box.
CACHE=(32GB 4GB 8GB 8GB 8GB)
MPORT=(9110 9111 9112 9113 9114)        # FUSE-mount metrics
NPORT=(20490 20491 20492 20493 20494)   # NFS listen. NOT 2049: the ParallelCluster
                                        # head node's kernel nfsd already owns that
                                        # port, and using a high port sidesteps any
                                        # collision with the cluster's own exports.
GPORT=(9210 9211 9212 9213 9214)        # gateway metrics

# ---------------------------------------------------------------- phase 0: preflight
say "gate 2 preflight — abort before spending if anything is missing"
echo "nodes: ${NODES[*]}   ranks: ${RANKS}"
if [[ ${#NODES[@]} -ne 2 ]]; then bad "need exactly 2 nodes, got ${#NODES[@]}"; exit 1; fi

# Per-node lith daemons must OUTLIVE the shell that starts them, so they are
# launched over ssh rather than in a Slurm step: proctrack/cgroup kills everything
# in a step's cgroup when the step ends, which would take the daemons with it.
# That makes cluster-internal passwordless ssh a hard prerequisite.
for h in "${NODES[@]}"; do
  if on "$h" true 2>/dev/null; then ok "ssh $h"; else
    bad "ssh $h — cannot launch per-node daemons; aborting rather than burning the allocation"
    exit 1
  fi
done

# The queue lists two instance types so EC2 can satisfy capacity. That is good
# for getting nodes and bad for this particular measurement: arm 3/5 puts the
# gateway on node 0 and a client on node 1, so if the two nodes are different
# hardware the shared-gateway penalty is confounded with a NIC difference. Check
# and abort rather than publish a number that cannot be attributed.
itype() { on "$1" "TOK=\$(curl -sX PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
            http://169.254.169.254/latest/api/token); \
          curl -s -H \"X-aws-ec2-metadata-token: \$TOK\" \
            http://169.254.169.254/latest/meta-data/instance-type"; }
IT0=$(itype "$N0"); IT1=$(itype "$N1")
echo "instance types: ${N0}=${IT0}  ${N1}=${IT1}"
if [[ "$IT0" != "$IT1" ]]; then
  bad "nodes are DIFFERENT instance types (${IT0} vs ${IT1}) — the gateway-vs-client"
  bad "comparison would confound the shared-gateway cost with a hardware difference."
  exit 1
fi
ok "both nodes are ${IT0}"
NIC=$(nic_for "$IT0")
if [[ "$NIC" == "0" ]]; then
  bad "no known NIC baseline for ${IT0} — refusing to pass a made-up --nic-gbps"
  exit 1
fi
ok "--nic-gbps ${NIC} (per-card baseline for ${IT0})"

echo "lith:";        each "${LITH} version 2>&1 | head -1"
echo "fusermount3:"; each "command -v fusermount3 || echo MISSING"
echo "mount.nfs:";   each "command -v mount.nfs || echo MISSING"
echo "mounts:";      each "for m in /input /scratch /sw; do mountpoint -q \$m && printf '%s=ok ' \$m || printf '%s=MISSING ' \$m; done"
echo "memory:";      each "free -g | awk '/^Mem:/{print \$2\" GiB\"}'"
for i in 0 1 2 3 4; do
  [[ -s "${GATES}/idx/${IDXF[$i]}" ]] && ok "index ${IDXF[$i]}" || { bad "index ${IDXF[$i]} missing"; exit 1; }
done
echo "gateway ports free on ${N0}:"
echo "  [$N0] $(on "$N0" "for p in ${NPORT[*]}; do ss -ltn | grep -q \":\$p \" && printf '%s=BUSY ' \$p || printf '%s=free ' \$p; done")"

say "2-node MPI smoke test (gates every arm below)"
source /sw/gchp-env.sh
mpirun -n "$RANKS" hostname 2>/dev/null | sort | uniq -c
nhosts=$(mpirun -n "$RANKS" hostname 2>/dev/null | sort -u | wc -l)
if [[ "$nhosts" -ne 2 ]]; then bad "MPI spans $nhosts node(s), expected 2"; exit 1; fi
ok "MPI spans 2 nodes at $RANKS ranks"

# ------------------------------------------------- phase 1: retune run dirs to 96
say "retuning both run directories to 2 nodes x ${CORES_PER_NODE} = ${RANKS} cores"
for rd in "$FSX_RUN" "$LITH_RUN"; do
  sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${RANKS}/;
          s/^NUM_NODES=.*/NUM_NODES=2/;
          s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${CORES_PER_NODE}/" \
      "${rd}/setCommonRunSettings.sh"
  echo "  ${rd##*/}: $(grep -E '^(TOTAL_CORES|NUM_NODES|NUM_CORES_PER_NODE)=' "${rd}/setCommonRunSettings.sh" | tr '\n' ' ')"
done

# --------------------------------------------------------------- mount management
# The bracket in '[l]ith-1.1.1' stops pkill matching the ssh command line that
# carries the pattern — without it pkill kills its own remote shell (learned the
# hard way on the head node).
teardown() {
  for h in "${NODES[@]}"; do
    on "$h" "for p in ${PREFIXES[*]}; do
               fusermount3 -u /input-lith/\$p 2>/dev/null
               sudo umount -f /input-lith/\$p 2>/dev/null || sudo umount -l /input-lith/\$p 2>/dev/null
             done
             pkill -f '[l]ith-1.1.1' 2>/dev/null
             sleep 2
             sudo sysctl -q -w vm.drop_caches=3 2>/dev/null
             printf '%s procs=%s fuse=%s nfs=%s\n' \$(hostname) \
               \$(pgrep -fc '[l]ith-1.1.1' | head -1) \
               \$(mount | grep -c fuse.lith) \$(mount | grep -c 'type nfs')" 2>&1 | sed 's/^/  /'
  done
}

mount_per_node() {
  say "arm setup: PER-NODE FUSE mounts (5 daemons on each of 2 nodes)"
  for h in "${NODES[@]}"; do
    for i in 0 1 2 3 4; do
      on "$h" "mkdir -p /input-lith/${PREFIXES[$i]} && \
               ${LITH} mount s3://gcgrid/${PREFIXES[$i]} /input-lith/${PREFIXES[$i]} \
                 --index-file ${GATES}/idx/${IDXF[$i]} --no-sign-request \
                 --nic-gbps ${NIC} --mem-cache ${CACHE[$i]} --metrics :${MPORT[$i]} --daemon" \
        >/dev/null 2>&1
    done
  done
  sleep 6
  local bad_n=0
  for h in "${NODES[@]}"; do
    local n; n=$(on "$h" "mount | grep -c fuse.lith")
    [[ "$n" == "5" ]] && ok "$h: 5 fuse.lith mounts" || { bad "$h: $n/5 fuse.lith mounts"; bad_n=1; }
  done
  return $bad_n
}

serve_nfs() {
  say "arm setup: ONE SHARED GATEWAY — 5 lith serve nfs on ${N0}, both nodes mount it"
  for i in 0 1 2 3 4; do
    on_bg "$N0" "cd /tmp && setsid nohup ${LITH} serve nfs s3://gcgrid/${PREFIXES[$i]} \
                --index-file ${GATES}/idx/${IDXF[$i]} --no-sign-request \
                --nic-gbps ${NIC} --mem-cache ${CACHE[$i]} \
                --listen :${NPORT[$i]} --metrics :${GPORT[$i]} \
                > ${GATES}/gate2-serve-${i}.log 2>&1 < /dev/null &" >/dev/null 2>&1
  done
  sleep 12
  # Health = "is something LISTENING on each port", checked with ss.
  # Do NOT count processes with pgrep -f here. It reported 15/5 in job 7 and
  # skipped both nfs arms while all five gateways were in fact up and serving:
  # each server contributes THREE command lines containing the pattern (the
  # ssh-spawned `bash -c`, the `setsid nohup` wrapper, and the real lith
  # process), because the pattern is part of the launcher's own cmdline. The
  # bracket trick only defeats self-matching, not launcher-matching. A bound
  # socket is unambiguous and is what the client actually needs.
  local up=0
  for i in 0 1 2 3 4; do
    if on "$N0" "ss -ltn | grep -q ':${NPORT[$i]} '"; then ((up+=1)); fi
  done
  ok "gateway ports listening on ${N0}: ${up}/5"
  [[ "$up" == "5" ]] || { bad "not all gateways started"; on "$N0" "tail -3 ${GATES}/gate2-serve-0.log"; return 1; }

  # Cross-node reachability BEFORE mounting: if the security group blocks these
  # ports, a hung mount would waste the allocation instead of failing here.
  for i in 0 1 2 3 4; do
    if on "$N1" "timeout 5 bash -c '</dev/tcp/${N0}/${NPORT[$i]}'" 2>/dev/null; then
      ok "${N1} -> ${N0}:${NPORT[$i]} reachable"
    else bad "${N1} -> ${N0}:${NPORT[$i]} BLOCKED"; return 1; fi
  done

  for h in "${NODES[@]}"; do
    for i in 0 1 2 3 4; do
      on "$h" "sudo mkdir -p /input-lith/${PREFIXES[$i]} && \
               sudo mount -t nfs -o vers=3,proto=tcp,port=${NPORT[$i]},mountport=${NPORT[$i]},nolock,ro \
                 ${N0}:/ /input-lith/${PREFIXES[$i]}" >/dev/null 2>&1
    done
  done
  sleep 4
  local bad_n=0
  for h in "${NODES[@]}"; do
    local n; n=$(on "$h" "mount | grep -c 'type nfs'")
    # /home and /opt come from the head node over NFS too, so 5 gateway mounts
    # land on top of an existing baseline rather than starting from zero.
    ok "$h: $n nfs mounts total (5 of them are the gateway)"
    on "$h" "ls /input-lith/${PREFIXES[0]} >/dev/null 2>&1" || { bad "$h: gateway mount unreadable"; bad_n=1; }
  done
  return $bad_n
}

# Read topology: the whole point. Print bytes fetched from S3 PER NODE.
read_topology() {
  local label="$1" kind="$2"
  say "read topology after ${label} — bytes fetched from S3, per node"
  if [[ "$kind" == "fuse" ]]; then
    for h in "${NODES[@]}"; do
      local tot=0
      for p in "${MPORT[@]}"; do
        local b; b=$(on "$h" "curl -s --max-time 5 http://localhost:${p}/metrics | awk '/^lith_s3_bytes_total /{print \$2}'" 2>/dev/null)
        [[ -n "$b" ]] && tot=$(awk -v a="$tot" -v b="$b" 'BEGIN{printf "%.0f", a+b}')
      done
      printf 'TOPOLOGY %-12s %-28s s3_bytes=%s (%.1f MB)\n' "$label" "$h" "$tot" \
        "$(awk -v t="$tot" 'BEGIN{print t/1048576}')"
    done
  else
    local tot=0
    for p in "${GPORT[@]}"; do
      local b; b=$(on "$N0" "curl -s --max-time 5 http://localhost:${p}/metrics | awk '/^lith_s3_bytes_total /{print \$2}'" 2>/dev/null)
      [[ -n "$b" ]] && tot=$(awk -v a="$tot" -v b="$b" 'BEGIN{printf "%.0f", a+b}')
    done
    printf 'TOPOLOGY %-12s %-28s s3_bytes=%s (%.1f MB)  [single gateway serves both nodes]\n' \
      "$label" "$N0" "$tot" "$(awk -v t="$tot" 'BEGIN{print t/1048576}')"
  fi
}

# ------------------------------------------------------------------------ the runner
# Success is the model's OWN internal clock reaching the end of the simulated day,
# deliberately NOT the checkpoint. A 2-node pnc4 checkpoint can hang after the
# simulation is complete, and waiting on it would burn the allocation for a number
# we do not need — gate 2 is about reads. GCHP also throws a teardown
# "double free or corruption (!prev)" in _dl_fini and leaves ranks spinning, so
# mpirun never returns; poll the log, then kill.
gchp_run() {
  local label="$1" dir="$2" readers="$3"
  local log="${GATES}/gate2-${label}.log"
  say "RUN ${label}   dir=${dir##*/}   NUM_READERS=${readers}"
  cd "$dir" || return 1
  echo "20190101 000000" > cap_restart
  rm -f Restarts/gcchem_internal_checkpoint* OutputDir/*.nc4 2>/dev/null
  source /sw/gchp-env.sh
  ulimit -s unlimited 2>/dev/null
  source setCommonRunSettings.sh >/dev/null 2>&1
  source setRestartLink.sh >/dev/null 2>&1
  source checkRunSettings.sh >/dev/null 2>&1
  # Applied AFTER the official scripts so they cannot clobber it. NUM_READERS
  # appears nowhere in setCommonRunSettings.sh, so this is additive, not a fight.
  sed -i "s/^NUM_READERS: .*/NUM_READERS: ${readers}/" GCHP.rc
  echo "  NX=$(awk '/^NX:/{print $2}' GCHP.rc) NY=$(awk '/^NY:/{print $2}' GCHP.rc) NUM_READERS=$(awk '/^NUM_READERS:/{print $2}' GCHP.rc)"

  local t0 t1 done_at="" i=0 deadline=420
  t0=$(date +%s.%N)
  mpirun -n "$RANKS" ./gchp 2>&1 | stamp > "$log" &
  local pipe_pid=$!
  while (( i < deadline )); do
    if grep -a -qE "GCHP Date: 2019/01/02 +Time: 00:00:00" "$log" 2>/dev/null; then
      done_at=$(date +%s.%N); break; fi
    kill -0 "$pipe_pid" 2>/dev/null || break
    sleep 1; ((i++))
  done
  t1=${done_at:-$(date +%s.%N)}

  kill -9 "$pipe_pid" 2>/dev/null
  for h in "${NODES[@]}"; do on "$h" "pkill -9 -x gchp; pkill -9 -x orted" >/dev/null 2>&1; done
  wait "$pipe_pid" 2>/dev/null
  sleep 3

  local init_s sim_end_s steps verdict=FAILED
  # -a is REQUIRED, not defensive. At 96 ranks across 2 nodes the interleaved
  # mpirun output contains NUL bytes, so grep declares the log a binary file and
  # prints "binary file matches" INSTEAD of the matching line — which silently
  # turned init and sim_end into NA on the first run of this job while the run
  # itself was perfectly fine. -c and -q are unaffected, which is why the step
  # count and the SIM_COMPLETE verdict still worked and hid the problem.
  init_s=$(grep -a -m1 "GCHP Date" "$log" | awk '{print $1}')
  sim_end_s=$(grep -a "GCHP Date" "$log" | tail -1 | awk '{print $1}')
  steps=$(grep -a -c "GCHP Date" "$log")
  [[ -n "$done_at" ]] && verdict=SIM_COMPLETE
  printf 'RESULT %-12s readers=%-3s init=%ss  sim_end=%ss  wall=%.1fs  steps=%s/144  %s\n' \
    "$label" "$readers" "${init_s:-NA}" "${sim_end_s:-NA}" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" "$steps" "$verdict"
  [[ -n "$done_at" ]]
}

# ============================================================================ arms
teardown

echo "arms selected: ${ARMS}"

if want fsx-r1; then
  say "ARM 1/5 — FSx Lustre anchor (also the 2-node GCHP smoke test)"
  if ! gchp_run fsx-r1 "$FSX_RUN" 1; then
    bad "2-node GCHP did not complete on FSx. That is a model/cluster problem, not a"
    bad "lith result, and every lith arm below would be uninterpretable. Stopping."
    tail -25 "${GATES}/gate2-fsx-r1.log"
    exit 1
  fi
fi

if want mount-r1; then
  say "ARM 2/5 — per-node lith mounts, stock NUM_READERS=1"
  teardown
  if mount_per_node; then
    gchp_run mount-r1 "$LITH_RUN" 1
    read_topology mount-r1 fuse
  else bad "skipping mount-r1: mounts not healthy"; fi
fi

if want nfs-r1; then
  say "ARM 3/5 — shared lith serve nfs gateway, stock NUM_READERS=1"
  teardown
  if serve_nfs; then
    gchp_run nfs-r1 "$LITH_RUN" 1
    read_topology nfs-r1 gw
  else bad "skipping nfs-r1: gateway not healthy"; fi
fi

if want mount-r24; then
  say "ARM 4/5 — per-node lith mounts, NUM_READERS=24"
  teardown
  if mount_per_node; then
    gchp_run mount-r24 "$LITH_RUN" 24
    read_topology mount-r24 fuse
  else bad "skipping mount-r24: mounts not healthy"; fi
fi

if want nfs-r24; then
  say "ARM 5/5 — shared lith serve nfs gateway, NUM_READERS=24"
  teardown
  if serve_nfs; then
    gchp_run nfs-r24 "$LITH_RUN" 24
    read_topology nfs-r24 gw
  else bad "skipping nfs-r24: gateway not healthy"; fi
fi

say "cleanup"
teardown
# Leave the run directories as we found them: 1 node, 48 cores.
for rd in "$FSX_RUN" "$LITH_RUN"; do
  sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=48/;
          s/^NUM_NODES=.*/NUM_NODES=1/;
          s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=48/" "${rd}/setCommonRunSettings.sh"
  sed -i "s/^NUM_READERS: .*/NUM_READERS: 1/" "${rd}/GCHP.rc"
done

say "GATE 2 SUMMARY"
grep -E "^(RESULT|TOPOLOGY)" "$RESULTS"
