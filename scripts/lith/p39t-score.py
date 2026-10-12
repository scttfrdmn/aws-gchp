import csv
for tag in ["SS-D-1","SS-X-1","SS-D-2","SS-X-2"]:
    f="/scratch/lith-gates/p39w/%s.trace.csv"%tag
    rs=[r for r in csv.DictReader(l for l in open(f) if not l.startswith("#"))]
    big=max(set(r["fh"] for r in rs), key=lambda h: sum(1 for r in rs if r["fh"]==h)); rs=[r for r in rs if r["fh"]==big]
    est=next(i for i,r in enumerate(rs) if r["state_after"]=="sequential")
    def first(th): return next((i-est for i,r in enumerate(rs) if int(r["window"])>=th), None)
    disp=[(i-est,int(r["window"]),int(r["dispatched"])) for i,r in enumerate(rs) if int(r["dispatched"] or 0)>0][:6]
    print("%s est@%d  reads after est to window>=8: %s  >=32: %s  >=64: %s  >=223: %s  first dispatches(rel,win,blk): %s"%(tag,est,first(8),first(32),first(64),first(223),disp))
