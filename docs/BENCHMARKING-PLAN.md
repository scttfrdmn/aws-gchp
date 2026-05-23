# GCHP Benchmarking Plan for AWS

## Overview

Systematic benchmarking plan to validate the GCC 12.3 + GCHP 14.7.1 software stack and compare performance across AWS instance types.

## Objectives

1. **Validate new stack** - Confirm GCC 12.3 + GCHP 14.7.1 performs as expected
2. **Compare with baseline** - Measure against previous GCC 14.2 + GCHP 14.5.0 results
3. **Optimize configurations** - Identify best instance types for cost/performance
4. **Document methodology** - Reproducible benchmarks for future stacks

---

## Phase 1: Single-Node Validation (Week 1)

### Goal
Establish baseline performance for new stack on single node.

### Configuration

**Instance Type:** c7a.48xlarge (96 vCPUs, AMD Zen 4)
- Why: Same architecture as build host, good baseline
- Cost: ~$4.85/hour

**GCHP Configuration:**
- **Resolution:** C24 (low enough to run quickly)
- **Duration:** 1 hour simulation
- **Chemistry:** TransportTracers (lightweight, fast)
- **Cores:** 48 (half of c7a.48xlarge)
- **Layout:** NX=8, NY=6 (48 cores, satisfies constraints)

### Metrics to Collect

```bash
# Timing
- Total runtime
- Initialization time
- Time per timestep
- I/O time

# Resource usage
- CPU utilization (via srun/SLURM stats)
- Memory usage (peak RSS)
- Network I/O (ENA stats if applicable)

# GCHP-specific
- Timestep performance (from GCHP.log)
- Load balance metrics
```

### Test Procedure

```bash
# 1. Create test cluster
AWS_PROFILE=aws ~/.local/bin/pcluster create-cluster \
  --cluster-name gchp-benchmark-c7a \
  --cluster-configuration configs/benchmark-c7a-single.yaml \
  --region us-east-1

# 2. SSH to cluster
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<head-node-ip>

# 3. Load environment
source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh

# 4. Create run directory
cd /scratch
cp -r /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-14.7.1/run/GCHP gchp-c24-1node
cd gchp-c24-1node

# 5. Configure
# Edit setCommonRunSettings.sh:
#   CS_RES=24
#   TOTAL_CORES=48
#   NUM_NODES=1
#   NUM_CORES_PER_NODE=48

# Edit HISTORY.rc for desired outputs

# 6. Create run script
./createRunDir.sh

# 7. Submit job
sbatch run.sh

# 8. Monitor
squeue
tail -f gchp.log

# 9. Collect results
./collect-benchmark-results.sh
```

### Success Criteria

- ✅ Simulation completes without errors
- ✅ Runtime comparable to previous stack (±10%)
- ✅ No MPI errors or warnings
- ✅ Output files generated correctly

---

## Phase 2: Multi-Node Scaling Test (Week 2)

### Goal
Validate EFA networking and multi-node scaling with new stack.

### Configurations to Test

| Test | Nodes | Cores | Resolution | NX×NY | Purpose |
|------|-------|-------|-----------|-------|---------|
| 2a | 2 | 96 | C48 | 12×8 | 2-node baseline |
| 2b | 4 | 192 | C90 | 16×12 | 4-node scaling |
| 2c | 8 | 384 | C128 | 16×24 | 8-node scaling (stretch goal) |

**Instance Type:** hpc7a.24xlarge (48 cores/node, EFA)
- Cost: ~$2.89/hour/node

### Grid Resolution Constraints

Validated formula:
```
X / NX >= 4  (X-direction constraint)
X / NY >= 4  (Y-direction constraint)
NY divisible by 6 (cubed-sphere requirement)
```

### Test Procedure (Per Configuration)

```bash
# 1. Calculate domain decomposition
# For C90 on 192 cores (4 nodes):
#   X = 90
#   Target: ~192 cores
#   Try: NX=16, NY=12 → 16×12 = 192 ✅
#   Check: 90/16 = 5.625 ≥ 4 ✅
#   Check: 90/12 = 7.5 ≥ 4 ✅
#   Check: 12 % 6 = 0 ✅

# 2. Configure run directory
cd /scratch/gchp-c90-4node
# Edit setCommonRunSettings.sh

# 3. Submit job
sbatch run-4node.sh

# 4. Monitor EFA utilization
# On head node:
watch -n 5 'squeue; ibstat'

# 5. Collect metrics
```

### Metrics to Compare

1. **Scaling Efficiency**
   ```
   Efficiency = (T_baseline / N) / T_N
   
   Where:
   T_baseline = runtime on baseline cores
   N = scaling factor
   T_N = runtime on N× cores
   ```

2. **Cost Efficiency**
   ```
   Cost per simulation = (hourly_rate × nodes × runtime_hours)
   ```

3. **Throughput**
   ```
   Simulated days per wall-clock hour
   ```

### Success Criteria

- ✅ Scaling efficiency > 90% (2→4 nodes)
- ✅ No EFA errors in logs
- ✅ MPI shows "mtl:ofi" transport in use
- ✅ Comparable to previous 95% efficiency

---

## Phase 3: Instance Type Comparison (Week 3)

### Goal
Identify optimal instance types for different use cases.

### Instance Types to Test

| Instance | vCPUs | Memory | Network | Arch | Cost/hr | Use Case |
|----------|-------|--------|---------|------|---------|----------|
| **c7a.48xlarge** | 96 | 384 GB | ENA | Zen 4 | ~$4.85 | Single-node |
| **hpc7a.24xlarge** | 48 | 768 GB | EFA | Zen 4 | ~$2.89 | Multi-node |
| **c6a.48xlarge** | 192 | 384 GB | ENA | Zen 3 | ~$4.13 | Cost compare |
| **hpc6a.48xlarge** | 96 | 384 GB | EFA | Zen 3 | ~$2.88 | Zen 3 compare |

### Test Matrix

**Single-Node Tests (C24, 48 cores):**
- c7a.48xlarge (Zen 4)
- c6a.48xlarge (Zen 3)
- Compare: Runtime, cost, memory usage

**Multi-Node Tests (C90, 4 nodes):**
- hpc7a.24xlarge (Zen 4 + EFA)
- hpc6a.48xlarge (Zen 3 + EFA)
- Compare: Scaling, EFA utilization, cost/performance

### Expected Results

**Hypothesis:**
- Zen 4 (c7a, hpc7a): Slightly faster due to newer arch
- Zen 3 (c6a, hpc6a): Competitive, potentially better cost/performance
- EFA instances: Much better multi-node scaling
- Non-EFA: Limited to 2-4 nodes

### Data Collection

Create standardized output format:

```yaml
benchmark:
  date: 2026-05-24
  git_tag: gchp-14.7.1-gcc12.3
  
  software:
    gchp: 14.7.1
    gcc: 12.3.0
    openmpi: 4.1.7
    optimizations: -O3 -march=znver3 -mtune=znver3
  
  instance:
    type: hpc7a.24xlarge
    vcpus: 48
    memory_gb: 768
    network: EFA
    architecture: AMD Zen 4
    
  simulation:
    resolution: C90
    duration_hours: 1
    chemistry: TransportTracers
    
  configuration:
    nodes: 4
    cores_total: 192
    cores_per_node: 48
    nx: 16
    ny: 12
    
  results:
    runtime_seconds: 116
    init_seconds: 8
    timestep_avg_seconds: 0.45
    memory_peak_gb: 120
    cost_dollars: 1.34
    
  comparison:
    baseline_runtime: 116
    scaling_efficiency: 0.95
    speedup: 3.8
```

---

## Phase 4: Resolution Scaling (Week 4)

### Goal
Test higher resolutions to validate production readiness.

### Configurations

| Resolution | Grid Size | Nodes | Cores | NX×NY | Est. Runtime |
|-----------|-----------|-------|-------|-------|--------------|
| C180 | 180×180 | 8 | 384 | 24×16 | ~8 hours |
| C180 | 180×180 | 16 | 768 | 32×24 | ~4 hours |
| C360 | 360×360 | 32 | 1536 | 48×32 | ~8 hours |

**Note:** Higher resolutions = longer runtimes = expensive. Start conservative.

### Test Strategy

1. **C180 on 8 nodes first**
   - Validates grid constraints at production scale
   - Reasonable cost (~$23/hour for 8× hpc7a.24xlarge)
   - 8-hour run = ~$184

2. **If successful, try 16 nodes**
   - Should be ~2× faster
   - Tests scaling beyond 4 nodes
   - 4-hour run = ~$184

3. **C360 only if needed**
   - Very expensive (32 nodes minimum)
   - ~$92/hour × 8 hours = $736
   - Reserve for final validation

---

## Phase 5: Long-Duration Stability Test (Week 5)

### Goal
Validate stack stability for production simulations.

### Configuration

**Test:** 7-day simulation (168 hours simulated time)
- **Resolution:** C90 (manageable size)
- **Nodes:** 4× hpc7a.24xlarge
- **Duration:** ~20 hours wall time (estimate)
- **Cost:** ~$231

### Metrics

- **Stability:** No crashes, hangs, or errors
- **Memory:** No leaks over time
- **I/O:** Restart files write correctly
- **Checkpoint:** Can resume from restart

### Success Criteria

- ✅ Simulation completes all 7 days
- ✅ All restart files valid
- ✅ Memory usage stable (no leaks)
- ✅ No MPI or EFA errors
- ✅ Output files pass scientific validation

---

## Benchmark Execution Checklist

### Before Each Benchmark

- [ ] Cluster config reviewed and correct
- [ ] Software stack path verified
- [ ] Run directory created fresh
- [ ] Domain decomposition calculated and validated
- [ ] Monitoring script prepared
- [ ] Cost estimate calculated

### During Benchmark

- [ ] Job submitted successfully
- [ ] Monitor SLURM queue status
- [ ] Check logs for errors every 30 minutes
- [ ] Monitor cluster costs in AWS console
- [ ] Save intermediate results

### After Benchmark

- [ ] Collect all metrics
- [ ] Save output files to S3
- [ ] Document any anomalies
- [ ] Update benchmark database
- [ ] Delete cluster to stop charges

---

## Tools and Scripts

### 1. Benchmark Runner Script

```bash
#!/bin/bash
# benchmark-runner.sh - Automated benchmark execution

RESOLUTION=$1
NODES=$2
INSTANCE=$3

# Validate inputs
# Calculate NX, NY
# Create run directory
# Configure GCHP
# Submit job
# Monitor
# Collect results
# Save to S3
```

### 2. Results Collector

```bash
#!/bin/bash
# collect-benchmark-results.sh

# Extract from GCHP.log:
#   - Total runtime
#   - Timestep performance
#   - Memory usage

# Extract from SLURM:
#   - CPU utilization
#   - Job efficiency

# Generate summary YAML
```

### 3. Comparison Tool

```bash
#!/bin/bash
# compare-benchmarks.sh baseline.yaml test.yaml

# Calculate:
#   - Speedup
#   - Scaling efficiency
#   - Cost difference
#   - Throughput comparison

# Generate report
```

---

## Budget Planning

### Conservative Estimate (5 weeks)

| Phase | Activity | Est. Cost |
|-------|----------|-----------|
| 1 | Single-node (10 runs × 1hr @ $5/hr) | $50 |
| 2 | Multi-node (6 runs × 2hr × 4 nodes @ $3/hr/node) | $144 |
| 3 | Instance comparison (12 runs × 2hr × avg $15/hr) | $360 |
| 4 | High-res (3 runs × 6hr × 8 nodes @ $3/hr/node) | $432 |
| 5 | Long-duration (1 run × 20hr × 4 nodes @ $3/hr/node) | $240 |
| | **Total** | **~$1,226** |

### Aggressive Estimate

If tests run long or require debugging: **~$2,000**

### Cost Optimization

- Use Spot instances where possible (50-70% savings)
- Delete clusters immediately after tests
- Shorter test simulations when possible
- Share results across tests (don't repeat)

---

## Comparison with Previous Stack

### Baseline Data (February 2026)

**GCC 14.2 + GCHP 14.5.0 + Zen 4 optimizations:**

| Config | Nodes | Cores | Resolution | Runtime | Efficiency |
|--------|-------|-------|-----------|---------|------------|
| A | 1 | 48 | C24 | 14s | - |
| B | 2 | 96 | C48 | 63s | 44% |
| C | 4 | 192 | C90 | 116s | 95% |

**Goal:** Match or exceed these results with new stack.

### Direct Comparison Tests

**Must-Do:**
1. Recreate exact same tests with new stack
2. Same instance types (hpc7a.24xlarge)
3. Same resolutions (C24, C48, C90)
4. Same simulation length (1 hour)
5. Compare runtimes directly

**Expected Outcome:**
- Within 5% of baseline (GCC version shouldn't matter much)
- If faster: Bonus! (newer libraries might help)
- If slower: Investigate (bad optimization flags?)

---

## Documentation Requirements

### For Each Benchmark

Create markdown file: `results/benchmark-YYYY-MM-DD-{config}.md`

**Required sections:**
1. Configuration (instance, resolution, nodes, etc.)
2. Software stack details
3. Raw results (runtime, metrics)
4. Analysis (efficiency, comparisons)
5. Anomalies or notes
6. Cost breakdown

### Final Report

`docs/BENCHMARK-RESULTS-GCC12.3-GCHP14.7.1.md`

**Sections:**
1. Executive summary
2. Methodology
3. Results by phase
4. Comparison with baseline
5. Recommendations
6. Cost analysis

---

## Next Steps

1. **Create cluster configs** for each benchmark scenario
2. **Write automation scripts** (runner, collector, comparator)
3. **Set budget alert** in AWS (stop at $500, $1000, $1500)
4. **Start with Phase 1** - single-node validation
5. **Document as you go** - don't batch documentation

## Success Metrics

**Project Success:**
- ✅ New stack validated across single and multi-node
- ✅ Performance within 5% of baseline
- ✅ No regressions identified
- ✅ Cost/performance analysis complete
- ✅ Recommendations documented

**Bonus Goals:**
- 📊 Performance improvements identified
- 💰 More cost-effective configurations found
- 📈 Scaling beyond 4 nodes validated
- 🎯 Production-ready for C180+ resolutions
