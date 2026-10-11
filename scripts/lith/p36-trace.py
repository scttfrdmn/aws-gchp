import csv, collections, sys
for tag in ["SS-D-1","SS-D-2"]:
    f="/scratch/lith-gates/p36/%s.trace.csv"%tag
    rs=[r for r in csv.DictReader(l for l in open(f) if not l.startswith("#")) if int(r["len"])>0]
    rs=[r for r in rs if r["fh"]!="1"] if len(set(r["fh"] for r in rs))>1 else rs
    big=max(set(r["fh"] for r in rs), key=lambda h: sum(1 for r in rs if r["fh"]==h))
    rs=[r for r in rs if r["fh"]==big]
    first_seq=next((i for i,r in enumerate(rs) if r["state_after"]=="sequential"),None)
    tr=collections.Counter((r["state_before"],r["state_after"]) for r in rs)
    print(tag,"reads",len(rs),"first sequential at read",first_seq,"transitions",dict(tr))
    disp=[(i,int(r["off"])//(1<<20),r["window"],r["dispatched"],r["peak_window"]) for i,r in enumerate(rs) if int(r["dispatched"] or 0)>0]
    print("  dispatches:",len(disp),"total blocks",sum(int(d[3]) for d in disp),"first 6",disp[:6],"last 3",disp[-3:])
    print("  states during scatter (first 40 reads):",dict(collections.Counter(r["state_after"] for r in rs[:40])))
    print("  max window",max(int(r["window"]) for r in rs),"last read off MiB",int(rs[-1]["off"])>>20)
