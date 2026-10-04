#!/bin/bash
# GATE 3 (docs/lith-input-layer-analysis.md) — /input read cost, lith vs FSx Lustre.
#
# Measures the two read shapes GCHP/MAPL actually issues against gcgrid met files,
# through the SAME HDF5 1.14.0 that GCHP links, so the access pattern is authentic:
#
#   meta  h5dump -H       walks every dataset's metadata = Finding 1's shape
#                         (224 range GETs / 200 KiB scattered over a 907 MB span).
#                         Near-zero CPU, so wall time here is pure I/O.
#   slab  ./slabread      H5Dread of one variable, one time slice = what ExtData
#                         issues via GriddedIO's collective_prefetch_data, and what
#                         lith#229 improved 92.5x -> 6.3x. Reports open and read
#                         separately plus a checksum of the returned bytes.
#
# NOT h5dump for the slab: h5dump can take the same subset (-d/-s/-c) but burns
# ~12 s of user CPU formatting a 3.3 MB slab, which buries the I/O entirely
# (measured: real 13.64 / user 11.77). slabread costs inflate and nothing else.
#
# Backends:
#   fsx   /input   FSx Lustre, ImportPath s3://gcgrid   <- CONTROL (gate 4)
#   lith  lith v1.1.0 FUSE mount over s3://gcgrid       <- TREATMENT
#
# Cold is honest on both sides:
#   lith cold = fresh mount process (mem cache empty, --disk-cache 0)
#   fsx  cold = file still HSM-released, never touched since ImportPath
# A different day per replicate, so every cold measurement is a real cold
# measurement rather than a re-release.
#
# --nic-gbps is passed explicitly: NIC autodetection fails on ParallelCluster both
# ways (lith#237) and silently clamps parts-max to 4 MiB. Recorded per run because
# it moves the derived settings 16x.
set -uo pipefail

MET_REL="GEOS_0.25x0.3125/GEOS_FP/2019/07"
FSX_DIR="/input/${MET_REL}"
MNT="/scratch/lith-gates/mnt"
IDX="/scratch/lith-gates/idx/met.lithidx"
NIC_GBPS="${NIC_GBPS:-15}"          # c7g.4xlarge baseline; m9g.48xlarge would be 100
# Days 02-04, not 01: the 01 files were touched during setup, so FSx has already
# hydrated them and their cold measurement is void.
DAYS="${DAYS:-02 03 04}"
OUT="${OUT:-/scratch/lith-gates/gate3-results.tsv}"
METRICS_PORT="${METRICS_PORT:-9101}"
SLAB=/scratch/lith-gates/slabread

source /sw/gchp-env.sh >/dev/null 2>&1
H5DUMP=$(command -v h5dump)
LITH_VER=$(lith version 2>&1 | head -1 | tr -d '\r')

# Build slabread if absent. Two relocation quirks of the S3-synced stack:
# the mpicc wrapper has the build-path gcc baked in (OMPI_CC overrides it), and
# gcc's cc1 loses its exec bit in the S3 sync.
if [ ! -x "$SLAB" ]; then
  sudo chmod -R a+x /sw/gcc-12.2.0/libexec/gcc/aarch64-unknown-linux-gnu/12.2.0/ 2>/dev/null
  OPAL_PREFIX=/sw/openmpi-4.1.7 PMIX_PREFIX=/sw/openmpi-4.1.7 OMPI_CC=gcc \
    mpicc -O2 -o "$SLAB" "${SLAB}.c" \
      -I/sw/hdf5-1.14.0/include -L/sw/hdf5-1.14.0/lib -lhdf5 -lz \
      -Wl,-rpath,/sw/hdf5-1.14.0/lib -lm || exit 1
fi

# tag : filename pattern (%s = MMDD) : dataset : start : count
CASES=(
  "A1:GEOSFP.2019%s.A1.025x03125.nc:/ALBEDO:0,0,0:1,721,1152"
  "A3dyn:GEOSFP.2019%s.A3dyn.025x03125.nc:/U:0,0,0,0:1,72,721,1152"
)

now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
mb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN{if(b>0) printf "%.1f", a/b; else print "-"}'; }
# Prometheus renders large counters as 3.145728e+06, which bash arithmetic cannot
# parse, so every counter difference goes through awk.
sub_() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%d", a-b}'; }

snap_metrics() { curl -s "http://localhost:${METRICS_PORT}/metrics" > /tmp/gate3-metrics.txt; }
metric() { awk -v k="$1" '$1==k{v=$2} END{print (v==""?0:v)}' /tmp/gate3-metrics.txt; }

remount_lith() {  # fresh daemon => cold cache and zeroed counters
  fusermount3 -u "$MNT" >/dev/null 2>&1
  for _ in $(seq 20); do
    curl -sf "http://localhost:${METRICS_PORT}/metrics" >/dev/null 2>&1 || break
    sleep 0.5
  done
  rm -rf "${TMPDIR:-/tmp}/lith-cache"
  lith mount "s3://gcgrid/${MET_REL}" "$MNT" \
    --index-file "$IDX" --no-sign-request \
    --nic-gbps "$NIC_GBPS" --metrics ":${METRICS_PORT}" --daemon >/dev/null 2>&1
  for _ in $(seq 40); do
    if curl -sf "http://localhost:${METRICS_PORT}/metrics" >/dev/null 2>&1; then
      snap_metrics
      # zeroed counters prove this is not the previous daemon still shutting down
      [ "$(metric lith_s3_bytes_total)" = "0" ] && return 0
    fi
    sleep 0.5
  done
  echo "FATAL: could not get a fresh lith mount" >&2
  return 1
}

emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$OUT"; }

# One slab measurement: prints "open read cksum"
do_slab() {
  local out
  out=$("$SLAB" "$1" "$2" "$3" "$4" 2>/dev/null) || { echo "- - FAIL"; return; }
  awk '{print $1, $2, $4}' <<< "$out"
}

# One metadata measurement: prints wall seconds
do_meta() {
  local t0 t1
  t0=$(now); "$H5DUMP" -H "$1" >/dev/null 2>&1; t1=$(now)
  elapsed "$t0" "$t1"
}

printf 'backend\tfile\tday\tsize_MB\top\tstate\topen_s\tread_s\ts3_MB\tdistinct_MB\tamp\tcksum\n' > "$OUT"

echo "gate 3 — lith '${LITH_VER}' vs FSx Lustre"
echo "  h5dump=${H5DUMP}  nic-gbps=${NIC_GBPS}  days=${DAYS}"
echo "  results -> $OUT"
echo

for day in $DAYS; do
  for case in "${CASES[@]}"; do
    IFS=':' read -r tag pat dset start count <<< "$case"
    fname=$(printf "$pat" "07${day}")
    fsx_f="${FSX_DIR}/${fname}"
    lith_f="${MNT}/${fname}"

    [ -f "$fsx_f" ] || { echo "skip (absent on FSx): $fname"; continue; }
    size_mb=$(mb "$(stat -c %s "$fsx_f")")
    echo "--- $tag day $day (${size_mb} MB) ---"

    # ---- FSx control: cold (HSM-released), then warm --------------------------
    hsm=$(sudo lfs hsm_state "$fsx_f" 2>/dev/null | sed 's/.*: //')
    fsx_state=cold
    echo "$hsm" | grep -q released || fsx_state=ALREADY-WARM
    read -r o r ck <<< "$(do_slab "$fsx_f" "$dset" "$start" "$count")"
    emit fsx "$tag" "$day" "$size_mb" slab "$fsx_state" "$o" "$r" - - - "$ck"
    echo "  fsx  slab $fsx_state   open=${o}s read=${r}s   hsm=$hsm"

    m=$(do_meta "$fsx_f")
    emit fsx "$tag" "$day" "$size_mb" meta warm - "$m" - - - -
    read -r o r ck <<< "$(do_slab "$fsx_f" "$dset" "$start" "$count")"
    emit fsx "$tag" "$day" "$size_mb" slab warm "$o" "$r" - - - "$ck"
    echo "  fsx  slab warm         open=${o}s read=${r}s   (meta warm ${m}s)"

    # ---- lith cold: one fresh mount, open+read (the primary comparison) ------
    remount_lith || exit 1
    read -r o r ck <<< "$(do_slab "$lith_f" "$dset" "$start" "$count")"
    snap_metrics
    s3=$(metric lith_s3_bytes_total); dist=$(metric lith_distinct_bytes_read)
    emit lith "$tag" "$day" "$size_mb" slab cold "$o" "$r" \
         "$(mb "$s3")" "$(mb "$dist")" "$(ratio "$s3" "$dist")" "$ck"
    echo "  lith slab cold         open=${o}s read=${r}s   s3=$(mb "$s3")MB distinct=$(mb "$dist")MB amp=$(ratio "$s3" "$dist")x"

    # ---- lith warm: repeat on the same mount --------------------------------
    s3_pre=$s3; dist_pre=$dist
    read -r o r ck <<< "$(do_slab "$lith_f" "$dset" "$start" "$count")"
    snap_metrics
    d_s3=$(sub_ "$(metric lith_s3_bytes_total)" "$s3_pre")
    d_dist=$(sub_ "$(metric lith_distinct_bytes_read)" "$dist_pre")
    emit lith "$tag" "$day" "$size_mb" slab warm "$o" "$r" \
         "$(mb "$d_s3")" "$(mb "$d_dist")" "$(ratio "$d_s3" "$d_dist")" "$ck"
    echo "  lith slab warm         open=${o}s read=${r}s   s3=+$(mb "$d_s3")MB"

    # ---- lith cold: the full metadata walk in isolation (Finding 1) ---------
    remount_lith || exit 1
    m=$(do_meta "$lith_f")
    snap_metrics
    s3=$(metric lith_s3_bytes_total); dist=$(metric lith_distinct_bytes_read)
    emit lith "$tag" "$day" "$size_mb" meta cold - "$m" \
         "$(mb "$s3")" "$(mb "$dist")" "$(ratio "$s3" "$dist")" -
    echo "  lith meta cold         ${m}s   s3=$(mb "$s3")MB distinct=$(mb "$dist")MB amp=$(ratio "$s3" "$dist")x"
    echo
  done
done

echo "=== $OUT ==="
column -t -s $'\t' "$OUT"
