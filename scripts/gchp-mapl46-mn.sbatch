#!/bin/bash
#SBATCH --job-name=mapl46-mn
#SBATCH --partition=compute
#SBATCH --nodes=2
#SBATCH --ntasks=48
#SBATCH --ntasks-per-node=24
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/scratch/gchp-mapl46/mn-%j.log
# GCHP#556 / MAPL PR#46, multi-node + launcher coverage: 2 nodes over EFA, 48 ranks (24/node), C24 TT 1 day.
# Pre-registered in data/gchp-mapl46/README.txt (addendum MN). Same three binaries as the head-node A/B
# (one build tree): A stock, B PR #46, C PR #46 + MPI_Finalize before _exit. Each arm is launched with
# mpirun (OpenMPI 4.1.7) and with srun --mpi=pmix. Every cell waits for the launcher to EXIT.
# No `set -u`: GCHP's setCommonRunSettings.sh dereferences $4.

W=/scratch/gchp-mapl46
GATES=/scratch/lith-gates
LITH=$GATES/lith-main-412
SRC=/scratch/gchp_lith_TransportTracers
RD=/scratch/gchp_mapl46_mn
OUT=$W/mn-$SLURM_JOB_ID
NODES_N=2; RPN=24; RANKS=$((NODES_N * RPN))
EXIT_GRACE=180
declare -A BIN=([A]=$W/gchp-stock [B]=$W/gchp-pr46 [C]=$W/gchp-pr46fin)
CELLS=${CELLS:-"A:mpirun B:mpirun C:mpirun A:srun B:srun C:srun C:mpirun C:srun"}
mkdir -p "$OUT"
say() { echo "[$(date -u +%H:%M:%S)] $*"; }
mapfile -t NODES < <(scontrol show hostnames "$SLURM_JOB_NODELIST")
on() { local h=$1; shift; ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 "$h" "$@"; }

PREFIXES=(GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS)
IDXF=(merra2 merra2-2015 hemco cheminp restarts)

say "=== MAPL PR#46 multi-node  job $SLURM_JOB_ID  nodes ${NODES[*]}  ranks $RANKS"
for a in A B C; do say "  bin $a $(md5sum "${BIN[$a]}" | cut -c1-12)"; done
for h in "${NODES[@]}"; do
  it=$(on "$h" 'T=$(curl -sX PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token); curl -s -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/instance-type')
  efa=$(on "$h" "source /sw/gchp-env.sh >/dev/null 2>&1; /sw/libfabric-1.22.0/bin/fi_info -p efa 2>/dev/null | grep -c 'provider: efa'")
  say "  $h $it efa_endpoints=$efa"
  [ "${efa:-0}" -gt 0 ] || { say "no EFA on $h -- aborting"; exit 1; }
  for i in 0 1 2 3 4; do
    on "$h" "mkdir -p /input-lith/${PREFIXES[$i]} && $LITH mount s3://gcgrid/${PREFIXES[$i]} /input-lith/${PREFIXES[$i]} \
      --index-file $GATES/idx/${IDXF[$i]}.lithidx --no-sign-request --nic-gbps 50 --mem-cache 8GB \
      --metrics :$((9210 + i)) --daemon" > /dev/null 2>&1
  done
done
sleep 6
for h in "${NODES[@]}"; do n=$(on "$h" "mount | grep -c fuse.lith"); say "  $h fuse.lith=$n"; [ "$n" = 5 ] || exit 1; done
teardown() {
  for h in "${NODES[@]}"; do
    on "$h" "for p in ${PREFIXES[*]}; do fusermount3 -u /input-lith/\$p 2>/dev/null; done; sleep 1; echo \$(hostname) fuse=\$(mount | grep -c fuse.lith)"
  done
}
trap teardown EXIT

source /sw/gchp-env.sh >/dev/null
export FI_PROVIDER=efa OMPI_MCA_mtl_ofi_provider_include=efa OMPI_MCA_pml=cm OMPI_MCA_mtl=ofi   # EFA or fail
ulimit -s unlimited

prep_rundir() {
  rm -rf "$RD"; cp -a "$SRC" "$RD" && cd "$RD" || return 1
  sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$RANKS/;s/^NUM_NODES=.*/NUM_NODES=$NODES_N/;s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/" setCommonRunSettings.sh
  echo "20190101 000000" > cap_restart
  rm -f gcchem_internal_checkpoint Restarts/gcchem_internal_checkpoint* allPEs.log warnings_and_errors.log
  source ./setCommonRunSettings.sh > "$1.setcommon.log" 2>&1
  source ./setRestartLink.sh >> "$1.setcommon.log" 2>&1
  source ./checkRunSettings.sh > "$1.checkrun.log" 2>&1
  grep -qiE "^ *ERROR|must equal" "$1.checkrun.log" && { say "checkRunSettings.sh OBJECTED"; return 1; }
  ln -sfn "$2" gchp
}
strays() { local s=0 h n; for h in "${NODES[@]}"; do n=$(on "$h" "pgrep -xc gchp"); s=$((s + ${n:-0})); done; echo $s; }

k=0
for cell in $CELLS; do
  arm=${cell%%:*}; L=${cell##*:}; k=$((k + 1)); tag=$k-$arm-$L; log=$OUT/$tag.gchp.log
  w=0; while [ "$(strays)" -gt 0 ] && [ $w -lt 300 ]; do sleep 5; w=$((w + 5)); done
  [ $w -gt 0 ] && say "  waited ${w}s for stray ranks"
  prep_rundir "$OUT/$tag" "${BIN[$arm]}" || exit 1
  say "RUN $tag"
  t0=$(date +%s); adv=NA; rc=NA; tdf=NA; timp=NA
  if [ "$L" = mpirun ]; then mpirun -n $RANKS --map-by ppr:$RPN:node ./gchp > "$log" 2>&1 &
  else srun --mpi=pmix -n $RANKS --ntasks-per-node=$RPN --kill-on-bad-exit=0 ./gchp > "$log" 2>&1 & fi
  mp=$!
  while kill -0 $mp 2>/dev/null; do
    sleep 1; el=$(( $(date +%s) - t0 ))
    [ "$adv" = NA ] && [ "$(awk '{print $1}' cap_restart)" != 20190101 ] && adv=$el
    [ "$tdf" = NA ] && grep -q "double free" "$log" && tdf=$el
    [ "$timp" = NA ] && grep -qE "exiting improperly|without calling .?finalize" "$log" && timp=$el
    if [ "$adv" != NA ] && [ $((el - adv)) -gt $EXIT_GRACE ]; then rc=HUNG; kill $mp; break; fi
    [ $el -gt 900 ] && { rc=TIMEOUT; kill $mp; break; }
  done
  wait $mp 2>/dev/null; wrc=$?; [ "$rc" = NA ] && rc=$wrc
  el=$(( $(date +%s) - t0 ))
  sleep 3; st=$(strays)
  for h in "${NODES[@]}"; do on "$h" "pkill -x gchp" 2>/dev/null; done
  ck=$(ls Restarts/gcchem_internal_checkpoint* 2>/dev/null | head -1)
  md5=$([ -n "$ck" ] && md5sum "$ck" | cut -c1-12 || echo NONE)
  cp -p allPEs.log "$OUT/$tag.allPEs.log" 2>/dev/null
  say "CELL $tag rc=$rc wall=${el}s cap_adv_at=${adv}s cap=$(cat cap_restart) ckpt_md5=$md5" \
      "double_free=$(grep -c 'double free' "$log") improper=$(grep -ciE 'exiting improperly|without calling .?finalize' "$log")" \
      "throughput=$(grep -c 'Model Throughput:' "$OUT/$tag.allPEs.log" 2>/dev/null) strays_after_exit=$st"
  say "  first seen (s): cap_restart=$adv double_free=$tdf improper=$timp exit=$el"
  say "  last log line: $(grep -v '^\s*$' "$log" | tail -1 | cut -c1-160)"
done
say "=== done $(date -u +%FT%TZ)"
