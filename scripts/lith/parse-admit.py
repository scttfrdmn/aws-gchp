#!/usr/bin/env python3
"""Gate 5f-O (lith#301/#306): OLD-vs-NEW per arm, and the coverage ratio that predicts it.

The model under test, which is arithmetic on two numbers upstream's own #308 log line
already prints:

    COVERED = prefetch_budget_bytes / window_commit_bytes
    covered fraction = min(1, COVERED / N)      <- readers that get prefetch at all

Admission is a prefix (blockstore.go: the first refusal ends the block), so a reader that
cannot fit a full window gets NO prefetch rather than a shallower one. The divisor sized
every handle to budget/N so all N were covered shallowly; admission covers COVERED of them
fully and starves the rest to synchronous 1 MiB demand reads.

Prints the wall ratio against the predicted and measured covered fraction, so the claim
stands or falls on whether those two columns track.
"""
import re, sys, statistics as st
from collections import defaultdict

LOGS = sys.argv[1:] or ["ga2.log"]
cells = defaultdict(dict)
for p in LOGS:
    for ln in open(p):
        m = re.match(r"CELL (\S+) readers=(\d+) \S+ agg_wall=(\S+) rmin=(\S+) rmax=(\S+)", ln)
        if m:
            t, n, w, lo, hi = m.groups()
            cells[t].update(n=int(n), wall=float(w), rmin=float(lo), rmax=float(hi))
            continue
        m = re.match(r"CELL (\S+) readers=(\d+) .*agg_wall=(\S+) bytes=\S+ "
                     r"reader_wall_min=(\S+) reader_wall_max=(\S+)", ln)
        if m:
            t, n, w, lo, hi = m.groups()
            cells[t].update(n=int(n), wall=float(w), rmin=float(lo), rmax=float(hi))
            continue
        m = re.match(r"MET (\S+) lith_(\S+?)(?:\{.*\})? (\S+)", ln)
        if m:
            t, k, v = m.groups()
            cells[t][k] = float(v)

# arm -> {OLD: [cells], NEW: [cells]}
arms = defaultdict(lambda: defaultdict(list))
for t, c in cells.items():
    parts = t.split("-")
    if len(parts) == 3:
        arms[parts[0]][parts[1]].append(c)
    elif len(parts) == 2 and parts[0] in ("OLD", "NEW", "POS"):
        arms["P1"][parts[0]].append(c)

BUDGET = 4127829504
WC = {"C": 1870659584, "L2": 1870659584, "L3": 1870659584, "L4": 1870659584,
      "L8": 1870659584, "P1": 1870659584, "W": 276824064, "D": 276824064}

def med(cs, k):
    v = [c[k] for c in cs if k in c]
    return st.median(v) if v else float("nan")

print("%-5s %4s %8s %9s %9s %7s  %7s %7s  %8s %8s %8s" % (
    "arm", "N", "COVERED", "OLD wall", "NEW wall", "NEW/OLD",
    "pred", "meas", "refused", "uncov", "GETs x"))
print("%-5s %4s %8s %9s %9s %7s  %7s %7s  %8s %8s %8s" % (
    "", "", "b/wc", "s", "s", "x", "cov%", "cov%", "NEW", "x OLD", "NEW/OLD"))
for arm in sorted(arms, key=lambda a: (a[0], len(a), a)):
    o, n = arms[arm].get("OLD", []), arms[arm].get("NEW", [])
    if not o or not n:
        continue
    N = o[0]["n"]
    wc = WC.get(arm, 1870659584)
    covered = BUDGET / wc
    ow, nw = med(o, "wall"), med(n, "wall")
    oi, ni = med(o, "prefetch_issued_total"), med(n, "prefetch_issued_total")
    og, ng = med(o, "s3_requests_total"), med(n, "s3_requests_total")
    ou, nu = med(o, "prefetch_uncovered_total"), med(n, "prefetch_uncovered_total")
    print("%-5s %4d %8.2f %9.2f %9.2f %7.2f  %6.1f%% %6.1f%%  %8.0f %8.1f %8.2f" % (
        arm, N, covered, ow, nw, nw / ow,
        100 * min(1, covered / N), 100 * ni / oi,
        med(n, "prefetch_refused_total"), nu / ou if ou else float("nan"), ng / og))

print("\nper-reader wall spread (max/min within a cell) -- F3, starvation:")
for arm in sorted(arms, key=lambda a: (a[0], len(a), a)):
    o, n = arms[arm].get("OLD", []), arms[arm].get("NEW", [])
    if not o or not n:
        continue
    so = med([{"s": c["rmax"] / c["rmin"]} for c in o], "s")
    sn = med([{"s": c["rmax"] / c["rmin"]} for c in n], "s")
    print("  %-5s OLD %5.3f  NEW %5.3f  ratio %5.2f%s" % (
        arm, so, sn, sn / so, "   <- F3 THRESHOLD 1.3x BREACHED" if sn / so > 1.3 else ""))

print("\nevicted_unread (F2) -- floor is 0:")
for t in sorted(cells):
    v = cells[t].get("prefetch_evicted_unread_total")
    if v:
        print("  %-12s %d" % (t, v))
