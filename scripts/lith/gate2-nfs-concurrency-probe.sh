#!/bin/bash
# Isolate the gate 2 `lith serve nfs` failure from GCHP, on the HEAD NODE ONLY.
#
# WHAT WENT WRONG UPSTREAM OF THIS SCRIPT
# Gate 2 arm nfs-r1 (2 nodes, 96 ranks) died 4 s in with, on many ranks at once:
#     nf90_open ... error code (-51) ... [NetCDF: Unknown file format]
#     nf90_open ... error code (116) ... [Stale file handle]
#     pe=00071 FAIL at line=00297  NetCDF4_FileFormatter.F90  <status=-51>
#     pe=00071 FAIL at line=00517  MAPL_GridManager.F90       <status=-51>
# on gchp_restart.nc4 — served through the gateway. The SAME file over per-node
# lith FUSE mounts works: arm mount-r1 completed 144/144 timesteps, twice.
# MAPL_GridManager.F90:517 is not gated by NUM_READERS, so all 96 ranks open that
# one file at once. "Unknown file format" means netCDF did not find a valid HDF5
# signature, i.e. the bytes returned were wrong — not that the file was missing.
#
# WHY A PROBE INSTEAD OF ANOTHER 2-NODE JOB
# "GCHP saw garbage" is a weak bug report and an expensive test. Comparing md5
# against the same object on FSx turns it into "the gateway returned N wrong
# bytes at concurrency C", needs no MPI, no model, and no compute nodes — the
# head node is already billing, so this costs nothing. It also separates three
# candidate culprits that the GCHP log cannot: the gateway, the NFS client's
# caching, and HDF5's own locking behaviour over NFS.
#
# Runs entirely on the head node. Port 20494, NOT 2049 — the ParallelCluster head
# node's kernel nfsd already owns 2049 for the /home export to compute nodes.
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
OUT=${GATES}/nfs-probe-results.txt

say()  { echo; echo "=== $* ==="; }
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; }
exec > >(tee -a "$OUT") 2>&1
echo "### probe $(date -u +%FT%TZ) on $(hostname)"

cleanup() {
  sudo umount -f "$NFSMNT" 2>/dev/null || sudo umount -l "$NFSMNT" 2>/dev/null
  fusermount3 -u "$FUSEMNT" 2>/dev/null
  pkill -f '[l]ith-1.1.1' 2>/dev/null
  sleep 2
}
cleanup

say "truth: the same S3 object as materialised by FSx Lustre"
if [[ ! -r "$TRUTH" ]]; then bad "no FSx copy at $TRUTH"; exit 1; fi
TRUTH_MD5=$(md5sum "$TRUTH" | awk '{print $1}')
TRUTH_SZ=$(stat -c %s "$TRUTH")
ok "md5=${TRUTH_MD5}  size=${TRUTH_SZ}"

# One reader: md5, size, and the 4-byte magic. netCDF-4/HDF5 files begin with
# \211HDF, so a wrong magic pins the corruption to the first block specifically,
# which is a different bug from a wrong byte in the middle.
reader() {
  local mnt=$1 id=$2
  local f="${mnt}/${REL}"
  local sz md5 magic
  sz=$(stat -c %s "$f" 2>/dev/null || echo ERR)
  md5=$(md5sum "$f" 2>/dev/null | awk '{print $1}'); [[ -n "$md5" ]] || md5=ERR
  magic=$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n'); [[ -n "$magic" ]] || magic=ERR
  echo "${id} ${sz} ${md5} ${magic}"
}
export -f reader
export REL

# Concurrency ladder against one mount. Every reader opens the SAME file, which
# is what MAPL_GridManager does at line 517.
ladder() {
  local mnt=$1 label=$2
  for C in 1 4 16 48 96; do
    local tmp; tmp=$(mktemp)
    local t0 t1 pids=()
    t0=$(date +%s.%N)
    for i in $(seq 1 "$C"); do reader "$mnt" "$i" >> "$tmp" & pids+=($!); done
    # Wait on the collected PIDs, NOT a bare `wait`. In bash 5 a bare `wait` also
    # waits for the process substitution created by `exec > >(tee ...)` at the top
    # of this script, and tee does not exit until the script's stdout closes — so
    # the two deadlock and the ladder hangs forever with every reader already
    # finished. Cost 15 minutes of head-node head-scratching; the readers were
    # done and the script was blocked on its own logger.
    wait "${pids[@]}" 2>/dev/null
    t1=$(date +%s.%N)
    local good bad_md5 bad_sz bad_magic err
    good=$(awk -v m="$TRUTH_MD5" '$3==m' "$tmp" | wc -l)
    bad_md5=$(awk -v m="$TRUTH_MD5" '$3!=m && $3!="ERR"' "$tmp" | wc -l)
    err=$(awk '$3=="ERR"' "$tmp" | wc -l)
    bad_sz=$(awk -v s="$TRUTH_SZ" '$2!=s' "$tmp" | wc -l)
    bad_magic=$(awk '$4!="89484446"' "$tmp" | wc -l)
    printf 'PROBE %-6s C=%-3s good=%-3s bad_md5=%-3s err=%-3s bad_size=%-3s bad_magic=%-3s  %.2fs\n' \
      "$label" "$C" "$good" "$bad_md5" "$err" "$bad_sz" "$bad_magic" \
      "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')"
    if (( bad_md5 + err + bad_sz > 0 )); then
      echo "  --- first 3 non-matching readers (id size md5 magic):"
      awk -v m="$TRUTH_MD5" -v s="$TRUTH_SZ" '$3!=m || $2!=s' "$tmp" | head -3 | sed 's/^/      /'
    fi
    rm -f "$tmp"
  done
}

# --------------------------------------------------------------- arm A: FUSE control
# This arm is the control, and it matters: if FUSE also fails then the bug is in
# lith's S3 read path or my index, not in the NFS gateway, and the gate 2
# conclusion would be entirely different.
say "arm A — per-node FUSE mount (control; this path completed GCHP twice)"
# /mnt is root-owned, so a plain mkdir fails and silently costs the control arm.
sudo mkdir -p "$FUSEMNT" && sudo chown "$(id -u):$(id -g)" "$FUSEMNT"
${LITH} mount "s3://gcgrid/${PREFIX}" "$FUSEMNT" --index-file "$IDX" \
   --no-sign-request --mem-cache 4GB --metrics ":${MPORT}" --daemon >/dev/null 2>&1
sleep 5
if mountpoint -q "$FUSEMNT"; then ok "FUSE mounted"; ladder "$FUSEMNT" FUSE
else bad "FUSE mount failed — cannot establish a control"; fi
fusermount3 -u "$FUSEMNT" 2>/dev/null
pkill -f '[l]ith-1.1.1' 2>/dev/null; sleep 2

# ------------------------------------------------------------ arm B: NFS gateway
say "arm B — lith serve nfs gateway, single client host"
cd /tmp || exit 1
setsid nohup ${LITH} serve nfs "s3://gcgrid/${PREFIX}" --index-file "$IDX" \
   --no-sign-request --mem-cache 4GB --listen ":${NPORT}" --metrics ":${GPORT}" \
   > "${GATES}/nfs-probe-serve.log" 2>&1 < /dev/null &
sleep 8
if ! ss -ltn | grep -q ":${NPORT} "; then
  bad "gateway not listening on :${NPORT}"; tail -5 "${GATES}/nfs-probe-serve.log"; cleanup; exit 1
fi
ok "gateway listening on :${NPORT}"
sudo mkdir -p "$NFSMNT"
sudo mount -t nfs -o vers=3,proto=tcp,port=${NPORT},mountport=${NPORT},nolock,ro \
   localhost:/ "$NFSMNT" 2>&1 | sed 's/^/  /'
if mountpoint -q "$NFSMNT"; then ok "NFS mounted"; ladder "$NFSMNT" NFS
else bad "NFS mount failed"; fi

say "gateway metrics"
curl -s --max-time 5 "http://localhost:${GPORT}/metrics" \
  | grep -E '^lith_(s3_bytes_total|s3_get|nfs|error|fallback)' | head -20

say "gateway log — anything it complained about"
grep -iE "error|warn|stale|handle|panic|concurren" "${GATES}/nfs-probe-serve.log" | head -15

cleanup
say "PROBE SUMMARY"
grep -E "^PROBE" "$OUT" | tail -12
