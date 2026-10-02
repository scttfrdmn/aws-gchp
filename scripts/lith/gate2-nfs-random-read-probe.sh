#!/bin/bash
# Probe v2 — does `lith serve nfs` return the RIGHT BYTES AT AN ARBITRARY OFFSET
# under interleaved concurrent readers? Head node only, so free.
#
# WHY v2 EXISTS. Probe v1 (gate2-nfs-concurrency-probe.sh) came back perfectly
# clean: 96 concurrent md5sum of the same file through the gateway, zero bad
# bytes. But its own metrics showed why that proved little —
#     lith_nfs_ops_total{op="read"} 39      lith_s3_bytes_total 3.87e7
# i.e. ONE file's worth of reads. The kernel NFS client's page cache served the
# other 95 readers, so the gateway saw a single sequential pass no matter how many
# processes I started. Any single-host, cached, sequential test is structurally
# incapable of reproducing the gate 2 failure.
#
# What GCHP actually does is different in two ways that matter here:
#   1. netCDF-4/HDF5 issues POSITIONAL reads at scattered offsets (superblock,
#      B-tree nodes, chunk index, then chunks) — not one sequential sweep.
#   2. The gateway keeps per-file sequential-detection state (`lith_nfs_seq_states`)
#      and does read coalescing/prefetch off it. Interleaved offset streams from
#      many readers are exactly the input that could mis-serve.
# The observed errors fit that shape: `-51 NetCDF: Unknown file format` means the
# bytes at the START of the file were wrong, and `116 Stale file handle` means a
# handle went bad mid-flight — on a file that reads perfectly over FUSE.
#
# METHOD. Precompute the md5 of every 1 MiB block from the FSx copy of the same S3
# object (truth). Then have C concurrent workers each read R RANDOM blocks through
# the mount with `dd iflag=direct`, which bypasses the page cache so every read
# goes to the wire, and compare each block against truth for its own offset. A
# mismatch names the exact offset that was mis-served — a minimal repro upstream
# can act on, rather than "GCHP crashed".
set -o pipefail

GATES=/scratch/lith-gates
LITH=${GATES}/lith-1.1.1
PREFIX=GEOSCHEM_RESTARTS
IDX=${GATES}/idx/restarts.lithidx
REL=GC_14.7.0/GEOSChem.Restart.TransportTracers.20190101_0000z.c24.nc4
TRUTH=/input/${PREFIX}/${REL}
NPORT=20494
GPORT=9214
MPORT=9114
NFSMNT=/mnt/lith-nfs
FUSEMNT=/mnt/lith-fuse
OUT=${GATES}/nfs-random-probe-results.txt
NBLK=36            # 1 MiB blocks; the file is 38736962 B = 36.94 MiB
READS=20           # random reads per worker

say()  { echo; echo "=== $* ==="; }
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; }
exec > >(tee -a "$OUT") 2>&1
echo "### random-read probe $(date -u +%FT%TZ) on $(hostname)"

cleanup() {
  sudo umount -f "$NFSMNT" 2>/dev/null || sudo umount -l "$NFSMNT" 2>/dev/null
  fusermount3 -u "$FUSEMNT" 2>/dev/null
  pkill -f '[l]ith-1.1.1' 2>/dev/null
  sleep 2
}
cleanup

say "truth table — md5 of each 1 MiB block, from the FSx copy of the same object"
if [[ ! -r "$TRUTH" ]]; then bad "no FSx copy at $TRUTH"; exit 1; fi
TRUTHDIR=$(mktemp -d)
for ((b=0; b<NBLK; b++)); do
  dd if="$TRUTH" bs=1M skip="$b" count=1 status=none 2>/dev/null | md5sum | awk '{print $1}'
done > "${TRUTHDIR}/truth.txt"
ok "$(wc -l < "${TRUTHDIR}/truth.txt") block hashes  file=$(stat -c %s "$TRUTH") B"

# One worker: R random blocks, O_DIRECT, each compared to truth for that offset.
# `iflag=direct` is the whole point — without it the page cache answers and the
# gateway is never asked (that is exactly how probe v1 fooled itself).
worker() {
  local mnt=$1 id=$2 direct=$3
  local f="${mnt}/${REL}"
  local flag=""; [[ "$direct" == "yes" ]] && flag="iflag=direct"
  local i b got want
  for ((i=0; i<READS; i++)); do
    b=$(( (RANDOM * 32768 + RANDOM) % NBLK ))
    got=$(dd if="$f" bs=1M skip="$b" count=1 status=none $flag 2>/dev/null | md5sum | awk '{print $1}')
    want=$(sed -n "$((b+1))p" "${TRUTHDIR}/truth.txt")
    if [[ -z "$got" || "$got" == "d41d8cd98f00b204e9800998ecf8427e" ]]; then
      echo "${id} blk=${b} EMPTY_OR_ERR"
    elif [[ "$got" != "$want" ]]; then
      echo "${id} blk=${b} MISMATCH got=${got} want=${want}"
    fi
  done
}
export -f worker
export REL TRUTHDIR READS NBLK

ladder() {
  local mnt=$1 label=$2 direct=$3
  for C in 8 32 96; do
    local tmp; tmp=$(mktemp) pids=()
    local t0 t1
    t0=$(date +%s.%N)
    for ((i=1; i<=C; i++)); do worker "$mnt" "$i" "$direct" >> "$tmp" & pids+=($!); done
    # Explicit PIDs, never a bare `wait` — a bare wait also blocks on the tee from
    # `exec > >(tee ...)` above, which never exits. That deadlocked probe v1.
    wait "${pids[@]}" 2>/dev/null
    t1=$(date +%s.%N)
    local mism err total
    mism=$(grep -c MISMATCH "$tmp"); err=$(grep -c EMPTY_OR_ERR "$tmp")
    total=$(( C * READS ))
    printf 'RAND %-5s direct=%-3s C=%-3s reads=%-5s mismatch=%-4s err=%-4s  %.2fs\n' \
      "$label" "$direct" "$C" "$total" "$mism" "$err" \
      "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')"
    if (( mism + err > 0 )); then
      echo "  --- first 5 bad reads:"; head -5 "$tmp" | sed 's/^/      /'
    fi
    rm -f "$tmp"
  done
}

say "arm A — FUSE control, random offsets"
sudo mkdir -p "$FUSEMNT" && sudo chown "$(id -u):$(id -g)" "$FUSEMNT"
${LITH} mount "s3://gcgrid/${PREFIX}" "$FUSEMNT" --index-file "$IDX" \
   --no-sign-request --mem-cache 4GB --metrics ":${MPORT}" --daemon >/dev/null 2>&1
sleep 5
if mountpoint -q "$FUSEMNT"; then ok "FUSE mounted"; ladder "$FUSEMNT" FUSE no
else bad "FUSE mount failed"; fi
fusermount3 -u "$FUSEMNT" 2>/dev/null; pkill -f '[l]ith-1.1.1' 2>/dev/null; sleep 2

say "arm B — NFS gateway, random offsets, O_DIRECT (every read hits the wire)"
cd /tmp || exit 1
setsid nohup ${LITH} serve nfs "s3://gcgrid/${PREFIX}" --index-file "$IDX" \
   --no-sign-request --mem-cache 4GB --listen ":${NPORT}" --metrics ":${GPORT}" \
   > "${GATES}/nfs-random-serve.log" 2>&1 < /dev/null &
sleep 8
if ! ss -ltn | grep -q ":${NPORT} "; then
  bad "gateway not listening"; tail -5 "${GATES}/nfs-random-serve.log"; cleanup; exit 1
fi
ok "gateway listening on :${NPORT}"
sudo mkdir -p "$NFSMNT"
# noac/actimeo=0 additionally stops the client caching ATTRIBUTES, so it cannot
# satisfy a stat from cache either. Combined with O_DIRECT the client becomes a
# thin pass-through and the gateway is genuinely under C-way concurrency.
sudo mount -t nfs -o vers=3,proto=tcp,port=${NPORT},mountport=${NPORT},nolock,ro,noac,actimeo=0 \
   localhost:/ "$NFSMNT" 2>&1 | sed 's/^/  /'
if mountpoint -q "$NFSMNT"; then
  ok "NFS mounted (noac, O_DIRECT reads)"
  ladder "$NFSMNT" NFS yes
else bad "NFS mount failed"; fi

say "gateway metrics — confirm the reads actually reached it this time"
curl -s --max-time 5 "http://localhost:${GPORT}/metrics" \
  | grep -E '^lith_(nfs|s3_bytes_total|s3_get|error|fallback)' | head -20

say "gateway log"
grep -iE "error|warn|stale|handle|panic" "${GATES}/nfs-random-serve.log" | head -15

rm -rf "$TRUTHDIR"
cleanup
say "RANDOM-READ SUMMARY"
grep -E "^RAND" "$OUT" | tail -8
