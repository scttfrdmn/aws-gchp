import csv, io, collections, statistics
def load(p):
    with open(p) as f: lines=[l for l in f if not l.startswith('#')]
    return list(csv.DictReader(io.StringIO(''.join(lines))))
print("The live cap is perHandleWindow = clamp(budgetBlocks/len(handles), 2, 223), applied via")
print("SetMax before EVERY Observe. The trace's `window` column is the prefetcher's window")
print("AFTER that cap, so max(window) is a hard LOWER BOUND on the cap at that instant.")
print("The replay uses a fixed 223.\n")
for label,arm,p in [('met','a','met-a.csv'),('met','b','met-b.csv'),('hemco','a','hemco-a.csv'),('hemco','b','hemco-b.csv')]:
    rows=[r for r in load('/scratch/lith-gates/capture/'+p) if r['path']=='window']
    w=[int(r['window']) for r in rows]; pk=[int(r['peak_window']) for r in rows]
    d=[int(r['dispatched']) for r in rows]
    nz=[x for x in w if x>0]
    print(f"== {label}/{arm}:  window  max {max(w)}  p99 {sorted(w)[int(.99*len(w))]}  mean(nonzero) {statistics.mean(nz) if nz else 0:.2f}  zero {100.0*w.count(0)/len(w):.0f}%")
    print(f"   peak_window max {max(pk)}    dispatched max {max(d)}  sum {sum(d)}")
    print(f"   replay cap 223 vs measured max window {max(w)}  ->  window inflation up to {223/max(max(w),1):.0f}x")
