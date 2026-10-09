#!/bin/bash
# Chain: wait for 5f-P10 to finish, run 5f-P11, then 5f-P12 (P9y every 30 min until 08:00Z). Pre-registered.
G=/scratch/lith-gates; cd "$G"
until grep -q "=== done" p10.log 2>/dev/null; do sleep 30; done
./gate-p11.sh > p11.log 2>&1; /scratch/ncenv/bin/python p11-score.py p11 > p11/score.txt 2>&1
mkdir -p p12; n=0
while [ "$(date -u +%H%M)" -lt 0800 ] || [ "$(date -u +%H)" -ge 22 ]; do
  n=$((n + 1)); OUT=$G/p12/s$n GATE=5f-P12 MODE=p12 PORT=$((12000 + (n % 40) * 20)) ./gate-p11.sh > p12/s$n.log 2>&1
  /scratch/ncenv/bin/python p11-score.py p12/s$n > p12/s$n.score 2>&1
  sleep 1760
done; echo DONE $(date -u +%FT%TZ) > p12/DONE
