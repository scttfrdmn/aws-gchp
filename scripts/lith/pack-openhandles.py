#!/usr/bin/env python3
"""Gate 5f-M archive packer.

The raw --pf-trace CSVs total ~500 MB over 150 cells (3586 fetch rows per streaming
handle), which is far out of line with the 1-2 MB archives banked for every other gate on
lith#256. So the archive keeps:
  - every mount log and every wall file, untrimmed
  - windows.csv: the DECISION observable for all 150 cells, one row per handle
    (cell, arm, forced max_readahead, open handles, fh, fetches, wmax, wsteady)
  - the full raw CSV for the decisive cells only (listed in KEEP_FULL)
Anything derived here can be recomputed from the full CSVs that are kept, and the per-cell
summary is what the result tables are actually built from.
"""
import csv, glob, os, re, statistics as st, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/scratch/lith-gates"
DEST = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "oh-archive")

# decisive cells: every main-gate cell at rep 1, and the forced-window control at 1 handle
KEEP_FULL = set()
for n in (1, 2, 3, 4, 8, 16):
    KEEP_FULL.add(("gate-handles", "A-n%d-1" % n))
for n in (2, 3, 4, 8, 16, 64, 256):
    KEEP_FULL.add(("gate-handles", "B-n%d-1" % n))
KEEP_FULL.add(("gate-handles", "C-n8-1"))
for mra in (2, 7, 30, 61):
    KEEP_FULL.add(("gh-ctl-%d" % mra, "A-n1-1"))

os.makedirs(DEST, exist_ok=True)
rows = []
for d in ["gate-handles"] + sorted(glob.glob(os.path.join(ROOT, "gh-ctl-*"))):
    dn = os.path.basename(d)
    full = d if os.path.isabs(d) else os.path.join(ROOT, d)
    mra = int(dn.split("-")[-1]) if dn.startswith("gh-ctl-") else 0   # 0 = auto (223)
    for cpath in sorted(glob.glob(os.path.join(full, "*.csv"))):
        cell = os.path.basename(cpath)[:-4]
        m = re.match(r"([ABC])-n(\d+)-(\d+)$", cell)
        if not m:
            continue
        arm, nh, rep = m.group(1), int(m.group(2)), int(m.group(3))
        fh = open(cpath)
        fh.readline()
        per = {}
        for r in csv.DictReader(fh):
            try:
                per.setdefault(r["fh"], []).append(int(r["window"]))
            except (KeyError, ValueError):
                pass
        fh.close()
        for h, v in sorted(per.items(), key=lambda kv: -len(kv[1])):
            tail = v[int(len(v) * 0.2):] or v
            rows.append([dn, cell, arm, mra, nh, rep, h, len(v),
                         max(v), int(st.median(tail))])
        if (dn, cell) in KEEP_FULL:
            od = os.path.join(DEST, dn)
            os.makedirs(od, exist_ok=True)
            with open(cpath) as src, open(os.path.join(od, cell + ".csv"), "w") as dst:
                dst.write(src.read())

with open(os.path.join(DEST, "windows.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["dir", "cell", "arm", "forced_max_readahead", "open_handles", "rep",
                "fh", "fetches", "wmax", "wsteady"])
    w.writerows(rows)
print("windows.csv rows:", len(rows), " full CSVs kept:", len(KEEP_FULL))
