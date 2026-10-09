# 5f-P9v: composition check, then per-label acquire/write/endpoint/wire.
import glob, os, sys
S = ["lith_s3_conn_acquire_seconds", "lith_s3_request_write_seconds", "lith_s3_endpoint_ttfb_seconds", "lith_s3_wire_ttfb_seconds"]
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.final.prom"))):
    m = {}
    for ln in open(p):
        if ln.startswith("#") or not ln.strip(): continue
        k, v = ln.rsplit(" ", 1); m[k] = float(v)
    tag = os.path.basename(p).split(".")[0]
    fn = m.get("lith_ttfb_seconds_count", 0); f50 = m.get('lith_ttfb_seconds_bucket{le="0.05"}', 0)
    print(f"{tag}: fill n={fn:.0f} <=50 {100*f50/fn:.1f}% mean {1e3*m.get('lith_ttfb_seconds_sum',0)/fn:.1f} ms")
    for c in ("new", "reused"):
        row = {}
        for s in S:
            n = m.get(f'{s}_count{{conn="{c}"}}', 0); sm = m.get(f'{s}_sum{{conn="{c}"}}', 0)
            le = lambda q: m.get(f'{s}_bucket{{conn="{c}",le="{q}"}}', None)
            row[s] = (n, sm, le("0.025"), le("0.05"), le("0.02"), le("0.03"))
        n = [row[s][0] for s in S]
        if n[3] == 0: print(f"   {c}: n=0"); continue
        parts = sum(row[s][1] for s in S[:3]); wire = row[S[3]][1]
        print(f"   {c:6s} counts acquire/write/endpoint/wire = {n[0]:.0f}/{n[1]:.0f}/{n[2]:.0f}/{n[3]:.0f}  "
              f"composition: mean(parts) {1e3*parts/n[3]:.2f} ms vs mean(wire) {1e3*wire/n[3]:.2f} ms (diff {1e3*(parts-wire)/n[3]:+.2f})")
        for s in S:
            cnt, sm, l25, l50, l20, l30 = row[s]
            frac = lambda x: "NA" if x is None or not cnt else f"{100*x/cnt:.1f}%"
            print(f"      {s.replace('lith_s3_',''):24s} mean {1e3*sm/cnt if cnt else 0:7.2f} ms  <=20 {frac(l20)} <=25 {frac(l25)} <=30 {frac(l30)} <=50 {frac(l50)}")
