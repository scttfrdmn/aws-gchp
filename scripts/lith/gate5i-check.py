#!/usr/bin/env python3
"""Gate 5i analysis: does PR#271's `seq` recover decision order, and does the gap
self-consistency test go to 0% as upstream's pre-capture criterion assumes?

Three separate questions, deliberately not conflated:
  A. FILE ORDER vs SEQ ORDER -- how many rows are appended out of decision order.
     This is the direct measurement of what I previously had to infer from `gap`.
  B. SEQ MONOTONIC WITHIN fh -- upstream's first criterion. Exact by construction if
     seq is allocated under w.mu; a failure here means it is in the wrong place.
  C. GAP SELF-CONSISTENCY, rows sorted by seq -- upstream's second criterion.
     gap == off - (prev_off + prev_len) for consecutive window rows of one fh.
     `gap` is computed from lastReadEnd BEFORE the lock and stored AFTER it, so
     concurrent reads on one fh can measure against the same stale value. If that is
     the residual, C stays > 0 on a CORRECT trace and must not be used as a gate.
  D. max_window -- present, populated, and what the mount actually applied.
"""
import csv
import sys


def load(path):
    rows = []
    with open(path) as fh:
        hdr = None
        for line in fh:
            if line.startswith("#"):
                continue
            if hdr is None:
                hdr = next(csv.reader([line]))
                continue
            r = dict(zip(hdr, next(csv.reader([line]))))
            rows.append(r)
    return hdr, rows


def main(paths):
    for p in paths:
        hdr, rows = load(p)
        name = p.rsplit("/", 1)[-1]
        has_seq = "seq" in hdr
        has_mw = "max_window" in hdr
        print(f"\n=== {name}: {len(rows)} rows  seq={has_seq} max_window={has_mw}")
        if not has_seq:
            print("    no seq column -- old format, nothing to check")
            continue
        if not rows:
            print("    EMPTY trace -- the reader produced no reads. Harness bug, not a "
                  "finding; do not score this arm.")
            continue

        # A. append order vs decision order
        seqs = [int(r["seq"]) for r in rows]
        inv = sum(1 for a, b in zip(seqs, seqs[1:]) if b < a)
        print(f"  A. rows appended out of decision order: {inv}/{max(len(seqs)-1,1)} "
              f"({100.0*inv/max(len(seqs)-1,1):.2f}%)   "
              f"[seq range {min(seqs)}..{max(seqs)}, duplicates {len(seqs)-len(set(seqs))}]")

        # B. seq strictly increasing within each fh (sorted by seq -> trivially true;
        #    the real content is whether file order within an fh is already sorted)
        byfh = {}
        for r in rows:
            byfh.setdefault(r["fh"], []).append(r)
        bad_fh = 0
        for fh, rs in byfh.items():
            s = [int(x["seq"]) for x in rs]
            if any(b <= a for a, b in zip(s, s[1:])):
                bad_fh += 1
        print(f"  B. fh with non-increasing seq in FILE order: {bad_fh}/{len(byfh)} "
              f"(sorted by seq: strictly increasing by construction)")

        # C. gap self-consistency, rows ordered by seq
        for label, keyf in (("file order", lambda rs: rs),
                            ("seq order", lambda rs: sorted(rs, key=lambda x: int(x["seq"])))):
            bad = 0
            tot = 0
            badfh = set()
            ex = []
            for fh, rs in byfh.items():
                last = None
                for r in keyf(rs):
                    if r["path"] != "window":
                        continue
                    off, ln, gap = int(r["off"]), int(r["len"]), int(r["gap"])
                    if last is not None:
                        tot += 1
                        implied = off - last
                        if implied != gap:
                            bad += 1
                            badfh.add(fh)
                            if len(ex) < 3:
                                ex.append(f"fh={fh} off={off} recorded_gap={gap} implied={implied}")
                    last = off + ln
            pct = 100.0 * bad / tot if tot else 0.0
            print(f"  C. gap self-inconsistent, {label}: {bad}/{tot} ({pct:.2f}%) "
                  f"over {len(badfh)} fh")
            for e in ex:
                print(f"       {e}")

        # D. max_window
        if has_mw:
            mw = [int(r["max_window"]) for r in rows]
            w = [int(r["window"]) for r in rows]
            print(f"  D. max_window: min={min(mw)} max={max(mw)} distinct={len(set(mw))} "
                  f"| window: max={max(w)}  (replay's static assumption was 223)")


if __name__ == "__main__":
    main(sys.argv[1:])
