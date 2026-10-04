#!/usr/bin/env python3
"""Gate 5f-N (lith#301/#303): resident prefetched-unread bytes against the proxy that
rations them. Every column below is read from a gauge the mount exported; nothing is
derived from a cumulative counter, which is what invalidated the 5f-M estimator.

  resident  lith_prefetch_resident_bytes   plateau (median over the steady span) and peak
  budget    lith_prefetch_budget_bytes
  win x N   lith_readahead_window_blocks x lith_open_handles x block_size  = the CHARGE
  tight     resident / charge
"""
import csv, glob, os, re, statistics as st, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
BLK = 8 * 1024 * 1024
MB = 1e6

cells = {}
for p in sorted(glob.glob(os.path.join(ROOT, "n*-*.samp.csv"))):
    m = re.match(r"n(\d+)-(\d+)\.samp\.csv$", os.path.basename(p))
    if not m:
        continue
    n, rep = int(m.group(1)), int(m.group(2))
    rows = []
    with open(p) as fh:
        for r in csv.DictReader(fh):
            try:
                # Prometheus prints large gauges in scientific notation ("1.87e+09"),
                # so these must go through float() -- int() rejects the whole row.
                rows.append((float(r["t"]), int(float(r["resident_bytes"])),
                             int(float(r["budget_bytes"])), int(float(r["window_blocks"])),
                             int(float(r["open_handles"]))))
            except (ValueError, KeyError):
                continue
    if not rows:
        continue
    live = [r for r in rows if r[1] > 0]
    if not live:
        continue
    budget = st.median([r[2] for r in rows])
    # steady span: samples with resident > 0, dropping the first and last 10% (ramp/drain)
    k = max(1, len(live) // 10)
    span = live[k:len(live) - k] or live
    res_med = st.median([r[1] for r in span])
    res_max = max(r[1] for r in live)
    win = int(st.median([r[3] for r in span]))
    hnd = int(st.median([r[4] for r in span]))
    cells.setdefault(n, []).append((res_med, res_max, budget, win, hnd))

print("GATE 5f-N  resident prefetched-unread vs the window x handles proxy")
print("%4s %4s %5s %4s  %11s %11s  %11s %8s  %9s" % (
    "N", "reps", "win", "hnd", "resident med", "resident max", "charge", "tight", "%budget"))
rowsout = []
for n in sorted(cells):
    v = cells[n]
    res = st.median([x[0] for x in v])
    rmx = max(x[1] for x in v)
    bud = st.median([x[2] for x in v])
    win = int(st.median([x[3] for x in v]))
    hnd = int(st.median([x[4] for x in v]))
    charge = win * hnd * BLK
    tight = res / charge if charge else 0
    print("%4d %4d %5d %4d  %8.1f MB %8.1f MB  %8.1f MB %8.3f  %8.1f%%" % (
        n, len(v), win, hnd, res / MB, rmx / MB, charge / MB, tight, 100.0 * res / bud))
    rowsout.append((n, win, hnd, res, charge, tight, bud))

print()
print("PREDICTION CHECK (pre-registered: resident ~ ONE window, tight ~ 1/N)")
print("%4s  %11s %11s %7s   %8s %8s %7s" % (
    "N", "res pred", "res obs", "ratio", "tight pr", "tight ob", "ratio"))
for n, win, hnd, res, charge, tight, bud in rowsout:
    pred = win * BLK
    tp = 1.0 / n
    print("%4d  %8.1f MB %8.1f MB %7.3f   %8.3f %8.3f %7.3f" % (
        n, pred / MB, res / MB, res / pred if pred else 0, tp, tight, tight / tp))

print()
if rowsout:
    worst = max(rowsout, key=lambda r: r[4] / max(r[3], 1))
    print("Largest proxy overstatement: N=%d charges %.1f MB, holds %.1f MB = %.0fx" % (
        worst[0], worst[4] / MB, worst[3] / MB, worst[4] / max(worst[3], 1)))
    n1 = [r for r in rowsout if r[0] == 1]
    if n1:
        r = n1[0]
        print("At N=1 (proxy's tightest case): %.1f%% of the %.0f MB budget held" % (
            100.0 * r[3] / r[6], r[6] / MB))
