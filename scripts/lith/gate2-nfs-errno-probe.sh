#!/bin/bash
# Probe v3 — pin down the `lith serve nfs` concurrency failure: what errno, at what
# concurrency, and is it the server refusing or the client giving up?
#
# WHERE v3 PICKS UP. v2 reproduced the gate 2 failure on the head node alone:
#   RAND NFS direct=yes C=8   reads=160  mismatch=0 err=0
#   RAND NFS direct=yes C=32  reads=640  mismatch=0 err=0
#   RAND NFS direct=yes C=96  reads=1920 mismatch=0 err=232     <-- 12% of reads fail
#   RAND FUSE direct=no C=96  reads=1920 mismatch=0 err=0       <-- control clean
# Two things that matters a lot for the bug report:
#   * mismatch=0 EVERYWHERE. The gateway never served wrong bytes. The failure is
#     reads that do not complete, not silent corruption. (Good news for lith: a
#     correctness bug would be far worse than a capacity bug.)
#   * Only 38.7 MB came from S3 while 2.6 GB was served from mem-cache, so S3 and
#     the network are not implicated at all.
# v2 recorded "EMPTY_OR_ERR" without keeping dd's stderr, so the errno is still
# unknown — and errno is the difference between a server-side limit (EIO/ESTALE
# from the gateway), a client-side RPC slot exhaustion (sunrpc), and a timeout.
# Reporting "12% of reads fail" without it would hand upstream a mystery.
#
# WHAT THIS ADDS
#   1. Captures dd's stderr verbatim per failing read, and tallies errno strings.
#   2. Walks C = 32,48,64,96,128 to locate the threshold rather than assume it.
#   3. Samples the client's own RPC counters (/proc/net/rpc/nfs + nfsstat) around
#      each rung, so a client-side retransmit/slot problem is visible as such.
#   4. Watches the gateway's goroutine/fd count, so a server-side cap shows up too.
# Head node only, so free.
set -o pipefail

GATES=/scratch/lith-gates
LITH=${GATES}/lith-1.1.1
PREFIX=GEOSCHEM_RESTARTS
IDX=${GATES}/idx/restarts.lithidx
REL=GC_14.7.0/GEOSChem.Restart.TransportTracers.20190101_0000z.c24.nc4
NPORT=20494
GPORT=9214
NFSMNT=/mnt/lith-nfs
OUT=${GATES}/nfs-errno-probe-results.txt
NBLK=36
READS=20

say()  { echo; echo "=== $* ==="; }
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; }
exec > >(tee -a "$OUT") 2>&1
echo "### errno probe $(date -u +%FT%TZ) on $(hostname)"

cleanup() {
  sudo umount -f "$NFSMNT" 2>/dev/null || sudo umount -l "$NFSMNT" 2>/dev/null
  pkill -f '[l]ith-1.1.1' 2>/dev/null
  sleep 2
}
cleanup

say "start gateway"
cd /tmp || exit 1
setsid nohup ${LITH} serve nfs "s3://gcgrid/${PREFIX}" --index-file "$IDX" \
   --no-sign-request --mem-cache 4GB --listen ":${NPORT}" --metrics ":${GPORT}" \
   > "${GATES}/nfs-errno-serve.log" 2>&1 < /dev/null &
sleep 8
ss -ltn | grep -q ":${NPORT} " || { bad "gateway not listening"; tail -5 "${GATES}/nfs-errno-serve.log"; exit 1; }
GWPID=$(pgrep -f '[l]ith-1.1.1 serve' | head -1)
ok "gateway listening on :${NPORT} (pid ${GWPID})"

sudo mkdir -p "$NFSMNT"
# MOPTS is overridable so the run can be repeated with PLAIN mount options. That
# control matters for the bug report: the first run used `noac,actimeo=0`, which
# inflates GETATTR about 10:1 (59068 getattr vs 6230 read), and a reviewer is
# entitled to ask whether the ESTALE is an artifact of my own mount flags rather
# than a real defect. Gate 2's failing GCHP arm used plain options, so re-running
# plain here either exonerates the flags or tells me my repro is the wrong one.
MOPTS=${MOPTS:-nolock,ro,noac,actimeo=0}
echo "  mount opts: ${MOPTS}"
sudo mount -t nfs -o "vers=3,proto=tcp,port=${NPORT},mountport=${NPORT},${MOPTS}" \
   localhost:/ "$NFSMNT" 2>&1 | sed 's/^/  /'
mountpoint -q "$NFSMNT" || { bad "mount failed"; cleanup; exit 1; }
ok "mounted"

# stderr is the payload here: dd prints the real errno text, e.g.
# "Input/output error", "Stale file handle", "Cannot allocate memory".
worker() {
  local id=$1
  local f="${NFSMNT}/${REL}"
  local i b rc errtxt
  for ((i=0; i<READS; i++)); do
    b=$(( (RANDOM * 32768 + RANDOM) % NBLK ))
    errtxt=$(dd if="$f" bs=1M skip="$b" count=1 iflag=direct of=/dev/null 2>&1 >/dev/null)
    rc=$?
    if (( rc != 0 )); then
      echo "id=${id} blk=${b} rc=${rc} err=$(echo "$errtxt" | tr '\n' ' ' | sed 's/  */ /g')"
    fi
  done
}
export -f worker
export NFSMNT REL READS NBLK

rpc_snapshot() { awk '/^rpc /{printf "calls=%s retrans=%s authrefresh=%s", $2, $3, $4}' /proc/net/rpc/nfs 2>/dev/null; }

say "concurrency ladder with errno capture"
for C in 32 48 64 96 128; do
  tmp=$(mktemp); pids=()
  before=$(rpc_snapshot)
  t0=$(date +%s.%N)
  for ((i=1; i<=C; i++)); do worker "$i" >> "$tmp" & pids+=($!); done
  wait "${pids[@]}" 2>/dev/null      # explicit PIDs: a bare wait deadlocks on tee
  t1=$(date +%s.%N)
  after=$(rpc_snapshot)
  nfail=$(wc -l < "$tmp"); total=$(( C * READS ))
  gwthreads=$(awk '/^Threads:/{print $2}' /proc/${GWPID}/status 2>/dev/null)
  gwfds=$(ls /proc/${GWPID}/fd 2>/dev/null | wc -l)
  printf 'ERRNO C=%-4s reads=%-5s fail=%-5s (%5.1f%%)  %.2fs  gw_threads=%-4s gw_fds=%-4s\n' \
    "$C" "$total" "$nfail" "$(awk -v a="$nfail" -v b="$total" 'BEGIN{print 100*a/b}')" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" "${gwthreads:-?}" "${gwfds:-?}"
  echo "      client rpc before: ${before}"
  echo "      client rpc after:  ${after}"
  if (( nfail > 0 )); then
    echo "      errno tally:"
    sed 's/.*err=//' "$tmp" | sed 's/[0-9]\+ bytes.*//' | sort | uniq -c | sort -rn | head -5 | sed 's/^/        /'
    echo "      sample failures:"; head -3 "$tmp" | sed 's/^/        /'
  fi
  rm -f "$tmp"
done

say "gateway metrics"
curl -s --max-time 5 "http://localhost:${GPORT}/metrics" \
  | grep -E '^lith_(nfs|s3_bytes_total|error|fallback)' | head -20

say "gateway log — server side of the story"
grep -viE "No handler for 100227" "${GATES}/nfs-errno-serve.log" | tail -20

say "kernel ring — client side complaints (nfs: server ... not responding etc)"
sudo dmesg -T 2>/dev/null | grep -iE "nfs|rpc" | tail -15 || echo "  (dmesg unavailable)"

cleanup
say "ERRNO SUMMARY"
grep -E "^ERRNO" "$OUT" | tail -10
