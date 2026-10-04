import csv, collections, math, sys
rows=list(csv.DictReader(open('/scratch/lith-gates/capture/all4.handles.csv')))
def f(r,k):
    v=r[k]
    return float('nan') if v in ('NaN','') else float(v)
def rank(xs):
    order=sorted(range(len(xs)), key=lambda i: xs[i]); r=[0.0]*len(xs); i=0
    while i<len(order):
        j=i
        while j+1<len(order) and xs[order[j+1]]==xs[order[i]]: j+=1
        avg=(i+j)/2.0+1
        for k in range(i,j+1): r[order[k]]=avg
        i=j+1
    return r
def spearman(x,y):
    if len(x)<3: return float('nan')
    rx,ry=rank(x),rank(y); n=len(x)
    mx,my=sum(rx)/n,sum(ry)/n
    num=sum((a-mx)*(b-my) for a,b in zip(rx,ry))
    den=math.sqrt(sum((a-mx)**2 for a in rx)*sum((b-my)**2 for b in ry))
    return num/den if den else float('nan')
def auc(pos,neg):
    if not pos or not neg: return float('nan')
    allv=pos+neg; r=rank(allv); rp=sum(r[:len(pos)])
    return (rp-len(pos)*(len(pos)+1)/2.0)/(len(pos)*len(neg))

print("== population, and where the fidelity mismatch lands")
print(f"{'class/arm':12} {'handles':>8} {'mismatch':>9} {'prefetching':>12} {'pf&clean':>9}")
groups=collections.defaultdict(list)
for r in rows: groups[(r['label'],r['arm'])].append(r)
for k in sorted(groups):
    g=groups[k]
    mm=[r for r in g if int(r['replay_mismatches'])>0]
    pf=[r for r in g if float(r['dispatched_bytes'])>0]
    pfc=[r for r in pf if int(r['replay_mismatches'])==0]
    print(f"{k[0]+'/'+k[1]:12} {len(g):8d} {len(mm):9d} {len(pf):12d} {len(pfc):9d}")

print()
print("== the pre-registered rule, scored ONLY on handles whose replay is faithful")
print(f"{'class/arm':12} {'n':>5} {'rho(mean_abs_gap)':>18} {'median ft':>10} {'mean ft':>9}")
clean={}
for k in sorted(groups):
    pf=[r for r in groups[k] if float(r['dispatched_bytes'])>0 and int(r['replay_mismatches'])==0
        and not math.isnan(f(r,'byte_follow_through'))]
    clean[k]=pf
    y=[f(r,'byte_follow_through') for r in pf]
    x=[f(r,'mean_abs_gap_blocks') for r in pf]
    ys=sorted(y)
    med=ys[len(ys)//2] if ys else float('nan')
    print(f"{k[0]+'/'+k[1]:12} {len(pf):5d} {spearman(x,y):18.3f} {med:10.3f} {sum(y)/len(y) if y else float('nan'):9.4f}")

print()
h=[f(r,'byte_follow_through') for k,v in clean.items() if k[0]=='hemco' for r in v]
m=[f(r,'byte_follow_through') for k,v in clean.items() if k[0]=='met'   for r in v]
print(f"AUC(hemco vs met) on the clean subset = {auc(h,m):.3f}  (n={len(h)} vs {len(m)})")

print()
print("== how much cross-handle sharing is there? (the per-handle model's assumption)")
for cls in ('met','hemco'):
    for arm in ('a','b'):
        g=groups[(cls,arm)]
        objs=collections.Counter(r['obj_size'] for r in g)
        disp=sum(float(r['dispatched_bytes']) for r in g)
        print(f"  {cls}/{arm}: {len(g)} handles over {len(objs)} distinct obj_size values "
              f"=> {len(g)/len(objs):.1f} handles per object; sum(dispatched)={disp/2**30:.1f} GiB")

print()
print("== cold tax (#256 floor) on the clean subset vs all handles")
for cls in ('met','hemco'):
    for arm in ('a','b'):
        g=groups[(cls,arm)]
        gc=[r for r in g if int(r['replay_mismatches'])==0]
        net=sum(float(r['cold_net_waste_bytes']) for r in g)/2**20
        gross=sum(float(r['cold_gross_waste_bytes']) for r in g)/2**20
        netc=sum(float(r['cold_net_waste_bytes']) for r in gc)/2**20
        print(f"  {cls}/{arm}: NET {net:8.1f} MiB  gross {gross:8.1f} MiB   (clean-only NET {netc:8.1f} MiB)")
