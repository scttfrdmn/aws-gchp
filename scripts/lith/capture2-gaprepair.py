#!/usr/bin/env python3
"""Two $0 checks on capture 2, both aimed at the verdict rather than at the run.

(1) RESIDUAL FIDELITY. lith#273's sort made met replay at 1.00x with fidelity OK, but
    HEMCO still mismatches on ~10/6229 handles. Characterise those handles against the
    faithful ones: rows, parts rows, object size, and the rate at which their recorded
    `gap` disagrees with the gap recomputed in decision order. Sorting is necessary; this
    asks whether it is sufficient.

(2) IS THE WINNING FEATURE AN ARTEFACT OF THE gap RACE? The scorer's SEPARATION verdict
    rests on mean_abs_gap_blocks (rho 0.635/0.634 on met). But gate 5i established that
    `gap` is computed from h.lastReadEnd.Load() BEFORE the lock and Store()d after it, so
    on a contended handle some rows carry another read's endpoint. met is exactly the
    contended shape. So: recompute the feature from a REPAIRED gap (off - previous end of
    the same fh, in seq order), correlate both against the scorer's own
    byte_follow_through, and see whether the signal survives.

    This does not re-run the replay. Feeding repaired gaps into the state machine would
    change its decisions and so trip the fidelity check by construction -- the mount really
    did decide on the racy values. What is testable is whether the PREDICTIVE signal is
    carried by the racy part of the column or by its honest part.

Usage: capture2-gaprepair.py <handles.csv> <label=trace.csv> [...]
"""
import collections
import csv
import sys

BLOCK = 8388608
K = 8                      # the scorer's -k default: a handle's first k reads


def spearman(xs, ys):
    n = len(xs)
    if n < 3:
        return None

    def ranks(v):
        order = sorted(range(n), key=lambda i: v[i])
        r = [0.0] * n
        i = 0
        while i < n:
            j = i
            while j + 1 < n and v[order[j + 1]] == v[order[i]]:
                j += 1
            avg = (i + j) / 2.0 + 1.0
            for k in range(i, j + 1):
                r[order[k]] = avg
            i = j + 1
        return r

    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    dx = sum((a - mx) ** 2 for a in rx) ** 0.5
    dy = sum((b - my) ** 2 for b in ry) ** 0.5
    return num / (dx * dy) if dx and dy else None


def load_trace(path):
    rows, hdr = [], None
    with open(path) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            if hdr is None:
                hdr = next(csv.reader([line]))
                continue
            try:
                rows.append(dict(zip(hdr, next(csv.reader([line])))))
            except Exception:
                break
    return rows


def main(argv):
    hpath, traces = argv[0], argv[1:]
    handles = collections.defaultdict(dict)   # label -> fh -> handle row
    with open(hpath) as fh:
        for r in csv.DictReader(fh):
            handles[f"{r['label']}/{r['arm']}"][r["fh"]] = r

    for spec in traces:
        label, path = spec.split("=", 1)
        rows = load_trace(path)
        byfh = collections.defaultdict(list)
        for r in rows:
            byfh[r["fh"]].append(r)
        for fh in byfh:
            byfh[fh].sort(key=lambda r: int(r["seq"]))

        # ---- per-handle features, recorded gap vs gap repaired in decision order
        feat = {}
        for fh, rs in byfh.items():
            rec, rep, racy, end = [], [], 0, None
            for r in rs[:K]:
                off, ln = int(r["off"]), int(r["len"])
                g_rec = int(r["gap"])
                g_rep = (off - end) if end is not None else g_rec
                if end is not None and g_rep != g_rec:
                    racy += 1
                rec.append(abs(g_rec) / BLOCK)
                rep.append(abs(g_rep) / BLOCK)
                end = off + ln
            feat[fh] = (sum(rec) / len(rec), sum(rep) / len(rep), racy, len(rs))

        hh = handles.get(label, {})
        # ---- (1) residual fidelity: who still mismatches, and how do they differ
        mm = [(fh, r) for fh, r in hh.items() if int(r.get("replay_mismatches") or 0) > 0]
        ok = [(fh, r) for fh, r in hh.items() if int(r.get("replay_mismatches") or 0) == 0]
        print(f"\n== {label}  ({path.rsplit('/',1)[-1]})")
        print(f"   handles in scorer output: {len(hh)}   still mismatching after #273's sort: {len(mm)}")
        if mm:
            def summarise(tag, group):
                if not group:
                    return
                rw = [int(r["rows"]) for _, r in group]
                sz = [int(r["obj_size"] or 0) for _, r in group]
                racy = [feat[fh][2] for fh, _ in group if fh in feat]
                parts = [sum(1 for x in byfh.get(fh, []) if x["path"] == "parts") for fh, _ in group]
                print(f"     {tag:<12} n={len(group):<5} rows median={sorted(rw)[len(rw)//2]:<6} "
                      f"max={max(rw):<6} obj_size median={sorted(sz)[len(sz)//2]:<12} "
                      f"parts-rows>0 on {sum(1 for p in parts if p)}/{len(parts)}  "
                      f"racy first-{K} gaps median={sorted(racy)[len(racy)//2] if racy else 'NA'}")
            summarise("MISMATCHING", mm)
            summarise("faithful", ok)

        # ---- (2) does the separation survive gap repair
        xs_rec, xs_rep, ys = [], [], []
        for fh, r in hh.items():
            if fh not in feat:
                continue
            if int(r.get("replay_mismatches") or 0) > 0:
                continue                      # the scorer excludes these; so do we
            try:
                d = float(r["dispatched_bytes"])
                y = float(r["byte_follow_through"])
            except (TypeError, ValueError):
                continue
            if d <= 0:
                continue                      # scored only over prefetching handles
            xs_rec.append(feat[fh][0])
            xs_rep.append(feat[fh][1])
            ys.append(y)
        n = len(ys)
        r_rec, r_rep = spearman(xs_rec, ys), spearman(xs_rep, ys)
        agree = spearman(xs_rec, xs_rep)
        racy_rows = sum(feat[fh][2] for fh in hh if fh in feat)
        print(f"   SEPARATION robustness over n={n} prefetching, faithful handles:")
        print(f"     rho(mean_abs_gap_blocks RECORDED, byte_follow_through) = "
              f"{'NA' if r_rec is None else f'{r_rec:+.3f}'}")
        print(f"     rho(mean_abs_gap_blocks REPAIRED, byte_follow_through) = "
              f"{'NA' if r_rep is None else f'{r_rep:+.3f}'}"
              f"   <- gap recomputed in seq order")
        print(f"     rho(recorded, repaired) = {'NA' if agree is None else f'{agree:+.3f}'}"
              f"   racy gaps among scored handles' first-{K} reads: {racy_rows}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
