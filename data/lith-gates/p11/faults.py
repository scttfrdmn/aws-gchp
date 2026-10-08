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
