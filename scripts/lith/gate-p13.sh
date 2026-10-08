#!/bin/bash
# 5f-P13 (lith#381): heavy-throwaway decay + tcp_metrics flush carrier test. Pre-registered in inregion-streams.txt.
G=/scratch/lith-gates; S3B=$G/lith-s3bench-384; OUT=$G/p13; IDLE=${IDLE:-600}
K=GEOS_0.5x0.625/MERRA2/2019/07/MERRA2.20190708.A3dyn.05x0625.nc4; mkdir -p "$OUT"
sb() { "$S3B" -bucket gcgrid -keys "$K" -workers 32 -part 8388608 -duration 1s > "$1" 2>&1; }
measure() { local tag=$1
  echo "tcp_metrics entries before M: $(ip tcp_metrics show | wc -l)" > "$OUT/$tag.pre.txt"
  sb "$OUT/$tag.M.txt" & local p=$!; sleep 0.4; ss -tin state established '( dport = :443 )' > "$OUT/$tag.ss.txt" 2>&1; wait $p
  local cw; cw=$(grep -o "cwnd:[0-9]*" "$OUT/$tag.ss.txt" | cut -d: -f2 | sort -n | awk '{a[NR]=$1} END{if(NR) printf "n=%d min=%d med=%d max=%d", NR, a[1], a[int((NR+1)/2)], a[NR]}')
  echo "STEP $tag $(date -u +%T) | $(grep -E '^TTFB' "$OUT/$tag.M.txt" | sed 's/  */ /g' | cut -c1-170) | cwnd@0.4s $cw | $(cat "$OUT/$tag.pre.txt")"
  grep -E "^SPLIT" "$OUT/$tag.M.txt" | sed 's/^/     /'; }
echo "=== gate 5f-P13 $(date -u +%FT%TZ) s3bench=$(md5sum "$S3B" | cut -c1-12) idle=${IDLE}s"
sleep "$IDLE"; measure a
sleep "$IDLE"; sb "$OUT/f5.H.txt"; sleep 5; measure f5
sleep "$IDLE"; sb "$OUT/fF.H.txt"; sudo ip tcp_metrics flush; echo "flushed: $(ip tcp_metrics show | wc -l) entries left" >> "$OUT/fF.flush.txt"; sleep 5; measure fF
sleep "$IDLE"; sb "$OUT/f60.H.txt"; sleep 60; measure f60
sleep "$IDLE"; sb "$OUT/f600.H.txt"; sleep 600; measure f600
echo "=== done $(date -u +%FT%TZ)"
