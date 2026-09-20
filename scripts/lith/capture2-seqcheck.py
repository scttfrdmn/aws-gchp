#!/usr/bin/env python3
"""Capture-2 in-job trace acceptance check, and the pre-registered max_window score.

Upstream's asked-for acceptance check on the new trace format is that `seq` orders the
decisions within every fh. It replaces the gap self-consistency criterion, which gate 5i
showed is NOT a validity test (it measures the mount's lastReadEnd read-modify-write
race, which the trace records faithfully; it survives seq and even rises).

Scored as UNIQUENESS, not as monotonicity in file order -- see the comment at the
acceptance block. Driving this script on the gate 5i traces before the job is what found
that distinction: the c64 arm, whose trace replays at exactly 1.00x under lith#273, fails
the literal file-order reading at 0.36%.

Also scores, in-job and before any offline scoring can be tuned to it, the gate 5i
prediction registered on lith#256 and #267:

    max_window will read 2 for essentially every HEMCO row, and 2-3 on met with a
    brief higher tail early in the run while few handles are open.
    FALSIFIER: values near 223.

Prints one block per trace. Exit status is 0 unless the trace is UNSCOREABLE, so a
failed prediction does not fail the job -- a prediction is scored, not enforced.
"""
import collections
import csv
import sys


def load(path):
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
                break          # truncated final row; the run was killed mid-write
    return hdr or [], rows


def main(paths):
    bad = 0
    for path in paths:
        hdr, rows = load(path)
        name = path.rsplit("/", 1)[-1]
        print(f"SEQCHECK {name}: rows={len(rows)} cols={len(hdr)}")
        if not rows:
            print("  UNSCOREABLE: no rows")
            bad = 1
            continue
        for c in ("seq", "max_window", "size"):
            if c not in hdr:
                print(f"  UNSCOREABLE: missing column '{c}'")
                bad = 1
        if "seq" not in hdr:
            continue

        # ACCEPTANCE: seq is a TOTAL ORDER over the decisions -- unique and positive. Then
        # sorting by it recovers decision order, which is the property a replay needs.
        #
        # NOT "strictly increasing within each fh in FILE order", which is how upstream's
        # ask reads literally: gate 5i measured that rows are APPENDED out of order 0.36% of
        # the time on a contended handle and 10.94% at 256 handles, by design, because the
        # append happens outside w.mu. A trace that satisfied the literal reading would be
        # one where seq was never needed. Gating on it would reject exactly the traces seq
        # was added for -- the same error as the retired gap criterion below.
        byfh = collections.defaultdict(list)
        for r in rows:
            byfh[r["fh"]].append(int(r["seq"]))
        seqs = [int(r["seq"]) for r in rows]
        dup = len(seqs) - len(set(seqs))
        nonpos = sum(1 for s in seqs if s <= 0)
        inv = sum(1 for a, b in zip(seqs, seqs[1:]) if b < a)
        ok = not dup and not nonpos
        print(f"  ACCEPT seq is a total order (unique, positive): {'YES' if ok else 'NO'}"
              f"   (handles={len(byfh)}, duplicate seq={dup}, non-positive={nonpos})")
        print(f"  rows appended out of decision order: {inv}/{max(len(seqs)-1,1)} "
              f"({100.0*inv/max(len(seqs)-1,1):.2f}%)  <- what `seq` exists to recover; "
              f"a NON-zero rate here is why the scorer must sort (lith#272)")
        if not ok:
            print("  UNSCOREABLE: seq does not order the decisions")
            bad = 1

        # PRE-REGISTERED: max_window.
        if "max_window" in hdr:
            mw = [int(r["max_window"]) for r in rows]
            c = collections.Counter(mw)
            top = ", ".join(f"{v}x{n}" for v, n in c.most_common(5))
            frac2 = 100.0 * sum(n for v, n in c.items() if v <= 3) / len(mw)
            near223 = 100.0 * sum(n for v, n in c.items() if v >= 200) / len(mw)
            print(f"  PREREG max_window: min={min(mw)} max={max(mw)} "
                  f"median={sorted(mw)[len(mw)//2]}  top={top}")
            print(f"         {frac2:.1f}% of rows at <=3 blocks, {near223:.1f}% at >=200"
                  f"   [predicted: overwhelmingly <=3; falsifier: near 223]")

        # For the record only: the retired gap criterion, so the retirement is auditable.
        last, ginc, gtot = {}, 0, 0
        for r in sorted(rows, key=lambda x: int(x["seq"])):
            if r["path"] != "window":
                continue
            fh, off, ln, gap = r["fh"], int(r["off"]), int(r["len"]), int(r["gap"])
            if fh in last:
                gtot += 1
                if off - last[fh] != gap:
                    ginc += 1
            last[fh] = off + ln
        pct = 100.0 * ginc / gtot if gtot else 0.0
        print(f"  (retired criterion, recorded not gated) gap self-inconsistent in seq "
              f"order: {ginc}/{gtot} ({pct:.2f}%) -- the mount's lastReadEnd race")
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
