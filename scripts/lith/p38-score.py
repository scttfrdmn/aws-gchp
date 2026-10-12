import csv, statistics as st
B="/scratch/sweep/p38"
A={a:list(csv.DictReader(open(f"{B}/{a}/rows.csv"))) for a in ("D","B","Dz")}
for sh in ["grib_idx"]:
    print("==",sh)
    kept=[]
    for rep in range(1,19):
        g=lambda a,k: next(r[k] for r in A[a] if r["shape"]==sh and r["rep"]==str(rep))
        d,b,z=(float(g(a,"wall_s")) for a in ("D","B","Dz")); dm=(d+z)/2; gap=abs(d-z)/dm; r=b/dm
        unc=[g(a,"uncovered") for a in ("D","B","Dz")]; used=[g(a,"pf_used")+":"+g(a,"pf_issued") for a in ("D","B","Dz")]
        fl=[ "%.1f"%(1e3*float(g(a,"ttfb_floor_s"))) if g(a,"ttfb_floor_s") else "NA" for a in ("D","B","Dz")]
        amp=[g(a,"amplification_x") for a in ("D","B","Dz")]; gets=[g(a,"get") for a in ("D","B","Dz")]
        keep=gap<=0.10
        if keep: kept.append(r)
        print(" rep%d wall D/B/Dz %.3f/%.3f/%.3f gap %.3f r %.3f %s | uncov %s used:iss %s floor_ms %s amp %s gets %s"%(rep,d,b,z,gap,r,"KEEP" if keep else "DISCARD","/".join(unc),"/".join(used),"/".join(fl),"/".join(amp),"/".join(gets)))
    if len(kept)>=4:
        med=st.median(kept); up=sum(1 for x in kept if x>1)/len(kept); dn=sum(1 for x in kept if x<1)/len(kept)
        v="SLOWER" if med>1.05 and up>=0.75 else ("FASTER" if med<0.95 and dn>=0.75 else "NEUTRAL")
        print(" kept %d  median r %.3f  share r>1 %.2f  share r<1 %.2f  -> %s"%(len(kept),med,up,dn,v))
    else: print(" kept %d -> INSUFFICIENT"%len(kept))
