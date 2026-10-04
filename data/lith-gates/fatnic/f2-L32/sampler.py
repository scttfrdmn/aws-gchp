import os, sys, time, urllib.request
url, out, hz, stop = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
WANT = ("lith_open_handles", "lith_streaming_handles", "lith_readahead_window_blocks",
        "lith_prefetch_committed_bytes", "lith_prefetch_budget_bytes")
f = open(out, "w")
f.write("t," + ",".join(w.replace("lith_", "") for w in WANT) + "\n")
t0 = time.time()
while not os.path.exists(stop):
    try:
        body = urllib.request.urlopen(url, timeout=2).read().decode()
    except Exception:
        time.sleep(1.0 / hz); continue
    v = {}
    for ln in body.splitlines():
        if ln.startswith("#"):
            continue
        p = ln.split()
        if len(p) >= 2 and p[0] in WANT:
            v[p[0]] = p[1]
    if len(v) == len(WANT):
        f.write("%.3f,%s\n" % (time.time() - t0, ",".join(v[w] for w in WANT)))
        f.flush()
    time.sleep(1.0 / hz)
f.close()
