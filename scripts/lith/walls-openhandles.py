#!/usr/bin/env python3
"""Gate 5f-M: wall time, GET count and fetched bytes per cell, from the gate log.

The window observable is in parse-openhandles.py. This is the consequence side: with the
window driven from 223 down to 2 by handles that are merely open, does the SAME single
streaming read of the SAME object get slower, and does it fetch different bytes?
"""
import collections, re, statistics as st, sys

log = sys.argv[1] if len(sys.argv) > 1 else "/scratch/lith-gates/gate-handles.log"
cells = collections.defaultdict(dict)
re_cell = re.compile(r"CELL (\S+) held=(\d+) readers=(\d+) agg_wall=(\S+) own_wall=(\S+) bytes=(\d+)")
re_get = re.compile(r'MET (\S+) lith_s3_requests_total\{op="get",status="ok"\} (\S+)')
re_b = re.compile(r"MET (\S+) lith_s3_bytes_total (\S+)")

for ln in open(log):
    m = re_cell.match(ln)
    if m:
        d = cells[m.group(1)]
        d["held"], d["rd"] = int(m.group(2)), int(m.group(3))
        d["agg"], d["own"], d["b"] = float(m.group(4)), float(m.group(5)), int(m.group(6))
    m = re_get.match(ln)
    if m:
        cells[m.group(1)]["get"] = int(float(m.group(2)))
    m = re_b.match(ln)
    if m:
        cells[m.group(1)]["s3b"] = float(m.group(2))

grp = collections.defaultdict(list)
for t, d in cells.items():
    arm, n, _rep = t.split("-")
    grp[(arm, int(n[1:]))].append(d)

print("%-4s %4s  %-22s %9s %9s  %-13s %11s" % (
    "arm", "N", "own_wall s (sorted)", "med s", "MB/s", "GETs", "fetched MB"))
for k in sorted(grp, key=lambda x: (x[0], x[1])):
    ds = grp[k]
    ow = sorted(d["own"] for d in ds)
    med = st.median(ow)
    b = ds[0]["b"]
    gets = sorted(set(d.get("get", 0) for d in ds))
    sb = st.median([d.get("s3b", 0) for d in ds])
    if k[0] == "A":
        ag = st.median([d["agg"] for d in ds])
        tb = st.median([d["b"] for d in ds])
        rate = "%.0f agg" % (tb / ag / 1e6)
    else:
        rate = "%.0f" % (b / med / 1e6)
    print("%-4s %4d  %-22s %9.3f %9s  %-13s %11.1f" % (
        k[0], k[1], " ".join("%.3f" % x for x in ow), med, rate,
        ",".join(str(x) for x in gets), sb / 1e6))
