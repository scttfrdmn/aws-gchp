#!/usr/bin/env python3
"""Is the key-level cold-waste fit a SHARED-DENOMINATOR ARTIFACT?

The binding target is cold_waste_per_distinct = W / D and the winning feature is
distinct_frac = D / S. They share D, on opposite sides of the ratio, so a negative
correlation is induced even if the waste W is statistically independent of coverage. The
observed rho is -0.689 / -0.707 on HEMCO; the question is how much of that a null would
produce for free.

Permutation null: shuffle W across the arm's objects, keeping D and S attached to their
object, and recompute rho(W_perm / D, D / S). That destroys any real relationship between
waste and coverage while preserving the algebra exactly. If the null centres near the
observed value, the fit is an artifact and must not be reported as a finding.

Also reported, for the same reason:
  - rho(W, distinct_frac): the artifact-free version of the claim. W shares no term with
    D/S, so nothing is induced. This is the number the claim should rest on.
  - rho(W/D, S) and rho(W, S): whether object SIZE alone carries it.
  - the same null for the follow-through target, where the concern is different (reads
    mechanically create redemption opportunities, not a shared denominator).

Usage: keylevel-artifact-null.py keys.csv [n_permutations]
"""
import csv
import math
import random
import sys


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


path = sys.argv[1]
NPERM = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
rows = list(csv.DictReader(open(path)))
random.seed(20260920)

arms = sorted({(r["label"], r["arm"]) for r in rows})
print(f"permutation null, {NPERM} shuffles per arm, seed 20260920")
print("W = cold_waste_bytes, D = distinct_bytes, S = obj_size\n")

for lab, arm in arms:
    sub = [r for r in rows if r["label"] == lab and r["arm"] == arm
           and int(r["reader_mismatches"]) == 0]
    W = [float(r["cold_waste_bytes"]) for r in sub]
    D = [float(r["distinct_bytes"]) for r in sub]
    S = [float(r["obj_size"]) for r in sub]
    keep = [i for i in range(len(sub)) if D[i] > 0 and S[i] > 0]
    W = [W[i] for i in keep]
    D = [D[i] for i in keep]
    S = [S[i] for i in keep]
    n = len(W)
    if n < 8:
        print(f"{lab}/{arm}: n={n} objects — below any usable n, skipped (pre-registered K7)")
        continue
    dfrac = [D[i] / S[i] for i in range(n)]
    t3 = [W[i] / D[i] for i in range(n)]

    obs = spearman(dfrac, t3)
    null = []
    idx = list(range(n))
    for _ in range(NPERM):
        random.shuffle(idx)
        wp = [W[i] for i in idx]
        null.append(spearman(dfrac, [wp[i] / D[i] for i in range(n)]))
    null.sort()
    lo, hi = null[int(0.025 * NPERM)], null[int(0.975 * NPERM)]
    mean = sum(null) / len(null)
    # One-sided: how often does the null reach a rho at least as negative as observed?
    p = sum(1 for v in null if v <= obs) / len(null)

    print(f"{lab}/{arm}  n={n} objects")
    print(f"   rho(distinct_frac, W/D)  observed {obs:+.3f}")
    print(f"     NULL (W shuffled):     mean {mean:+.3f}   95% [{lo:+.3f}, {hi:+.3f}]   p(null <= obs) = {p:.4f}")
    print(f"   artifact-free versions (no shared term):")
    print(f"     rho(distinct_frac, W) = {spearman(dfrac, W):+.3f}       rho(S, W) = {spearman(S, W):+.3f}")
    print(f"     rho(S, W/D)           = {spearman(S, t3):+.3f}       rho(D, W) = {spearman(D, W):+.3f}")
    print()
