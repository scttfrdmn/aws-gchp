# One row per mount per tick: cumulative TTFB histogram (le 0.025 / 0.06 / count), median, gauge, inflight.
import os, sys, time, urllib.request
out, hz, stop = sys.argv[1], float(sys.argv[2]), sys.argv[3]
targets = [a.split("=", 1) for a in sys.argv[4:]]
KEYS = {"lith_ttfb_seconds_bucket{le=\"0.025\"}": "le025", "lith_ttfb_seconds_bucket{le=\"0.06\"}": "le060",
        "lith_ttfb_seconds_count": "count", "lith_ttfb_median_seconds": "median",
        "lith_ttfb_measured": "measured", "lith_readahead_evidence_ratio": "gauge",
        "lith_s3_inflight": "inflight", "lith_s3_bytes_total": "s3bytes", "lith_open_handles": "open",
        "lith_ttfb_floor_seconds": "floor"}   # v1.6.0+; NA on older binaries
cols = list(KEYS.values())
f = open(out, "w"); f.write("t,mount," + ",".join(cols) + "\n"); t0 = time.time()
while not os.path.exists(stop):
    for name, url in targets:
        try: body = urllib.request.urlopen(url, timeout=2).read().decode()
        except Exception: continue
        v = {}
        for ln in body.splitlines():
            if ln.startswith("#"): continue
            k, _, val = ln.rpartition(" ")
            if k in KEYS: v[KEYS[k]] = val
        if len(v) >= len(cols) - 1:
            f.write("%.2f,%s,%s\n" % (time.time() - t0, name, ",".join(v.get(c, "NA") for c in cols)))
    f.flush(); time.sleep(1.0 / hz)
f.close()
