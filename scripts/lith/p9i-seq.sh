#!/bin/bash
# 5f-P9i diagnostic (unscored): does the evidence gate stay engaged across successive opens on one
# default v1.5.0 mount? var1 slice of A3dyn for 6 different days in one mount; scrape after each.
G=/scratch/lith-gates; B=$G/v150/lith_linux_arm64; MNT=/scratch/mnt/p9; PORT=9950; OUT=${OUT:-$G/p9i}
PYX=/scratch/ncenv/bin/python; READER=$G/gate2nd/reader.py
mkdir -p "$MNT" "$OUT"
"$B" mount s3://gcgrid/GEOS_0.5x0.625/MERRA2/2019/07 "$MNT" --metrics ":$PORT" --nic-gbps 50 \
    --log-level warn > "$OUT/seq.mount.log" 2>&1 &
for _ in $(seq 1 90); do mountpoint -q "$MNT" && break; sleep 1; done
for d in 02 03 04 05 06 07; do
  rd=$($PYX "$READER" "$MNT/MERRA2.201907$d.A3dyn.05x0625.nc4" var1 2>&1 | tail -1)
  curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/seq.$d.prom"
  echo "OPEN $d reader=[$rd]"
done
fusermount3 -u "$MNT"
$PYX - "$OUT" <<'PY'
import sys, re
out = sys.argv[1]; prev = {}
for d in "02 03 04 05 06 07".split():
    m = {}
    for l in open(f"{out}/seq.{d}.prom"):
        if l.startswith("#"): continue
        k, v = l.rsplit(" ", 1); m[k] = m.get(k, 0) + float(v) if k.startswith("lith_s3_requests_total") else float(v)
    get = lambda k: m.get(k, 0.0)
    reqs = sum(v for k, v in m.items() if k.startswith("lith_s3_requests_total"))
    b = {re.search(r'le="([^"]+)"', k).group(1): v for k, v in m.items() if k.startswith("lith_ttfb_seconds_bucket")}
    cnt = get("lith_ttfb_seconds_count"); pc = prev.get("cnt", 0); pb = prev.get("b", {})
    le50 = b.get("0.05", 0) - pb.get("0.05", 0)
    print(f"{d}: dMB={(get('lith_s3_bytes_total')-prev.get('bytes',0))/1e6:7.1f} dGETs={reqs-prev.get('reqs',0):4.0f} "
          f"gauge={get('lith_readahead_evidence_ratio'):.0f} median_ms={get('lith_ttfb_median_seconds')*1e3:6.1f} "
          f"this-open samples={cnt-pc:.0f} le50={le50:.0f} mean_ms={(get('lith_ttfb_seconds_sum')-prev.get('sum',0))/max(cnt-pc,1)*1e3:5.1f}")
    prev = dict(bytes=get('lith_s3_bytes_total'), reqs=reqs, cnt=cnt, b=b, sum=get('lith_ttfb_seconds_sum'))
PY
