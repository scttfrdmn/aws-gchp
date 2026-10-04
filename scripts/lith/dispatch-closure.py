#!/usr/bin/env python3
"""Gate 5f-M follow-on (lith#301): can resident prefetched-unread bytes be derived from
--pf-trace, instead of from the new gauge upstream proposed? No. This script is the
refutation, kept because the failure mode is a trap the gauge's own validation could fall into.

The tempting estimator is, per handle,

    lead_i = cumsum(dispatched)_i - (blk_i + 1)

"blocks dispatched but not yet consumed". It does not close. `dispatched` carries one
establishment burst of exactly the window, and then +1 at every subsequent block boundary
all the way to the last block of the object -- including boundaries where the frontier has
already passed EOF and there is nothing left to dispatch. So

    sum(dispatched) - distinct_blocks_read == window - 2

and the estimator therefore returns ~window-2 at steady state no matter what is resident.
Divide that by the charge (window x handles) and you "measure" a tight proxy tautologically.

Reported per cell: the closure defect, and the burst taxonomy that IS directly observable
(single rows, no cumulation) -- establishment bursts vs re-grant bursts late in the run.
"""
import csv, glob, os, re, statistics as st, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."


def analyse(path):
    fh = open(path)
    cfg = fh.readline()
    mra = int(re.search(r"max_readahead=(\d+)", cfg).group(1))
    per = {}
    for r in csv.DictReader(fh):
        try:
            seq, h = int(r["seq"]), r["fh"]
            d, blk, w = int(r["dispatched"]), int(r["blk"]), int(r["window"])
        except (KeyError, ValueError):
            continue
        e = per.setdefault(h, {"cum": 0, "blks": set(), "w": [], "bursts": [], "n": 0, "last": 0})
        e["cum"] += d
        e["blks"].add(blk)
        e["n"] += 1
        e["last"] = seq
        if w:
            e["w"].append(w)
        if d > 1:
            e["bursts"].append((seq, blk, d, "%s->%s" % (r["state_before"], r["state_after"])))
    fh.close()
    return mra, per


paths = []
for d in sorted(glob.glob(os.path.join(ROOT, "gate-handles"))) + sorted(glob.glob(os.path.join(ROOT, "gh-ctl-*"))):
    paths += sorted(glob.glob(os.path.join(d, "[ABC]-n*-1.csv")))

print("CLOSURE DEFECT in cumsum(dispatched): overshoot should be 0 if it counted distinct blocks")
print("%-11s %-10s %5s %7s %9s %9s %9s  %s" % (
    "cell", "dir", "win", "distinct", "sum(disp)", "overshoot", "win-2", "verdict"))
for p in paths:
    mra, per = analyse(p)
    strm = {h: e for h, e in per.items() if e["n"] >= 50}
    if not strm:
        continue
    h = max(strm, key=lambda k: strm[k]["n"])
    e = strm[h]
    w = int(st.median(e["w"])) if e["w"] else 0
    nb, cum = len(e["blks"]), e["cum"]
    ov = cum - nb
    print("%-11s %-10s %5d %7d %9d %9d %9d  %s" % (
        os.path.basename(p)[:-4], os.path.basename(os.path.dirname(p)), w, nb, cum, ov, w - 2,
        "overshoot == win-2" if ov == w - 2 else "overshoot != win-2"))

print()
print("BURST TAXONOMY (directly observable, one row each; no cumulation)")
print("%-11s %-10s %5s  %-34s %s" % ("cell", "dir", "win", "establishment burst", "later bursts (pos in run, size)"))
for p in paths:
    mra, per = analyse(p)
    strm = {h: e for h, e in per.items() if e["n"] >= 50}
    if not strm:
        continue
    h = max(strm, key=lambda k: strm[k]["n"])
    e = strm[h]
    w = int(st.median(e["w"])) if e["w"] else 0
    nb = len(e["blks"])
    if not e["bursts"]:
        est, later = "none", ""
    else:
        s0, b0, d0, t0 = e["bursts"][0]
        est = "blk %d size %d (=win? %s) %s" % (b0, d0, "yes" if d0 == w else "NO", t0)
        later = ", ".join("%.0f%%:%d" % (100.0 * b / nb, d) for _, b, d, _ in e["bursts"][1:]) or "none"
    print("%-11s %-10s %5d  %-34s %s" % (
        os.path.basename(p)[:-4], os.path.basename(os.path.dirname(p)), w, est, later))
