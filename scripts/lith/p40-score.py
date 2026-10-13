import json, re, statistics as st
def load(log, work):
    c={}
    for l in open(log):
        m=re.match(r"CELL %s-(\w+)-(\d+) .*?gets=(\d+).*?prefetch_range_MB=([\d.]+).*?uncovered=(\d+)\s*(\{.*\})?"%work,l)
        if m: c[(m.group(1),int(m.group(2)))]=dict(gets=int(m.group(3)),pr=float(m.group(4)),unc=int(m.group(5)),j=json.loads(m.group(6)) if m.group(6) else {},s3=float(re.search(r"s3_MB=([\d.]+)",l).group(1)))
    return c
def score(name, c, arm, metric, lower_is_slower):
    print("==",name)
    kept=[]
    for rep in sorted(set(k[1] for k in c)):
        x,b,z=(metric(c[(a,rep)]) for a in ("X",arm,"Xz")); m=(x+z)/2; gap=abs(x-z)/m; r=b/m
        if gap<=0.10: kept.append(r)
        print(" rep%d X/%s/Xz %.2f/%.2f/%.2f gap %.3f r %.3f %s | uncov %d/%d/%d gets %d/%d/%d pr %.1f s3 %.1f/%.1f/%.1f"%(rep,arm,x,b,z,gap,r,"KEEP" if gap<=.10 else "DISCARD",
              c[("X",rep)]["unc"],c[(arm,rep)]["unc"],c[("Xz",rep)]["unc"],c[("X",rep)]["gets"],c[(arm,rep)]["gets"],c[("Xz",rep)]["gets"],c[(arm,rep)]["pr"],c[("X",rep)]["s3"],c[(arm,rep)]["s3"],c[("Xz",rep)]["s3"]))
    if len(kept)<4: print(" kept",len(kept),"-> INSUFFICIENT"); return
    med=st.median(kept); lo=sum(1 for v in kept if v<1)/len(kept); hi=sum(1 for v in kept if v>1)/len(kept)
    if lower_is_slower: v="SLOWER" if med<0.95 and lo>=.75 else ("FASTER" if med>1.05 and hi>=.75 else "NEUTRAL")
    else: v="SLOWER" if med>1.05 and hi>=.75 else ("FASTER" if med<0.95 and lo>=.75 else "NEUTRAL")
    print(" kept",len(kept),"median r %.3f"%med,"->",v)
G="/scratch/lith-gates/"
score("SS v1.17.1 stream_MBps", load(G+"p40css.log","SS"), "B", lambda d: d["j"]["stream_MBps"], True)
score("NC v1.17.1 wall (open+read)", load(G+"p40bnc.log","NC"), "B", lambda d: d["j"]["open_s"]+d["j"]["read_s"], False)
score("NC v1.16.0 wall (open+read), D=default-on span-once", load(G+"p40bnc16.log","NC"), "D", lambda d: d["j"]["open_s"]+d["j"]["read_s"], False)
