# GCHP AWS Benchmark Tracker

**Project:** AWS GCHP Benchmarking (1-8 nodes)  
**Cluster:** gchp-benchmark (us-east-1)  
**Instance:** c7a.48xlarge (192 cores, AMD EPYC 4th Gen)  
**Started:** May 24, 2026

## Phase 1: Transport Tracers (7-day simulations)

### Run 1: C24, 1 Node ⏳ RUNNING
- **Grid:** C24 (4° × 4°)
- **Cores:** 48 (2×2×6 decomposition)
- **Nodes:** 1
- **Duration:** 2019-01-01 → 2019-01-08 (7 days)
- **Job ID:** 3
- **Status:** Submitted, configuring compute node
- **Expected Runtime:** 10-30 minutes
- **Expected Cost:** ~$0.50

---

## Phase 1 Plan

| Run | Grid | Resolution | Cores | Nodes | Decomp | Status |
|-----|------|------------|-------|-------|--------|--------|
| 1   | C24  | 4° × 4°    | 48    | 1     | 2×2×6  | ⏳ RUNNING |
| 2   | C48  | 2° × 2°    | 96    | 1     | 4×2×6  | ⏸️ Planned |
| 3   | C90  | ~1° × 1°   | 180   | 1     | 6×2×6  | ⏸️ Planned |
| 4   | C90  | ~1° × 1°   | 384   | 2     | 8×4×6  | ⏸️ Planned |
| 5   | C90  | ~1° × 1°   | 768   | 4     | 16×4×6 | ⏸️ Planned |
| 6   | C180 | 0.5° × 0.5°| 384   | 2     | 8×4×6  | ⏸️ Planned |
| 7   | C180 | 0.5° × 0.5°| 768   | 4     | 16×4×6 | ⏸️ Planned |
| 8   | C180 | 0.5° × 0.5°| 1536  | 8     | 32×4×6 | ⏸️ Planned |

**Phase 1 Total:** 8 runs, ~$40 compute

## Phase 2 Plan (Full Chemistry)

| Run | Grid | Resolution | Cores | Nodes | Decomp | Status |
|-----|------|------------|-------|-------|--------|--------|
| 9   | C48  | 2° × 2°    | 96    | 1     | 4×2×6  | ⏸️ Planned |
| 10  | C90  | ~1° × 1°   | 192   | 1     | 6×2×6  | ⏸️ Planned |
| 11  | C90  | ~1° × 1°   | 384   | 2     | 8×4×6  | ⏸️ Planned |
| 12  | C90  | ~1° × 1°   | 768   | 4     | 16×4×6 | ⏸️ Planned |
| 13  | C180 | 0.5° × 0.5°| 384   | 2     | 8×4×6  | ⏸️ Planned |
| 14  | C180 | 0.5° × 0.5°| 768   | 4     | 16×4×6 | ⏸️ Planned |
| 15  | C180 | 0.5° × 0.5°| 1536  | 8     | 32×4×6 | ⏸️ Planned |

**Phase 2 Total:** 7 runs, ~$275 compute

---

## Results Summary

### Phase 1: Transport Tracers

#### Run 1: C24 1-Node
- **Wall Time:** TBD
- **Throughput:** TBD sim-days/wall-day
- **Cost:** TBD
- **Notes:** First benchmark run

---

## Performance Targets

### Transport Tracers (7-day)
- C24 @ 48 cores: < 15 minutes ✅
- C48 @ 96 cores: < 25 minutes
- C90 @ 192 cores: < 45 minutes
- C180 @ 768 cores: < 90 minutes

### Scaling Efficiency
- Strong scaling @ 4 nodes: > 85%
- Weak scaling @ 8 nodes: > 90%

---

## Cost Tracking

| Phase | Runs Complete | Compute Cost | Status |
|-------|---------------|--------------|--------|
| Phase 1 (Transport) | 0/8 | $0.00 | ⏳ In Progress |
| Phase 2 (FullChem) | 0/7 | $0.00 | ⏸️ Pending |
| **Total** | **0/15** | **$0.00** | **~$350 target** |

**Additional Costs:**
- FSx (7 days): ~$35
- Head node + scratch FSx (7 days): ~$520
- **Grand Total Target:** ~$905

---

## Timeline

- **Day 1:** Infrastructure validation ✅
- **Day 2:** Phase 1 begins (Run 1 in progress) ⏳
- **Day 3-4:** Phase 1 completion
- **Day 4-7:** Phase 2 (Full Chemistry)
- **Day 7:** Analysis and reporting

---

## Notes

- All runs use 7-day simulations (2019-01-01 → 2019-01-08)
- Transport Tracers: Minimal chemistry (Rn-Pb-Be)
- Full Chemistry: UCX tropospheric mechanism
- WRITE_RESTART_BY_OSERVER=YES (AWS EFA workaround)
- Restart files from /input/GEOSCHEM_RESTARTS/GC_14.7.0/
- Met fields from /input/GEOS_0.25x0.3125/GEOS_FP/

---

**Status Legend:**
- ✅ Complete
- ⏳ Running
- ⏸️ Planned
- ❌ Failed
- ⏭️ Skipped

**Last Updated:** May 24, 2026 04:53 UTC
