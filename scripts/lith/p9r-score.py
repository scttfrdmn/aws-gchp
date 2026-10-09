# Score 5f-P9r: per conn label, wire TTFB and acquisition; fill histogram for reference.
import glob, os, re, sys
def load(p):
    m = {}
    for ln in open(p):
        if ln.startswith("#") or not ln.strip(): continue
        k, v = ln.rsplit(" ", 1); m[k] = float(v)
    return m
def h(m, name, conn=None):
    lab = f'conn="{conn}",' if conn else ""
    n = m.get(f"{name}_count{{conn=\"{conn}\"}}" if conn else f"{name}_count", 0)
    s = m.get(f"{name}_sum{{conn=\"{conn}\"}}" if conn else f"{name}_sum", 0)
    b = lambda q: m.get(f'{name}_bucket{{{lab}le="{q}"}}', 0)
    return n, s, b
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.final.prom"))):
    m = load(p); tag = os.path.basename(p).split(".")[0]
    fn, fs, fb = h(m, "lith_ttfb_seconds")
    print(f"{tag}: fill n={fn:.0f} <=50 {100*fb('0.05')/fn:.1f}% mean {1e3*fs/fn:.1f} ms")
    for c in ("new", "reused"):
        n, s, b = h(m, "lith_s3_wire_ttfb_seconds", c); an, as_, ab = h(m, "lith_s3_conn_acquire_seconds", c)
        if n == 0: print(f"   {c:6s} wire n=0"); continue
        print(f"   {c:6s} wire n={n:4.0f} <=25 {100*b('0.025')/n:5.1f}% <=50 {100*b('0.05')/n:5.1f}% <=100 {100*b('0.1')/n:5.1f}% mean {1e3*s/n:6.1f} ms"
              f" | acquire n={an:4.0f} <=10 {100*ab('0.01')/an if an else 0:5.1f}% <=25 {100*ab('0.025')/an if an else 0:5.1f}% <=50 {100*ab('0.05')/an if an else 0:5.1f}% mean {1e3*as_/an if an else 0:6.1f} ms")
