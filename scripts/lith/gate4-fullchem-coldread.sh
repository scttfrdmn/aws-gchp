#!/bin/bash
# Gate 4 -- the last real gap in the lith /input analysis: does lith's cold
# advantage grow, hold, or invert when the working set goes from C24
# TransportTracers (~4.1 GB, a handful of families) to fullchem (30.2 GiB, 57
# families, 485 objects)?
#
# Everything in the analysis so far is TT. This is head-node only: no MPI, no
# compute nodes, no spend beyond the already-running head node.
#
# MANIFEST comes from gate4-fullchem-manifest.py, which parses an OFFICIAL
# createRunDir.sh fullchem run directory (see mk-fullchem-rundir.expect). Same
# manifest is read through both layers, so any manifest error is common-mode and
# cannot bias the comparison.
#
# ARM ORDER IS DELIBERATE: lith FIRST. The FSx cold arm is ONE-SHOT by physics --
# reading a released file hydrates it permanently, and there is no way to
# un-hydrate without destroying the file system. lith cold, by contrast, is
# repeatable at will (restart the daemon with an empty cache). So lith goes first
# to shake out harness bugs on the repeatable arm, and FSx cold is spent only once
# the harness is known good. Reading through lith does not hydrate FSx: they are
# independent paths, and the only shared state is the page cache, which is dropped
# between arms.
#
# WHAT IS MEASURED
#   * wall time and aggregate throughput for the whole manifest, P readers
#   * how COLD the FSx arm actually was, via `lfs hsm_state` residency before it
#   * lith's S3 GETs / bytes / fills, to compare fetch amplification with gate 3
#   * the C180 restart (13.1 GB single file) separately -- the ONLY
#     resolution-dependent input, and the read pattern that most favours coalescing
set -u -o pipefail

GATES=/scratch/lith-gates
LITHVER=${LITHVER:-1.1.2}
LITH=${GATES}/lith-${LITHVER}
IDX=${GATES}/idx
MANIFEST=${MANIFEST:-${GATES}/fullchem-manifest.tsv}
OUT=${GATES}/gate4-coldread-${LITHVER}.txt
P=${P:-8}                       # concurrent readers, same for both arms
ARMS=${ARMS:-lith,fsx,restart-lith,restart-fsx}
MNT=/mnt/lith-fc
RESTART_KEY=GEOSCHEM_RESTARTS/GC_14.7.0/GEOSChem.Restart.fullchem.20190701_0000z.c180.nc4

exec > >(tee -a "$OUT") 2>&1
echo "### gate4 cold read $(date -u +%FT%TZ) on $(hostname)  lith=${LITHVER} P=${P}"

say() { echo; echo "=== $* ==="; }

# Three prefix-scoped daemons cover the whole manifest: HEMCO (471 objects),
# GEOS_0.5x0.625 (13), CHEM_INPUTS (1). Plus restarts for the C180 arm. Scoped
# rather than one index over all of gcgrid, per the existing gate practice.
declare -a NAME=(hemco   merra2-201907                    cheminp      restarts)
declare -a PFX=(HEMCO    GEOS_0.5x0.625/MERRA2/2019/07    CHEM_INPUTS  GEOSCHEM_RESTARTS)
declare -a SUB=(HEMCO    GEOS_0.5x0.625/MERRA2/2019/07    CHEM_INPUTS  GEOSCHEM_RESTARTS)
declare -a CACHE=(8GB    8GB                              2GB          2GB)
declare -a MPORT=(9310   9311                             9312         9313)

cleanup() {
  for s in "${SUB[@]}"; do sudo umount -f "${MNT}/${s}" 2>/dev/null; done
  pkill -f "[l]ith-${LITHVER} mount" 2>/dev/null
  sleep 2
}
trap cleanup EXIT
cleanup

# ---------------------------------------------------------------- indexes
say "indexes"
for i in "${!NAME[@]}"; do
  f="${IDX}/${NAME[$i]}.lithidx"
  if [ -s "$f" ]; then
    echo "  have  ${NAME[$i]} ($(stat -c %s "$f") B)"
  else
    s=$(date +%s)
    "$LITH" index build "s3://gcgrid/${PFX[$i]}" --no-sign-request \
        --index-file "$f" >/dev/null 2>&1
    echo "  built ${NAME[$i]} in $(( $(date +%s) - s ))s ($(stat -c %s "$f" 2>/dev/null || echo 0) B)"
  fi
done

# ---------------------------------------------------------------- path lists
# The manifest records FSx paths. lith paths are the same keys under the scoped
# mounts, so the two lists are the same objects by construction.
awk -F'\t' '$1!~/^#/ && $4 ~ /^\/input\// {print $4}' "$MANIFEST" > /tmp/g4.fsx
sed 's|^/input/|'"${MNT}"'/|' /tmp/g4.fsx > /tmp/g4.lith
NOBJ=$(wc -l < /tmp/g4.fsx)
NBYTES=$(awk -F'\t' '$1!~/^#/ && $4 ~ /^\/input\// {s+=$3} END{print s}' "$MANIFEST")
echo "  manifest: ${NOBJ} objects, ${NBYTES} bytes ($(awk -v b="$NBYTES" 'BEGIN{printf "%.1f", b/2^30}') GiB)"

metric() { curl -s --max-time 5 "http://localhost:$1/metrics" | awk -v k="$2" 'index($1,k)==1 {print $2; exit}'; }
sum_metric() { local k=$1 t=0 v; for p in "${MPORT[@]}"; do v=$(metric "$p" "$k"); t=$(awk -v a="$t" -v b="${v:-0}" 'BEGIN{print a+b}'); done; echo "$t"; }

# Read every path in a list with P concurrent whole-file reads. Whole-file
# sequential is the honest analogue of "hydrate the working set" -- it is exactly
# what `lfs hsm_restore` does on the FSx side, so the two arms are doing the same
# job. (GCHP's real pattern is hyperslab, which is why gate 3's byte advantage was
# 1.43x and not 9.3x; that is a separate question from this one.)
read_list() {
  local list=$1
  local t0 t1
  t0=$(date +%s.%N)
  # -I{} already implies one argument per invocation; adding -n 1 makes xargs warn
  # about mutually exclusive options on every call.
  xargs -P "$P" -a "$list" -I{} sh -c 'dd if="{}" bs=4M of=/dev/null 2>/dev/null'
  t1=$(date +%s.%N)
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}'
}

# ---------------------------------------------------------------- lith arm
if [[ ",$ARMS," == *,lith,* ]]; then
  say "ARM lith -- cold daemons, ${P} readers"
  for i in 0 1 2; do
    sudo mkdir -p "${MNT}/${SUB[$i]}"
    sudo chown ec2-user:ec2-user "${MNT}/${SUB[$i]}" 2>/dev/null
    setsid nohup "$LITH" mount "s3://gcgrid/${PFX[$i]}" "${MNT}/${SUB[$i]}" \
      --index-file "${IDX}/${NAME[$i]}.lithidx" --no-sign-request \
      --mem-cache "${CACHE[$i]}" --metrics ":${MPORT[$i]}" \
      > "${GATES}/g4-mount-${NAME[$i]}.log" 2>&1 < /dev/null &
  done
  sleep 10
  for i in 0 1 2; do mountpoint -q "${MNT}/${SUB[$i]}" && echo "  mounted ${SUB[$i]}" || echo "  FAIL mount ${SUB[$i]}"; done
  sudo sysctl -q vm.drop_caches=3
  g0=$(sum_metric 'lith_s3_requests_total{op="get",status="ok"}')
  b0=$(sum_metric 'lith_s3_bytes_total')
  WALL_LITH=$(read_list /tmp/g4.lith)
  g1=$(sum_metric 'lith_s3_requests_total{op="get",status="ok"}')
  b1=$(sum_metric 'lith_s3_bytes_total')
  printf 'LITH  wall=%ss  %s MB/s  gets=%s  s3_MB=%s  ampl=%.3fx\n' \
    "$WALL_LITH" \
    "$(awk -v b="$NBYTES" -v t="$WALL_LITH" 'BEGIN{printf "%.1f", b/t/1e6}')" \
    "$(awk -v a="$g0" -v b="$g1" 'BEGIN{print b-a}')" \
    "$(awk -v a="$b0" -v b="$b1" 'BEGIN{printf "%.1f", (b-a)/1e6}')" \
    "$(awk -v a="$b0" -v b="$b1" -v n="$NBYTES" 'BEGIN{print (b-a)/n}')"
fi

# ---------------------------------------------------------------- fsx arm
if [[ ",$ARMS," == *,fsx,* ]]; then
  say "ARM fsx -- ONE-SHOT cold, ${P} readers"
  # Quantify how cold it really is BEFORE spending the one shot. `released` means
  # the content lives only in S3; anything already `archived` without `released`
  # has been hydrated by an earlier run and is NOT cold. Reporting this makes the
  # arm interpretable instead of an assumption.
  echo "  hsm residency before (sample of 60):"
  head -60 /tmp/g4.fsx | while read -r f; do sudo lfs hsm_state "$f" 2>/dev/null; done \
    | grep -oE "released|archived|\(0x0+\)" | sort | uniq -c | sed 's/^/    /'
  sudo sysctl -q vm.drop_caches=3
  WALL_FSX=$(read_list /tmp/g4.fsx)
  printf 'FSX   wall=%ss  %s MB/s\n' "$WALL_FSX" \
    "$(awk -v b="$NBYTES" -v t="$WALL_FSX" 'BEGIN{printf "%.1f", b/t/1e6}')"
fi

# ------------------------------------------------- C180 restart, the one resolution-dependent input
if [[ ",$ARMS," == *,restart-lith,* ]]; then
  say "ARM restart-lith -- C180 fullchem restart (13.1 GB) single stream"
  sudo mkdir -p "${MNT}/${SUB[3]}"; sudo chown ec2-user:ec2-user "${MNT}/${SUB[3]}" 2>/dev/null
  setsid nohup "$LITH" mount "s3://gcgrid/${PFX[3]}" "${MNT}/${SUB[3]}" \
    --index-file "${IDX}/${NAME[3]}.lithidx" --no-sign-request \
    --mem-cache "${CACHE[3]}" --metrics ":${MPORT[3]}" \
    > "${GATES}/g4-mount-restarts.log" 2>&1 < /dev/null &
  sleep 8
  RP="${MNT}/${SUB[3]}/${RESTART_KEY#GEOSCHEM_RESTARTS/}"
  ls -l "$RP" 2>&1 | sed 's/^/  /'
  sudo sysctl -q vm.drop_caches=3
  g0=$(metric "${MPORT[3]}" 'lith_s3_requests_total{op="get",status="ok"}')
  t0=$(date +%s.%N); dd if="$RP" bs=8M of=/dev/null 2>/dev/null; t1=$(date +%s.%N)
  g1=$(metric "${MPORT[3]}" 'lith_s3_requests_total{op="get",status="ok"}')
  sz=$(stat -c %s "$RP")
  printf 'RESTART-LITH  wall=%.2fs  %s MB/s  gets=%s\n' \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" \
    "$(awk -v s="$sz" -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", s/(b-a)/1e6}')" \
    "$(awk -v a="${g0:-0}" -v b="${g1:-0}" 'BEGIN{print b-a}')"
fi

if [[ ",$ARMS," == *,restart-fsx,* ]]; then
  say "ARM restart-fsx -- same file through FSx, ONE-SHOT cold"
  RF=/input/${RESTART_KEY}
  sudo lfs hsm_state "$RF" 2>&1 | sed 's/^/  /'
  sudo sysctl -q vm.drop_caches=3
  t0=$(date +%s.%N); dd if="$RF" bs=8M of=/dev/null 2>/dev/null; t1=$(date +%s.%N)
  sz=$(stat -c %s "$RF")
  printf 'RESTART-FSX   wall=%.2fs  %s MB/s\n' \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" \
    "$(awk -v s="$sz" -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", s/(b-a)/1e6}')"
fi

say "SUMMARY"
grep -E "^(LITH|FSX|RESTART-)" "$OUT" | tail -8
