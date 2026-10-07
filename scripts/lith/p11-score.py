# Score 5f-P11/P12 dirs: per pair, pooled endpoint R and acquisition split by conn= for both programs.
import glob, os, re, statistics as st, sys
def one(prom, s3b):
    m = {}
    for ln in open(prom):
        if ln.startswith("#") or not ln.strip(): continue
        k, v = ln.rsplit(" ", 1); m[k] = float(v)
    g = lambda s, c, f: m.get(f'{s}_{f}{{conn="{c}"}}', 0)
    ln_ = {c: g("lith_s3_endpoint_ttfb_seconds", c, "count") for c in ("new", "reused")}
    le = sum(g("lith_s3_endpoint_ttfb_seconds", c, "sum") for c in ln_) / sum(ln_.values()) * 1e3
    la = {c: (g("lith_s3_conn_acquire_seconds", c, "sum") / g("lith_s3_conn_acquire_seconds", c, "count") * 1e3) if g("lith_s3_conn_acquire_seconds", c, "count") else float("nan") for c in ("new", "reused")}
    f50 = m.get('lith_ttfb_seconds_bucket{le="0.05"}', 0) / m.get("lith_ttfb_seconds_count", 1)
    t = open(s3b).read()
    sp = {x[0]: (int(x[1]), float(x[2]), float(x[3])) for x in re.findall(r"SPLIT\s+conn=(\w+)\s+n=\s*(\d+)\s+acquire=\s*([\d.]+)ms\s+write=\s*[\d.]+ms\s+endpoint=\s*([\d.]+)ms", t)}
    n = sum(v[0] for v in sp.values()); se = sum(v[0] * v[2] for v in sp.values()) / n
    s50 = float(re.search(r"<=50ms=([\d.]+)%", t).group(1))
    return dict(le=le, se=se, R=le / se, lshare=ln_["new"] / sum(ln_.values()), lacq_new=la["new"], lacq_reu=la["reused"],
                sshare=sp["new"][0] / n, sacq_new=sp["new"][1], sacq_reu=sp["reused"][1], l50=100 * f50, s50=s50)
for d in sys.argv[1:]:
    print(f"## {d}")
    rows = {}
    for p in sorted(glob.glob(f"{d}/*.final.prom")):
        tag = os.path.basename(p).split(".")[0]
        if tag == "WARMUP": continue
        x = one(p, f"{d}/{tag}.s3bench.txt"); rows[tag] = x
        when = open(f"{d}/{tag}.when").read().strip() if os.path.exists(f"{d}/{tag}.when") else ""
        reg = "SLOW" if x["se"] >= 70 else "fast"
        print(f"  {tag:4s} {when} {reg} | lith ep {x['le']:6.1f} <=50 {x['l50']:5.1f}% new {100*x['lshare']:4.1f}% acq new/reu {x['lacq_new']:5.2f}/{x['lacq_reu']:5.2f}"
              f" | s3b ep {x['se']:6.1f} <=50 {x['s50']:5.1f}% new {100*x['sshare']:4.1f}% acq new/reu {x['sacq_new']:5.2f}/{x['sacq_reu']:5.2f} | R {x['R']:.2f}")
    for pre in sorted({t[0] for t in rows}):
        xs = [v for k, v in rows.items() if k[0] == pre]
        print(f"  [{pre}] median lith reused-acq {st.median(v['lacq_reu'] for v in xs):.2f} ms, s3b reused-acq {st.median(v['sacq_reu'] for v in xs):.2f} ms,"
              f" lith new-share {100*st.median(v['lshare'] for v in xs):.1f}%, R median {st.median(v['R'] for v in xs):.2f}")
