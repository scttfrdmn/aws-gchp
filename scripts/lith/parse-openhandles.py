#!/usr/bin/env python3
"""Gate 5f-M (lith#298): realized prefetch window per handle vs number of open handles.

Reads the --pf-trace CSVs written by gate-openhandles.sh and reports, per cell, the
window actually computed for the STREAMING handle(s).

Two statistics per handle, because arm A's readers do not start simultaneously and the
first fetches of the first reader legitimately see fewer open handles:
  wmax     max(window) over the handle's fetches   -- upper bound, start-up inflated
  wsteady  median(window) over the LAST 80% of the handle's fetches -- the steady state
The pre-registered prediction is about wsteady.
"""
import csv, glob, os, re, statistics, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
BUDGET_BLOCKS = 492      # prefetchBudget / blockSize on this box, at 8 MiB
MAXRA = 223              # auto-resolved --max-readahead at 8 MiB

def predict(n):
    return max(2, min(MAXRA, BUDGET_BLOCKS // n))

rows = {}
for path in sorted(glob.glob(os.path.join(OUT, "*.csv"))):
    m = re.match(r"([ABC])-n(\d+)-(\d+)\.csv$", os.path.basename(path))
    if not m:
        continue
    arm, nh, rep = m.group(1), int(m.group(2)), int(m.group(3))
    fh = open(path)
    cfg = fh.readline()
    per = {}
    for r in csv.DictReader(fh):
        try:
            w = int(r["window"])
        except (KeyError, ValueError):
            continue
        per.setdefault(r["fh"], []).append(w)
    fh.close()
    # streaming handles are the ones with many fetches; held handles have ~0-1
    stream = {k: v for k, v in per.items() if len(v) >= 50}
    if not stream:
        continue
    wmax, wsteady = [], []
    for v in stream.values():
        wmax.append(max(v))
        tail = v[int(len(v) * 0.2):] or v
        wsteady.append(int(statistics.median(tail)))
    rows.setdefault((arm, nh), []).append(
        (rep, len(stream), len(per), max(wmax), int(statistics.median(wsteady))))

print("%-4s %5s %5s %8s %8s %8s %9s  %s" % (
    "arm", "N", "rep", "stream", "handles", "wmax", "wsteady", "predicted(H_charge)"))
for (arm, nh) in sorted(rows, key=lambda k: (k[0], k[1])):
    for rep, ns, nt, wmax, wst in sorted(rows[(arm, nh)]):
        print("%-4s %5d %5d %8d %8d %8d %9d  %d" % (
            arm, nh, rep, ns, nt, wmax, wst, predict(nh)))

print()
print("%-4s %5s %9s %9s  %9s  %s" % ("arm", "N", "wsteady", "predict", "aggMB", "verdict"))
for (arm, nh) in sorted(rows, key=lambda k: (k[0], k[1])):
    wsts = [r[4] for r in rows[(arm, nh)]]
    w = int(statistics.median(wsts))
    p = predict(nh)
    nstream = statistics.median([r[1] for r in rows[(arm, nh)]])
    agg = w * nstream * 8.388608 if arm == "A" else w * 8.388608
    tag = "H_charge" if abs(w - p) <= max(2, 0.1 * p) else (
        "H_active" if abs(w - MAXRA) <= 2 else "NEITHER")
    print("%-4s %5d %9d %9d  %9.0f  %s   reps=%s" % (arm, nh, w, p, agg, tag, wsts))
