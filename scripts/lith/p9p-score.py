# Score 5f-P9o/P9p (pre-registered in data/lith-gates/inregion-streams.txt).
# P9o: gauge == 4 on every tick of every mount arm; W1 bytes.  P9p: mount TTFB over the s3bench window
# (delta of the cumulative histogram between the ticks bracketing it) vs s3bench's own TTFB, plus box CPU.
import csv, glob, os, re, sys
d = sys.argv[1]

def rows(tag):
    return [{k: (float(v) if v not in ("NA", "") else None) for k, v in r.items()}
            for r in csv.DictReader(open(f"{d}/{tag}.csv"))]

def final(tag, key):
    for ln in open(f"{d}/{tag}.final.prom"):
        if ln.startswith(key + " "): return float(ln.split()[1])

def s3b(tag):
    p = f"{d}/{tag}.s3bench.txt"
    if not os.path.exists(p): return None
    t = open(p).read()
    m = re.search(r"TTFB .* p10=([\d.]+)ms p50=([\d.]+)ms p90=([\d.]+)ms p99=([\d.]+)ms\s+<=25ms=([\d.]+)% <=50ms=([\d.]+)%", t)
    c = re.search(r"cpu=([\d.]+)s \((\d+)% of", t)
    w = re.search(r"s3bench_start=([\d.]+) s3bench_end=([\d.]+)", t)
    return dict(p50=float(m.group(2)), p90=float(m.group(3)), le50=float(m.group(6)),
                cpu_pct=int(c.group(2)), t0=float(w.group(1)), t1=float(w.group(2)))

def window(R, t0, t1):  # histogram delta over the ticks bracketing [t0, t1]
    a = max([r for r in R if r["epoch"] <= t0 and r["count"] is not None], key=lambda r: r["epoch"], default=R[0])
    b = min([r for r in R if r["epoch"] >= t1 and r["count"] is not None], key=lambda r: r["epoch"], default=R[-1])
    n = b["count"] - a["count"]
    inside = [r for r in R if a["epoch"] <= r["epoch"] <= b["epoch"]]
    return dict(n=n, le25=(b["le025"] - a["le025"]) / n if n else None, le50=(b["le050"] - a["le050"]) / n if n else None,
                le100=(b["le100"] - a["le100"]) / n if n else None,
                cpu_mean=sum(r["cpu_busy_pct"] for r in inside) / len(inside), cpu_max=max(r["cpu_busy_pct"] for r in inside),
                infl_max=max(r["inflight"] or 0 for r in inside))

tags = sorted(os.path.basename(p)[:-4] for p in glob.glob(f"{d}/*.csv"))
print("P9o: gauge per tick (all mount arms)")
bad = 0
for t in tags:
    R = rows(t); g = [r["gauge"] for r in R]
    nz = sum(1 for x in g if x == 4); bad += len(g) - nz
    extra = ""
    if t.startswith("MA-W1") or t.startswith("MS-W1"): extra = " s3_MB=%.1f" % (final(t, "lith_s3_bytes_total") / 1e6)
    print("  %-10s gauge==4 on %d/%d ticks%s" % (t, nz, len(g), extra))
print("  P9o gauge verdict:", "PASS" if bad == 0 else f"FAIL ({bad} ticks not 4)")

print("\nP9p: whole-arm mount TTFB (final histogram) + depth + CPU")
for t in tags:
    R = rows(t); n = final(t, "lith_ttfb_seconds_count")
    le = lambda q: final(t, 'lith_ttfb_seconds_bucket{le="%s"}' % q) / n
    print("  %-10s n=%4d  <=25ms %5.1f%%  <=50ms %5.1f%%  <=100ms %5.1f%%  median_end %6.1f ms  inflight_max %3d  committed_max %6.0f MB  cpu mean/max %4.1f/%4.1f%%"
          % (t, n, 100 * le("0.025"), 100 * le("0.05"), 100 * le("0.1"), 1e3 * final(t, "lith_ttfb_median_seconds"),
             max(r["inflight"] or 0 for r in R), max(r["committed"] or 0 for r in R) / 1e6,
             sum(r["cpu_busy_pct"] for r in R) / len(R), max(r["cpu_busy_pct"] for r in R)))

print("\nP9p: same-moment comparison (MS arms) and s3bench-alone control")
for t in tags:
    if not t.startswith("MS"): continue
    s = s3b(t); w = window(rows(t), s["t0"], s["t1"])
    mount = "~100" if w["le50"] is not None and w["le50"] < 0.30 else ("~25" if w["le50"] is not None and w["le50"] >= 0.80 else "between")
    bench = "stays" if s["p50"] <= 40 else ("rises" if s["p50"] >= 60 else "between")
    print("  %-10s mount window n=%4d <=50ms %s (%s)  | s3bench p50 %.1f p90 %.1f <=50ms %.1f%% (%s) cpu %d%%  | box cpu mean/max %.1f/%.1f%%  inflight_max %d"
          % (t, w["n"], "NA" if w["le50"] is None else "%.1f%%" % (100 * w["le50"]), mount, s["p50"], s["p90"], s["le50"], bench,
             s["cpu_pct"], w["cpu_mean"], w["cpu_max"], w["infl_max"]))
for p in sorted(glob.glob(f"{d}/SA-*.s3bench.txt")):
    t = os.path.basename(p).split(".")[0]; s = s3b(t)
    print("  %-10s s3bench alone p50 %.1f p90 %.1f <=50ms %.1f%% cpu %d%%" % (t, s["p50"], s["p90"], s["le50"], s["cpu_pct"]))
