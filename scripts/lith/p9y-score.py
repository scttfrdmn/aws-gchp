# Score 5f-P9y: pooled endpoint mean, lith vs s3bench, same instant.
import glob, os, re, sys
d = sys.argv[1]
for p in sorted(glob.glob(f"{d}/*.final.prom")):
    tag = os.path.basename(p).split(".")[0]; m = {}
    for ln in open(p):
        if ln.startswith("#") or not ln.strip(): continue
        k, v = ln.rsplit(" ", 1); m[k] = float(v)
    def pooled(s):
        n = sum(m.get(f'{s}_count{{conn="{c}"}}', 0) for c in ("new", "reused"))
        return (sum(m.get(f'{s}_sum{{conn="{c}"}}', 0) for c in ("new", "reused")) / n * 1e3 if n else float("nan")), n
    le, ln_ = pooled("lith_s3_endpoint_ttfb_seconds"); lw, _ = pooled("lith_s3_wire_ttfb_seconds"); la, _ = pooled("lith_s3_conn_acquire_seconds")
    f50 = m.get('lith_ttfb_seconds_bucket{le="0.05"}', 0) / m.get("lith_ttfb_seconds_count", 1)
    t = open(f"{d}/{tag}.s3bench.txt").read()
    sp = re.findall(r"SPLIT\s+conn=(\w+)\s+n=\s*(\d+)\s+acquire=\s*([\d.]+)ms write=\s*([\d.]+)ms endpoint=\s*([\d.]+)ms\s+wire=\s*([\d.]+)ms", t)
    n = sum(int(x[1]) for x in sp); se = sum(int(x[1]) * float(x[4]) for x in sp) / n; sw = sum(int(x[1]) * float(x[5]) for x in sp) / n
    sa = sum(int(x[1]) * float(x[2]) for x in sp) / n
    s50 = float(re.search(r"<=50ms=([\d.]+)%", t).group(1)) / 100; auth = re.search(r"auth=(\w+)", t).group(1)
    R = le / se
    v = "MATCH" if 0.80 <= R <= 1.25 else ("DIFFER" if R >= 1.5 else "between")
    print(f"{tag:7s} lith n={ln_:3.0f} endpoint {le:6.1f} wire {lw:6.1f} acq {la:5.1f} ms <=50 {100*f50:5.1f}% | s3bench({auth}) n={n:3d} endpoint {se:6.1f} wire {sw:6.1f} acq {sa:5.1f} ms <=50 {100*s50:5.1f}% | R={R:4.2f} {v}")
