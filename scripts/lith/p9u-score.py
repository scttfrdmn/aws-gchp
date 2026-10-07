# 5f-P9u (descriptive): runtime metrics across the W2 burst, from the 0.5 s scrapes bracketing [t0, t1].
import glob, os, sys
d = sys.argv[1]
def load(p):
    m = {}
    for ln in open(p):
        if ln.startswith("#") or not ln.strip(): continue
        k, v = ln.rsplit(" ", 1); m[k] = float(v)
    return m
SCHED = ["6.399999999999999e-08", "6.399999999999999e-07", "7.167999999999999e-06", "8.191999999999999e-05",
         "0.0009175039999999999", "0.010485759999999998", "0.11744051199999998", "+Inf"]
for tag in sorted(t.split(".")[0] for t in os.listdir(d) if t.endswith(".scrapes")):
    t0 = float(open(f"{d}/{tag}.t0").read()); t1 = float(open(f"{d}/{tag}.t1").read())
    S = sorted((float(os.path.basename(p)[:-5]), p) for p in glob.glob(f"{d}/{tag}.scrapes/*.prom"))
    a = max((s for s in S if s[0] <= t0), default=S[0]); b = min((s for s in S if s[0] >= t1), default=S[-1])
    A, Bm = load(a[1]), load(b[1]); dt = b[0] - a[0]
    D = lambda k: Bm.get(k, 0) - A.get(k, 0)
    sched = {q: D(f'go_sched_latencies_seconds_bucket{{le="{q}"}}') for q in SCHED}
    tot = sched["+Inf"]
    over1ms = tot - sched["0.0009175039999999999"]; over10ms = tot - sched["0.010485759999999998"]
    gor = max(load(p).get("go_goroutines", 0) for t, p in S if a[0] <= t <= b[0])
    fn = D("lith_ttfb_seconds_count"); f50 = D('lith_ttfb_seconds_bucket{le="0.05"}')
    print(f"{tag}: window {dt:.2f} s (burst {t1-t0:.2f} s) | fill n={fn:.0f} <=50ms {100*f50/fn if fn else 0:.1f}%"
          f" | GC cycles {D('go_gc_duration_seconds_count'):.0f}, total STW {1e3*D('go_gc_duration_seconds_sum'):.2f} ms,"
          f" max pause(q=1 at end) {1e3*Bm.get('go_gc_duration_seconds{quantile=\"1\"}',0):.2f} ms"
          f" | alloc {D('go_memstats_alloc_bytes_total')/1e9:.2f} GB ({D('go_memstats_alloc_bytes_total')/1e9/dt:.2f} GB/s)"
          f" | CPU {D('process_cpu_seconds_total'):.2f} s = {D('process_cpu_seconds_total')/dt:.2f} cores"
          f" | sched waits n={tot:.0f}, >0.9ms {over1ms:.0f} ({100*over1ms/tot if tot else 0:.2f}%), >10ms {over10ms:.0f}"
          f" | goroutines peak {gor:.0f}")
