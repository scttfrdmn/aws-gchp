#!/bin/bash
#SBATCH --job-name=gate5b-hemco-arms
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=01:30:00
#SBATCH --output=/scratch/lith-gates/gate5b-%j.log
#
# GATE 5b — WHICH lith mechanism whole-fetches HEMCO's 13 MB files? (scttfrdmn/lith#256)
#
# Gate 5 found fullchem byte-identical over lith AND found HEMCO amplifying 2.46x
# (9086.9 MB from S3 for a 3698.2 MB distinct set) against 1.21x on the met mount in
# the same job, with a prefetch hit rate of 783 used / 4750 issued / 7260 uncovered.
# Upstream's source analysis (#256): on a ~13 MB file the #229 coverage gate cannot
# discriminate -- a rank's own subdomain reads tile a span that IS most of the file --
# so the handle establishes and the window jumps straight to maxReadahead, which is
# NIC-derived and therefore many GB on a fat pipe. Whole file, every file, every step.
#
# TWO CANDIDATE MECHANISMS, NOT ONE. `lith doctor` resolves --parts-max (default
# "auto" = NIC baseline x first-byte latency) to 64 MiB at --nic-gbps 50 and 35 MiB at
# 7.5 -- BOTH far above a 13 MB file. So parts-max ALONE whole-fetches every HEMCO
# object on first read, independently of establishment or the readahead window. That
# also means upstream's proposed --nic-gbps 7.5 vs 50 arm CANNOT DISCRIMINATE: both
# rungs whole-fetch, so it would return flat and be misread as a refutation. Worse,
# --nic-gbps moves four things at once (inflight-bytes, the window, parts-max,
# coalesce-gap).
#
# So: cross the FILE-SIZE boundary with the direct knobs, one variable at a time.
#
#   A  defaults                            baseline on v1.1.3
#   B  --parts-max 0                       kills whole-file-on-first-read
#   C  --parts-max 0 --max-readahead 4     + caps the established window (see CORRECTION)
#   D  --parts-max 0 --max-readahead 1     the GENUINELY sub-file window: 1 x 8 MiB < 13 MB
#   E  D + --small-file 0                  kills the THIRD whole-file path (see below)
#
# CORRECTION to arm C, from upstream and verified against `lith mount --help`:
# --max-readahead is "max sequential readahead window IN BLOCKS" and --block-size
# defaults to 8MiB, so --max-readahead 4 = 32 MiB -- still ~2.5x a 13 MB file, NOT the
# "4 MiB << 13 MB" the first version of this header claimed. Arm C therefore never
# tested a sub-file window at all, and whatever it saved came from HEMCO's LARGER
# members. Arm D (1 block = 8 MiB) is the real sub-file rung.
#
# THE THIRD WHOLE-FILE PATH, which neither of us named: --small-file defaults to 4MiB
# and fetches files at or below that size whole on first read. `--parts-max 0` does not
# disable it -- it is a separate flag with its own threshold -- so on every arm so far,
# every HEMCO file <=4 MiB was whole-fetched regardless of establishment, window or
# parts-max. Arm E sets --small-file 0 to find out what that path is worth.
#
#   B collapses            -> parts-max is the mechanism
#   B flat, C collapses    -> the established window is, as upstream argued
#   both flat              -> neither; look at demand-read straddle (3062 on HEMCO)
#
# ---------------------------------------------------------------------------------
# GATE 5c — ARMS F0/F/G: does bounding the window BY EVIDENCE fix the PRECISION?
#
# A-E answered a different question than they were asked. Shrinking the window 4x
# (C 32 MiB -> D 8 MiB) cut bad-prefetch VOLUME almost linearly (4086 -> 2044 MB) and
# left the HIT RATE untouched (13.0% -> 13.3%, against met's 80%). So size is not the
# defect; PRECISION is, and ~2.0 GB of A's 5317 MB waste survives the MINIMUM window
# with all three whole-file paths disabled. That residue needs state that outlives a
# handle, because lith constructs one prefetcher per Open (fuse/fs.go:562) and every one
# of ~2400-4600 decisions is therefore made cold.
#
# lith PR #259 is upstream's answer: --readahead-evidence-ratio k bounds a committed
# window to k x the bytes the handle has actually read, applied at establishment, at
# window growth AND at re-establishment. It does not need cross-handle memory, because
# the evidence a handle has accrued IS its own history. Off by default.
#
#   F0 PR binary, flag UNSET               must reproduce arm A
#   F  PR binary, --readahead-evidence-ratio 8    upstream's requested rung
#   G  PR binary, --readahead-evidence-ratio 32   sensitivity to k
#
# F0 IS NOT CEREMONY. The PR sits on main (merge-base = 24b151f), which is v1.1.3 plus
# #257 and #258 -- and #258 touched internal/fuse/fs.go. Without F0, a moved number in F
# cannot be attributed to the flag rather than to the 14 commits' worth of binary it
# arrived in. F0 also proves "off by default" is actually inert, which is the claim the
# PR makes in its own title.
#
# Everything else in F0/F/G is arm A's configuration: --parts-max, --small-file and
# --max-readahead are all left at their defaults, on upstream's instruction, because the
# gate is meant to REPLACE window tuning rather than stack on top of it. And the four
# control mounts keep running the RELEASED v1.1.3 binary, so met's 1.210x stays
# comparable to arms A-E instead of moving for two reasons at once.
#
# The assertion order is upstream's, not mine: (1) does used/issued move off 13%?
# (2) does met stay at 1.210x? (3) checkpoint md5. Amplification is the headline but the
# hit rate is the mechanism, and a fall in amplification with a FLAT hit rate would mean
# #259 is just another volume cap wearing a new name.
#
# ---------------------------------------------------------------------------------
# GATE 5d — ARMS H0/H/I/J: cap the OSCILLATION instead of the window (lith PR #260)
#
# 5c's answer was that #259 is a volume cap: it cut issued 45% and used 53%, so the hit
# rate FELL (16.7% -> 14.3%). #259 merged on that framing. PR #260 is hypothesis 4, and
# it acts on the one signal that has been constant through all eight arms:
# prefetch_reset_random_total is 307-332 on HEMCO in EVERY arm against 113 on met. The
# detector notices the jump ~320 times a run and then forgets, because a history of
# failed predictions costs nothing.
#
#   --readahead-reestablish-max N   after a handle has lost establishment N times, stop
#                                   re-establishing it: contiguous progress is still
#                                   recognized, reads still served, nothing more committed
#
#   H0  PR #260 binary, flag unset                 must reproduce A/F0
#   H   --readahead-reestablish-max 2   (HEMCO)     upstream's requested rung
#   I   --readahead-reestablish-max 4   (HEMCO)     is the allowance a knob or a threshold?
#   J   --readahead-reestablish-max 2   (MET)       upstream's own named RISK, measured
#
# ARM J IS THE ONE UPSTREAM DID NOT ASK FOR AND SHOULD HAVE. They named the risk
# themselves: a legitimate MULTI-PASS reader -- one that reads a file in several separate
# sequential sweeps -- does de-establish between sweeps and would be capped, losing
# readahead it should have had. met is exactly that reader (80% hit rate, 1.210x, and
# still 113 de-establishments), so capping HEMCO leaves the risk untested: in arms H and
# I, met is uncapped and therefore cannot show it. Arm J caps MET and leaves HEMCO at
# defaults, which inverts the control -- HEMCO becomes the thing that must not move -- and
# turns "if it moves at all, the cap is catching something it shouldn't" into a
# measurement instead of a hope. Upstream offered this as an ALTERNATIVE first rung; it is
# cheaper to run it as a FOURTH arm than to choose.
#
# H0 EARNS ITS PLACE TWICE. #259 is now merged, so main -- and therefore this PR's
# binary -- is a different binary again (merge-base 41322f4 = the #259 merge). H0 both
# re-proves inertness on the new release line and, because cap 0 still COUNTS
# oscillation as a diagnostic, hands back the unsuppressed deestablished_total histogram
# that arms H/I/J are measured against.
#
# PRE-REGISTERED, BEFORE THE ARMS RAN, from the gate-4 manifest at #260's own size_class
# boundaries -- 471 HEMCO objects:
#     <=4MiB    134 files (28.5%)    180.2 MB ( 0.7%)
#     4-16MiB   100 files (21.2%)    788.9 MB ( 3.0%)
#     16-64MiB   73 files (15.5%)   2542.9 MB ( 9.7%)
#     >64MiB    164 files (34.8%)  22627.4 MB (86.6%)
# Upstream predicts deestablished_total ~300+ CONCENTRATED in >64MiB. The null to beat is
# NOT zero: if de-establishment were uniform per open, >64MiB would take ~34.8% of the
# count on file mix alone. "Concentrated" therefore has to mean materially more than 35%,
# and that threshold is fixed here in advance so it cannot be adjusted afterwards.
#
# HYPOTHESIS 2 (prefetch-induced eviction) IS ALREADY EXCLUDED and is not an arm here:
# the HEMCO mount ran --mem-cache 32GB against 9.1 GB ever fetched, so there was never
# capacity pressure. I had reported 8GB to upstream; that was my misreading of my own
# harness (8GB is gate 3c's value) and is corrected on #256.
#
# ONLY THE HEMCO MOUNT CHANGES. Met, restart, CHEM_INPUTS and the 2015 CN mount keep
# gate 5's flags in every arm, so they are in-run controls: if met's 1.21x moves, the
# arm changed something it was not supposed to.
#
# CORRECTNESS IS STILL GATED, IN EVERY ARM. Each arm's checkpoint md5 is compared to
# gate 5's banked f3dd15b2191bbce63dadcbfc100196a6. A fetch-policy flag must not
# change the bytes the model reads; if one does, that is a far bigger finding than the
# amplification question and the arm table is the least of it.
#
# NOTE: deliberately NOT `set -u`. GCHP's setCommonRunSettings.sh dereferences unset
# positionals, so sourcing it under `set -u` aborts before mpirun is reached
# (diagnosed on a head-node dry run during gate 3c, not here).
set -o pipefail

GATES=/scratch/lith-gates
RD=/scratch/gchp_lith_fullchem
OVL=/scratch/hemco-ovl              # FSx arm's HEMCO, prebuilt with the 5 GMI aliases
LITH=${GATES}/lith-1.1.3   # v1.1.3, sha256-verified against the release checksums.txt
# Arms F0/F/G serve the HEMCO mount from a local build of PR #259 while the four control
# mounts stay on the release above. Built on the head node from refs/pull/259/head =
# 85b8102, whose merge-base with origin/main is 24b151f (i.e. the PR is main + 1 commit),
# stamped so `lith version` says pr259-evidence-gate rather than "dev".
LITH_PR259=${GATES}/lith-pr259
# Arms H0/H/I/J: PR #260 (--readahead-reestablish-max), built the same way from
# refs/pull/260/head = 1dea9e4, merge-base 41322f4 = main AFTER #259 merged, so this
# binary carries both experimental knobs and H0 re-proves inertness on the new line.
LITH_PR260=${GATES}/lith-pr260
RANKS=48
START=20190701                      # cap_restart's start date; the watchdog keys off it
# Run_Duration in setCommonRunSettings.sh is "YYYYMMDD HHmmSS", so the run directory's
# default "00000100 000000" is ONE MONTH, not one day. Job 12 ran fullchem happily for
# 254 timesteps and then projected 1.5 h per arm -- two arms could not fit the 1:30
# limit. Set to "00000001 000000". A 1-day checkpoint is exactly as decisive for
# byte-identity and ~30x cheaper.
EXPECT_SGMT="00000001 000000"
RESULTS=${GATES}/gate5b-results.txt
# Declared BEFORE preflight so preflight can check only what the requested arms need
# (the PR binary is not required to rerun A-E, and A-E are not required to run F).
ARMLIST=${ARMLIST:-A,B,C,D,E}
# SUBMIT AS `ARMLIST=F,G sbatch --export=ALL <this>`, NEVER as
# `sbatch --export=ALL,ARMLIST=F0,F,G`: sbatch splits --export on COMMAS, so that form
# sets ARMLIST=F0 and then tries to export two variables named F and G. Job 18 ran arm
# F0 alone, reported a clean verdict for it, and silently dropped the two arms the job
# existed to run -- the harness was right, the submission was wrong, and nothing in the
# log said so.
# Any subset of arms can be run alone: ARMLIST=B sbatch ... . Each arm's checkpoint md5
# is persisted to gate5b-md5-<arm>.txt, so a partial rerun still gets a verdict against
# gate 5's banked control instead of paying for it again.

exec > >(tee -a "$RESULTS") 2>&1
say()   { echo; echo "=== $* ==="; }
stamp() { awk -v t0="$(date +%s.%N)" '{printf "%8.2f  %s\n", systime()-t0, $0; fflush()}'; }

say "node facts $(date -u +%FT%TZ)"
TOK=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
ITYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
echo "instance: ${ITYPE}  host: $(hostname)  cores: $(nproc)  mem: $(free -g | awk '/Mem:/{print $2}') GiB"
echo "/dev/shm: $(df -h /dev/shm | awk 'NR==2{print $2" size, "$4" avail"}')"
# C180 fullchem needed /dev/shm ~550 G and domains_stack_size 64M (SIGBUS at the
# first KPP call = tmpfs exhaustion). C24 has 56x fewer cells so the requirement is
# far smaller, but both values are REPORTED here so that if this job dies at the
# first chemistry step the cause is already in the log instead of needing a rerun.
# No domains_stack_size key exists in this run directory: the recorded C180 fix ADDS
# one, it is not a default. Left absent deliberately -- C24 has 56x fewer cells than
# the case that needed it, and CLAUDE.md's rule is not to change configuration we do
# not need to. If this job dies at the first KPP call with SIGBUS, that key is the
# first thing to add.
echo "domains_stack_size: $(awk '/^ *domains_stack_size/{print $2; f=1} END{if(!f) print "absent (GCHP default)"}' "$RD/GCHP.rc")"
NIC=$(case "$ITYPE" in m9g.48xlarge) echo 100;; c8g.48xlarge) echo 50;; *) echo 50;; esac)
echo "lith: $("$LITH" version 2>&1 | head -1)   --nic-gbps ${NIC}"

# ---------------------------------------------------------------- preflight
# Every check here is something that would otherwise fail AFTER mpirun starts, i.e.
# after the expensive part. Failing now costs seconds instead of a node-hour.
say "preflight"
fail=0
[[ -x "$RD/gchp" ]] || { echo "  FAIL no executable $RD/gchp"; fail=1; }
grep -q '^NUM_NODES=1$' "$RD/setCommonRunSettings.sh" || { echo "  FAIL NUM_NODES != 1"; fail=1; }
# TOTAL_CORES is a THIRD independent knob, not derived from the other two. Job 11
# died because it still said 96 after NUM_NODES went 2 -> 1.
grep -q "^TOTAL_CORES=${RANKS}\$" "$RD/setCommonRunSettings.sh" || { echo "  FAIL TOTAL_CORES != ${RANKS} (must equal NUM_NODES x NUM_CORES_PER_NODE)"; fail=1; }
grep -q '^Require_Species_in_Restart=0$' "$RD/setCommonRunSettings.sh" || { echo "  FAIL Require_Species_in_Restart != 0 (fullchem aborts on gcgrid restarts)"; fail=1; }
grep -q "^Run_Duration=\"${EXPECT_SGMT}\"\$" "$RD/setCommonRunSettings.sh" \
  || { echo "  FAIL Run_Duration != ${EXPECT_SGMT} (\"YYYYMMDD HHmmSS\"; 00000100 is a MONTH)"; fail=1; }
# No FSx arm here: the control md5 is banked from gate 5, so the GMI overlay is not
# needed and is not checked.
for i in merra2-201907 merra2-2015 hemco cheminp restarts; do
  [[ -s "$GATES/idx/$i.lithidx" ]] || { echo "  FAIL missing index $i"; fail=1; }
done
# Only demand the PR build if an arm actually asks for it, and demand that it really
# carries the flag: a stale or wrongly-built binary would silently run arm A three times
# and the amplification numbers would look like a refutation of #259.
if [[ ",${ARMLIST}," == *,F* || ",${ARMLIST}," == *,G* ]]; then
  if [[ ! -x "$LITH_PR259" ]]; then
    echo "  FAIL $LITH_PR259 missing (arms F0/F/G need the PR #259 build)"; fail=1
  elif ! "$LITH_PR259" mount --help 2>&1 | grep -q -- --readahead-evidence-ratio; then
    echo "  FAIL $LITH_PR259 has no --readahead-evidence-ratio — wrong commit built"; fail=1
  else
    echo "  PR build: $("$LITH_PR259" version 2>&1 | head -1) / $("$LITH_PR259" version 2>&1 | sed -n 2p)"
    echo "  PR build sha256: $(sha256sum "$LITH_PR259" | awk '{print $1}')"
  fi
  # The control binary must NOT understand the flag, or the arms are not separated.
  "$LITH" mount --help 2>&1 | grep -q -- --readahead-evidence-ratio \
    && { echo "  FAIL control binary $LITH also has the flag"; fail=1; } \
    || echo "  control binary $LITH does not know the flag (as expected)"
fi
if [[ ",${ARMLIST}," == *,H* || ",${ARMLIST}," == *,I, || ",${ARMLIST}," == *,J, ]]; then
  if [[ ! -x "$LITH_PR260" ]]; then
    echo "  FAIL $LITH_PR260 missing (arms H0/H/I/J need the PR #260 build)"; fail=1
  elif ! "$LITH_PR260" mount --help 2>&1 | grep -q -- --readahead-reestablish-max; then
    echo "  FAIL $LITH_PR260 has no --readahead-reestablish-max — wrong commit built"; fail=1
  else
    echo "  PR260 build: $("$LITH_PR260" version 2>&1 | head -1) / $("$LITH_PR260" version 2>&1 | sed -n 2p)"
    echo "  PR260 sha256: $(sha256sum "$LITH_PR260" | awk '{print $1}')"
    # #259 is merged, so its flag must ALSO be present here; if it is not, the build is
    # off an older base and H0 is not testing the release line it claims to.
    "$LITH_PR260" mount --help 2>&1 | grep -q -- --readahead-evidence-ratio \
      && echo "  PR260 also carries merged #259's flag (base is post-#259, as expected)" \
      || { echo "  FAIL PR260 lacks --readahead-evidence-ratio — base predates the #259 merge"; fail=1; }
  fi
fi
(( fail )) && { echo "PREFLIGHT FAILED — not spending node time"; exit 1; }
echo "  all preflight checks passed"

# ---------------------------------------------------------------- input layers
PORTS="9110:merra2-2019-07 9111:merra2-2015 9112:hemco 9113:chem-inputs 9114:restarts"

clean_stale_lith() {
  # `lith mount --daemon` detaches, so the daemons SURVIVE scancel and survive the job
  # that created them: daemonizing escapes the Slurm cgroup. Job 13 inherited job 12's
  # five mounts, could not create its own ("Permission denied" from mkdir/chown on live
  # FUSE mountpoints, then "daemon failed to start"), counted the stale mounts as
  # success, and ran GCHP against dead daemons -- it died in 10 s. Always start from a
  # known-clean state.
  for m in /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
           /input-lith/HEMCO /input-lith/CHEM_INPUTS /input-lith/GEOSCHEM_RESTARTS; do
    fusermount3 -u "$m" >/dev/null 2>&1
  done
  # Pattern must cover the PR build too (lith-pr259), not just the release: a pkill that
  # misses the binary the previous arm mounted leaves a live daemon holding the HEMCO
  # mountpoint, which is exactly how arm C was lost.
  pkill -f "lith-[0-9a-z.]+ mount" >/dev/null 2>&1
  sleep 3
  # Second pass with a lazy unmount for anything still attached: a mount whose daemon
  # we just killed can linger as a stale entry that no longer serves reads, which is
  # the worst of both worlds.
  local m
  for m in /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
           /input-lith/HEMCO /input-lith/CHEM_INPUTS /input-lith/GEOSCHEM_RESTARTS; do
    mountpoint -q "$m" && fusermount3 -uz "$m" >/dev/null 2>&1
  done
  sleep 2
  local left; left=$(mount | grep -c fuse.lith)
  echo "  stale fuse.lith mounts after cleanup: ${left}"
  if (( left )); then
    # Do not paper over this: a leftover mount means the next arm's reads go somewhere
    # other than where the log says they do.
    mount | grep fuse.lith | sed 's/^/    /'
    return 1
  fi
}

mount_lith() {
  # The mountpoints MUST be created here, on the node that runs the job. /input-lith
  # is node-local (unlike /scratch and /input, which are FSx), so directories made
  # during head-node prep do not exist here -- job 10 died exactly this way:
  # "fusermount3: failed to access mountpoint /input-lith/CHEM_INPUTS".
  for d in GEOS_0.5x0.625/MERRA2/2019/07 GEOS_0.5x0.625/MERRA2/2015/01 \
           HEMCO CHEM_INPUTS GEOSCHEM_RESTARTS; do
    sudo mkdir -p "/input-lith/${d}"
  done
  sudo chown -R "$(id -u):$(id -g)" /input-lith
  # Prefix-scoped mounts, one index each, mirroring gate 3c. MERRA2 is mounted at the
  # 2019/07 leaf (the simulation month) and MetDir points at the MERRA2 parent, so
  # ExtData's MetDir/%y4/%m2/... resolves through the mountpoint.
  #
  # 2015/01 is NOT optional: ExtData.rc has exactly one date-pinned met reference,
  # the constant-field file MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4, which does
  # not template over the simulation year. Without it GCHP aborts in
  # ExtDataGridCompMod.F90:1942 about nine seconds into init.
  #
  # --mem-cache is bounded on every mount. The default is 25% of system memory PER
  # DAEMON, so five mounts would default to capping 125% of the box; GCHP wants that
  # memory for the model.
  # The met mount is the in-run CONTROL in every arm except J, where it is the subject:
  # $MET_EXTRA/$MET_LITH are empty everywhere else, so the command is byte-identical to
  # gate 5's. Arm J exists because upstream named a risk -- a legitimate multi-pass
  # reader being capped -- that no HEMCO arm can show.
  echo "  MET arm flags:   [${MET_EXTRA:-<gate-5 defaults>}]  binary: $(basename "${MET_LITH:-$LITH}")"
  "${MET_LITH:-$LITH}" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 \
    --index-file "${GATES}/idx/merra2-201907.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 24GB --metrics ":9110" ${MET_EXTRA} --daemon
  "$LITH" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2015/01 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
    --index-file "${GATES}/idx/merra2-2015.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 4GB --metrics ":9111" --daemon
  # THE ONLY LINE THAT DIFFERS BETWEEN ARMS. $HEMCO_EXTRA is unquoted on purpose so
  # that an empty value adds no argument at all (arm A must be byte-identical in
  # configuration to gate 5 apart from the lith version).
  # ...and, from arm F0 on, the only mount whose BINARY differs: HEMCO can be served by
  # the PR #259 build while the four controls stay on the release, so met's 1.210x
  # remains comparable to arms A-E rather than moving for two reasons at once.
  echo "  HEMCO arm flags: [${HEMCO_EXTRA:-<defaults>}]"
  echo "  HEMCO binary:    ${HEMCO_LITH:-$LITH} ($("${HEMCO_LITH:-$LITH}" version 2>&1 | head -1))"
  "${HEMCO_LITH:-$LITH}" mount s3://gcgrid/HEMCO /input-lith/HEMCO \
    --index-file "${GATES}/idx/hemco.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 32GB --metrics ":9112" ${HEMCO_EXTRA} --daemon
  "$LITH" mount s3://gcgrid/CHEM_INPUTS /input-lith/CHEM_INPUTS \
    --index-file "${GATES}/idx/cheminp.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 8GB --metrics ":9113" --daemon
  "$LITH" mount s3://gcgrid/GEOSCHEM_RESTARTS /input-lith/GEOSCHEM_RESTARTS \
    --index-file "${GATES}/idx/restarts.lithidx" --no-sign-request --nic-gbps $NIC \
    --mem-cache 8GB --metrics ":9114" --daemon
  sleep 6
  local n; n=$(mount | grep -c fuse.lith)
  echo "  fuse.lith mounts: ${n}"
  # Counting mount entries is NOT sufficient evidence that OUR daemons are serving
  # them -- that is precisely how job 13 fooled itself. Prove each daemon we just
  # started is alive by asking its own metrics endpoint.
  local alive=0 pp port
  for pp in $PORTS; do
    port=${pp%%:*}
    curl -s --max-time 4 "http://localhost:${port}/metrics" | grep -q '^lith_' && alive=$((alive+1))
  done
  echo "  daemons answering on their metrics ports: ${alive}/5"
  (( n == 5 && alive == 5 )) || { echo "  MOUNTS NOT HEALTHY — refusing to run GCHP against them"; return 1; }
}

umount_lith() {
  # A plain `fusermount3 -u` is not enough between arms. Arm B left /input-lith/HEMCO
  # mounted -- the busiest mount, and the last one the 48 dying ranks had open -- so
  # arm C's clean-state guard correctly refused to run and the arm was lost. Retry,
  # then fall back to a LAZY unmount (-uz), which detaches the mountpoint even while a
  # reference is still held and lets the daemon exit on its own.
  local m i
  for m in /input-lith/GEOS_0.5x0.625/MERRA2/2019/07 /input-lith/GEOS_0.5x0.625/MERRA2/2015/01 \
           /input-lith/HEMCO /input-lith/CHEM_INPUTS /input-lith/GEOSCHEM_RESTARTS; do
    for i in 1 2 3; do
      mountpoint -q "$m" || break
      fusermount3 -u "$m" >/dev/null 2>&1 || { sleep 2; fusermount3 -uz "$m" >/dev/null 2>&1; }
      sleep 1
    done
  done
}

# Point the run directory's four input symlinks at a layer. This is the ONLY thing
# that differs between arms.
point_at() {  # point_at lith|fsx
  local root
  case "$1" in
    lith) root=/input-lith ;;
    fsx)  root=/input ;;
    *) echo "  bad layer $1"; return 1 ;;
  esac
  ln -sfn "${root}/GEOS_0.5x0.625/MERRA2" "$RD/MetDir"
  ln -sfn "${root}/CHEM_INPUTS"           "$RD/ChemDir"
  # HEMCO: the FSx arm must use the overlay, because /input itself cannot serve the
  # five GMI aliases fullchem needs. The lith arm points straight at the real tree.
  local hco
  if [[ "$1" == fsx ]]; then hco=$OVL; else hco="${root}/HEMCO"; fi
  ln -sfn "$hco" "$RD/HcoDir"
  # HEMCO_Config.rc carries the ONE absolute input path in the run directory
  # (`ROOT:`), and HEMCO field paths are built from it, so the symlink alone does not
  # redirect HEMCO. ExtData.rc by contrast is fully relative — 1772 ./HcoDir refs and
  # zero absolute paths — so it follows the symlinks with no edit.
  sed -i -E "s|^(ROOT: *).*|\1${hco}|" "$RD/HEMCO_Config.rc"
  echo "  HEMCO ROOT -> $(awk '/^ROOT:/{print $2}' "$RD/HEMCO_Config.rc")"
  for r in "$RD"/Restarts/GEOSChem.Restart.*.nc4; do
    local tgt suf; tgt=$(readlink "$r") || continue
    # Strip whichever root is currently in the link, longest first, then re-root once.
    # Stripping both prefixes in separate ln calls would re-root an already-correct
    # path a second time and produce /input-lith/input/... — silently broken.
    suf=${tgt#/input-lith}; suf=${suf#/input}
    ln -sfn "${root}${suf}" "$r"
  done
  echo "  MetDir  -> $(readlink "$RD/MetDir")"
  echo "  HcoDir  -> $(readlink "$RD/HcoDir")"
  echo "  ChemDir -> $(readlink "$RD/ChemDir")"
  echo "  restart -> $(readlink "$RD/Restarts/GEOSChem.Restart.${START}_0000z.c24.nc4")"
  # Prove the model's entry points actually resolve through this layer before paying
  # for mpirun. -L follows the link; a broken chain fails here, not 60 s into init.
  ls -L "$RD/MetDir/2019/07/MERRA2.20190701.A1.05x0625.nc4" \
        "$RD/MetDir/2015/01/MERRA2.20150101.CN.05x0625.nc4" \
        "$RD/HcoDir/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc" \
        "$RD/Restarts/GEOSChem.Restart.${START}_0000z.c24.nc4" >/dev/null \
    && echo "  entry points resolve OK" || { echo "  ENTRY POINTS DO NOT RESOLVE"; return 1; }
}

# ---------------------------------------------------------------- one run
reset_rundir() {
  cd "$RD" || exit 1
  echo "${START} 000000" > cap_restart
  # Stale checkpoints are not cosmetic: a pre-existing gcchem_internal_checkpoint is
  # the NC_EEXIST bug that was long misread as a multi-node pnc4 collective hang.
  rm -f Restarts/gcchem_internal_checkpoint* OutputDir/*.nc4 2>/dev/null
}

gchp_run() {  # gchp_run LABEL
  local label="$1" log="${GATES}/gate5b-${1}.log"
  say "RUN ${label}"
  reset_rundir
  source /sw/gchp-env.sh              # exports OPAL_PREFIX and PMIX_PREFIX; do not override
  ulimit -s unlimited 2>/dev/null
  # Do NOT discard these scripts' output. Job 11 died here with nothing in the log
  # because `>/dev/null 2>&1` swallowed setCommonRunSettings.sh's own diagnostic
  # ("ERROR: TOTAL_CORES must equal NUM_NODES times NUM_CORES_PER_NODE") -- the
  # official tooling said exactly what was wrong and the harness hid it. Capture and
  # surface instead.
  local setup="${GATES}/gate5b-${label}-setup.log"
  source setCommonRunSettings.sh > "$setup" 2>&1
  source setRestartLink.sh       >> "$setup" 2>&1
  source checkRunSettings.sh     >> "$setup" 2>&1
  if grep -qiE "^ *ERROR|must equal" "$setup"; then
    echo "  GCHP SETUP REJECTED THE CONFIGURATION:"; grep -iE "ERROR|must equal" "$setup" | sed 's/^/    /'
    printf 'RESULT %-6s SETUP-REJECTED\n' "$label"; return 1
  fi
  echo "  layout: NX=$(awk '/^NX:/{print $2}' GCHP.rc) NY=$(awk '/^NY:/{print $2}' GCHP.rc) ranks=${RANKS}"
  # Re-read the layer AFTER sourcing the GCHP setup scripts, in case any of them
  # rewrite the run directory. This line, not the one in point_at, is the proof of
  # which layer actually served the run.
  echo "  at launch: HcoDir -> $(readlink HcoDir)  MetDir -> $(readlink MetDir)  HEMCO ROOT -> $(awk '/^ROOT:/{print $2}' HEMCO_Config.rc)"

  # WATCHDOG, NOT `wait`: GCHP 14.7.1 completes the simulation, writes the checkpoint
  # and cap_restart, and THEN throws "double free or corruption" in library
  # destructors after main() returns, leaving ranks spinning forever. Waiting on
  # mpirun never returns. So poll for the completion evidence GCHP itself writes.
  local t0 t1 deadline=4200
  t0=$(date +%s.%N)
  mpirun -n "$RANKS" ./gchp 2>&1 | stamp > "$log" &
  local pipe_pid=$!
  local done_at="" i=0
  while (( i < deadline )); do
    if [[ -s cap_restart ]] && [[ "$(awk '{print $1}' cap_restart)" != "$START" ]] \
       && [[ -s Restarts/gcchem_internal_checkpoint ]]; then
      done_at=$(date +%s.%N); break
    fi
    kill -0 "$pipe_pid" 2>/dev/null || break
    sleep 2; ((i+=2))
  done
  t1=${done_at:-$(date +%s.%N)}
  pkill -9 -f "$RD/gchp" 2>/dev/null
  kill -9 "$pipe_pid" 2>/dev/null; wait "$pipe_pid" 2>/dev/null
  sleep 3

  local init_s sim_end_s after verdict=FAILED ck="n/a"
  init_s=$(grep -m1 "GCHP Date" "$log" | awk '{print $1}')
  sim_end_s=$(grep "GCHP Date" "$log" | tail -1 | awk '{print $1}')
  after=$(awk '{print $1}' cap_restart 2>/dev/null)
  if [[ -n "$done_at" ]]; then
    verdict=SUCCEEDED
    ck=$(md5sum Restarts/gcchem_internal_checkpoint | awk '{print $1}')
    cp -f Restarts/gcchem_internal_checkpoint "${GATES}/gate5b-ckpt-${label}.nc4" 2>/dev/null
  else
    echo "  --- last 25 log lines (failure) ---"; tail -25 "$log" | sed 's/^/  /'
  fi
  printf 'RESULT %-6s init=%ss sim_end=%ss to_completion=%.1fs cap_restart->%s md5=%s %s\n' \
    "$label" "${init_s:-NA}" "${sim_end_s:-NA}" \
    "$(awk -v a=$t0 -v b=$t1 'BEGIN{print b-a}')" "${after:-NA}" "$ck" "$verdict"
  echo "$ck" > "${GATES}/gate5b-md5-${label}.txt"
}

metrics_dump() {
  say "lith metrics after $1"
  for pp in $PORTS; do
    local port=${pp%%:*} name=${pp##*:}
    echo "-- ${name} (:${port})"
    curl -s --max-time 5 "http://localhost:${port}/metrics" \
      | grep -E "^lith_(s3_bytes_total|distinct_bytes_read|cache_misses_total|fill_runs_total|s3_requests_total|read_straddle_total|prefetch_[a-z_]+|sibling_[a-z_]+|parts_[a-z_]+)" \
      | grep -v bucket | sed 's/^/   /'
  done
}

# Gate 5 reported lith_prefetch_evicted_unread_total as "absent from the scrape". It is
# not absent -- it exports as a plain 0 -- the gate's regex ENUMERATED prefetch counters
# and omitted it. Hence the family globs above: a diagnostic you filtered out looks
# exactly like a diagnostic that does not exist. Verified on v1.1.3 on the head node.

# The one number the arms are about, pulled straight from the HEMCO daemon.
hemco_ampl() {  # hemco_ampl LABEL
  local m; m=$(curl -s --max-time 5 http://localhost:9112/metrics)
  local s3 d iss used unc
  s3=$(  awk '/^lith_s3_bytes_total /{print $2}'          <<<"$m")
  d=$(   awk '/^lith_distinct_bytes_read /{print $2}'     <<<"$m")
  iss=$( awk '/^lith_prefetch_issued_total /{print $2}'   <<<"$m")
  used=$(awk '/^lith_prefetch_used_total /{print $2}'     <<<"$m")
  unc=$( awk '/^lith_prefetch_uncovered_total /{print $2}'<<<"$m")
  # used/issued is printed as a RATE, not just a pair, because from arm F on it is the
  # primary assertion: A-E showed a 4x window cut moves the volume and leaves the rate
  # at 13%, so a fall in amplification with a flat rate means #259 is another volume cap
  # rather than the precision fix it claims to be.
  printf 'HEMCO %-4s s3=%.1fMB distinct=%.1fMB ampl=%.3fx prefetch_used=%s/%s (%.1f%%) uncovered=%s\n' \
    "$1" "$(awk -v x="$s3" 'BEGIN{print x/1e6}')" "$(awk -v x="$d" 'BEGIN{print x/1e6}')" \
    "$(awk -v a="$s3" -v b="$d" 'BEGIN{print (b>0)?a/b:0}')" "${used:-NA}" "${iss:-NA}" \
    "$(awk -v u="${used:-0}" -v i="${iss:-0}" 'BEGIN{print (i>0)?100*u/i:0}')" "${unc:-NA}"
}

# The in-run control, asserted explicitly instead of left to be eyeballed in the metrics
# dump: the met mount read 1.210x in all five of arms A-E on the SAME binary and flags,
# so any movement here means the arm changed something it was not supposed to.
met_ampl() {  # met_ampl LABEL
  local m; m=$(curl -s --max-time 5 http://localhost:9110/metrics)
  local s3 d iss used
  s3=$(  awk '/^lith_s3_bytes_total /{print $2}'        <<<"$m")
  d=$(   awk '/^lith_distinct_bytes_read /{print $2}'   <<<"$m")
  iss=$( awk '/^lith_prefetch_issued_total /{print $2}' <<<"$m")
  used=$(awk '/^lith_prefetch_used_total /{print $2}'   <<<"$m")
  printf 'MET   %-4s s3=%.1fMB distinct=%.1fMB ampl=%.3fx prefetch_used=%s/%s (%.1f%%)  [control: expect 1.210x]\n' \
    "$1" "$(awk -v x="$s3" 'BEGIN{print x/1e6}')" "$(awk -v x="$d" 'BEGIN{print x/1e6}')" \
    "$(awk -v a="$s3" -v b="$d" 'BEGIN{print (b>0)?a/b:0}')" "${used:-NA}" "${iss:-NA}" \
    "$(awk -v u="${used:-0}" -v i="${iss:-0}" 'BEGIN{print (i>0)?100*u/i:0}')"
}

# PR #260's labelled counters are the discriminator upstream pre-registered, so they are
# reported per size class rather than left in the raw dump. sizeClass (fuse/fs.go:961)
# buckets at 4 / 16 / 64 MiB. Both counters are recorded once per handle at Release.
#
# The reason to print the SHARE and not just the count: upstream predicts de-establishment
# is concentrated in >64MiB, but 34.8% of HEMCO's 471 objects are already >64MiB, so
# 34.8% is the null, not 0%. Printing the share against that null is what makes the
# prediction falsifiable, and a suppression share that lands on the SMALL classes is
# upstream's own stated kill condition for the mechanism.
size_class_dump() {  # size_class_dump LABEL
  local pp port name
  for pp in 9112:hemco 9110:met; do
    port=${pp%%:*}; name=${pp##*:}
    curl -s --max-time 5 "http://localhost:${port}/metrics" \
      | awk -v arm="$1" -v mount="$name" '
        /^lith_prefetch_deestablished_total\{/ || /^lith_prefetch_reestablish_suppressed_total\{/ ||
        /^lith_prefetch_evidence_clamped_total\{/ || /^lith_prefetch_evidence_withheld_blocks_total\{/ {
          m=$1; sub(/\{.*/,"",m); sub(/^lith_prefetch_/,"",m); sub(/_total$/,"",m)
          cls=$1; sub(/^.*size_class="/,"",cls); sub(/".*$/,"",cls)
          v[m"|"cls]=$2; tot[m]+=$2; seen[m]=1
        }
        END{
          for (m in seen) {
            for (k in v) { split(k,p,"|"); if (p[1]!=m) continue
              printf "CLASS %-4s %-5s %-24s %-9s %10.0f  %5.1f%% of %.0f\n",
                arm, mount, m, p[2], v[k], (tot[m]>0)?100*v[k]/tot[m]:0, tot[m] }
          }
          if (!length(seen)) printf "CLASS %-4s %-5s (no labelled #259/#260 counters exported)\n", arm, mount
        }' | sort -k3,3 -k4,4
  done
}

# ---------------------------------------------------------------- the three arms
# Banked from gate 5 (job 13 fsx arm / job 14 lith arm, both v1.1.2). Every arm below
# must reproduce it.
BASE_MD5=f3dd15b2191bbce63dadcbfc100196a6
SUMMARY=${GATES}/gate5b-summary.txt
: > "$SUMMARY"

arm_flags() {  # HEMCO mount flags for this arm
  case "$1" in
    A) echo "" ;;
    B) echo "--parts-max 0" ;;
    # --max-readahead is in BLOCKS and --block-size defaults to 8MiB, so 4 = 32 MiB
    # (> the 13 MB files) and 1 = 8 MiB (< them). C is therefore NOT a sub-file arm; D is.
    C) echo "--parts-max 0 --max-readahead 4" ;;
    D) echo "--parts-max 0 --max-readahead 1" ;;
    E) echo "--parts-max 0 --max-readahead 1 --small-file 0" ;;
    # F0/F/G deliberately carry NO window/parts/small-file flags: #259 is meant to
    # replace window tuning, so stacking D's or E's caps underneath it would make a fall
    # in amplification unattributable. F0 is arm A's configuration on the PR binary.
    F0) echo "" ;;
    F)  echo "--readahead-evidence-ratio 8" ;;
    G)  echo "--readahead-evidence-ratio 32" ;;
    # H0 = arm A's configuration on the #260 binary. H/I cap HEMCO. J caps MET instead
    # and deliberately leaves HEMCO at defaults, so HEMCO becomes the arm's control.
    H0) echo "" ;;
    H)  echo "--readahead-reestablish-max 2" ;;
    I)  echo "--readahead-reestablish-max 4" ;;
    J)  echo "" ;;
    *) return 1 ;;
  esac
}

arm_met_flags() {  # MET mount flags -- empty in every arm but J, so met stays a control
  case "$1" in
    J) echo "--readahead-reestablish-max 2" ;;
    *) echo "" ;;
  esac
}

arm_binary() {  # which lith serves the HEMCO mount for this arm
  case "$1" in
    F0|F|G)    echo "$LITH_PR259" ;;
    H0|H|I|J)  echo "$LITH_PR260" ;;
    *)         echo "$LITH" ;;
  esac
}

arm_met_binary() {  # which lith serves the MET mount; the release EXCEPT in arm J, where
  case "$1" in     # the met mount is the subject and needs the flag
    J) echo "$LITH_PR260" ;;
    *) echo "$LITH" ;;
  esac
}

for arm in ${ARMLIST//,/ }; do
  HEMCO_EXTRA=$(arm_flags "$arm") || { echo "unknown arm $arm"; continue; }
  HEMCO_LITH=$(arm_binary "$arm")
  MET_EXTRA=$(arm_met_flags "$arm")
  MET_LITH=$(arm_met_binary "$arm")
  say "ARM ${arm} — HEMCO [${HEMCO_EXTRA:-<defaults>}] on $(basename "$HEMCO_LITH") | MET [${MET_EXTRA:-<control>}] on $(basename "$MET_LITH")"
  export HEMCO_EXTRA HEMCO_LITH MET_EXTRA MET_LITH
  # A dead or inherited daemon serves nothing and looks like a mechanism result, so the
  # clean/verify/abort chain from gate 5 is kept exactly as-is on every arm.
  if clean_stale_lith && mount_lith && point_at lith; then
    gchp_run "$arm"
    metrics_dump "$arm"
    hemco_ampl "$arm" | tee -a "$SUMMARY"
    met_ampl   "$arm" | tee -a "$SUMMARY"
    size_class_dump "$arm" | tee -a "$SUMMARY"
  else
    echo "ABORT ARM ${arm}: lith layer not usable — NOT running GCHP (a run against"
    echo "      stale or dead daemons produces a failure that looks like a result)"
    echo "HEMCO ${arm}  NOT-RUN" >> "$SUMMARY"
  fi
  umount_lith
  sleep 3
done

# ---------------------------------------------------------------- the verdict
say "GATE 5b — HEMCO amplification by arm"
cat "$SUMMARY"

say "correctness: every arm must reproduce gate 5's checkpoint"
echo "  banked (gate 5, v1.1.2): ${BASE_MD5}"
bad=0
for arm in ${ARMLIST//,/ }; do
  m=$(cat "${GATES}/gate5b-md5-${arm}.txt" 2>/dev/null)
  # "n/a" is what a non-completing arm writes; treat it as MISSING, never as a
  # mismatch. A harness must not be able to manufacture a correctness claim out of its
  # own breakage (gate 5 job 13 did exactly that).
  [[ "$m" == "n/a" ]] && m=""
  if [[ -z "$m" ]]; then
    printf '  %-3s MISSING — arm did not complete\n' "$arm"; bad=1
  elif [[ "$m" == "$BASE_MD5" ]]; then
    printf '  %-3s %s  IDENTICAL\n' "$arm" "$m"
  else
    printf '  %-3s %s  *** DIFFERS FROM BANKED ***\n' "$arm" "$m"; bad=1
  fi
done
(( bad )) && echo "  NOTE: a fetch-policy flag changing the model's bytes, or an arm not"
(( bad )) && echo "        completing, outranks the amplification question. Read the RESULT lines."
grep -E "^RESULT" "$RESULTS" | tail -6
