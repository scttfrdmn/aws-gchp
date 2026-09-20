import csv, collections, sys, io

def load(p):
    with open(p) as f:
        lines=[l for l in f if not l.startswith('#')]
    return list(csv.DictReader(io.StringIO(''.join(lines))))

for name,p in [('met/a','met-a.csv'),('met/b','met-b.csv'),('hemco/a','hemco-a.csv'),('hemco/b','hemco-b.csv')]:
    rows=load('/scratch/lith-gates/capture/'+p)
    # gap is computed as off - h.lastReadEnd, and lastReadEnd is stored AFTER the
    # row is written, only on the window path. So for consecutive window rows of one
    # fh, in true issue order, gap must equal off - (prev_off + prev_len).
    last=dict(); mism=0; tot=0; first=0
    ex=[]
    per_fh_mism=collections.Counter()
    for r in rows:
        if r['path']!='window': continue
        fh=r['fh']; off=int(r['off']); ln=int(r['len']); gap=int(r['gap'])
        if fh not in last:
            exp=off-0; first+=1
        else:
            exp=off-last[fh]
        tot+=1
        if exp!=gap:
            mism+=1; per_fh_mism[fh]+=1
            if len(ex)<4: ex.append((fh,off,ln,gap,exp))
        last[fh]=off+ln
    print(f"{name}: window rows {tot}  gap self-consistent mismatches {mism} ({100.0*mism/max(tot,1):.2f}%)  handles affected {len(per_fh_mism)}")
    for e in ex:
        print(f"    fh={e[0]} off={e[1]} len={e[2]} recorded_gap={e[3]} implied_by_row_order={e[4]}  delta={e[3]-e[4]}")
