#!/bin/bash
# Gate 5f-P11 (lith#232): what does a serial random page-fault stream cost per fault, in-region
# vs cross-region? Pre-registered in data/lith-gates/inregion-streams.txt before any cell ran.
#
# One process mmaps one object PROT_READ (MADV_NORMAL, as a bwa-style index reader would) and
# touches 3000 distinct random 4 KiB pages, serially, timing each fault. The original #232 run
# (892 MB fasta.gz, region unknown) was 326 s / 676 MB = 109 ms per fault. Head node; cross-region
# from a throwaway us-west-2 copy that is deleted after.
set -u

G=${G:-/scratch/lith-gates}
OUT=${OUT:-$G/p11}
MNT=${MNT:-/scratch/mnt/p11}
B=${B:-$G/lith-324}
PYX=${PYX:-/scratch/ncenv/bin/python}
OBJ=${OBJ:-GEOSFP.20190701.A3mstC.025x03125.nc}
XPREFIX=${XPREFIX:-s3://gchp-lith-xregion-usw2-942542972736/geosfp}
IPREFIX=${IPREFIX:-s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07}
NFAULT=${NFAULT:-3000}
REPS=${REPS:-2}
PORT_BASE=${PORT_BASE:-10150}
mkdir -p "$OUT" "$MNT"

cat > "$OUT/faults.py" <<'PY'
import mmap, os, random, sys, time
path, n, seed, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
fd = os.open(path, os.O_RDONLY)
size = os.fstat(fd).st_size
mm = mmap.mmap(fd, size, prot=mmap.PROT_READ)
pages = random.Random(seed).sample(range(size // 4096), n)
lat = []
t0 = time.perf_counter()
for p in pages:
    s = time.perf_counter(); mm[p * 4096]; lat.append(time.perf_counter() - s)
wall = time.perf_counter() - t0
open(out, "w").write("\n".join("%d %.6f" % (p, l) for p, l in zip(pages, lat)) + "\n")
lat.sort()
q = lambda f: lat[min(len(lat) - 1, int(f * len(lat)))] * 1e3
print("faults=%d wall=%.2f per_fault_ms=%.2f p50=%.2f p90=%.2f p99=%.2f max=%.2f under_1ms=%d"
      % (n, wall, wall / n * 1e3, q(.5), q(.9), q(.99), lat[-1] * 1e3, sum(1 for l in lat if l < 1e-3)))
PY

umount_wait() {
  fusermount3 -u "$MNT" 2>/dev/null
  for _ in $(seq 1 40); do mountpoint -q "$MNT" || return 0; sleep 0.5; done
  echo "  WARNING: $MNT still mounted"
}

N=0
run_cell() {
  local where=$1 rep=$2 prefix tag="M$1-$2"
  [ "$where" = X ] && prefix=$XPREFIX || prefix=$IPREFIX
  N=$((N + 1)); local PORT=$((PORT_BASE + N))
  umount_wait
  "$B" mount "$prefix" "$MNT" --metrics ":$PORT" --log-level info \
      --pf-trace "$OUT/$tag.trace.csv" > "$OUT/$tag.mount.log" 2>&1 &
  for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || { echo "$tag MOUNT FAILED"; tail -n 3 "$OUT/$tag.mount.log"; return 1; }
  local rd met
  # Same seed every rep and both regions: the identical page set, so only distance varies.
  rd=$($PYX "$OUT/faults.py" "$MNT/$OBJ" "$NFAULT" 232 "$OUT/$tag.lat" 2>&1)
  met=$(curl -s "http://127.0.0.1:$PORT/metrics" | grep -v '^#' | awk '
    /^lith_s3_bytes_total /{b=$2} /^lith_s3_requests_total/{r+=$2} /^lith_distinct_bytes_read /{d=$2}
    /^lith_prefetch_issued_total /{s=$2}
    END{printf "s3_MB=%.1f GETs=%d distinct_MB=%.1f KiB_per_fault=%.0f prefetch_issued=%d",
        b/1e6, r, d/1e6, b/1024/'"$NFAULT"', s}')
  echo "CELL $tag $rd $met"
  grep -o '"msg":"nic bandwidth"[^}]*' "$OUT/$tag.mount.log" | head -1 | sed 's/^/  /'
  umount_wait
}

echo "=== gate 5f-P11  $(date -u +%FT%TZ)  B=$(md5sum "$B" | cut -c1-12)  $OBJ faults=$NFAULT"
for rep in $(seq 1 "$REPS"); do
  run_cell I "$rep"; run_cell X "$rep"
done
echo "=== done $(date -u +%FT%TZ)"
