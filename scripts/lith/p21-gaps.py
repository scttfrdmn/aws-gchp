# 5f-P21 (lith#312): per-KEY gaps between consecutive demand reads (hit|uncovered|join) from --timeline-csv.
import csv, glob, os, statistics as st, sys
d = sys.argv[1]; names = {"9210": "merra2-201901", "9211": "merra2-201501", "9212": "hemco", "9213": "cheminputs", "9214": "restarts"}
q = lambda xs, p: sorted(xs)[min(len(xs) - 1, int(p * len(xs)))]
allk = 0; allk_long = 0; ev_all = 0; ev_long = 0
for f in sorted(glob.glob(f"{d}/tl-*.csv")):
    port = os.path.basename(f)[3:7]; ev = {}
    for r in csv.DictReader(open(f)):
        if r["kind"] in ("hit", "uncovered", "join"): ev.setdefault(r["key"], []).append(float(r["ms"]))
    gaps, maxg, nlong, evlong = [], [], 0, 0
    for k, ts in ev.items():
        ts.sort(); g = [b - a for a, b in zip(ts, ts[1:])]; gaps += g
        m = max(g) if g else 0.0; maxg.append(m)
        if m >= 2000: nlong += 1; evlong += len(ts)
    n = len(ev); ne = sum(len(v) for v in ev.values())
    allk += n; allk_long += nlong; ev_all += ne; ev_long += evlong
    if not gaps: print(f"{names[port]:14s} keys {n:3d} (no gaps)"); continue
    big = [g for g in gaps if g >= 2000]
    print(f"{names[port]:14s} keys {n:3d}  demand events {ne:6d} | gap p50 {q(gaps,.5):8.1f} p90 {q(gaps,.9):8.1f} p99 {q(gaps,.99):8.1f} max {max(gaps)/1e3:6.1f} s"
          f" | keys with max gap >= 2 s: {nlong}/{n} ({100*nlong/n:.0f}%), their events {100*evlong/ne:.0f}% | gaps >= 2 s: {len(big)} (median {st.median(big)/1e3 if big else 0:.1f} s)")
print(f"ALL mounts: keys with max gap >= 2 s: {allk_long}/{allk} ({100*allk_long/allk:.0f}%), covering {100*ev_long/ev_all:.0f}% of demand events")
# Does a long gap contain an 'open' of the same key? Then the handle that read before it was not necessarily held idle.
print("\nlong gaps (>= 2 s) that contain an 'open' of the same key (re-open => not necessarily an idle held handle):")
for f in sorted(glob.glob(f"{d}/tl-*.csv")):
    port = os.path.basename(f)[3:7]; dem, op = {}, {}
    for r in csv.DictReader(open(f)):
        (dem if r["kind"] in ("hit", "uncovered", "join") else op if r["kind"] == "open" else {}).setdefault(r["key"], []).append(float(r["ms"]))
    tot = withopen = 0
    for k, ts in dem.items():
        ts.sort(); o = sorted(op.get(k, []))
        for a, b in zip(ts, ts[1:]):
            if b - a >= 2000:
                tot += 1; withopen += any(a < x < b for x in o)
    if tot: print(f"  {names[port]:14s} {withopen}/{tot} long gaps contain a re-open ({100*withopen/tot:.0f}%)")
