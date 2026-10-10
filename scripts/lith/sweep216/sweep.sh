#!/bin/bash
# lith#216 re-sweep harness (5f-P25). One cold, fresh mount per shape x rep; simultaneous light lith-s3bench control.
G=/scratch/lith-gates; S=/scratch/sweep; B=${B:-$G/v1120/lith_linux_arm64}; S3B=$G/lith-s3bench-385
PY=/scratch/sweepenv/bin/python; OUT=${OUT:-$S/out}; MNT=/scratch/mnt/sweep; NIC=${NIC:-15}; PORT=14000
mkdir -p "$OUT" "$MNT"
spec() {  # spec SHAPE -> "prefix|signflag|indexfile"
  case $1 in
    grib_idx|concurrent_handles) echo "s3://noaa-gfs-bdp-pds/gfs.20261009/00/atmos|--no-sign-request|" ;;
    netcdf4_hyperslab)           echo "s3://noaa-goes19/ABI-L2-CMIPF/2026/281/00|--no-sign-request|" ;;
    mmap_random)                 echo "s3://1000genomes/technical/reference|--no-sign-request|" ;;
    kerchunk_scan|kerchunk_read) echo "s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07|--no-sign-request|$G/idx/merra2-201907.lithidx" ;;
    hemco_timeslice)             echo "s3://gcgrid/HEMCO|--no-sign-request|$G/idx/hemco.lithidx" ;;
    *)                           echo "s3://gchp-shared-storage-us-east-1/lith-sweep||" ;;   # staged, signed
  esac; }
row() {  # row SHAPE REP
  local sh=$1 rep=$2 tag="$1-$2"; PORT=$((PORT + 1)); IFS='|' read -r pre sign idx <<< "$(spec "$sh")"
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  local ix=(); [ -n "$idx" ] && ix=(--index-file "$idx")
  "$B" mount "$pre" "$MNT" --metrics ":$PORT" --nic-gbps "$NIC" --log-level warn $sign "${ix[@]}" \
      --pf-trace "$OUT/$tag.trace.csv" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 120); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED: $(tail -2 "$OUT/$tag.mount.log")"; return 1; }
  curl -s "localhost:$PORT/metrics" > "$OUT/$tag.pre.prom"; date -u +%FT%TZ > "$OUT/$tag.utc"
  "$S3B" -bucket gcgrid -keys GEOS_0.5x0.625/MERRA2/2019/07/MERRA2.20190710.A3dyn.05x0625.nc4 -workers 4 -part 65536 \
      -warmup 1s -warmup-workers 4 -duration 3s > "$OUT/$tag.ctl.txt" 2>&1 & local cp=$!
  "$PY" "$S/shapes.py" "$sh" "$MNT" > "$OUT/$tag.tool.json" 2> "$OUT/$tag.tool.err"
  sleep 1; curl -s "localhost:$PORT/metrics" > "$OUT/$tag.post.prom"; wait $cp
  fusermount3 -u "$MNT"; for _ in $(seq 1 40); do mountpoint -q "$MNT" || break; sleep 0.5; done
  "$PY" "$S/summarize.py" "$OUT" "$tag" "$sh" "$rep" >> "$OUT/rows.csv"; tail -1 "$OUT/rows.csv"; }
SHAPES=${SHAPES:-"grib_idx netcdf4_hyperslab mmap_random concurrent_handles cog_overview_window fits_header_cutout webdataset_stream zip_seek_to_end tinyfiles_random sqlite_random kerchunk_scan kerchunk_read hemco_timeslice"}
echo "=== 5f-P25 sweep $(date -u +%FT%TZ) lith=$(md5sum "$B" | cut -c1-12) nic=$NIC"
"$PY" "$S/summarize.py" --header > "$OUT/rows.csv"
for rep in ${REPS:-1 2}; do for sh in $SHAPES; do row "$sh" "$rep"; done; done
echo "=== done $(date -u +%FT%TZ)"
