#!/bin/bash
# lith#233 confirmation — does a cold sequential read chunk-fetch its FIRST 8 MiB
# block as 8x1 MiB GETs before the pattern establishes, and does the cost decay
# with file size? Measured on real gcgrid met objects (1.17 GB MERRA-2 A3dyn),
# which is the shape lith#233 asks about. Head node only, so free.
#
# THE CLAIM (lith#233, measured upstream on a 30 MB object: GET 4->12, wall +55%)
# lith pins FUSE MaxWrite at 128 KiB, so a sequential reader issues 128 KiB reads
# and stays inside one 8 MiB block for ~64 of them (d==0). Establishment requires a
# block-advance (d==1), so it cannot fire until the reader crosses into block 1 —
# and block 0 is therefore demand-fetched as 8 separate 1 MiB chunks instead of one
# coalesced 8 MiB range. Cold-only, and shrinks with file size because block 0 is a
# smaller fraction of a bigger file.
#
# HOW THIS TESTS IT — a cold-prefix ladder, which is decisive rather than suggestive
# Read the first N MiB of a 1.17 GB file on a FRESH COLD mount for each N, and count
# GETs. The three hypotheses predict clearly different numbers:
#     N MiB read:            8    16    32    64
#   #233 holds (8 + 1/blk):  8     9    11    15
#   everything coalesces:    1     2     4     8
#   nothing coalesces:       8    16    32    64
# A fresh mount per rung is what makes each rung genuinely cold; the daemon is
# restarted and the page cache dropped between rungs.
#
# Ideal GETs for a fully-coalescing reader = ceil(bytes / 8 MiB). Excess over that
# is the block-0 tax, and part B watches it decay against file size.
set -o pipefail

GATES=/scratch/lith-gates
LITH=${GATES}/lith-1.1.1
PREFIX=GEOS_0.5x0.625/MERRA2/2019/01
IDX=${GATES}/idx/merra2.lithidx
MNT=/mnt/lith-fuse
MPORT=9110
BIG=MERRA2.20190112.A3dyn.05x0625.nc4      # 1168.4 MB
OUT=${GATES}/gate233-results.txt

say() { echo; echo "=== $* ==="; }
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; }
exec > >(tee -a "$OUT") 2>&1
echo "### lith#233 block-0 probe $(date -u +%FT%TZ) on $(hostname)  lith=$(${LITH} version 2>&1 | head -1)"

unmount() { fusermount3 -u "$MNT" 2>/dev/null; pkill -f '[l]ith-1.1.1' 2>/dev/null; sleep 2; }
remount() {
  unmount
  sudo sysctl -q -w vm.drop_caches=3 2>/dev/null   # so the kernel cannot answer from a previous rung
  cd /tmp || return 1
  ${LITH} mount "s3://gcgrid/${PREFIX}" "$MNT" --index-file "$IDX" --no-sign-request \
     --mem-cache 2GB --metrics ":${MPORT}" --daemon >/dev/null 2>&1
  sleep 4
  mountpoint -q "$MNT"
}

# Plain substring match, not a regex with braces — escaping `\{` in an awk regex
# emits "escape sequence treated as plain" warnings that pollute the results file.
m() { curl -s --max-time 5 "http://localhost:${MPORT}/metrics" | awk -v k="$1" 'index($1,k)==1 {print $2; exit}'; }
gets()  { m 'lith_s3_requests_total{op="get",status="ok"}'; }
bytes() { m 'lith_s3_bytes_total'; }
fills() { m 'lith_fill_runs_total'; }
waste() { m 'lith_prefetch_evicted_unread_total'; }
issued(){ m 'lith_prefetch_issued_total'; }
# ceil(a/b) done with integer arithmetic. `printf "%.0f"` on (n+7)/8 ROUNDS rather
# than truncates, so it returned ideal+1 on every rung of the first run — 2 instead
# of 1 for an 8 MiB read. Small bug, but it understated the block-0 tax it exists to
# measure, which is the one number this probe is for.
ceildiv() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%d", int((a + b - 1) / b)}'; }

# Direct evidence for the 128 KiB MaxWrite the whole mechanism rests on. Prometheus
# buckets are CUMULATIVE, so per-bucket counts are successive differences; and the
# label must be parsed from le="..." rather than a positional field.
readhist() {
  curl -s --max-time 5 "http://localhost:${MPORT}/metrics" \
    | grep '^lith_read_size_bytes_bucket' \
    | sed 's/.*le="\([^"]*\)"[^0-9]*/\1 /' \
    | awk '{c=$2; d=c-p; p=c; if (d>0) printf "%s:%d ", ($1=="+Inf" ? "inf" : sprintf("%.0fK", $1/1024)), d}'
}

unmount

# ------------------------------------------------------------------ part A: ladder
say "part A — cold-prefix ladder on ${BIG} (fresh cold mount per rung)"
# MB_S3 vs RUN_MiB is the column that matters most, and it is why PF_ISS/PF_UNREAD
# are here: the first run of this probe showed a 16 MiB read pulling 248 MB from S3,
# which no version of the #233 mechanism predicts. Either establishment fires a large
# read-ahead ramp (then most of those bytes are prefetch, and the ones past the end of
# a short read get evicted unread), or the block-0 chunking is far wider than 8 GETs.
# The prefetch counters separate those two without guessing.
printf '%-8s %-6s %-6s %-8s %-8s %-8s %-8s %-9s %s\n' \
  RUN_MiB GETs IDEAL EXCESS MB_S3 AMPL PF_ISS PF_UNREAD WALL
for N in 8 16 32 64; do
  remount || { bad "mount failed at N=${N}"; continue; }
  g0=$(gets); b0=$(bytes); p0=$(issued); w0=$(waste)
  g0=${g0:-0}; b0=${b0:-0}; p0=${p0:-0}; w0=${w0:-0}
  t0=$(date +%s.%N)
  dd if="${MNT}/${BIG}" bs=128k count=$((N*8)) of=/dev/null status=none 2>/dev/null
  t1=$(date +%s.%N)
  g1=$(gets); b1=$(bytes); p1=$(issued); w1=$(waste)
  dg=$(awk -v a="${g1:-0}" -v b="$g0" 'BEGIN{printf "%.0f", a-b}')
  db=$(awk -v a="${b1:-0}" -v b="$b0" 'BEGIN{printf "%.1f", (a-b)/1048576}')
  ideal=$(ceildiv "$N" 8)                                  # ceil(N MiB / 8 MiB blocks)
  printf '%-8s %-6s %-6s %-8s %-8s %-8s %-8s %-9s %.2fs\n' "$N" "$dg" "$ideal" \
    "$(awk -v a="$dg" -v b="$ideal" 'BEGIN{printf "%+d", a-b}')" "$db" \
    "$(awk -v a="$db" -v n="$N" 'BEGIN{printf "%.1fx", a/n}')" \
    "$(awk -v a="${p1:-0}" -v b="$p0" 'BEGIN{printf "%.0f", a-b}')" \
    "$(awk -v a="${w1:-0}" -v b="$w0" 'BEGIN{printf "%.0f", a-b}')" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')"
done

say "part A interpretation aid — FUSE read sizes the kernel actually issued (last rung)"
echo "  $(readhist)"

# ------------------------------------------------------ part A2: locate the transition
# The jump lives somewhere in 8->16 MiB, which is exactly where #233 says establishment
# happens (first block-advance). This ladder steps 1 MiB at a time across that boundary
# so the answer is a location, not an interval: if amplification appears the instant the
# reader crosses into block 1 (9 MiB) it is establishment firing a read-ahead ramp; if it
# climbs gradually it is something else.
say "part A2 — fine ladder across the block0->block1 boundary on ${BIG}"
printf '%-8s %-6s %-8s %-8s %-8s %-9s %s\n' RUN_MiB GETs MB_S3 AMPL PF_ISS PF_UNREAD WALL
for N in 7 8 9 10 12 16 24; do
  remount || { bad "mount failed at N=${N}"; continue; }
  g0=$(gets); b0=$(bytes); p0=$(issued); w0=$(waste)
  g0=${g0:-0}; b0=${b0:-0}; p0=${p0:-0}; w0=${w0:-0}
  t0=$(date +%s.%N)
  dd if="${MNT}/${BIG}" bs=128k count=$((N*8)) of=/dev/null status=none 2>/dev/null
  t1=$(date +%s.%N)
  g1=$(gets); b1=$(bytes); p1=$(issued); w1=$(waste)
  db=$(awk -v a="${b1:-0}" -v b="$b0" 'BEGIN{printf "%.1f", (a-b)/1048576}')
  printf '%-8s %-6s %-8s %-8s %-8s %-9s %.2fs\n' "$N" \
    "$(awk -v a="${g1:-0}" -v b="$g0" 'BEGIN{printf "%.0f", a-b}')" "$db" \
    "$(awk -v a="$db" -v n="$N" 'BEGIN{printf "%.1fx", a/n}')" \
    "$(awk -v a="${p1:-0}" -v b="$p0" 'BEGIN{printf "%.0f", a-b}')" \
    "$(awk -v a="${w1:-0}" -v b="$w0" 'BEGIN{printf "%.0f", a-b}')" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')"
done

# -------------------------------------------------------------- part B: size decay
say "part B — cold FULL sequential read, three object sizes (size-decay claim)"
mapfile -t FILES < <(remount >/dev/null 2>&1; ls -l "$MNT" | awk 'NR>1 && $5>0 {print $5" "$9}' | sort -n \
  | awk 'NR==1{print} {last=$0; n++} END{print last}')
# smallest, one mid-size, largest — chosen from what the prefix actually holds
MID=$(ls -l "$MNT" | awk 'NR>1 && $5>0 {print $5" "$9}' | sort -n | awk '{a[NR]=$0} END{print a[int(NR/2)]}')
# MB_S3 here answers the question part A raises: on a read that runs to EOF there is
# nothing past the end to over-fetch, so if the amplification is a prefetch ramp then
# MB_S3 should land on the file size and only the GET count should be excess.
printf '%-42s %-9s %-6s %-6s %-7s %-9s %-8s %s\n' \
  FILE SIZE_MB GETs IDEAL EXCESS EXCESS_PCT MB_S3 WALL
for spec in "${FILES[0]}" "$MID" "${FILES[1]}"; do
  sz=${spec%% *}; fn=${spec##* }
  [[ -n "$fn" ]] || continue
  remount || { bad "mount failed for ${fn}"; continue; }
  g0=$(gets); b0=$(bytes); g0=${g0:-0}; b0=${b0:-0}
  t0=$(date +%s.%N)
  dd if="${MNT}/${fn}" bs=128k of=/dev/null status=none 2>/dev/null
  t1=$(date +%s.%N)
  g1=$(gets); b1=$(bytes)
  dg=$(awk -v a="${g1:-0}" -v b="$g0" 'BEGIN{printf "%.0f", a-b}')
  db=$(awk -v a="${b1:-0}" -v b="$b0" 'BEGIN{printf "%.1f", (a-b)/1048576}')
  ideal=$(ceildiv "$sz" 8388608)
  printf '%-42s %-9.1f %-6s %-6s %-7s %-9s %-8s %.2fs\n' "$fn" "$(awk -v s="$sz" 'BEGIN{print s/1048576}')" \
    "$dg" "$ideal" "$(awk -v a="$dg" -v b="$ideal" 'BEGIN{printf "%+d", a-b}')" \
    "$(awk -v a="$dg" -v b="$ideal" 'BEGIN{printf "%+.1f%%", 100*(a-b)/b}')" "$db" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')"
done

say "part C — what GCHP itself does, for contrast (from the gate 3c metric dump)"
# Not re-measured: taken from the committed gate 3c run. Included because it is the
# reason #233's severity for us is not the same as its severity in general.
echo "  gate 3c, MERRA2 mount over a full GCHP init:"
echo "    lith_s3_requests_total{get,ok} = 3647   lith_s3_bytes_total = 4105.4 MB"
echo "    => 1125 KB per GET, and lith_fill_runs_total = 0"
echo "  i.e. GCHP's own reads are ~1 MiB-granular for the WHOLE init, not just block 0."

unmount
say "SUMMARY"
grep -E "^[0-9]+ +[0-9]+|^MERRA2" "$OUT" | tail -10
