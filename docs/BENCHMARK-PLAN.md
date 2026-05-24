# GCHP AWS Benchmarking Plan

**Goal:** Comprehensive performance benchmarking of GCHP 14.7.1 on AWS ParallelCluster across 1-8 nodes with scientifically valid simulations.

**Date:** May 24, 2026  
**Cluster:** gchp-benchmark (us-east-1)  
**Instance Type:** c7a.48xlarge (192 cores, AMD EPYC 4th Gen)

## Benchmark Strategy

### Phase 1: Transport Tracers (Fast Validation)
**Purpose:** Rapid scaling validation with minimal chemistry  
**Duration:** 7 days (2019-01-01 00:00 → 2019-01-08 00:00)  
**Chemistry:** Rn-Pb-Be transport tracers only

**Configurations:**

| Grid | Resolution | Cores | Nodes | Decomposition | Cost/Run |
|------|------------|-------|-------|---------------|----------|
| C24  | 4° × 4°    | 48    | 1     | 2×2×6         | ~$0.50   |
| C48  | 2° × 2°    | 96    | 1     | 4×2×6 or 3×2×6 | ~$1.00   |
| C90  | ~1° × 1°   | 180   | 1     | 6×2×6         | ~$2.00   |
| C90  | ~1° × 1°   | 384   | 2     | 8×4×6         | ~$3.00   |
| C90  | ~1° × 1°   | 768   | 4     | 16×4×6        | ~$5.00   |
| C180 | 0.5° × 0.5°| 384   | 2     | 8×4×6         | ~$4.00   |
| C180 | 0.5° × 0.5°| 768   | 4     | 16×4×6        | ~$8.00   |
| C180 | 0.5° × 0.5°| 1536  | 8     | 32×4×6        | ~$16.00  |

**Expected Runtime:** 10-30 minutes per configuration  
**Total Phase 1 Cost:** ~$40

### Phase 2: Full Chemistry (Production Benchmark)
**Purpose:** Realistic production workload performance  
**Duration:** 7 days (2019-01-01 00:00 → 2019-01-08 00:00)  
**Chemistry:** Full tropospheric chemistry (UCX mechanism)

**Configurations:**

| Grid | Resolution | Cores | Nodes | Decomposition | Cost/Run |
|------|------------|-------|-------|---------------|----------|
| C48  | 2° × 2°    | 96    | 1     | 4×2×6         | ~$10     |
| C90  | ~1° × 1°   | 192   | 1     | 6×2×6         | ~$15     |
| C90  | ~1° × 1°   | 384   | 2     | 8×4×6         | ~$20     |
| C90  | ~1° × 1°   | 768   | 4     | 16×4×6        | ~$30     |
| C180 | 0.5° × 0.5°| 384   | 2     | 8×4×6         | ~$40     |
| C180 | 0.5° × 0.5°| 768   | 4     | 16×4×6        | ~$60     |
| C180 | 0.5° × 0.5°| 1536  | 8     | 32×4×6        | ~$100    |

**Expected Runtime:** 2-12 hours per configuration  
**Total Phase 2 Cost:** ~$275

## Performance Metrics

### Primary Metrics
1. **Wall Time** - Total simulation time
2. **Throughput** - Simulated days per wall-clock day
3. **Scalability** - Speedup vs. baseline (1 node)
4. **Efficiency** - Parallel efficiency percentage
5. **Cost Efficiency** - Simulated days per dollar

### Secondary Metrics
6. **Time per timestep** - Average across simulation
7. **Chemistry time** - Time in chemistry solver
8. **Transport time** - Time in advection
9. **I/O time** - Time reading/writing data
10. **Communication time** - MPI overhead

### System Metrics
11. **CPU utilization** - Average across cores
12. **Memory usage** - Peak and average
13. **Network I/O** - FSx read/write bandwidth
14. **Compute cost** - EC2 costs
15. **Storage cost** - FSx costs

## Data Collection

### GCHP Timing Output
- Enable MAPL timers: `MAPL_ENABLE_TIMERS: YES`
- Collect from `GCHP.*.log` files
- Parse component times:
  - DYNAMICS
  - CHEMISTRY
  - CONVECTION  
  - EMISSIONS
  - TOTAL

### SLURM Accounting
```bash
sacct -j JOBID --format=JobID,JobName,Elapsed,CPUTime,MaxRSS,State,ExitCode
```

### FSx Metrics
```bash
# Before run
df -h /fsx /input /scratch

# After run  
du -sh /scratch/OUTPUT/
```

### CloudWatch Metrics
- EC2 CPU utilization
- Network bytes in/out
- EBS read/write ops

## Expected Results

### Scaling Expectations

**Strong Scaling (Fixed Grid):**
- C90 @ 192 cores (1 node): Baseline
- C90 @ 384 cores (2 nodes): 1.8-1.9× speedup (90-95% efficiency)
- C90 @ 768 cores (4 nodes): 3.4-3.7× speedup (85-92% efficiency)

**Weak Scaling (Fixed Work/Core):**
- C48 @ 96 cores: Baseline throughput
- C90 @ 384 cores: ~4× grid points, ~4× cores → similar time
- C180 @ 1536 cores: ~16× grid points, ~16× cores → similar time

### Performance Targets

**Transport Tracers (7-day simulation):**
- C24 @ 48 cores: < 15 minutes
- C48 @ 96 cores: < 25 minutes
- C90 @ 192 cores: < 45 minutes
- C180 @ 768 cores: < 90 minutes

**Full Chemistry (7-day simulation):**
- C48 @ 96 cores: < 3 hours
- C90 @ 192 cores: < 6 hours
- C180 @ 768 cores: < 10 hours

## Run Directory Setup

### Using createRunDir.sh
```bash
cd /scratch
source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh

# Create run directory (interactive)
/fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-14.7.1/run/createRunDir.sh

# Configure:
# - ExtData: /input
# - Simulation: TransportTracers or fullchem
# - Grid: C24, C48, C90, or C180
# - Duration: 7 days
```

### Key Configuration Files

**CAP.rc:**
```
BEG_DATE: 20190101 000000
END_DATE: 20190108 000000
JOB_SGMT: 00000007 000000
HEARTBEAT_DT: 3600
```

**GCHP.rc (C90 example):**
```
NX: 6
NY: 2
GCHP.IM_WORLD: 90
GCHP.IM: 90
GCHP.JM: 540
```

**HISTORY.rc:**
```
# Minimal diagnostics for benchmarking
COLLECTIONS: 'Restart',
::
```

## Execution Plan

### Step 1: Transport Tracers (1-2 days)
1. Create C24 run directory → 1 node test
2. Create C48 run directory → 1 node test
3. Create C90 run directory → 1, 2, 4 node tests
4. Create C180 run directory → 2, 4, 8 node tests

**Total: 8 runs, ~$40**

### Step 2: Analysis (0.5 days)
1. Parse timing logs
2. Calculate speedup/efficiency
3. Identify any issues
4. Validate scientific output

### Step 3: Full Chemistry (3-5 days)
1. Create fullchem C48 → 1 node
2. Create fullchem C90 → 1, 2, 4 nodes
3. Create fullchem C180 → 2, 4, 8 nodes

**Total: 7 runs, ~$275**

### Step 4: Final Analysis (1 day)
1. Complete performance database
2. Generate scaling plots
3. Cost analysis
4. Write benchmark report

## Deliverables

1. **Performance Database** (CSV/JSON)
   - All timing data
   - Scaling metrics
   - Cost data

2. **Scaling Plots**
   - Strong scaling (C90, C180)
   - Weak scaling (C48→C90→C180)
   - Cost efficiency

3. **Benchmark Report** (Markdown)
   - Executive summary
   - Methodology
   - Results and analysis
   - Recommendations

4. **Configuration Archive**
   - All run directories
   - SLURM scripts
   - Timing logs

## Cost Estimate

| Phase | Runs | Compute Cost | FSx Cost | Total |
|-------|------|--------------|----------|-------|
| Transport Tracers | 8 | ~$40 | ~$10 | ~$50 |
| Full Chemistry | 7 | ~$275 | ~$25 | ~$300 |
| **Total** | **15** | **~$315** | **~$35** | **~$350** |

**Timeline:** 5-7 days total
**Cluster Lifetime:** ~7 days (~$520 head node + scratch FSx)

**Grand Total:** ~$870 for complete benchmark suite

## Success Criteria

1. ✅ All 15 benchmark runs complete successfully
2. ✅ Scientifically valid output (mass conservation, etc.)
3. ✅ Strong scaling efficiency > 85% at 4 nodes
4. ✅ Weak scaling efficiency > 90% at 8 nodes
5. ✅ Complete performance database
6. ✅ Publication-ready scaling plots
7. ✅ Comprehensive benchmark report

## Notes

- **Grid Resolution Constraints:** C/NX ≥ 4, C/NY ≥ 4, NY divisible by 6
- **Restart Files:** Available at /input/GEOSCHEM_RESTARTS/GC_14.7.0/
- **Met Fields:** GEOS-FP 2019 at /input/GEOS_0.25x0.3125/GEOS_FP/
- **Output Storage:** /scratch (12 GB free, can expand if needed)
- **Data Preservation:** Save timing logs and key outputs to S3

## Next Actions

1. Create first Transport Tracers run directory (C24)
2. Submit 7-day benchmark job
3. Validate output and timing
4. Scale to larger configurations
5. Repeat for Full Chemistry

---

**Status:** Ready to begin Phase 1 (Transport Tracers)
