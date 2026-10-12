import csv, statistics as st
B="/scratch/sweep/p39"
A={a:list(csv.DictReader(open(f"{B}/{a}/rows.csv"))) for a in ("D","X")}
shapes=[]; [shapes.append(r["shape"]) for r in A["D"] if r["shape"] not in shapes]
for sh in shapes:
    g=lambda a,k:[r[k] for r in A[a] if r["shape"]==sh]
    d=g("D","amplification_x"); x=g("X","amplification_x")
    rat=[float(p)/float(q) if float(q) else float("nan") for p,q in zip(d,x)]
    mv="MOVES" if all(abs(r-1)>0.10 for r in rat) else "same"
    print("%-20s D %-11s X %-11s D/X %-11s %-5s get D %-9s X %-9s pr_MB D %-11s X %-11s ok %s %s"%(sh,"/".join(d),"/".join(x),"/".join("%.2f"%r for r in rat),mv,
      "/".join(g("D","get")),"/".join(g("X","get")),"/".join("%.2f"%(int(v)/1e6) for v in g("D","fill_prefetch_range")),"/".join("%.2f"%(int(v)/1e6) for v in g("X","fill_prefetch_range")),"/".join(g("D","ok")),"/".join(g("X","ok"))))
print("== wall cell webdataset_stream (X, D, Xz)")
W={a:list(csv.DictReader(open(f"/scratch/sweep/p39b/{a}/rows.csv"))) for a in ("X","D","Xz")}
kept=[]
for rep in range(1,13):
    w=lambda a: float(next(r["wall_s"] for r in W[a] if r["rep"]==str(rep)))
    x,d,z=w("X"),w("D"),w("Xz"); m=(x+z)/2; gap=abs(x-z)/m; r=d/m
    if gap<=0.10: kept.append(r)
    print(" rep%d X/D/Xz %.3f/%.3f/%.3f gap %.3f r %.3f %s"%(rep,x,d,z,gap,r,"KEEP" if gap<=0.10 else "DISCARD"))
if len(kept)>=4:
    med=st.median(kept); up=sum(1 for v in kept if v>1)/len(kept); dn=sum(1 for v in kept if v<1)/len(kept)
    print(" kept",len(kept),"median %.3f"%med,"->","SLOWER" if med>1.05 and up>=.75 else ("FASTER" if med<.95 and dn>=.75 else "NEUTRAL"))
else: print(" kept",len(kept),"-> INSUFFICIENT")
