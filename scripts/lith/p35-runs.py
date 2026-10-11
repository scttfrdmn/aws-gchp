import csv, collections, sys
for sh in ["grib_idx","fits_header_cutout","hemco_timeslice"]:
    f="/scratch/sweep/p35/AB/%s-1.trace.csv" % sh
    rows=[r for r in csv.DictReader(l for l in open(f) if not l.startswith("#"))]
    byfh=collections.defaultdict(list)
    for r in rows: byfh[(r["key"],r["fh"])].append(r)
    for (k,fh),rs in byfh.items():
        est=sum(1 for r in rs if r["state_before"]!="sequential" and r["state_after"]=="sequential")
        ends=sum(1 for r in rs if r["state_before"]=="sequential" and r["state_after"]!="sequential")
        seqreads=sum(1 for r in rs if r["state_after"]=="sequential")
        disp=sum(int(r["dispatched"] or 0) for r in rs)
        tr=collections.Counter((r["state_before"],r["state_after"]) for r in rs)
        lens=collections.Counter(int(r["len"]) for r in rs).most_common(3)
        paths=dict(collections.Counter(r["path"] for r in rs))
        print("%-19s fh=%-3s reads=%3d establish=%d run_ends=%d seq_reads=%d dispatched=%d lens=%s paths=%s" % (sh,fh,len(rs),est,ends,seqreads,disp,lens,paths))
        print("     transitions:", dict(tr))
