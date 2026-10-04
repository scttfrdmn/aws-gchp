import csv, collections
CAP='/scratch/lith-gates/capture/'
for cls in ('met','hemco'):
    p=CAP+cls+'-a.csv'
    lines=[l for l in open(p) if not l.startswith('#')]
    rd=list(csv.DictReader(lines))
    keys=collections.defaultdict(set)          # key -> set of fh
    for r in rd: keys[r['key']].add(r['fh'])
    nh=len({r['fh'] for r in rd})
    shared=[k for k,v in keys.items() if len(v)>1]
    print(f"{cls}/a: {len(rd)} rows, {nh} handles, {len(keys)} DISTINCT KEYS")
    print(f"   handles per key: mean {nh/len(keys):.1f}  max {max(len(v) for v in keys.values())}"
          f"   keys touched by >1 handle: {len(shared)}/{len(keys)} ({100*len(shared)/len(keys):.0f}%)")
    # of the handles, how many are the SOLE reader of their key?
    fh_keys=collections.defaultdict(set)
    for r in rd: fh_keys[r['fh']].add(r['key'])
    sole={fh for fh,ks in fh_keys.items() if all(len(keys[k])==1 for k in ks)}
    print(f"   handles that are the SOLE reader of every key they touch: {len(sole)}/{nh}")
    # cross-check against the scored handles: are the fidelity-clean prefetchers the sole readers?
    hs=[r for r in csv.DictReader(open(CAP+'all4.handles.csv')) if r['label']==cls and r['arm']=='a']
    pf=[r for r in hs if float(r['dispatched_bytes'])>0]
    pfc=[r for r in pf if int(r['replay_mismatches'])==0]
    print(f"   prefetching handles: {len(pf)}; fidelity-clean: {len(pfc)}; "
          f"of those clean, sole-reader: {sum(1 for r in pfc if r['fh'] in sole)}/{len(pfc)}")
    print(f"   of the MISMATCHING prefetchers, sole-reader: "
          f"{sum(1 for r in pf if int(r['replay_mismatches'])>0 and r['fh'] in sole)}/{len(pf)-len(pfc)}")
