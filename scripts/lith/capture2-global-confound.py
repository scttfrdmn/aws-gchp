#!/usr/bin/env python3
"""Is the shared-cache verdict flip the UNIT, or the POPULATION?

Scoring against a shared cache changes two things at once, and only one of them is the
point:

  UNIT        a (key, block) is charged once mount-wide, and any handle's later read
              redeems it. That is the intended change.
  POPULATION  a handle every one of whose dispatches was already resident now causes no
              fetch at all, so it has no follow-through to score and drops out. met goes
              from 283 scored handles to 126.

A population change alone can move a correlation, and the per-handle verdict was
SEPARATION (rho +0.635 on mean_abs_gap_blocks) while the shared verdict is PARTIAL (best
+0.441). If restricting the PER-HANDLE score to the handles the shared pass can score
also kills the correlation, the flip is the population and says nothing about the unit.
If the per-handle correlation survives on that same subset, the flip is the unit.

This is the same class of error as capture 1's: a verdict computed over the handles an
earlier filter had already rejected. Usage:

  capture2-global-confound.py capture2-global.csv capture2-global.global.csv
"""
import csv
import math
import sys


def load(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def rank(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    r = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1
        for k in range(i, j + 1):
            r[order[k]] = avg
        i = j + 1
    return r


def spearman(xs, ys):
    if len(xs) < 3:
        return float("nan")
    rx, ry = rank(xs), rank(ys)
    n = len(xs)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    dx = math.sqrt(sum((a - mx) ** 2 for a in rx))
    dy = math.sqrt(sum((b - my) ** 2 for b in ry))
    if dx == 0 or dy == 0:
        return float("nan")
    return num / (dx * dy)


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return float("nan")


ph = load(sys.argv[1])
gl = load(sys.argv[2])
key = lambda r: (r["label"], r["arm"], r["fh"])
glby = {key(r): r for r in gl}

FEATS = ["mean_abs_gap_blocks", "max_abs_gap_blocks", "frac_large_gap", "mean_read_kib",
         "frac_monotonic", "frac_straddle"]

# The fidelity filter is upstream's and applies to both units identically.
rows = [r for r in ph if int(r["replay_mismatches"]) == 0 and key(r) in glby]

print("== populations (faithful handles only, as the verdict uses)")
print(f"{'class/arm':<12} {'faithful':>9} {'per-handle scored':>18} {'shared scored':>14} {'both':>6}")
arms = sorted({(r["label"], r["arm"]) for r in rows})
for lab, arm in arms:
    sub = [r for r in rows if r["label"] == lab and r["arm"] == arm]
    nph = sum(1 for r in sub if float(r["dispatched_bytes"]) > 0)
    ngl = sum(1 for r in sub if float(glby[key(r)]["dispatched_bytes"]) > 0)
    nboth = sum(1 for r in sub if float(r["dispatched_bytes"]) > 0 and float(glby[key(r)]["dispatched_bytes"]) > 0)
    print(f"{lab+'/'+arm:<12} {len(sub):>9} {nph:>18} {ngl:>14} {nboth:>6}")

print("\n== Spearman rho vs byte follow-through, three ways")
print("   A = per-handle FT over ALL per-handle-scored handles      (the banked verdict)")
print("   B = per-handle FT over the SHARED-scoreable subset ONLY   (isolates population)")
print("   C = shared FT over that same subset                       (isolates unit)")
print(f"\n{'feature':<22} {'class/arm':<10} {'A':>8} {'B':>8} {'C':>8}  {'n_A':>5} {'n_BC':>5}")
for ft in FEATS:
    for lab, arm in arms:
        sub = [r for r in rows if r["label"] == lab and r["arm"] == arm]
        a = [(num(r[ft]), num(r["byte_follow_through"])) for r in sub
             if float(r["dispatched_bytes"]) > 0]
        bc = [(num(r[ft]), num(r["byte_follow_through"]), num(glby[key(r)]["byte_follow_through"]))
              for r in sub
              if float(r["dispatched_bytes"]) > 0 and float(glby[key(r)]["dispatched_bytes"]) > 0]
        rA = spearman([x for x, _ in a], [y for _, y in a])
        rB = spearman([x for x, _, _ in bc], [y for _, y, _ in bc])
        rC = spearman([x for x, _, _ in bc], [z for _, _, z in bc])
        print(f"{ft:<22} {lab+'/'+arm:<10} {rA:>+8.3f} {rB:>+8.3f} {rC:>+8.3f}  {len(a):>5} {len(bc):>5}")

print("\n== do the two units even rank the same handles the same way?")
for lab, arm in arms:
    sub = [r for r in rows if r["label"] == lab and r["arm"] == arm
           and float(r["dispatched_bytes"]) > 0 and float(glby[key(r)]["dispatched_bytes"]) > 0]
    xs = [num(r["byte_follow_through"]) for r in sub]
    ys = [num(glby[key(r)]["byte_follow_through"]) for r in sub]
    print(f"   {lab}/{arm:<3} rho(per-handle FT, shared FT) = {spearman(xs, ys):+.3f}   n={len(sub)}")

print("\n== the cold tax, per unit (sum over faithful handles)")
for lab, arm in arms:
    sub = [r for r in rows if r["label"] == lab and r["arm"] == arm]
    p = sum(float(r["cold_net_waste_bytes"]) for r in sub)
    g = sum(float(glby[key(r)]["cold_net_waste_bytes"]) for r in sub)
    print(f"   {lab}/{arm:<3} per-handle {p/1e6:9.1f} MB   shared {g/1e6:9.1f} MB   ratio {p/g if g else float('nan'):.2f}x")
