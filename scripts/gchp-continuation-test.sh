#!/bin/bash
# gchp-continuation-test.sh — Measurement 5: bitwise restart-continuation test (C180 TransportTracers).
#
# Question: does (run 12h -> checkpoint -> restart -> run 12h) reproduce (run 24h straight) bit-for-bit?
#   - Fields that MATCH  => the MAPL INTERNAL checkpoint fully captures that state across a stop/restart.
#   - Fields that DIFFER => state that lives OUTSIDE the snapshot (module SAVE, un-checkpointed
#     accumulators, RNG, etc.) — exactly what a faithful decoupled-execution boundary must ALSO carry.
#
# Mechanism (verified from the run dir, not guessed): GCHP reads gchp_restart.nc4 (-> Restarts/
# GEOSChem.Restart.<startdate>z.cN.nc4) as INTERNAL restart, writes Restarts/gcchem_internal_checkpoint
# at end; the canonical chaining (runScriptSamples/gchp.batch_job.sh) advances cap_restart, renames the
# checkpoint to GEOSChem.Restart.<newdate>z.cN.nc4, and re-runs setRestartLink.sh for the next segment.
#
# Runs on the STOCK/instrumented binary alike (no instrumentation needed). Single node (1×60) is plenty
# and avoids multi-node nondeterminism confounders for a bit-reproducibility test.
set -uo pipefail
STACK=/sw
GCHP_BIN=/scratch/gchp-instr/GCHP/build/bin/gchp
RUNDIR=/scratch/gchp_tt
# RESOLUTION/NODE CHOICE for the continuation test:
#  - C180 1-node OOMs (128 GB) even for TT; C180 2-node fits BUT the end-of-run collective checkpoint
#    rides the MAPL o-server, which on a 2-node job busy-waits and NEVER returns (observed live: all
#    ranks State R / wchan=0, no checkpoint file after 20+ min). That hang blocks the comparison.
#  - C90 on ONE node sidesteps both: it fits TT comfortably, and a 1-node pnc4 checkpoint writes
#    NATIVELY (no multi-node o-server) — the documented "1-node works" path. The o-server is turned
#    OFF here for that reason. Bitwise reproducibility is resolution-independent, so C90 is a valid
#    target; both arms use the identical 1-node C90 decomposition.
CS=90; NODES=1; RPN=60; TOTAL=$((NODES*RPN)); NX=5; NY=12    # C90 1-node: 60 ranks, 5x12
TAG="c180tt_contin"

cd "$RUNDIR" || { echo "FAIL: run dir missing"; exit 1; }

# Common layout for ALL segments (identical decomposition is required for a fair bitwise comparison).
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${TOTAL}/"             setCommonRunSettings.sh
sed -i "s/^NUM_NODES=.*/NUM_NODES=${NODES}/"                 setCommonRunSettings.sh
sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${RPN}/" setCommonRunSettings.sh
sed -i "s/^CS_RES=.*/CS_RES=${CS}/"                          setCommonRunSettings.sh
sed -i "s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/"          setCommonRunSettings.sh
sed -i "s/^NX=.*/NX=${NX}/"                                  setCommonRunSettings.sh
sed -i "s/^NY=.*/NY=${NY}/"                                  setCommonRunSettings.sh
sed -i "s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
# RECORD_FREQUENCY off — we control segmentation by Run_Duration + explicit restart chaining, not alarms.
sed -i "s/^RECORD_FREQUENCY:.*/#RECORD_FREQUENCY: 120000/" GCHP.rc 2>/dev/null || true
# o-server OFF: on 1 node the native pnc4 write completes; the o-server path is the thing that hangs.
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: NO/" GCHP.rc 2>/dev/null || true
ln -sf "$GCHP_BIN" "$RUNDIR/gchp"

cat > "$RUNDIR/run_${TAG}.slurm" <<EOF
#!/bin/bash
#SBATCH --job-name=${TAG}
#SBATCH --partition=compute
#SBATCH --nodes=${NODES}
#SBATCH --ntasks=${TOTAL}
#SBATCH --ntasks-per-node=${RPN}
#SBATCH --time=01:30:00
#SBATCH --output=slurm-${TAG}-%j.log
#SBATCH --exclusive
# NO 'set -e': GCHP 14.7.1 exits with a BENIGN finalization SIGABRT (signal 6 / exit 134) AFTER it has
# successfully written the checkpoint. Under set -e that benign abort would kill the script before we
# can save/compare the result. Success is judged by the CHECKPOINT appearing + cap_restart advancing,
# not by mpirun's exit code.
cd "\$SLURM_SUBMIT_DIR"
source ${STACK}/gchp-env.sh
export PATH="${STACK}/libfabric-1.22.0/bin:\$PATH"
export FI_PROVIDER=efa
ulimit -s unlimited 2>/dev/null
N=${CS}
RUN() {  # \$1 = duration "DDDDDDDD HHMMSS" ; \$2 = log suffix
  sed -i "s/^Run_Duration=.*/Run_Duration=\"\$1\"/" setCommonRunSettings.sh
  source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh
  srun --ntasks-per-node=1 --ntasks=${NODES} sudo mount -o remount,size=64G /dev/shm 2>&1 | tail -1
  echo "=== SEGMENT \$2 : start=\$(cat cap_restart) dur=\$1 restart_link=\$(readlink gchp_restart.nc4) ==="
  mpirun -n ${TOTAL} --mca mtl_ofi_provider_include efa ./gchp > gchp_${TAG}_\$2.log 2>&1 || \
    echo "=== SEGMENT \$2 mpirun returned \$? (benign finalization SIGABRT expected; checking checkpoint) ==="
  if [ ! -f Restarts/gcchem_internal_checkpoint ]; then
    echo "FATAL: SEGMENT \$2 produced NO checkpoint — last log lines:"; tail -8 gchp_${TAG}_\$2.log; exit 2
  fi
  echo "=== SEGMENT \$2 done: last date \$(grep -a 'GCHP Date' gchp_${TAG}_\$2.log | tail -1 | grep -oE 'Date: [0-9/]+  Time: [0-9:]+') ; checkpoint \$(ls -l Restarts/gcchem_internal_checkpoint | awk '{print \$5}') bytes ==="
}
CHAIN() {  # advance cap_restart + rename checkpoint -> restart for next segment (mirrors gchp.batch_job.sh)
  new_start_str=\$(sed 's/ /_/g' cap_restart)   # cap_restart already auto-advanced by GCHP
  mv Restarts/gcchem_internal_checkpoint Restarts/GEOSChem.Restart.\${new_start_str:0:13}z.c\${N}.nc4
  echo "=== CHAIN: checkpoint -> Restarts/GEOSChem.Restart.\${new_start_str:0:13}z.c\${N}.nc4 ; cap_restart=\$(cat cap_restart) ==="
}

# ---------- ARM B: straight 24h (do this FIRST, save its result aside) ----------
echo "20190101 000000" > cap_restart
RUN "00000001 000000" "straight24"
cp Restarts/gcchem_internal_checkpoint /scratch/gchp_tt/CONTIN_straight_20190102.nc4
echo "=== saved straight-24h final -> CONTIN_straight_20190102.nc4 (\$(ls -l Restarts/gcchem_internal_checkpoint | awk '{print \$5}') bytes) ==="
rm -f Restarts/gcchem_internal_checkpoint

# ---------- ARM A: 12h + 12h segmented ----------
echo "20190101 000000" > cap_restart
RUN "00000000 120000" "seg1_12h"      # first 12h -> checkpoint at 20190101 120000
CHAIN                                  # rename checkpoint -> 20190101_1200z restart, cap_restart now 20190101 120000
RUN "00000000 120000" "seg2_12h"      # second 12h from that restart -> checkpoint at 20190102 000000
cp Restarts/gcchem_internal_checkpoint /scratch/gchp_tt/CONTIN_segmented_20190102.nc4
echo "=== saved segmented final -> CONTIN_segmented_20190102.nc4 (\$(ls -l Restarts/gcchem_internal_checkpoint | awk '{print \$5}') bytes) ==="

# ---------- COMPARE: bitwise diff of the two 20190102_0000z finals ----------
echo "RESULT_CONTIN_DIFF tag=${TAG}"
echo "--- h5diff -c (count differences per dataset; 0 diffs = bit-identical) ---"
h5diff -v2 -c /scratch/gchp_tt/CONTIN_straight_20190102.nc4 /scratch/gchp_tt/CONTIN_segmented_20190102.nc4 \
  > /scratch/gchp_tt/CONTIN_h5diff_full.txt 2>&1 || true
echo "h5diff exit captured to CONTIN_h5diff_full.txt (\$(wc -l < /scratch/gchp_tt/CONTIN_h5diff_full.txt) lines)"
echo "--- per-dataset diff summary (datasets with >0 differences) ---"
grep -aE "dataset:|differences found|0 differences" /scratch/gchp_tt/CONTIN_h5diff_full.txt | \
  grep -aB1 "differences found" | head -60
echo "--- totals ---"
echo "datasets compared : \$(grep -ac 'dataset:' /scratch/gchp_tt/CONTIN_h5diff_full.txt)"
echo "datasets DIFFERING : \$(grep -ac 'differences found' /scratch/gchp_tt/CONTIN_h5diff_full.txt)"
echo "RESULT_CONTIN_DONE tag=${TAG}"
EOF

JID=$(sbatch --parsable "$RUNDIR/run_${TAG}.slurm")
echo "SUBMITTED ${TAG} job=$JID"
