# Score 5f-P9j C2 (pre-registered in data/lith-gates/inregion-streams.txt): headline H = whole-run
# le025/count per mount and pooled; T = delta-histogram fraction <= 25 ms over ticks with inflight >= 64.
import csv, sys
for path in sys.argv[1:]:
    rows = list(csv.DictReader(open(path)))
    by = {}
    for r in rows: by.setdefault(r["mount"], []).append({k: float(v) for k, v in r.items() if k != "mount"})
    print(path)
    print("  %-14s %7s %8s %8s %8s | %8s %8s %6s | %6s %6s" % ("mount", "count", "le025%", "le060%", "med_last",
          "T:le025%", "T:n", "ticks", "inflmx", "gauge1"))
    P = [0, 0, 0]; TP = [0, 0]
    for m, v in by.items():
        last = v[-1]; c = last["count"]
        dn = dl = ticks = 0
        for a, b in zip(v, v[1:]):
            if b["inflight"] >= 64 or a["inflight"] >= 64:
                dn += b["count"] - a["count"]; dl += b["le025"] - a["le025"]; ticks += 1
        P[0] += c; P[1] += last["le025"]; P[2] += last["le060"]; TP[0] += dn; TP[1] += dl
        g1 = sum(1 for x in v if x["gauge"] > 0) / len(v)
        print("  %-14s %7d %7.1f%% %7.1f%% %6.1fms | %7.1f%% %8d %6d | %6d %5.0f%%" % (m, c,
              100 * last["le025"] / c if c else float("nan"), 100 * last["le060"] / c if c else float("nan"),
              last["median"] * 1e3, 100 * dl / dn if dn else float("nan"), dn, ticks,
              max(x["inflight"] for x in v), 100 * g1))
    print("  %-14s %7d %7.1f%% %7.1f%%          | %7.1f%% %8d" % ("POOLED", P[0], 100 * P[1] / P[0],
          100 * P[2] / P[0], 100 * TP[1] / TP[0] if TP[0] else float("nan"), TP[0]))
