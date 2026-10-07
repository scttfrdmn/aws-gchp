# 5f-P9z: acquisition split by conn label, lith vs s3bench, per rep (upstream 20:11Z ask).
import glob, os, re, statistics as st, sys
d = sys.argv[1]; rows = []
for s in sorted(glob.glob(f"{d}/s[0-9]")):
    for r in ("R1", "R2", "R3", "R4", "R5"):
        m = {}
        for ln in open(f"{s}/{r}.final.prom"):
            if ln.startswith("#") or not ln.strip(): continue
            k, v = ln.rsplit(" ", 1); m[k] = float(v)
        L = {c: (m[f'lith_s3_conn_acquire_seconds_count{{conn="{c}"}}'], m[f'lith_s3_conn_acquire_seconds_sum{{conn="{c}"}}']) for c in ("new", "reused")}
        S = {x[0]: (int(x[1]), float(x[2])) for x in re.findall(r"SPLIT\s+conn=(\w+)\s+n=\s*(\d+)\s+acquire=\s*([\d.]+)ms", open(f"{s}/{r}.s3bench.txt").read())}
        ln_, lr = L["new"][0], L["reused"][0]; sn, sr = S["new"][0], S["reused"][0]
        rows.append(dict(tag=f"{os.path.basename(s)}-{r}", l_share=ln_ / (ln_ + lr), l_new=1e3 * L["new"][1] / ln_, l_reu=1e3 * L["reused"][1] / lr,
                         l_pool=1e3 * (L["new"][1] + L["reused"][1]) / (ln_ + lr), s_share=sn / (sn + sr), s_new=S["new"][1], s_reu=S["reused"][1],
                         s_pool=(sn * S["new"][1] + sr * S["reused"][1]) / (sn + sr)))
print("tag      lith new-share  acq new / reused / pooled (ms)   | s3bench new-share  acq new / reused / pooled")
for x in rows:
    print(f"{x['tag']:8s} {100*x['l_share']:5.1f}%   {x['l_new']:6.2f} / {x['l_reu']:5.2f} / {x['l_pool']:5.2f}      | {100*x['s_share']:5.1f}%   {x['s_new']:6.2f} / {x['s_reu']:5.2f} / {x['s_pool']:5.2f}")
q = lambda k: (min(x[k] for x in rows), st.median(x[k] for x in rows), max(x[k] for x in rows))
for k in ("l_share", "l_new", "l_reu", "l_pool", "s_share", "s_new", "s_reu", "s_pool"):
    a, b, c = q(k); f = 100 if "share" in k else 1
    print(f"  {k:8s} min {f*a:7.2f}  median {f*b:7.2f}  max {f*c:7.2f}")
# predicted pooled from share alone, using each rep's own s3bench reused/new costs as the "per-connection" baseline
pred = [x["l_share"] * x["s_new"] + (1 - x["l_share"]) * x["s_reu"] for x in rows]
print("  lith pooled predicted from its new-share x s3bench per-class costs: min %.2f median %.2f max %.2f ms" % (min(pred), st.median(pred), max(pred)))
