#!/usr/bin/env python3
"""Gate 5f-M follow-on (lith#301): how big is the transient when a handle establishes?

#301's stated risk for candidate 1 is that "transient over-commitment is bounded by
(newly establishing handles x their window) and that wants measuring, not reasoning."
The banked --pf-trace carries the dispatch schedule, so the shape of establishment is
measurable without a gauge: every event with dispatched > 1 is a burst, and its size is
how much a single handle commits in one step.
"""
import csv, glob, os, re, statistics as st, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
print("%-13s %-13s %5s  %-28s %s" % (
    "cell", "dir", "win", "bursts (dispatched>1)", "state transition at the burst"))
for d in sorted(glob.glob(os.path.join(ROOT, "gate-handles"))) + sorted(glob.glob(os.path.join(ROOT, "gh-ctl-*"))):
    for p in sorted(glob.glob(os.path.join(d, "[ABC]-n*-1.csv"))):
        fh = open(p)
        cfg = fh.readline()
        bursts, trans, wins = [], set(), []
        for r in csv.DictReader(fh):
            try:
                dd, w = int(r["dispatched"]), int(r["window"])
            except (KeyError, ValueError):
                continue
            if w:
                wins.append(w)
            if dd > 1:
                bursts.append(dd)
                trans.add("%s->%s" % (r["state_before"], r["state_after"]))
        fh.close()
        if not wins:
            continue
        w = int(st.median(wins))
        bs = ("n=%d  sizes %s" % (len(bursts), sorted(set(bursts)))) if bursts else "none"
        print("%-13s %-13s %5d  %-28s %s" % (
            os.path.basename(p)[:-4], os.path.basename(d), w, bs,
            ",".join(sorted(trans)) or "-"))
