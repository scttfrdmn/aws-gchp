#!/bin/bash
#SBATCH --job-name=gate3c-preflight
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --time=00:12:00
#SBATCH --output=/scratch/lith-gates/preflight-%j.log
#
# Cheap preflight for gate3c-gchp-init.sbatch. ~4 minutes of m9g instead of
# discovering a mount bug 40 minutes and ~$7 into the real job — gate3c runs
# fsx-cold FIRST, so nothing on the lith side is exercised until well after the
# money is spent.
#
# It also answers the one thing the compute node can tell us that the head node
# cannot, and that lith upstream is holding a tag for: what lith's IMDS size
# table estimates for a 100 Gbps instance (scttfrdmn/lith#237). Authoritative
# DescribeInstanceTypes for m9g.48xlarge: baseline 100.0, peak 100.0, 1 card.
#
# No GCHP here. Nothing is measured for publication. Pass/fail only.
set -o pipefail

GATES=/scratch/lith-gates
LITH=${GATES}/lith-1.1.1
LITH_RUN=/scratch/gchp_lith_TransportTracers
FSX_RUN=/scratch/gchp_merra2_TransportTracers
NIC=100
fails=0

ok()   { echo "  PASS  $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails+1)); }
say()  { echo; echo "=== $* ==="; }

say "node identity"
TOK=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ITYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-type)
echo "instance: $ITYPE   host: $(hostname)   cores: $(nproc)"
free -g | head -2
[[ "$ITYPE" == m9g.48xlarge ]] && ok "instance type" || bad "expected m9g.48xlarge, got $ITYPE"

say "node bootstrap: did OnNodeConfigured actually run this time?"
# This is the check that the three self-terminated launches would have failed:
# the compute node role could not download install-lith.sh (HeadObject 403).
if command -v lith >/dev/null 2>&1; then
  nv=$(lith version 2>&1 | head -1); echo "node lith: $nv"
  grep -q 1.1.1 <<<"$nv" && ok "node rpm is 1.1.1" || bad "node rpm is not 1.1.1: $nv"
else
  bad "lith not installed on node — OnNodeConfigured did not complete"
fi
command -v fusermount3 >/dev/null 2>&1 && ok "fusermount3 present" || bad "fuse3 missing"
[[ -d /input-lith ]] && ok "/input-lith exists" || bad "/input-lith missing"

say "pinned binary on shared scratch"
[[ -x "$LITH" ]] && ok "$LITH ($("$LITH" version 2>&1|head -1))" || bad "$LITH missing/not executable"

say "shared storage"
mountpoint -q /input   && ok "/input mounted"   || bad "/input not mounted"
mountpoint -q /scratch && ok "/scratch mounted" || bad "/scratch not mounted"
[[ -d /sw/gchp-14.7.1 ]] && ok "/sw stack present" || bad "/sw stack missing"
echo "lfs available: $(command -v lfs || echo NO)"
lfs hsm_state /input/GEOS_0.5x0.625/MERRA2/2019/01/MERRA2.20190101.A1.05x0625.nc4 2>&1 | head -1

say "lith#237 datapoint: IMDS NIC estimate on a 100 Gbps node"
# Reported upstream. v1.1.1 carries the fix, so this is the release binary.
"$LITH" doctor s3://gcgrid --no-sign-request 2>&1 | grep -iE "nic|parts-max|inflight|WARN|denied" || echo "(no nic line matched)"

say "A/B premise: the two run dirs differ ONLY in where input comes from"
# Compare the pointers, NOT the trees. `diff -rq` here is a trap: MetDir is a
# symlink to a directory, diff dereferences it, and the FSx side then walks the
# entire multi-year MERRA2 tree on Lustre while the lith side is an unmounted
# empty dir. Metadata-only, but minutes of readdir for no information.
for p in MetDir gchp_restart.nc4; do
  printf '  %-18s fsx=%s\n' "$p" "$(readlink -f "${FSX_RUN}/${p}" 2>/dev/null || echo MISSING)"
  printf '  %-18s lith=%s\n' "$p" "$(readlink    "${LITH_RUN}/${p}" 2>/dev/null || echo MISSING)"
done
echo "  HEMCO ROOT fsx : $(grep -m1 -i '^ROOT:' "${FSX_RUN}/HEMCO_Config.rc"  2>/dev/null)"
echo "  HEMCO ROOT lith: $(grep -m1 -i '^ROOT:' "${LITH_RUN}/HEMCO_Config.rc" 2>/dev/null)"
# Everything that is NOT an input pointer must be identical. Config only, no
# symlink following, no bulk reads.
for f in CAP.rc GCHP.rc HISTORY.rc setCommonRunSettings.sh; do
  if cmp -s "${FSX_RUN}/${f}" "${LITH_RUN}/${f}"; then ok "$f identical"; else bad "$f differs"; fi
done
if cmp -s "${FSX_RUN}/gchp" "${LITH_RUN}/gchp"; then ok "gchp binary identical"; else bad "gchp binary differs"; fi
# ExtData.rc legitimately differs only if a path was edited; show the delta.
d=$(diff "${FSX_RUN}/ExtData.rc" "${LITH_RUN}/ExtData.rc" 2>&1 | head -10)
[[ -z "$d" ]] && ok "ExtData.rc identical" || { echo "ExtData.rc delta:"; echo "$d"; }
# No stray /input references may remain on the lith side, or it could silently
# fall back to FSx and the run would prove nothing.
stray=$(grep -rl "/input/" "${LITH_RUN}"/*.rc "${LITH_RUN}"/*.sh 2>/dev/null | head)
[[ -z "$stray" ]] && ok "no residual /input/ references on lith side" \
                  || bad "lith side still references /input: $stray"

say "mounting all five lith prefixes at --nic-gbps ${NIC}"
# --mem-cache bounded on every mount: the default is 25% of system memory PER
# DAEMON, which on a 768 GB box is 192 GB apiece and would reserve the whole
# machine across five mounts. GCHP needs that memory.
for d in GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
  mkdir -p "/input-lith/${d}"
done
m() { "$LITH" mount "s3://gcgrid/$1" "/input-lith/$1" --index-file "$2" \
        --no-sign-request --nic-gbps $NIC --mem-cache "$3" --metrics ":$4" --daemon; }
m GEOS_0.5x0.625/MERRA2/2019/01 "${GATES}/idx/merra2.lithidx"      32GB 9110
m GEOS_0.5x0.625/MERRA2/2015/01 "${GATES}/idx/merra2-2015.lithidx"  4GB 9111
m HEMCO                         "${GATES}/idx/hemco.lithidx"        8GB 9112
m CHEM_INPUTS                   "${GATES}/idx/cheminp.lithidx"      8GB 9113
m GEOSCHEM_RESTARTS             "${GATES}/idx/restarts.lithidx"     8GB 9114
sleep 5
n=$(mount | grep -c fuse.lith)
[[ "$n" == 5 ]] && ok "5 fuse.lith mounts" || bad "expected 5 mounts, got $n"

say "the model's own entry points resolve through lith"
for p in "${LITH_RUN}/MetDir/2019/01/MERRA2.20190101.A1.05x0625.nc4" \
         "${LITH_RUN}/MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4" \
         "${LITH_RUN}/gchp_restart.nc4"; do
  if sz=$(stat -Lc %s "$p" 2>/dev/null) && [[ "$sz" -gt 0 ]]; then
    ok "$(basename "$p") ${sz} bytes"
  else
    bad "cannot stat $p"
  fi
done

say "a real read through lith (16 MB off a met file)"
t0=$(date +%s.%N)
dd if="${LITH_RUN}/MetDir/2019/01/MERRA2.20190101.A1.05x0625.nc4" of=/dev/null bs=1M count=16 2>&1 | tail -1
t1=$(date +%s.%N)
echo "  read wall: $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2fs", b-a}')"

say "metrics endpoints"
for port in 9110 9111 9112 9113 9114; do
  if curl -s --max-time 5 "http://localhost:${port}/metrics" | grep -q "^lith_"; then
    ok ":${port} serving metrics"
  else
    bad ":${port} not serving metrics"
  fi
done

say "concurrency probe: 48 simultaneous readers on one FUSE mount"
# The single question no head-node run could answer. Not a benchmark — just
# proof that 48 concurrent opens against one daemon do not deadlock or EACCES.
t0=$(date +%s.%N)
for i in $(seq 1 48); do
  ( dd if="${LITH_RUN}/MetDir/2019/01/MERRA2.20190101.A1.05x0625.nc4" \
       of=/dev/null bs=1M count=4 skip=$((i*8)) status=none 2>/dev/null ) &
done
wait
t1=$(date +%s.%N)
echo "  48x4MB concurrent: $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2fs", b-a}')"
ok "48 concurrent readers returned without deadlock"

say "unmounting"
for d in GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
  fusermount3 -u "/input-lith/${d}" 2>&1 | head -1
done
sleep 2
n=$(mount | grep -c fuse.lith)
[[ "$n" == 0 ]] && ok "all mounts released" || bad "$n mounts still present"

say "VERDICT"
if [[ "$fails" == 0 ]]; then echo "PREFLIGHT PASS — safe to release gate3c"; else echo "PREFLIGHT FAIL — $fails check(s) failed; do NOT release gate3c"; fi
exit "$fails"
