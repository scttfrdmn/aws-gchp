#!/bin/bash
# GCHP#556 / geoschem/MAPL PR #46 A/B on the head node: does the finalization fix remove the
# exit-time double free without changing the science? Pre-registered in data/gchp-mapl46/README.txt.
# Arms (same run dir, same lith mounts, 12 ranks C24 TT 1 day; only the binary differs):
#   P  production /sw/gchp-14.7.1/bin/gchp
#   A  stock 14.7.1 built from the same tree as B (scripts/build-gchp-mapl46.sh)
#   B  stock 14.7.1 + PR #46 (MAPL_Cap.F90 only)
# Unlike gate-streams-gchp.sh this waits for mpirun to EXIT, because the exit is what is under test.
# No `set -u`: GCHP's setCommonRunSettings.sh dereferences $4.

GATES=/scratch/lith-gates
LITH=${LITH:-$GATES/lith-main-412}
W=${W:-/scratch/gchp-mapl46}
SRC=${SRC:-/scratch/gchp_lith_TransportTracers}
RD=${RD:-/scratch/gchp_mapl46_TT}
OUT=${OUT:-$W/ab}
RANKS=${RANKS:-12}
REPS=${REPS:-2}
EXIT_GRACE=${EXIT_GRACE:-180}   # seconds mpirun may take to exit after cap_restart advances
MEMC=2GB
declare -A BIN=([P]=/sw/gchp-14.7.1/bin/gchp [A]=$W/gchp-stock [B]=$W/gchp-pr46)

mkdir -p "$OUT"
say() { echo "[$(date -u +%H:%M:%S)] $*"; }
MNTS="GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS"

mount_lith() {
  local d i=0 idx=(merra2 merra2-2015 hemco cheminp restarts)
  for d in $MNTS; do sudo mkdir -p "/input-lith/$d"; done
  sudo chown -R "$(id -u):$(id -g)" /input-lith
  for d in $MNTS; do
    "$LITH" mount "s3://gcgrid/$d" "/input-lith/$d" --index-file "$GATES/idx/${idx[$i]}.lithidx" \
      --no-sign-request --nic-gbps 50 --mem-cache $MEMC --metrics ":$((9210 + i))" --daemon
    i=$((i + 1))
  done
  sleep 6
  [ "$(mount | grep -c fuse.lith)" -eq 5 ] || { say "MOUNTS NOT HEALTHY"; return 1; }
}
clean_lith() {
  local d; for d in $MNTS; do fusermount3 -u "/input-lith/$d" >/dev/null 2>&1; done
  sleep 2; say "stale fuse.lith mounts after cleanup: $(mount | grep -c fuse.lith)"
}
trap clean_lith EXIT

prep_rundir() {
  rm -rf "$RD"; cp -a "$SRC" "$RD" && cd "$RD" || return 1
  sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$RANKS/;s/^NUM_NODES=.*/NUM_NODES=1/;s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RANKS/" setCommonRunSettings.sh
  echo "20190101 000000" > cap_restart
  rm -f gcchem_internal_checkpoint Restarts/gcchem_internal_checkpoint*
  source /sw/gchp-env.sh; ulimit -s unlimited 2>/dev/null
  source ./setCommonRunSettings.sh > "$1.setcommon.log" 2>&1
  source ./setRestartLink.sh >> "$1.setcommon.log" 2>&1
  source ./checkRunSettings.sh > "$1.checkrun.log" 2>&1
  grep -qiE "^ *ERROR|must equal" "$1.checkrun.log" && { say "checkRunSettings.sh OBJECTED"; return 1; }
  ln -sfn "$2" gchp
}

run_arm() {  # run_arm ARM REP
  local tag=$1-$2 log t0 el mp rc=NA adv=NA ck md5 stray
  log=$OUT/$tag.gchp.log
  prep_rundir "$OUT/$tag" "${BIN[$1]}" || return 1
  say "RUN $tag bin=$(md5sum "${BIN[$1]}" | cut -c1-12)"
  t0=$(date +%s); mpirun -n "$RANKS" ./gchp > "$log" 2>&1 & mp=$!
  while kill -0 $mp 2>/dev/null; do
    sleep 1; el=$(( $(date +%s) - t0 ))
    if [ "$adv" = NA ] && [ "$(awk '{print $1}' cap_restart)" != 20190101 ]; then adv=$el; fi
    if [ "$adv" != NA ] && [ $((el - adv)) -gt "$EXIT_GRACE" ]; then say "  $tag mpirun still alive ${EXIT_GRACE}s after cap_restart -> HUNG, killing"; rc=HUNG; kill $mp; break; fi
    [ "$el" -gt 1200 ] && { rc=TIMEOUT; kill $mp; break; }
  done
  wait $mp 2>/dev/null; local wrc=$?; [ "$rc" = NA ] && rc=$wrc
  el=$(( $(date +%s) - t0 ))
  sleep 2; stray=$(pgrep -xc gchp); pkill -x gchp >/dev/null 2>&1
  ck=$(ls Restarts/gcchem_internal_checkpoint* 2>/dev/null | head -1)
  md5=$([ -n "$ck" ] && md5sum "$ck" | cut -c1-12 || echo NONE)
  say "CELL $tag rc=$rc wall=${el}s cap_adv_at=${adv}s cap=$(cat cap_restart) ckpt_md5=$md5" \
      "double_free=$(grep -c 'double free' "$log") backtrace=$(grep -c 'Backtrace for this error' "$log")" \
      "improper=$(grep -ciE 'exiting improperly|without calling .?finalize' "$log")" \
      "timers=$(grep -c 'Times for' "$log") throughput=$(grep -c "Model Throughput:" "$log") stray_gchp=$stray"
  say "  last log line: $(grep -v '^\s*$' "$log" | tail -1 | cut -c1-140)"
}

say "=== GCHP#556 / MAPL PR#46 A/B  $(date -u +%FT%TZ)  ranks=$RANKS lith=$(md5sum "$LITH" | cut -c1-12)"
for a in P A B; do say "  bin $a $(md5sum "${BIN[$a]}" | cut -c1-12) ${BIN[$a]}"; done
mount_lith || exit 1
for r in $(seq 1 "$REPS"); do for a in A B P; do run_arm $a $r; done; done
say "=== done $(date -u +%FT%TZ)"
