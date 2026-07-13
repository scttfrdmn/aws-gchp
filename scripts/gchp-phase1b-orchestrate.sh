#!/bin/bash
# gchp-phase1b-orchestrate.sh — run the WHOLE Phase 1b verification chain on the
# head node, in order, gating hard on each step. Real money; fail fast.
#
#   0. build decoupled + worker binaries (CHEM_BACKEND=decoupled BUILD_WORKER=1)
#   1. shim unit selftest (chem_remote_selftest.sh) — plumbing gate
#   2. baseline: 1-rank C24 fullchem, remote OFF -> Phase-0 restart MD5
#   3. single-rank identity: 1-rank, remote ON -> MD5 must == baseline
#   4. full identity: 12-rank, remote ON -> MD5 must == baseline
#   5. fallback proof: 12-rank, remote ON, kill 1 worker -> MD5 must == baseline
#   6. report handoff cost (from step 4's log)
#
# Do NOT proceed past a failing single-rank identity (step 3).
#
# Usage (head node):  bash gchp-phase1b-orchestrate.sh 2>&1 | tee ~/p1b.log
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUB=parallelcluster/../scripts   # not used; scripts are alongside
RUNBASE=/scratch

say(){ echo; echo "############################################################"; echo "## $*"; echo "############################################################"; }
wait_job(){ # $1=jobid ; block until it leaves the queue
  local jid=$1 n=0
  while squeue -j "$jid" -h 2>/dev/null | grep -q .; do sleep 10; n=$((n+10)); [ $n -ge 2400 ] && { echo "TIMEOUT waiting on job $jid"; return 1; }; done
}
md5_from_log(){ grep -aoE "RESULT_P1B_MD5 tag=[^ ]+ file=[^ ]+ md5=[0-9a-f]+" "$1" | grep -oE "md5=[0-9a-f]+" | cut -d= -f2 | tail -1; }
submit(){ "$HERE/gchp-phase1b-run.sh" "$@" | grep -aoE "job=[0-9]+" | cut -d= -f2 | tail -1; }
slurmlog(){ ls -t $RUNBASE/gchp_$1/slurm-$1-*.log 2>/dev/null | head -1; }

########## 0. BUILD ##########
say "0. BUILD decoupled + worker"
if [ ! -x /scratch/gchp-instr/GCHP-decoupled/build/bin/gchp ] || [ "${REBUILD:-0}" = "1" ]; then
  CHEM_BACKEND=decoupled BUILD_WORKER=1 bash "$HERE/build-instrumented-gchp.sh" 2>&1 | tail -30
fi
GBIN=/scratch/gchp-instr/GCHP-decoupled/build/bin/gchp
WBIN=/scratch/gchp-instr/GCHP-decoupled/build/bin/kpp_worker
[ -x "$GBIN" ] || { echo ">>> BUILD FAILED: no $GBIN"; exit 1; }
[ -x "$WBIN" ] || { echo ">>> BUILD FAILED: no $WBIN (worker)"; exit 1; }
echo "BUILD OK: $(ls -la $GBIN $WBIN)"

########## 1. SHIM SELFTEST ##########
say "1. SHIM UNIT SELFTEST"
if bash "$HERE/chem_remote_selftest.sh" 2>&1 | tee /tmp/p1b_selftest.out | tail -20; then :; fi
grep -q "PHASE1B SHIM SELFTEST PASS" /tmp/p1b_selftest.out || { echo ">>> STOP: shim selftest FAILED"; exit 1; }
echo ">>> STEP 1 PASS"

########## 2. BASELINE (remote OFF) ##########
say "2. BASELINE 6-rank remote OFF -> Phase-0 MD5"
JID=$(submit 6 baseline); echo "baseline job=$JID"; wait_job "$JID" || exit 1
BLOG=$(slurmlog c24p1b_r6_baseline); echo "log: $BLOG"
BASE_MD5=$(md5_from_log "$BLOG")
[ -n "$BASE_MD5" ] || { echo ">>> STOP: no baseline MD5 (run failed?)"; tail -30 "$BLOG"; exit 1; }
echo ">>> BASELINE MD5 = $BASE_MD5"

########## 3. SMALL-SCALE IDENTITY (remote ON) ##########
say "3. SMALL identity: 6-rank remote ON (smallest valid GCHP layout)"
JID=$(submit 6 normal); echo "job=$JID"; wait_job "$JID" || exit 1
L=$(slurmlog c24p1b_r6_normal); M=$(md5_from_log "$L")
echo "  6-rank remote MD5 = $M   (baseline $BASE_MD5)"
grep -aE "buffers are SHM-backed|PHASE1B HANDOFF" "$L" | head -3
if [ "$M" = "$BASE_MD5" ]; then echo ">>> STEP 3 PASS (byte-identical)"; else echo ">>> STOP: 6-rank MD5 MISMATCH"; tail -40 "$L"; exit 1; fi

########## 4. FULL 12-RANK IDENTITY ##########
say "4. FULL 12-rank identity: remote ON"
JID=$(submit 12 normal); echo "job=$JID"; wait_job "$JID" || exit 1
L4=$(slurmlog c24p1b_r12_normal); M=$(md5_from_log "$L4")
echo "  12-rank remote MD5 = $M   (baseline $BASE_MD5)"
if [ "$M" = "$BASE_MD5" ]; then echo ">>> STEP 4 PASS (byte-identical, 12 ranks)"; else echo ">>> STEP 4 MISMATCH"; tail -40 "$L4"; fi

########## 5. FALLBACK PROOF ##########
say "5. FALLBACK proof: 12-rank, kill 1 worker mid-run"
JID=$(submit 12 kill1); echo "job=$JID"; wait_job "$JID" || exit 1
L5=$(slurmlog c24p1b_r12_kill1); M=$(md5_from_log "$L5")
echo "  12-rank kill1 MD5 = $M   (baseline $BASE_MD5)"
grep -aE "worker timeout/err|in-process fallback" "$L5" | head -3
if [ "$M" = "$BASE_MD5" ]; then echo ">>> STEP 5 PASS (fallback byte-identical)"; else echo ">>> STEP 5 MISMATCH"; tail -40 "$L5"; fi

########## 6. HANDOFF COST ##########
say "6. HANDOFF cost (from 12-rank run)"
grep -aE "PHASE1B HANDOFF" "$L4" | head -12

say "PHASE 1b CHAIN COMPLETE"
echo "baseline=$BASE_MD5"
echo "  step3 6-rank : $(md5_from_log "$(slurmlog c24p1b_r6_normal)")"
echo "  step4 12-rank: $(md5_from_log "$L4")"
echo "  step5 kill1  : $(md5_from_log "$L5")"
