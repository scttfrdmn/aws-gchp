import json, re, statistics as st
L=open("/scratch/lith-gates/p39w2.log").read().splitlines()
c={}
for l in L:
    m=re.match(r"CELL SS-(\w+)-(\d+) .*?gets=(\d+).*?prefetch_range_MB=([\d.]+).*?(\{.*\})",l)
    if m: j=json.loads(m.group(5)); c[(m.group(1),int(m.group(2)))]=(j["stream_MBps"],j["scatter_s"],int(m.group(3)),m.group(4))
kept=[]
for rep in sorted(set(k[1] for k in c)):
    x,d,z=c[("X",rep)][0],c[("D",rep)][0],c[("Xz",rep)][0]; m=(x+z)/2; gap=abs(x-z)/m; r=d/m
    k=gap<=0.10; kept+= [r] if k else []
    print(" rep%d stream MB/s X/D/Xz %.1f/%.1f/%.1f gap %.3f r %.3f %s  gets %d/%d/%d"%(rep,x,d,z,gap,r,"KEEP" if k else "DISCARD",c[("X",rep)][2],c[("D",rep)][2],c[("Xz",rep)][2]))
if len(kept)>=4:
    med=st.median(kept); dn=sum(1 for v in kept if v<1)/len(kept); up=sum(1 for v in kept if v>1)/len(kept)
    print(" kept",len(kept),"median r %.3f"%med,"share r<1 %.2f"%dn,"->","SLOWER" if med<0.95 and dn>=.75 else ("FASTER" if med>1.05 and up>=.75 else "NEUTRAL"))
else: print(" kept",len(kept),"-> INSUFFICIENT")
