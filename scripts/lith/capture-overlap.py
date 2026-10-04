import csv, io, collections

def load(p):
    with open(p) as f:
        lines=[l for l in f if not l.startswith('#')]
    return list(csv.DictReader(io.StringIO(''.join(lines))))

H=list(csv.DictReader(open('/scratch/lith-gates/capture/all4-269.handles.csv')))
for label,arm,p in [('met','a','met-a.csv'),('met','b','met-b.csv'),('hemco','a','hemco-a.csv'),('hemco','b','hemco-b.csv')]:
    rows=load('/scratch/lith-gates/capture/'+p)
    last={}; bad=set(); allfh=set(); pf_window_varies=collections.Counter()
    for r in rows:
        if r['path']!='window': continue
        fh=r['fh']; off=int(r['off']); ln=int(r['len']); gap=int(r['gap'])
        allfh.add(fh)
        exp = off - last.get(fh,0)
        if exp!=gap: bad.add(fh)
        last[fh]=off+ln
        pf_window_varies[r['window']]+=1
    hs=[h for h in H if h['label']==label and h['arm']==arm]
    mis={h['fh'] for h in hs if int(h['replay_mismatches'])>0}
    pref={h['fh'] for h in hs if float(h['dispatched_bytes'])>0}
    print(f"== {label}/{arm}")
    print(f"   fidelity-mismatching handles {len(mis)}   gap-inconsistent handles {len(bad)}   overlap {len(mis&bad)}")
    print(f"   mismatching AND gap-inconsistent: {len(mis&bad)}/{len(mis)} = {100.0*len(mis&bad)/max(len(mis),1):.1f}% of the mismatches")
    print(f"   gap-inconsistent but faithful: {len(bad-mis)}    mismatching but gap-consistent: {len(mis-bad)}")
    print(f"   prefetching handles {len(pref)}; of those mismatching {len(pref&mis)}; of those gap-inconsistent {len(pref&bad)}")
    print(f"   distinct 'window' values in trace: {dict(list(pf_window_varies.most_common(6)))}")
