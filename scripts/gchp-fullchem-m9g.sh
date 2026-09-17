#!/bin/bash
# gchp-fullchem-m9g.sh — run C180 fullchem on m9g.48xl (768 GB Graviton5). STOCK aarch64 binary.
# Goal: the fullchem headline numbers hpc7g couldn't give — memory high-water on 768 GB, throughput,
# and the MAPL component split (CHEM vs ADV vs IO) via MAPL_ENABLE_TIMERS.
#
# Usage (head node): gchp-fullchem-m9g.sh <nodes> [CS=180]
# Prereq handled here: stage the 5 GMI symlink-alias files onto Lustre (read-only /input can't hold
# them) — NPMN/IPMN->PMN, RIPA/RIPB/RIPD->RIP — from our S3 bucket. See gchp_gmi_symlink_aliases.
set -uo pipefail
NODES=${1:-1}; CS=${2:-180}
STACK=/sw
GCHP_BIN=/sw/gchp-14.7.1/bin/gchp           # STOCK validated aarch64 binary from the synced stack
RPN=48                                        # ranks/node: 48 of 192 cores (fullchem is mem+cache heavy;
                                              # match the per-node rank count used elsewhere, leave SMT room)
TOTAL=$((NODES*RPN))
RUNDIR=/scratch/gchp_fc
TAG="c${CS}fc_n${NODES}_m9g"

# ---- locate the stock binary (stack layout may be gchp-14.7.1/bin or just /sw/gchp) ----
[ -x "$GCHP_BIN" ] || GCHP_BIN=/sw/gchp
[ -x "$GCHP_BIN" ] || { echo "FAIL: no gchp binary at /sw/gchp-14.7.1/bin/gchp or /sw/gchp"; exit 1; }

# ---- create the fullchem run dir if absent (official createRunDir, non-interactive) ----
if [ ! -f "$RUNDIR/setCommonRunSettings.sh" ]; then
  CRD=$(find /sw -path '*/run/GCHP/createRunDir.sh' 2>/dev/null | head -1)
  [ -n "$CRD" ] || CRD=$(find /scratch -path '*/run/GCHP/createRunDir.sh' 2>/dev/null | head -1)
  echo "[fc] createRunDir at: ${CRD:-NONE}"
  printf 'export GC_DATA_ROOT=/input\nexport GC_USER_REGISTERED=true\n' > ~/.geoschem/config 2>/dev/null || { mkdir -p ~/.geoschem; printf 'export GC_DATA_ROOT=/input\nexport GC_USER_REGISTERED=true\n' > ~/.geoschem/config; }
  command -v expect >/dev/null || sudo dnf install -y expect >/dev/null 2>&1
  EXP=$(mktemp); cat > "$EXP" <<'XPCT'
#!/usr/bin/expect -f
set timeout 600
cd [lindex $argv 0]
spawn ./createRunDir.sh
expect "Choose simulation type:"  { send "1\r" }
expect -re "additional simulation option|Choose number of species|Select an option" { send "1\r" }
expect "Choose meteorology source:" { send "1\r" }
expect "Enter path where the run directory will be created:" { send "/scratch\r" }
expect "Enter run directory name"  { send "gchp_fc\r" }
expect -re "track run directory changes with git" { send "n\r" }
expect -re "build the KPP-Standalone Box Model" { send "n\r" }
expect eof
XPCT
  expect "$EXP" "$(dirname "$CRD")" >/tmp/crd_fc.log 2>&1; rm -f "$EXP"
  [ -f "$RUNDIR/setCommonRunSettings.sh" ] || { echo "FAIL: createRunDir did not produce $RUNDIR"; tail -25 /tmp/crd_fc.log; exit 1; }
fi

cd "$RUNDIR" || { echo "FAIL: run dir $RUNDIR missing"; exit 1; }

# ---- STAGE THE 5 GMI SYMLINK ALIASES (read-only /input can't hold them) — NO config editing ----
# createRunDir makes HcoDir a symlink -> /input/HEMCO (read-only). Replace it with a REAL directory
# whose entries symlink straight through to /input/HEMCO/* for everything, EXCEPT GMI which points to
# a writable Lustre overlay that has the real GMI files PLUS the 5 alias copies. HEMCO sees a normal
# ./HcoDir tree; no HEMCO_Config.rc surgery, no path rewriting. This is the GCHP-intended layout (the
# aliases simply exist as files, exactly as download_data.py would have left them).
GMI_OVL=/scratch/gchp_fc_gmi/GMI/v2015-02
mkdir -p "$GMI_OVL"
for f in /input/HEMCO/GMI/v2015-02/gmi.clim.*.nc; do ln -sf "$f" "$GMI_OVL/$(basename "$f")" 2>/dev/null; done
for a in IPMN NPMN RIPA RIPB RIPD; do
  [ -e "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" ] || \
    aws s3 cp "s3://gchp-shared-storage-us-east-1/gmi-aliases/v2015-02/gmi.clim.$a.geos5.2x25.nc" \
      "$GMI_OVL/gmi.clim.$a.geos5.2x25.nc" --region us-east-1 --only-show-errors
done
# Rebuild HcoDir as a real dir: every top-level entry of /input/HEMCO symlinked through, but GMI is
# our overlay (with v2015-02 carrying the aliases; other GMI versions pass through from /input).
if [ -L HcoDir ] || [ ! -d HcoDir/GMI/v2015-02 ] || [ ! -e HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc ]; then
  rm -f HcoDir
  mkdir -p HcoDir/GMI
  for e in /input/HEMCO/*; do [ "$(basename "$e")" = "GMI" ] || ln -sf "$e" "HcoDir/$(basename "$e")"; done
  for v in /input/HEMCO/GMI/*; do
    bn=$(basename "$v")
    if [ "$bn" = "v2015-02" ]; then ln -sf "$GMI_OVL" "HcoDir/GMI/v2015-02"; else ln -sf "$v" "HcoDir/GMI/$bn"; fi
  done
fi
echo "[fc] HcoDir rebuilt; GMI aliases present: $(ls HcoDir/GMI/v2015-02/gmi.clim.{IPMN,NPMN,RIPA,RIPB,RIPD}.geos5.2x25.nc 2>/dev/null | wc -l)/5"

# ---- layout (fullchem C180 valid layouts; NY%6=0, CS/NX>=4) ----
if [ "$CS" = "180" ]; then
  case "$TOTAL" in
    48) NX=4; NY=12 ;; 96) NX=8; NY=12 ;; 192) NX=8; NY=24 ;;
    *) echo "FAIL: no preset C180 layout for $TOTAL cores"; exit 1 ;;
  esac
else echo "FAIL: only C180 presets here"; exit 1; fi

echo "20190101 000000" > cap_restart
sed -i "s/^TOTAL_CORES=.*/TOTAL_CORES=${TOTAL}/"             setCommonRunSettings.sh
sed -i "s/^NUM_NODES=.*/NUM_NODES=${NODES}/"                 setCommonRunSettings.sh
sed -i "s/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=${RPN}/" setCommonRunSettings.sh
sed -i "s/^CS_RES=.*/CS_RES=${CS}/"                          setCommonRunSettings.sh
sed -i 's/^Run_Duration=.*/Run_Duration="00000000 020000"/' setCommonRunSettings.sh  # 2h: enough to
                                              # reach steady-state throughput + hit chem; short on $.
sed -i "s/^AutoUpdate_NXNY=.*/AutoUpdate_NXNY=OFF/" setCommonRunSettings.sh
sed -i "s/^NX=.*/NX=${NX}/" setCommonRunSettings.sh
sed -i "s/^NY=.*/NY=${NY}/" setCommonRunSettings.sh
sed -i "s/^Require_Species_in_Restart=.*/Require_Species_in_Restart=0/" setCommonRunSettings.sh
# FMS mpp_domains halo stack: default 20M overflows for C180 at coarse decomposition (48 ranks ->
# big subdomains). The FATAL names the needed size (~32.5M); set 64M with headroom.
sed -i "s/domains_stack_size = [0-9]*/domains_stack_size = 64000000/" input.nml 2>/dev/null || true
# MAPL component report ON (free CHEM/ADV/IO split) + 1-node o-server OFF (per restart findings).
grep -q "MAPL_ENABLE_TIMERS" CAP.rc 2>/dev/null && sed -i "s/^MAPL_ENABLE_TIMERS:.*/MAPL_ENABLE_TIMERS: YES/" CAP.rc || echo "MAPL_ENABLE_TIMERS: YES" >> CAP.rc
sed -i "s/^WRITE_RESTART_BY_OSERVER:.*/WRITE_RESTART_BY_OSERVER: $([ "$NODES" -ge 2 ] && echo YES || echo NO)/" GCHP.rc 2>/dev/null || true
ln -sf "$GCHP_BIN" "$RUNDIR/gchp"
echo "[fc] C${CS} fullchem: ${NODES}n x ${RPN} = ${TOTAL} cores, NX=${NX} NY=${NY}, bin=$GCHP_BIN"

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
cd "\$SLURM_SUBMIT_DIR"
source ${STACK}/gchp-env.sh
export PATH="${STACK}/libfabric-1.22.0/bin:\$PATH"
export FI_PROVIDER=efa
ulimit -s unlimited 2>/dev/null
# libexec exec-bit safety net (S3 sync only chmod'd bin/) — needed for gfortran-built runtime? no, but
# harmless; ensures any helper execs work.
sudo chmod -R +x ${STACK}/gcc-12.2.0/libexec 2>/dev/null || true

source setCommonRunSettings.sh; source setRestartLink.sh; source checkRunSettings.sh

# m9g has 768 GB; give /dev/shm generous room for MAPL on-node windows (fullchem state is large).
srun --ntasks-per-node=1 --ntasks=${NODES} sudo mount -o remount,size=550G /dev/shm 2>&1 | tail -1

echo "=== fullchem C${CS} on m9g: ${NODES}n x ${RPN}, NX=${NX} NY=${NY} ==="
fi_info -p efa 2>&1 | grep -E "provider|fabric" | head -2
RUNLOG=gchp_${TAG}.log
# 2h sim -> end mark at 02:00. Memory high-water printed each step as 'Mem/Swap Used'.
END_MARK="GCHP Date: 2019/01/01  Time: 02:00:00"
GRACE=420

mpirun -n ${TOTAL} --mca mtl_ofi_provider_include efa ./gchp > \${RUNLOG} 2>&1 &
MPI=\$!; ENDSEEN=0; WAITED=0
while kill -0 \$MPI 2>/dev/null; do
  if [ \$ENDSEEN -eq 0 ] && grep -aq "\${END_MARK}" \${RUNLOG} 2>/dev/null; then
     ENDSEEN=1; echo "=== END_MARK seen; finalize grace \${GRACE}s ==="; fi
  if [ \$ENDSEEN -eq 1 ]; then WAITED=\$((WAITED+3)); [ \$WAITED -ge \$GRACE ] && { echo "=== checkpoint grace exceeded; killing ==="; kill -TERM \$MPI 2>/dev/null; sleep 3; kill -KILL \$MPI 2>/dev/null; break; }; fi
  sleep 3
done
wait \$MPI 2>/dev/null

echo "RESULT_FC_MEM tag=${TAG} (memory high-water across run, MB)"
grep -aoE "Mem/Swap Used \(MB\)[^=]*=[ ]*[0-9.E+]+" \${RUNLOG} | grep -oE "[0-9.E+]+\$" | sort -g | tail -3
echo "RESULT_FC_THROUGHPUT tag=${TAG} (final cumulative Avg + last step)"
grep -a "GCHP Date" \${RUNLOG} | tail -1
echo "RESULT_FC_SPLIT tag=${TAG} (MAPL component report — CHEM vs DYNAMICS vs IO)"
grep -aE "Times for|GCHPchem|DYNAMICS|GCHPctmEnv| GCHP |GC_CHEM|DYN_CORE" \${RUNLOG} | tail -30
echo "RESULT_FC_DONE tag=${TAG} endseen=\${ENDSEEN}"
EOF

JID=$(sbatch --parsable "$RUNDIR/run_${TAG}.slurm")
echo "SUBMITTED ${TAG} job=$JID"
