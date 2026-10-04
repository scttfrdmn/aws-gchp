#!/usr/bin/env python3
"""Upstream says my stated MECHANISM for the positive null centre is wrong.

I wrote: "the artifact runs the other way -- because rho(D,W) = +0.55, the shared
denominator induces a positive correlation."

Their argument: the permutation destroys which W belongs to which (D,S), so NO statistic
of that pairing can enter the null's expectation. They offer the D-S structure instead:
null centre ~= -rho(distinct_frac, D), attenuated.

Three tests, in increasing strength:
  T1  Re-attach W to force rho(D,W) = +1 and -1. If their argument holds the null centre
      does not move. If MY claim held it would move a lot.
  T2  Does -rho(D/S, D) predict the null centre on all four arms (incl. met, n=12)?
      Their explanation is only worth having if it PREDICTS, not just post-hoc fits.
  T3  Synthetic: hold the W multiset fixed and DIAL rho(D/S, D) by construction. If the
      mechanism is the D-S structure, the null centre must track it across the range.
"""
import csv, gzip, math, random, sys

def rank(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i]); r = [0.0]*len(xs); i = 0
    while i < len(order):
        j = i
        while j+1 < len(order) and xs[order[j+1]] == xs[order[i]]: j += 1
        avg = (i+j)/2.0 + 1
        for k in range(i, j+1): r[order[k]] = avg
        i = j+1
    return r

def spearman(xs, ys):
    if len(xs) < 3: return float("nan")
    rx, ry = rank(xs), rank(ys); n = len(xs)
    mx, my = sum(rx)/n, sum(ry)/n
    num = sum((a-mx)*(b-my) for a, b in zip(rx, ry))
    dx = math.sqrt(sum((a-mx)**2 for a in rx)); dy = math.sqrt(sum((b-my)**2 for b in ry))
    return float("nan") if dx == 0 or dy == 0 else num/(dx*dy)

def null_centre(D, S, W, nperm=2000, seed=20260926):
    rnd = random.Random(seed)
    dfrac = [D[i]/S[i] for i in range(len(D))]
    idx = list(range(len(W))); acc = []
    for _ in range(nperm):
        rnd.shuffle(idx)
        acc.append(spearman(dfrac, [W[idx[i]]/D[i] for i in range(len(D))]))
    acc.sort()
    return sum(acc)/len(acc), acc[int(0.025*nperm)], acc[int(0.975*nperm)]

rows = list(csv.DictReader(gzip.open("data/lith-gates/key-level-scores.csv.gz", "rt")))
arms = sorted({(r["label"], r["arm"]) for r in rows})

print("T1/T2 -- on the real data\n")
print(f"{'arm':10} {'n':>4} {'rho(D,W)':>9} {'rho(D/S,D)':>11} {'-rho(D/S,D)':>12} "
      f"{'null centre':>12} {'obs rho':>9}")
for lab, arm in arms:
    sub = [r for r in rows if r["label"] == lab and r["arm"] == arm
           and int(r["reader_mismatches"]) == 0]
    trip = [(float(r["distinct_bytes"]), float(r["obj_size"]), float(r["cold_waste_bytes"]))
            for r in sub]
    trip = [t for t in trip if t[0] > 0 and t[1] > 0]
    D, S, W = [t[0] for t in trip], [t[1] for t in trip], [t[2] for t in trip]
    n = len(D)
    dfrac = [D[i]/S[i] for i in range(n)]
    obs = spearman(dfrac, [W[i]/D[i] for i in range(n)])
    c, _, _ = null_centre(D, S, W)
    print(f"{lab+'/'+arm:10} {n:>4} {spearman(D,W):>+9.3f} {spearman(dfrac,D):>+11.3f} "
          f"{-spearman(dfrac,D):>+12.3f} {c:>+12.4f} {obs:>+9.3f}")

print("\nT1 -- re-attach W to force rho(D,W) to its extremes (hemco arms only)\n")
for lab, arm in [a for a in arms if a[0] == "hemco"]:
    sub = [r for r in rows if r["label"] == lab and r["arm"] == arm
           and int(r["reader_mismatches"]) == 0]
    trip = [(float(r["distinct_bytes"]), float(r["obj_size"]), float(r["cold_waste_bytes"]))
            for r in sub]
    trip = [t for t in trip if t[0] > 0 and t[1] > 0]
    D, S, W = [t[0] for t in trip], [t[1] for t in trip], [t[2] for t in trip]
    ordD = sorted(range(len(D)), key=lambda i: D[i])
    Ws = sorted(W)
    Wpos = [0.0]*len(W); Wneg = [0.0]*len(W)
    for r, i in enumerate(ordD):
        Wpos[i] = Ws[r]            # W monotone increasing in D  -> rho(D,W) = +1
        Wneg[i] = Ws[len(Ws)-1-r]  # monotone decreasing          -> rho(D,W) = -1
    for name, Wv in (("as measured", W), ("rho(D,W)=+1", Wpos), ("rho(D,W)=-1", Wneg)):
        c, lo, hi = null_centre(D, S, Wv)
        print(f"  {lab}/{arm}  {name:14} rho(D,W)={spearman(D,Wv):>+7.3f}   "
              f"null centre {c:>+7.4f}  95% [{lo:+.3f},{hi:+.3f}]")

print("\nT3 -- synthetic: same W multiset, DIAL rho(D/S,D) by construction\n")
sub = [r for r in rows if r["label"] == "hemco" and r["arm"] == "a"
       and int(r["reader_mismatches"]) == 0]
Wreal = sorted(float(r["cold_waste_bytes"]) for r in sub
               if float(r["distinct_bytes"]) > 0 and float(r["obj_size"]) > 0)
n = len(Wreal)
rnd = random.Random(7)
print(f"{'built for':>12} {'rho(D/S,D)':>11} {'-rho(D/S,D)':>12} {'null centre':>12}")
for target in ("D/S indep of D", "D/S rises with D", "D/S falls with D"):
    Dv = [math.exp(rnd.uniform(11, 18)) for _ in range(n)]
    if target == "D/S indep of D":
        Sv = [Dv[i]/rnd.uniform(0.05, 0.95) for i in range(n)]
    elif target == "D/S rises with D":
        ordD = sorted(range(n), key=lambda i: Dv[i])
        Sv = [0.0]*n
        for r_, i in enumerate(ordD):
            Sv[i] = Dv[i]/(0.05 + 0.90*r_/(n-1))
    else:
        ordD = sorted(range(n), key=lambda i: Dv[i])
        Sv = [0.0]*n
        for r_, i in enumerate(ordD):
            Sv[i] = Dv[i]/(0.95 - 0.90*r_/(n-1))
    Wv = Wreal[:]; rnd.shuffle(Wv)
    dfrac = [Dv[i]/Sv[i] for i in range(n)]
    c, _, _ = null_centre(Dv, Sv, Wv, nperm=800)
    print(f"{target:>12} {spearman(dfrac,Dv):>+11.3f} {-spearman(dfrac,Dv):>+12.3f} {c:>+12.4f}")
