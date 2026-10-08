#!/bin/bash
# Wait for 5f-P13, then run 5f-P14 and 5f-P15 (both pre-registered).
cd /scratch/lith-gates; until grep -q "=== done" p13.log 2>/dev/null; do sleep 30; done
./gate-p14.sh > p14.log 2>&1; ./gate-p15.sh > p15.log 2>&1; echo DONE $(date -u +%FT%TZ) > chain-p14-p15.done
