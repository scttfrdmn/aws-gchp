#!/usr/bin/env python3
"""Gate 5f-M: the two depth bounds compose as min(), and wall is a function of the
realized window alone.

Builds a (forced --max-readahead) x (open handles) grid of realized window and streaming
wall from the control runs, so the handle divisor and the declared depth bound can be seen
composing. Predicted window is clamp(budgetBlocks/N, 2, maxReadahead).
"""
import csv, glob, os, re, statistics as st, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/scratch/lith-gates"
BUDGET_BLOCKS = 492

def cell_window(csv_path):
    """steady-state window of the streaming handle in one cell"""
    fh = open(csv_path)
    fh.readline()
    per = {}
    for r in csv.DictReader(fh):
        try:
            per.setdefault(r["fh"], []).append(int(r["window"]))
        except (KeyError, ValueError):
            pass
    fh.close()
    stream = [v for v in per.values() if len(v) >= 50]
    if not stream:
        return None
    return int(st.median([int(st.median(v[int(len(v) * 0.2):] or v)) for v in stream]))

rows = {}
for d in sorted(glob.glob(os.path.join(ROOT, "gh-ctl-*"))):
    mra = int(os.path.basename(d).split("-")[-1])
    for cpath in sorted(glob.glob(os.path.join(d, "[AB]-n*-*.csv"))):
        m = re.match(r"([AB])-n(\d+)-(\d+)\.csv$", os.path.basename(cpath))
        arm, n = m.group(1), int(m.group(2))
        w = cell_window(cpath)
        wf = cpath[:-4] + ".walls"
        wall = None
        if os.path.exists(wf):
            for ln in open(wf):
                p = ln.split()
                if p and p[0] == "0":
                    wall = float(p[1])
        if w is None or wall is None:
            continue
        rows.setdefault((mra, n), []).append((w, wall))

print("forced --max-readahead x open handles, 1 streaming reader, in-region, n=3")
print("%6s %5s  %8s %9s  %-24s %9s" % (
    "mra", "N", "window", "predict", "stream wall s", "MB/s"))
for (mra, n) in sorted(rows):
    v = rows[(mra, n)]
    w = int(st.median([x[0] for x in v]))
    walls = sorted(x[1] for x in v)
    pred = max(2, min(mra, BUDGET_BLOCKS // n))
    print("%6d %5d  %8d %9d  %-24s %9.0f%s" % (
        mra, n, w, pred, " ".join("%.2f" % x for x in walls),
        3776.834855 / st.median(walls), "" if w == pred else "   <-- MISMATCH"))

print()
print("wall as a function of realized window ALONE (all mra x N cells pooled)")
byw = {}
for (mra, n), v in rows.items():
    for w, wall in v:
        byw.setdefault(w, []).append(wall)
print("%8s %6s  %9s %9s  %s" % ("window", "cells", "med s", "MB/s", "spread s"))
for w in sorted(byw, reverse=True):
    v = sorted(byw[w])
    print("%8d %6d  %9.2f %9.0f  %.2f-%.2f" % (
        w, len(v), st.median(v), 3776.834855 / st.median(v), v[0], v[-1]))
