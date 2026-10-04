#!/bin/bash
# gchp-phase1a-verify.sh — Decoupled-Chemistry Phase 1a byte-identity gate.
#
# Proves the offline kpp_worker reproduces fullchem's in-process DECOUPLED_CHEM
# solve BYTE-IDENTICALLY. Steps:
#   1. Set up a C24 fullchem MERRA-2 run dir (1 node) using the decoupled binary.
#   2. Run it with GCHP_DUMP_CHEM set -> fullchem dumps, per gathering rank:
#        chemdump_input_<pid>.bin   (header + ATOL/RTOL + C_1D/RCONST_1D/ICNTRL_1D/RCNTRL_1D)
#        chemdump_golden_<pid>.bin  (fullchem-solved C_1D)
#   3. Run kpp_worker on one input dump -> worker_out.bin (worker-solved C_1D).
#   4. GATE: md5/cmp of the C_1D payload in worker_out.bin vs chemdump_golden_<pid>.bin.
#
# Run on the head node. Assumes the decoupled+worker binaries are built at
# /scratch/gchp-instr/GCHP-decoupled/build/bin/{gchp,kpp_worker}.
set -uo pipefail
STACK=/sw
BK=decoupled
BIN=/scratch/gchp-instr/GCHP-$BK/build/bin/gchp
WORKER=/scratch/gchp-instr/GCHP-$BK/build/bin/kpp_worker
RUNDIR=/scratch/gchp_c24_p1a
DUMPDIR=/scratch/p1a_dump
NX=2; NY=6; RPN=12; TOTAL=12          # C24 1-node

# ---- compare mode: run the worker on one dump + byte-compare vs golden ----
if [ "${1:-}" = "compare" ]; then
  source $STACK/gchp-env.sh 2>/dev/null
  # pick the input dump with the MOST cells (the rank that gathered the biggest
  # subdomain) for the strongest test; its golden shares the same <pid>.
  IN=$(ls -S "$DUMPDIR"/chemdump_input_*.bin 2>/dev/null | head -1)
  [ -n "$IN" ] || { echo "FAIL: no input dumps in $DUMPDIR (did the run set GCHP_DUMP_CHEM + finish?)"; exit 1; }
  PID=$(echo "$IN" | sed -E 's/.*chemdump_input_([0-9]+)\.bin/\1/')
  GOLD="$DUMPDIR/chemdump_golden_${PID}.bin"
  [ -f "$GOLD" ] || { echo "FAIL: golden $GOLD missing for pid $PID"; exit 1; }
  OUT="$DUMPDIR/worker_out_${PID}.bin"
  echo "=== running kpp_worker on pid=$PID input ==="
  "$WORKER" "$IN" "$OUT" || { echo "FAIL: kpp_worker errored"; exit 2; }
  echo "=== GATE: byte-compare worker C_1D vs fullchem golden C_1D ==="
  # both files start with (NSPEC,NCELL) int header then C_1D stream — identical layout.
  echo "  worker md5: $(md5sum "$OUT"  | awk '{print $1}')"
  echo "  golden md5: $(md5sum "$GOLD" | awk '{print $1}')"
  if cmp -s "$OUT" "$GOLD"; then
     echo ">>> PHASE1A PASS: worker output is BYTE-IDENTICAL to fullchem golden (pid=$PID)"
     exit 0
  else
     echo ">>> PHASE1A DIFFER: files differ — investigating first diff offset:"
     cmp "$OUT" "$GOLD" 2>&1 | head -2
     echo "    (bisect: RTOL? ICNTRL(15)? FIX species? autoreduce flag? retry path?)"
     exit 3
  fi
fi

[ -x "$BIN" ]    || { echo "FAIL: no decoupled gchp at $BIN"; exit 1; }
[ -x "$WORKER" ] || { echo "FAIL: no kpp_worker at $WORKER"; exit 1; }
mkdir -p "$DUMPDIR"; rm -f "$DUMPDIR"/*.bin

# ---- run dir (createRunDir C24 fullchem MERRA-2) ----
if [ ! -f "$RUNDIR/setCommonRunSettings.sh" ]; then
  CRD=$(find /scratch/gchp-instr/GCHP-$BK -path "*/run/GCHP/createRunDir.sh" 2>/dev/null | head -1)
  mkdir -p ~/.geoschem; printf 'export GC_DATA_ROOT=/input\nexport GC_USER_REGISTERED=true\n' > ~/.geoschem/config
  command -v expect >/dev/null || sudo dnf install -y expect >/dev/null 2>&1
  EXP=$(mktemp); cat > "$EXP" <<XPCT
#!/usr/bin/expect -f
# Prompt sequence for GCHP fullchem + MERRA-2 (verified from createRunDir.sh):
# sim-type -> additional-option -> met-source -> [ExtData path if ~/.geoschem
# unset] -> run-dir path -> run-dir name -> git? -> KPP-standalone?
# There is NO horizontal-resolution prompt here (resolution is set later in
# setCommonRunSettings.sh). Use a robust dispatch loop keyed on prompt text.
set timeout 900
cd [lindex \$argv 0]
spawn ./createRunDir.sh
expect {
  -re "path for ExtData"                  { send "/input\r"; exp_continue }
  -re "Choose simulation type:"           { send "1\r"; exp_continue }
  -re "additional simulation option"      { send "1\r"; exp_continue }
  -re "Choose meteorology source:"        { send "1\r"; exp_continue }
  -re "Enter path where the run directory" { send "/scratch\r"; exp_continue }
  -re "Enter run directory name"          { send "gchp_c24_p1a\r"; exp_continue }
  -re "track run directory changes with git" { send "n\r"; exp_continue }
  -re "build the KPP-Standalone Box Model"   { send "n\r"; exp_continue }
  eof
}
XPCT
  expect "$EXP" "$(dirname "$CRD")" > /tmp/crd_p1a.log 2>&1; rm -f "$EXP"
  [ -f "$RUNDIR/setCommonRunSettings.sh" ] || { echo "FAIL createRunDir"; tail -20 /tmp/crd_p1a.log; exit 1; }
fi
cd "$RUNDIR"

# ---- GMI aliases overlay (fullchem needs them; /input read-only) ----
GMI_OVL=/scratch/gmi_ovl/GMI/v2015-02; mkdir -p "$GMI_OVL"
for f in /input/HEMCO/GMI/v2015-02/gmi.clim.*.nc; do ln -sf "$f" "$GMI_OVL/$(basename "$f")" 2>/dev/null; done
for a in IPMN NPMN RIPA RIPB RIPD; do [ -e "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" ] || aws s3 cp "s3://gchp-shared-storage-us-east-1/gmi-aliases/v2015-02/gmi.clim.$a.geos5.2x25.nc" "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" --region us-east-1 --only-show-errors; done
if [ -L HcoDir ] || [ ! -e HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc ]; then
  rm -f HcoDir; mkdir -p HcoDir/GMI
  for e in /input/HEMCO/*; do [ "$(basename "$e")" = "GMI" ] || ln -sf "$e" "HcoDir/$(basename "$e")"; done
  for v in /input/HEMCO/GMI/*; do bn=$(basename "$v"); if [ "$bn" = "v2015-02" ]; then ln -sf "$GMI_OVL" HcoDir/GMI/v2015-02; else ln -sf "$v" "HcoDir/GMI/$bn"; fi; done
fi

# ---- settings: C24 fullchem, 1 node, SHORT (1 chem step is enough to dump), o-server OFF ----
R=/input/GEOSCHEM_RESTARTS/GC_14.7.0/GEOSChem.Restart.fullchem.20190101_0000z.c24.nc4
mkdir -p Restarts; ln -sf "$R" Restarts/GEOSChem.Restart.20190101_0000z.c24.nc4
echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=$TOTAL/; s/^NUM_NODES=.*/NUM_NODES=1/; s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=$RPN/; s/^CS_RES=.*/CS_RES=24/; s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/; s/^NX=.*/NX=$NX/; s/^NY=.*/NY=$NY/; s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
sed -i 's/^Run_Duration=.*/Run_Duration="00000000 001000"/' setCommonRunSettings.sh   # 10 min = 1 chem step
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: NO/" GCHP.rc 2>/dev/null || true
sed -i "s/domains_stack_size = [0-9]*/domains_stack_size = 64000000/" input.nml 2>/dev/null || true
ln -sf "$BIN" "$RUNDIR/gchp"

cat > run_p1a.slurm <<SL
#!/bin/bash
#SBATCH --job-name=c24p1a
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=$TOTAL
#SBATCH --ntasks-per-node=$RPN
#SBATCH --time=00:30:00
#SBATCH --output=slurm-c24p1a-%j.log
#SBATCH --exclusive
cd "\$SLURM_SUBMIT_DIR"
source $STACK/gchp-env.sh
export FI_PROVIDER=efa
export GCHP_DUMP_CHEM=$DUMPDIR       # <-- turns the (default-off) dump ON
ulimit -s unlimited 2>/dev/null
source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh
srun --ntasks-per-node=1 --ntasks=1 sudo mount -o remount,size=32G /dev/shm 2>&1 | tail -1
mpirun -n $TOTAL --mca mtl_ofi_provider_include efa ./gchp > gchp_c24p1a.log 2>&1
echo "RUN_DONE exit=\$?"
ls -la $DUMPDIR/*.bin 2>/dev/null
SL
JID=$(sbatch --parsable run_p1a.slurm)
echo "SUBMITTED c24_p1a job=$JID  (dumps -> $DUMPDIR)"
echo "After it finishes, run the compare step:  bash $0 compare"
