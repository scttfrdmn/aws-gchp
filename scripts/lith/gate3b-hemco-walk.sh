#!/bin/bash
# GATE 3b — the small-file regime: a HEMCO directory walk, lith vs FSx Lustre.
#
# Gate 3 measured the large met files (0.95-3.5 GB), where FSx's whole-object lazy
# load is maximally punishing. This measures the opposite regime, deliberately
# looking for where lith does WORST:
#
#   - HEMCO emission files are ~10-30 MB, BELOW lith's parts-max (64 MiB at
#     --nic-gbps 15), so lith fetches them WHOLE via the parts path (#220/#229).
#     FSx also hydrates whole objects. Same bytes moved, so this is the regime
#     where lith's byte advantage disappears and only latency/concurrency differ.
#   - Many files opened in key order, which is lith's sibling-walk detector
#     (--sibling-readahead 16, --sibling-window 4) — a path gate 3 never touched.
#
# This is also the closest cheap proxy for GCHP init: ExtData opens each HEMCO
# file, reads its metadata, and pulls a slab, file after file.
#
# Metadata-only (h5dump -H) because for a whole-fetched file the metadata walk IS
# the fetch trigger, and it costs no CPU, so wall time is I/O.
set -uo pipefail

HEMCO_REL="${HEMCO_REL:-HEMCO/CEDS/v2021-06/2019}"
FSX_DIR="/input/${HEMCO_REL}"
MNT="/scratch/lith-gates/mnt-hemco"
IDX="/scratch/lith-gates/idx/hemco.lithidx"
NIC_GBPS="${NIC_GBPS:-15}"
NFILES="${NFILES:-40}"
OUT="${OUT:-/scratch/lith-gates/gate3b-results.tsv}"
METRICS_PORT="${METRICS_PORT:-9102}"

source /sw/gchp-env.sh >/dev/null 2>&1
H5DUMP=$(command -v h5dump)
LITH_VER=$(lith version 2>&1 | head -1 | tr -d '\r')

now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
mb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN{if(b>0) printf "%.1f", a/b; else print "-"}'; }

snap_metrics() { curl -s "http://localhost:${METRICS_PORT}/metrics" > /tmp/gate3b-metrics.txt; }
metric() { awk -v k="$1" '$1==k{v=$2} END{print (v==""?0:v)}' /tmp/gate3b-metrics.txt; }

mkdir -p "$MNT"
remount_lith() {
  fusermount3 -u "$MNT" >/dev/null 2>&1
  for _ in $(seq 20); do
    curl -sf "http://localhost:${METRICS_PORT}/metrics" >/dev/null 2>&1 || break
    sleep 0.5
  done
  rm -rf "${TMPDIR:-/tmp}/lith-cache"
  lith mount "s3://gcgrid/${HEMCO_REL}" "$MNT" \
    --index-file "$IDX" --no-sign-request \
    --nic-gbps "$NIC_GBPS" --metrics ":${METRICS_PORT}" --daemon >/dev/null 2>&1
  for _ in $(seq 40); do
    if curl -sf "http://localhost:${METRICS_PORT}/metrics" >/dev/null 2>&1; then
      snap_metrics
      [ "$(metric lith_s3_bytes_total)" = "0" ] && return 0
    fi
    sleep 0.5
  done
  echo "FATAL: could not get a fresh lith mount" >&2
  return 1
}

# Key order matters: the sibling-walk detector keys off successive opens being
# adjacent in index order, so the walk must be sorted the way the index is.
mapfile -t FILES < <(cd "$FSX_DIR" && ls *.nc 2>/dev/null | sort | head -"$NFILES")
[ "${#FILES[@]}" -eq 0 ] && { echo "no .nc files under $FSX_DIR"; exit 1; }

total_bytes=0
released=0
for f in "${FILES[@]}"; do
  total_bytes=$(( total_bytes + $(stat -c %s "${FSX_DIR}/${f}") ))
  sudo lfs hsm_state "${FSX_DIR}/${f}" 2>/dev/null | grep -q released && released=$((released+1))
done

echo "gate 3b — HEMCO walk, lith '${LITH_VER}' vs FSx"
echo "  prefix=${HEMCO_REL}  files=${#FILES[@]}  total=$(mb $total_bytes) MB  HSM-released=${released}/${#FILES[@]}"
echo "  nic-gbps=${NIC_GBPS}"
echo

walk() {  # walk DIR -> wall seconds for the whole directory walk
  local dir="$1" t0 t1
  t0=$(now)
  for f in "${FILES[@]}"; do "$H5DUMP" -H "${dir}/${f}" >/dev/null 2>&1; done
  t1=$(now)
  elapsed "$t0" "$t1"
}

printf 'backend\tstate\tfiles\ttotal_MB\twall_s\ts3_MB\tdistinct_MB\tamp\tper_file_ms\n' > "$OUT"
emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$OUT"; }
perfile() { awk -v w="$1" -v n="$2" 'BEGIN{printf "%.0f", 1000*w/n}'; }

# FSx cold (as-released), then warm
w=$(walk "$FSX_DIR")
state=cold; [ "$released" -eq 0 ] && state=ALREADY-WARM
emit fsx "$state" "${#FILES[@]}" "$(mb $total_bytes)" "$w" - - - "$(perfile "$w" "${#FILES[@]}")"
echo "  fsx  $state   ${w}s   $(perfile "$w" "${#FILES[@]}") ms/file"

w=$(walk "$FSX_DIR")
emit fsx warm "${#FILES[@]}" "$(mb $total_bytes)" "$w" - - - "$(perfile "$w" "${#FILES[@]}")"
echo "  fsx  warm   ${w}s   $(perfile "$w" "${#FILES[@]}") ms/file"

# lith cold, then warm on the same mount
remount_lith || exit 1
w=$(walk "$MNT")
snap_metrics
s3=$(metric lith_s3_bytes_total); dist=$(metric lith_distinct_bytes_read)
emit lith cold "${#FILES[@]}" "$(mb $total_bytes)" "$w" "$(mb "$s3")" "$(mb "$dist")" \
     "$(ratio "$s3" "$dist")" "$(perfile "$w" "${#FILES[@]}")"
echo "  lith cold   ${w}s   $(perfile "$w" "${#FILES[@]}") ms/file   s3=$(mb "$s3")MB distinct=$(mb "$dist")MB amp=$(ratio "$s3" "$dist")x"
echo "         sibling-prefetch: $(metric lith_sibling_prefetch_total) issued, $(metric lith_sibling_prefetch_unread_total) unread"

w=$(walk "$MNT")
emit lith warm "${#FILES[@]}" "$(mb $total_bytes)" "$w" - - - "$(perfile "$w" "${#FILES[@]}")"
echo "  lith warm   ${w}s   $(perfile "$w" "${#FILES[@]}") ms/file"
echo

echo "=== $OUT ==="
column -t -s $'\t' "$OUT"
