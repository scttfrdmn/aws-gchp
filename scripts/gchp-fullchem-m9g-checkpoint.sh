#!/bin/bash
# gchp-fullchem-m9g-checkpoint.sh — get GCHP 14.7.1 fullchem to WRITE (and RESTART FROM) a clean
# internal checkpoint at C180 multi-node, which the project has never done (all prior C180 multi-node
# runs KILLED mpirun at sim-end before the checkpoint). This harness WAITS for the checkpoint instead.
#
# Two distinct failure modes are separated here:
#   Symptom A: status=-35 at NetCDF4_FileFormatter:189 = NC_EEXIST (stale checkpoint + NOCLOBBER) —
#              fixed by overwrite_checkpoint:.true. + deleting the stale file (applied EVERY run below).
#   Symptom B: genuine collective/o-server HANG (ranks State R, no file). This harness bisects the
#              writer config to find one that writes cleanly, then proves it restart-able.
#
# Modes (arg 1):
#   a  : NUM_WRITERS=1, oserver NO, split NO           (baseline: was the "hang" just the -35?)
#   b  : SPLIT_CHECKPOINT+SPLIT_RESTART, NUM_WRITERS=6  (per-writer serial creates; no collective file)
#   c  : WRITE_RESTART_BY_OSERVER YES, NUM_WRITERS=1    (historical partial fix, retested on a clean dir)
#   d  : NUM_WRITERS=6, collective single file          (isolates collective MPI-IO on Lustre)
#   contin : restart-continuation proof for the WINNING config (arg 2 = winning mode a|b|c|d)
#
# Stock GCHP path: uses the decoupled binary with GCHP_USE_REMOTE_CHEM UNSET (== stock code).
# Usage (head node): gchp-fullchem-m9g-checkpoint.sh <a|b|c|d|contin> [win-mode-for-contin]
set -uo pipefail
STACK=/sw
# Prefer a stock binary if present; else the decoupled binary run in stock mode (remote unset).
BIN=/scratch/gchp-instr/GCHP-decoupled/build/bin/gchp
[ -x "$BIN" ] || BIN=/sw/gchp-14.7.1/bin/gchp
[ -x "$BIN" ] || BIN=/sw/gchp
NODES=2; RPN=48; TOTAL=$((NODES*RPN)); CS=180; NX=8; NY=12   # C180 2-node
MODE=${1:-a}
WINMODE=${2:-a}
RUNBASE=/scratch
RUNDIR=$RUNBASE/gchp_fc_ckpt
TAG="c180fc_ckpt_${MODE}"

[ -x "$BIN" ] || { echo "FAIL: no gchp binary"; exit 1; }

# ---- create the fullchem run dir if absent (official createRunDir, non-interactive) ----
if [ ! -f "$RUNDIR/setCommonRunSettings.sh" ]; then
  CRD=$(find /scratch/gchp-instr /scratch/gchp-src -path '*/run/GCHP/createRunDir.sh' 2>/dev/null | head -1)
  [ -n "$CRD" ] || CRD=$(find /sw -path '*/run/GCHP/createRunDir.sh' 2>/dev/null | head -1)
  mkdir -p ~/.geoschem; printf 'export GC_DATA_ROOT=/input\nexport GC_USER_REGISTERED=true\n' > ~/.geoschem/config
  command -v expect >/dev/null || sudo dnf install -y expect >/dev/null 2>&1
  EXP=$(mktemp); cat > "$EXP" <<XPCT
#!/usr/bin/expect -f
set timeout 900
cd [lindex \$argv 0]
spawn ./createRunDir.sh
expect {
  -re "path for ExtData"                     { send "/input\r"; exp_continue }
  -re "Choose simulation type:"              { send "1\r"; exp_continue }
  -re "additional simulation option"         { send "1\r"; exp_continue }
  -re "Choose meteorology source:"           { send "1\r"; exp_continue }
  -re "Enter path where the run directory"   { send "$RUNBASE\r"; exp_continue }
  -re "Enter run directory name"             { send "gchp_fc_ckpt\r"; exp_continue }
  -re "track run directory changes with git" { send "n\r"; exp_continue }
  -re "build the KPP-Standalone Box Model"   { send "n\r"; exp_continue }
  eof
}
XPCT
  expect "$EXP" "$(dirname "$CRD")" > /tmp/crd_ckpt.log 2>&1; rm -f "$EXP"
  [ -f "$RUNDIR/setCommonRunSettings.sh" ] || { echo "FAIL createRunDir"; tail -20 /tmp/crd_ckpt.log; exit 1; }
fi
cd "$RUNDIR"

# ---- GMI symlink-alias overlay (fullchem needs the 5 aliases; /input read-only) ----
GMI_OVL=/scratch/gchp_fc_ckpt_gmi/GMI/v2015-02; mkdir -p "$GMI_OVL"
for f in /input/HEMCO/GMI/v2015-02/gmi.clim.*.nc; do ln -sf "$f" "$GMI_OVL/$(basename "$f")" 2>/dev/null; done
for a in IPMN NPMN RIPA RIPB RIPD; do [ -e "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" ] || aws s3 cp "s3://gchp-shared-storage-us-east-1/gmi-aliases/v2015-02/gmi.clim.$a.geos5.2x25.nc" "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" --region us-east-1 --only-show-errors; done
if [ -L HcoDir ] || [ ! -e HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc ]; then
  rm -f HcoDir; mkdir -p HcoDir/GMI
  for e in /input/HEMCO/*; do [ "$(basename "$e")" = "GMI" ] || ln -sf "$e" "HcoDir/$(basename "$e")"; done
  for v in /input/HEMCO/GMI/*; do bn=$(basename "$v"); if [ "$bn" = "v2015-02" ]; then ln -sf "$GMI_OVL" HcoDir/GMI/v2015-02; else ln -sf "$v" "HcoDir/GMI/$bn"; fi; done
fi

# ---- C180 restart + common layout ----
R=/input/GEOSCHEM_RESTARTS/GC_14.7.0/GEOSChem.Restart.fullchem.20190101_0000z.c180.nc4
mkdir -p Restarts; ln -sf "$R" Restarts/GEOSChem.Restart.20190101_0000z.c180.nc4
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$TOTAL/; s/^NUM_NODES=.*/NUM_NODES=$NODES/; s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/; s/^CS_RES=.*/CS_RES=$CS/; s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/; s/^NX=.*/NX=$NX/; s/^NY=.*/NY=$NY/; s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
sed -i "s/domains_stack_size = [0-9]*/domains_stack_size = 64000000/" input.nml 2>/dev/null || true

# ---- CHECKPOINT-WRITER CONFIG per MODE (this is the bisection knob) ----
# helper: set-or-append a GCHP.rc resource line
setrc(){ local k="$1" v="$2"; if grep -q "^$k" GCHP.rc; then sed -i "s|^$k.*|$k $v|" GCHP.rc; else echo "$k $v" >> GCHP.rc; fi; }
# hygiene applies to ALL modes: overwrite_checkpoint + always delete stale checkpoint(s)
setrc "overwrite_checkpoint:" ".true."
setrc "GCHPchem_INTERNAL_CHECKPOINT_TYPE:" "pnc4"
case "$MODE" in
  a|contin) NW=1; SPLITC=NO;  SPLITR=NO;  OSRV=NO ;;
  b)        NW=6; SPLITC=YES; SPLITR=YES; OSRV=NO ;;
  c)        NW=1; SPLITC=NO;  SPLITR=NO;  OSRV=YES ;;
  d)        NW=6; SPLITC=NO;  SPLITR=NO;  OSRV=NO ;;
  *) echo "FAIL: mode must be a|b|c|d|contin"; exit 1 ;;
esac
# for the continuation proof, inherit the WINNING mode's writer config
if [ "$MODE" = "contin" ]; then
  case "$WINMODE" in
    a) NW=1; SPLITC=NO;  SPLITR=NO;  OSRV=NO ;;
    b) NW=6; SPLITC=YES; SPLITR=YES; OSRV=NO ;;
    c) NW=1; SPLITC=NO;  SPLITR=NO;  OSRV=YES ;;
    d) NW=6; SPLITC=NO;  SPLITR=NO;  OSRV=NO ;;
  esac
fi
setrc "NUM_WRITERS:" "$NW"
setrc "SPLIT_CHECKPOINT:" "$SPLITC"
setrc "SPLIT_RESTART:" "$SPLITR"
setrc "WRITE_RESTART_BY_OSERVER:" "$OSRV"
ln -sf "$BIN" "$RUNDIR/gchp"
echo "[ckpt] MODE=$MODE  NUM_WRITERS=$NW SPLIT_CHECKPOINT=$SPLITC SPLIT_RESTART=$SPLITR OSERVER=$OSRV  bin=$BIN"

# Wall backstop: single-segment write tests fit in 40 min; the 3-segment continuation
# proof (ARM B 40-min sim + ARM A 20+20, each with cold-ish FSx init ~20+ min wall) needs ~2h.
SBTIME="00:40:00"; [ "$MODE" = "contin" ] && SBTIME="02:00:00"

cat > run_$TAG.slurm <<SL
#!/bin/bash
#SBATCH --job-name=$TAG
#SBATCH --partition=compute
#SBATCH --nodes=$NODES
#SBATCH --ntasks=$TOTAL
#SBATCH --ntasks-per-node=$RPN
#SBATCH --time=$SBTIME
#SBATCH --output=slurm-$TAG-%j.log
#SBATCH --exclusive
# NO 'set -e': GCHP 14.7.1 exits with a BENIGN finalization SIGABRT (exit 134) AFTER a good checkpoint
# write. Success = checkpoint file(s) present + cap_restart advanced + process returned, NOT exit code.
# NO 'set -u' either: GCHP's own setCommonRunSettings.sh/checkRunSettings.sh reference optional unset
# positional args (e.g. \$4 in the .rc replace fn at line ~578) and abort under nounset when sourced.
cd "\$SLURM_SUBMIT_DIR"
source $STACK/gchp-env.sh
export PATH="$STACK/libfabric-1.22.0/bin:\$PATH"
export FI_PROVIDER=efa
ulimit -s unlimited 2>/dev/null
# STOCK path: ensure the decoupled remote-chem hook is OFF (this is a GCHP checkpoint test).
unset GCHP_USE_REMOTE_CHEM
# m9g has 768 GB; generous /dev/shm for on-node MAPL windows (fullchem C180 state is large).
srun --ntasks-per-node=1 --ntasks=$NODES sudo mount -o remount,size=550G /dev/shm 2>&1 | tail -1

CKPT_GLOB="Restarts/gcchem_internal_checkpoint*"
ckpt_present(){ ls \$CKPT_GLOB >/dev/null 2>&1; }

RUN() {  # \$1 = duration "DDDDDDDD HHMMSS" ; \$2 = log suffix
  # hygiene: NOCLOBBER + split-create ignores clobber, so DELETE the stale checkpoint every segment.
  rm -f Restarts/gcchem_internal_checkpoint* 2>/dev/null
  sed -i "s/^Run_Duration=.*/Run_Duration=\"\$1\"/" setCommonRunSettings.sh
  source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh
  echo "=== SEG \$2: start=\$(cat cap_restart) dur=\$1 restart=\$(readlink gchp_restart.nc4) NW=$NW SPLITC=$SPLITC OSRV=$OSRV ==="
  mpirun -n $TOTAL --mca mtl_ofi_provider_include efa ./gchp > gchp_${TAG}_\$2.log 2>&1 &
  MPI=\$!
  # WAIT for the checkpoint (bounded by the SBATCH --time backstop); do NOT kill at sim-end.
  local waited=0
  while kill -0 \$MPI 2>/dev/null; do sleep 5; waited=\$((waited+5)); done
  wait \$MPI 2>/dev/null; local rc=\$?
  echo "=== SEG \$2: mpirun returned \$rc after \${waited}s (134=benign finalize abort ok) ==="
  echo "  last GCHP date: \$(grep -a 'GCHP Date' gchp_${TAG}_\$2.log | tail -1 | grep -oE 'Date: [0-9/]+  Time: [0-9:]+')"
  echo "  -35 in log: \$(grep -ac 'status=-35' gchp_${TAG}_\$2.log)   NetCDF4_FileFormatter fails: \$(grep -ac 'NetCDF4_FileFormatter.F90' gchp_${TAG}_\$2.log)"
  if ckpt_present; then
    echo "  CHECKPOINT WRITTEN:"; ls -la \$CKPT_GLOB | sed 's/^/    /'
    echo "  cap_restart=\$(cat cap_restart)"
  else
    echo "  NO CHECKPOINT (hang or fail). tail:"; tail -6 gchp_${TAG}_\$2.log
  fi
}
CHAIN() {  # rename checkpoint(s) -> restart for next segment; handle single AND split (_<rank>) files.
  new=\$(sed 's/ /_/g' cap_restart); stamp=\${new:0:13}
  if ls Restarts/gcchem_internal_checkpoint_* >/dev/null 2>&1; then
    for f in Restarts/gcchem_internal_checkpoint_*; do
      r=\${f##*_}; mv "\$f" "Restarts/GEOSChem.Restart.\${stamp}z.c${CS}.nc4_\${r}"
    done
    echo "=== CHAIN (split): renamed \$(ls Restarts/GEOSChem.Restart.\${stamp}z.c${CS}.nc4_* 2>/dev/null | wc -l) per-writer files; cap=\$(cat cap_restart) ==="
  else
    mv Restarts/gcchem_internal_checkpoint Restarts/GEOSChem.Restart.\${stamp}z.c${CS}.nc4
    echo "=== CHAIN: checkpoint -> GEOSChem.Restart.\${stamp}z.c${CS}.nc4 ; cap=\$(cat cap_restart) ==="
  fi
}

if [ "$MODE" != "contin" ]; then
  # ---- WRITE TEST: single 20-min segment, WAIT for the checkpoint ----
  echo "20190101 000000" > cap_restart
  RUN "00000000 002000" "write"
  if ckpt_present && grep -aq "00:20:00" gchp_${TAG}_write.log; then
    echo "RESULT_CKPT tag=$TAG MODE=$MODE STATUS=PASS files=\$(ls \$CKPT_GLOB 2>/dev/null | wc -l)"
  else
    echo "RESULT_CKPT tag=$TAG MODE=$MODE STATUS=FAIL"
  fi
else
  # ---- RESTART-CONTINUATION PROOF (winning mode=$WINMODE): ARM B cold to 00:40, ARM A warm 20+20 ----
  echo "=== ARM B (cold to 00:40) ==="
  echo "20190101 000000" > cap_restart
  RUN "00000000 004000" "coldB"
  if ckpt_present; then
    if ls Restarts/gcchem_internal_checkpoint_* >/dev/null 2>&1; then
      mkdir -p /scratch/coldB; cp Restarts/gcchem_internal_checkpoint_* /scratch/coldB/
    else cp Restarts/gcchem_internal_checkpoint /scratch/coldB_final.nc4; fi
    echo "  saved ARM B final"
  fi
  echo "=== ARM A (warm: 20min -> chain -> 20min to 00:40) ==="
  echo "20190101 000000" > cap_restart
  RUN "00000000 002000" "warmA_seg1"
  CHAIN
  RUN "00000000 002000" "warmA_seg2"
  # ---- COMPARE warm-final vs cold-final (h5diff -c content compare) ----
  echo "RESULT_CONTIN tag=$TAG winmode=$WINMODE"
  if ls Restarts/gcchem_internal_checkpoint_* >/dev/null 2>&1; then
    # split: compare each per-writer file
    tot=0; diffds=0
    for f in Restarts/gcchem_internal_checkpoint_*; do
      r=\${f##*_}
      h5diff -v2 -c "\$f" "/scratch/coldB/gcchem_internal_checkpoint_\${r}" > /scratch/h5d_\${r}.txt 2>&1 || true
      d=\$(grep -ac 'differences found' /scratch/h5d_\${r}.txt); tot=\$((tot+\$(grep -ac 'dataset:' /scratch/h5d_\${r}.txt))); diffds=\$((diffds+d))
    done
    echo "  SPLIT h5diff: datasets_differing=\$diffds across \$(ls Restarts/gcchem_internal_checkpoint_*|wc -l) writer files"
  else
    h5diff -v2 -c Restarts/gcchem_internal_checkpoint /scratch/coldB_final.nc4 > /scratch/h5d_contin.txt 2>&1 || true
    echo "  datasets compared: \$(grep -ac 'dataset:' /scratch/h5d_contin.txt)  DIFFERING: \$(grep -ac 'differences found' /scratch/h5d_contin.txt)"
    grep -aE 'dataset:|differences found' /scratch/h5d_contin.txt | grep -aB1 'differences found' | head -40
  fi
  warm_last=\$(grep -a 'GCHP Date' gchp_${TAG}_warmA_seg2.log | tail -1 | grep -oE 'Time: [0-9:]+')
  echo "RESULT_CONTIN_DONE tag=$TAG warm_reached=\$warm_last (want 00:40:00)"
fi
SL

JID=$(sbatch --parsable run_$TAG.slurm)
echo "SUBMITTED $TAG job=$JID (MODE=$MODE)"
echo "watch: grep -aE 'RESULT_CKPT|RESULT_CONTIN|SEG .*mpirun|CHECKPOINT|NO CHECKPOINT' $RUNDIR/slurm-$TAG-*.log"
