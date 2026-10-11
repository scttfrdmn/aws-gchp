# lith#407 direction-1 witness: a handle that reads SCATTERED (irregular small preads, like a header/index walk) and
# THEN streams a long contiguous stretch. Direction 1 bounds the first establishment of a handle with a Random history,
# so this is the shape that could pay for it: the stream phase must not get slower.
# Usage: python scatter_stream.py <file> <stream_MB>. Prints one JSON line with per-phase wall and throughput.
import json, os, random, sys, time
p, smb = sys.argv[1], int(sys.argv[2])
R = random.Random(407)
sz = os.path.getsize(p); fd = os.open(p, os.O_RDONLY)
# phase 1: 40 scattered 8 KiB reads at irregular, increasing offsets within the first 256 MiB (gaps 1-12 MiB)
t0 = time.perf_counter(); off = 0; n1 = 0
for _ in range(40):
    off += R.randint(1 << 20, 12 << 20)
    if off + 8192 > min(sz, 256 << 20): break
    n1 += len(os.pread(fd, 8192, off))
t1 = time.perf_counter()
# phase 2: stream smb MiB contiguously from just past the last scattered read, 1 MiB reads
pos = off + 8192; end = min(sz, pos + (smb << 20)); n2 = 0
while pos < end:
    b = os.pread(fd, min(1 << 20, end - pos), pos); n2 += len(b); pos += len(b)
    if not b: break
t2 = time.perf_counter(); os.close(fd)
print(json.dumps({"scatter_reads_bytes": n1, "scatter_s": round(t1 - t0, 3), "stream_bytes": n2,
                  "stream_s": round(t2 - t1, 3), "stream_MBps": round(n2 / (t2 - t1) / 1e6, 1)}))
