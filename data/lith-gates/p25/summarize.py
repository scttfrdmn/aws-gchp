# lith#216 re-sweep: one CSV row from pre/post scrapes, pf-trace, tool JSON and the simultaneous control.
import csv, json, re, sys
COLS = ["shape", "source", "rep", "utc_start", "get", "list", "s3_bytes", "distinct_bytes", "amplification_x",
        "kernel_read_bytes", "tool_bytes", "amp_vs_tool", "fill_whole", "fill_demand", "fill_plan", "fill_demand_batch",
        "pf_cold_pct", "pf_seq_pct", "pf_strided_pct", "pf_random_pct", "uncovered", "pf_used", "pf_issued", "n_opens",
        "wall_s", "ctl_ttfb_p50_ms", "ctl_le50_pct", "ok", "notes"]
if sys.argv[1] == "--header": print(",".join(COLS)); sys.exit()
out, tag, shape, rep = sys.argv[1:5]
def prom(p):
    m = {}
    for ln in open(p):
        if ln.startswith("#") or not ln.strip(): continue
        k, v = ln.rsplit(" ", 1)
        try: m[k] = float(v)
        except ValueError: pass
    return m
a, b = prom(f"{out}/{tag}.pre.prom"), prom(f"{out}/{tag}.post.prom")
d = lambda k: b.get(k, 0) - a.get(k, 0)
ds = lambda pre: sum(b[k] - a.get(k, 0) for k in b if k.startswith(pre))
get = sum(d(k) for k in b if k.startswith("lith_s3_requests_total") and 'op="get"' in k)
lst = sum(d(k) for k in b if k.startswith("lith_s3_requests_total") and 'op="list"' in k)
s3b, dist = d("lith_s3_bytes_total"), d("lith_distinct_bytes_read")
fill = {kk: d(f'lith_fill_bytes_total{{kind="{kk}"}}') for kk in ("whole", "demand", "plan", "demand-batch")}
st = {"cold": 0, "seq": 0, "strided": 0, "random": 0}; n = 0
try:
    for r in csv.DictReader(l for l in open(f"{out}/{tag}.trace.csv") if not l.startswith("#")):
        s = r["state_after"].lower(); n += 1
        st["seq" if "seq" in s else "strided" if "strid" in s else "random" if "rand" in s else "cold"] += 1
except FileNotFoundError: pass
pct = lambda x: round(100 * x / n) if n else ""
try: tj = json.loads(open(f"{out}/{tag}.tool.json").read().strip().splitlines()[-1])
except Exception: tj = {"ok": False, "detail": open(f"{out}/{tag}.tool.err").read().strip().splitlines()[-1:][0][:160] if open(f"{out}/{tag}.tool.err").read().strip() else "no output"}
c = open(f"{out}/{tag}.ctl.txt").read()
m50 = re.search(r"TTFB .*?p50=([\d.]+)ms.*?<=50ms=([\d.]+)%", c)
tb = tj.get("tool_bytes")
row = [shape, "lith", rep, open(f"{out}/{tag}.utc").read().strip(), int(get), int(lst), int(s3b), int(dist),
       round(s3b / dist, 2) if dist else "", int(d("lith_read_size_bytes_sum")), tb if tb is not None else "",
       round(s3b / tb, 2) if tb else "", int(fill["whole"]), int(fill["demand"]), int(fill["plan"]), int(fill["demand-batch"]),
       pct(st["cold"]), pct(st["seq"]), pct(st["strided"]), pct(st["random"]), int(d("lith_prefetch_uncovered_total")),
       int(d("lith_prefetch_used_total")), int(d("lith_prefetch_issued_total")), tj.get("n_opens", ""), tj.get("wall_s", ""),
       m50.group(1) if m50 else "", m50.group(2) if m50 else "", tj.get("ok"), str(tj.get("detail", "")).replace(",", ";")]
w = csv.writer(sys.stdout); w.writerow(row)
