#!/bin/bash
#SBATCH --job-name=gate3c-fsxcold
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=00:30:00
#SBATCH --output=/scratch/lith-gates/gate3c-fsxcold-%j.log
#
# GATE 3c, part 2 — the paired COLD comparison that part 1 could not produce.
#
# Part 1 got all four runs, but its FSx "cold" arm was not cold: `lfs hsm_release`
# returned 0 files released because the met files are root-owned on /input and HSM
# release needs write access, so it failed with EACCES (13) — and the release loop
# swallowed stderr, so the run reported "released 0 files" without saying why.
# Part 1's FSx numbers are therefore warm-vs-warm on a fully hydrated Lustre,
# which is FSx's best case.
#
# The fix is `sudo`. This job runs the two COLD arms back to back in one
# allocation so they are paired on the same node in the same conditions:
#
#   1  fsx-cold-real   HSM blocks genuinely released first (verified 'released')
#   2  lith-cold-2     fresh mounts, nothing cached
#
# This is the comparison the /input proposal actually turns on: a brand new
# cluster where nobody has pre-hydrated anything. Part 1 already showed the warm
# steady state is a tie (lith 15.94 s vs FSx 16.66 s init).
set -o pipefail

GATES=/scratch/lith-gates
FSX_RUN=/scratch/gchp_merra2_TransportTracers
LITH_RUN=/scratch/gchp_lith_TransportTracers
RANKS=48
NIC=100
RESULTS=${GATES}/gate3c-fsxcold-results.txt
LITH=${GATES}/lith-1.1.1

say() { echo; echo "=== $* ==="; }
stamp() { awk -v t0="$(date +%s.%N)" '{printf "%8.2f  %s\n", systime()-t0, $0; fflush()}'; }
exec > >(tee -a "$RESULTS") 2>&1

say "node facts"
echo "host: $(hostname)  cores: $(nproc)  lith(node): $(lith version 2>&1|head -1)"

# The working set for a C24 1-day TransportTracers run: every MERRA-2 collection
# for 2019-01-01 and 01-02, plus the one date-pinned 2015 constant-field file.
MET_FSX=(/input/GEOS_0.5x0.625/MERRA2/2019/01/MERRA2.2019010[12].*.nc4
         /input/GEOS_0.5x0.625/MERRA2/2015/01/MERRA2.20150101.CN.05x0625.nc4)

say "releasing FSx HSM blocks as root (part 1 failed here with EACCES)"
# Safe and reversible: /input is a read-only S3-backed import, so release frees
# local blocks only — the file stays, and the next read re-fetches it from
# s3://gcgrid, which is the authoritative public RODA copy. Nothing is deleted.
# stderr is NOT discarded this time.
rel=0 tot=0 bytes=0
for f in "${MET_FSX[@]}"; do
  [[ -f "$f" ]] || continue
  tot=$((tot+1)); bytes=$((bytes+$(stat -c %s "$f")))
  if sudo lfs hsm_release "$f"; then rel=$((rel+1)); fi
done
echo "released ${rel}/${tot} files, ${bytes} bytes of working set"
say "HSM state after release (every line MUST say 'released')"
for f in "${MET_FSX[@]}"; do [[ -f "$f" ]] && lfs hsm_state "$f"; done
notrel=$(for f in "${MET_FSX[@]}"; do [[ -f "$f" ]] && lfs hsm_state "$f"; done | grep -vc released)
if [[ "$notrel" -ne 0 ]]; then
  echo "ABORT: ${notrel} file(s) still resident — an FSx-cold measurement is not"
  echo "available, and reporting this run as cold would be wrong. Not spending"
  echo "the rest of the allocation on a number that cannot be labelled."
  exit 1
fi

reset_rundir() { cd "$1" || exit 1; echo "20190101 000000" > cap_restart
                 rm -f Restarts/gcchem_internal_checkpoint* OutputDir/*.nc4 2>/dev/null; }

# Identical to part 1's runner, including the watchdog: GCHP 14.7.1 completes the
# simulation and writes both cap_restart and the checkpoint, then throws
# "double free or corruption (!prev)" in _dl_fini on most ranks and leaves some
# spinning, so waiting on mpirun never returns. Poll for the model's own
# completion evidence, then kill. Unrelated to lith; identical on FSx.
gchp_run() {
  local label="$1" dir="$2" log="${GATES}/gate3c-${1}.log"
  say "RUN ${label}  (${dir})"
  reset_rundir "$dir"
  source /sw/gchp-env.sh
  ulimit -s unlimited 2>/dev/null
  source setCommonRunSettings.sh >/dev/null 2>&1
  source setRestartLink.sh
  source checkRunSettings.sh >/dev/null 2>&1
  local t0 t1 deadline=1800 done_at="" i=0
  t0=$(date +%s.%N)
  mpirun -n "$RANKS" ./gchp 2>&1 | stamp > "$log" &
  local pipe_pid=$!
  while (( i < deadline )); do
    if [[ -s cap_restart ]] && [[ "$(awk '{print $1}' cap_restart)" != "20190101" ]] \
       && [[ -s Restarts/gcchem_internal_checkpoint ]]; then done_at=$(date +%s.%N); break; fi
    kill -0 "$pipe_pid" 2>/dev/null || break
    sleep 1; ((i++))
  done
  t1=${done_at:-$(date +%s.%N)}
  pkill -9 -f "$dir/gchp" 2>/dev/null; kill -9 "$pipe_pid" 2>/dev/null; wait "$pipe_pid" 2>/dev/null
  sleep 2
  local init_s sim_end_s after verdict=FAILED
  init_s=$(grep -m1 "GCHP Date" "$log" | awk '{print $1}')
  sim_end_s=$(grep "GCHP Date" "$log" | tail -1 | awk '{print $1}')
  after=$(awk '{print $1}' cap_restart 2>/dev/null)
  [[ -n "$done_at" ]] && verdict=SUCCEEDED
  printf 'RESULT %-14s init=%ss  sim_end=%ss  to_completion=%.1fs  cap_restart->%s  %s\n' \
    "$label" "${init_s:-NA}" "${sim_end_s:-NA}" \
    "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "${after:-NA}" "$verdict"
}

gchp_run fsx-cold-real "$FSX_RUN"

say "FSx HSM state after the cold run (released blocks should now be resident)"
for f in "${MET_FSX[@]}"; do [[ -f "$f" ]] && lfs hsm_state "$f"; done | sort | uniq -c | head

# ------------------------------------------------- paired lith cold, fresh mounts
say "mounting lith fresh (--nic-gbps ${NIC}, --mem-cache bounded per mount)"
for d in GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
  mkdir -p "/input-lith/${d}"; done
m() { "$LITH" mount "s3://gcgrid/$1" "/input-lith/$1" --index-file "$2" \
        --no-sign-request --nic-gbps $NIC --mem-cache "$3" --metrics ":$4" --daemon; }
m GEOS_0.5x0.625/MERRA2/2019/01 "${GATES}/idx/merra2.lithidx"      32GB 9110
m GEOS_0.5x0.625/MERRA2/2015/01 "${GATES}/idx/merra2-2015.lithidx"  4GB 9111
m HEMCO                         "${GATES}/idx/hemco.lithidx"        8GB 9112
m CHEM_INPUTS                   "${GATES}/idx/cheminp.lithidx"      8GB 9113
m GEOSCHEM_RESTARTS             "${GATES}/idx/restarts.lithidx"     8GB 9114
sleep 5
echo "fuse.lith mounts: $(mount | grep -c fuse.lith)"

gchp_run lith-cold-2 "$LITH_RUN"

say "lith metrics after lith-cold-2"
for pp in 9110:merra2-2019 9111:merra2-2015 9112:hemco 9113:chem-inputs 9114:restarts; do
  echo "-- ${pp##*:} (:${pp%%:*})"
  curl -s --max-time 5 "http://localhost:${pp%%:*}/metrics" \
    | grep -E "^lith_(s3_bytes_total|distinct_bytes_read|cache_misses_total|fill_runs_total|prefetch_(issued|used|uncovered|evicted_unread)_total|sibling_prefetch(_unread)?_total|s3_requests_total|read_straddle_total)" \
    | grep -v bucket
done

for d in GEOS_0.5x0.625/MERRA2/2019/01 GEOS_0.5x0.625/MERRA2/2015/01 HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
  fusermount3 -u "/input-lith/${d}" >/dev/null 2>&1; done

say "done — $RESULTS"
grep "^RESULT" "$RESULTS"
