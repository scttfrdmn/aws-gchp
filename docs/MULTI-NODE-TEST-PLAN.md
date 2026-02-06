# Multi-Node Testing Plan (4 Nodes)

**Date:** January 28, 2026
**Configuration:** 4 × hpc7a.24xlarge (192 total cores)
**Purpose:** Validate EFA, MPI scaling, and inter-node communication

---

## Why 4 Nodes for Testing?

### Practical Validation
- **Sufficient scale** to validate multi-node behavior
- **More cost-effective** than testing with 10 nodes initially
- **Faster to provision** (4 nodes vs 10 nodes)
- **Easier to debug** if issues arise

### Technical Coverage
- **Tests EFA** across multiple nodes
- **Validates PlacementGroup** configuration
- **Measures inter-node communication** overhead
- **Establishes scaling baseline** (1 node → 4 nodes)

### Cost-Effective
- **4 nodes:** ~$1.13/hour (Spot)
- **10 nodes:** ~$2.83/hour (Spot)
- **Testing duration:** 30-60 minutes
- **Total cost:** ~$0.57-1.13 (vs ~$1.42-2.83 for 10 nodes)

---

## Test Configuration

### Cluster Setup
```yaml
InstanceType: hpc7a.24xlarge
- vCPUs: 48
- Cores: 48 (SMT disabled)
- Memory: 192 GB
- EFA: 300 Gbps

MaxCount: 4 nodes
Total Resources:
- Cores: 192
- Memory: 768 GB
- Total EFA bandwidth: 1200 Gbps
```

### SLURM Configuration
```bash
# Request all 4 nodes
srun -N 4 -n 192 --mpi=pmi2 ./gchp

# Domain decomposition for 192 cores (C24)
# Options: 12x16, 16x12, 8x24, 24x8
# Optimal likely: 12x16 or 16x12
```

---

## Test Scenarios

### Scenario 1: Single-Node Baseline
**Purpose:** Establish baseline performance

```bash
# Run on 1 node, 48 cores
srun -N 1 -n 48 --mpi=pmi2 ./gchp
```

**Expected Runtime (C24):**
- Based on c8a benchmarks, 48 cores: ~85 seconds
- hpc7a may be ~75-80 seconds (better memory bandwidth)

### Scenario 2: 2-Node Scaling
**Purpose:** Validate basic multi-node functionality

```bash
# Run on 2 nodes, 96 cores total
srun -N 2 -n 96 --mpi=pmi2 ./gchp
```

**Expected Runtime (C24):**
- Single-node 96 cores (hpc7a.48xlarge): ~60-65 seconds (estimate)
- Multi-node 2×48: ~65-75 seconds (some communication overhead)
- **Goal:** Scaling efficiency > 85%

### Scenario 3: 4-Node Scaling
**Purpose:** Test full 4-node configuration

```bash
# Run on 4 nodes, 192 cores total
srun -N 4 -n 192 --mpi=pmi2 ./gchp
```

**Expected Runtime (C24):**
- Based on c8a benchmarks, 180 cores had significant degradation
- But: EFA may help significantly vs standard networking
- **Goal:** Determine if 192 cores with EFA outperforms single-node 96 cores
- **Hypothesis:** EFA keeps scaling efficient up to 4 nodes

### Scenario 4: EFA vs No-EFA Comparison
**Purpose:** Quantify EFA benefit

```bash
# Run with EFA disabled (if possible via env var)
# Compare runtime with EFA enabled

# Expected: 10-30% improvement with EFA on multi-node
```

---

## Success Criteria

### Must Pass ✅
1. **All 4 nodes launch successfully** in PlacementGroup
2. **MPI ranks distribute correctly** across nodes
3. **EFA interfaces detected** on all nodes (`fi_info -p efa`)
4. **Simulation completes** without MPI errors
5. **Results are correct** (bit-for-bit comparison with single-node)

### Performance Targets 🎯
1. **2-node scaling efficiency** > 85% (vs 1-node baseline)
2. **4-node scaling efficiency** > 70% (vs 1-node baseline)
3. **EFA benefit** > 10% (vs TCP fallback)
4. **No significant memory issues** (GCHP fits in 192 GB per node)

### Bonus Insights 📊
1. **Optimal domain decomposition** for 192 cores
2. **Communication patterns** (GCHP component timings)
3. **Spot interruption** handling (if we get lucky/unlucky)
4. **Cost per simulation** comparison (4-node vs single-node)

---

## Testing Commands

### Step 1: Deploy Cluster

```bash
AWS_PROFILE=aws AWS_REGION=us-east-1 uv run pcluster create-cluster \
  --cluster-name gchp-test-multinode \
  --cluster-configuration parallelcluster/configs/gchp-test-multinode.yaml \
  --region us-east-1

# Monitor creation
watch -n 30 'AWS_PROFILE=aws AWS_REGION=us-east-1 uv run pcluster describe-cluster \
  --cluster-name gchp-test-multinode --region us-east-1 \
  --query clusterStatus'
```

### Step 2: SSH and Validate Environment

```bash
# Get head node IP
HEAD_NODE=$(AWS_PROFILE=aws AWS_REGION=us-east-1 uv run pcluster describe-cluster \
  --cluster-name gchp-test-multinode --region us-east-1 \
  --query headNode.publicIpAddress --output text)

# SSH to cluster
ssh -i ~/.ssh/aws-benchmark.pem ec2-user@$HEAD_NODE

# On head node:
sinfo                          # Check SLURM state
sinfo -N -l                    # Check node details
scontrol show partition        # Check queue config

# Allocate 4 compute nodes
salloc -N 4 -p multinode-test

# In the allocation:
srun -N 4 hostname             # Test basic MPI
srun -N 4 fi_info -p efa       # Verify EFA on all nodes
```

### Step 3: Run Test Suite

```bash
# Ensure we're in GCHP run directory
cd /fsx/scratch/rundirs/c24-test

# Test 1: Single node baseline (48 cores)
srun -N 1 -n 48 --mpi=pmi2 \
  --cpu-bind=cores --export=ALL \
  ./gchp | tee run-1node-48cores.log

# Test 2: Two nodes (96 cores)
srun -N 2 -n 96 --mpi=pmi2 \
  --cpu-bind=cores --export=ALL \
  ./gchp | tee run-2node-96cores.log

# Test 3: Four nodes (192 cores)
srun -N 4 -n 192 --mpi=pmi2 \
  --cpu-bind=cores --export=ALL \
  ./gchp | tee run-4node-192cores.log

# Extract timings
for log in run-*.log; do
  echo "=== $log ==="
  grep "All" $log | tail -1
done
```

### Step 4: Analyze Results

```bash
# Compare GCHP component timings
for log in run-*.log; do
  echo "=== $log ==="
  grep -E "(DYNAMICS|GCHPchem|EXTDATA|HIST)" $log
done

# Check for MPI communication time
# Look for imbalance between components

# Download logs for detailed analysis
scp -i ~/.ssh/aws-benchmark.pem \
  ec2-user@$HEAD_NODE:/fsx/scratch/rundirs/c24-test/run-*.log \
  ./multinode-test-results/
```

### Step 5: Cleanup

```bash
# Exit cluster
exit

# Delete cluster
AWS_PROFILE=aws AWS_REGION=us-east-1 uv run pcluster delete-cluster \
  --cluster-name gchp-test-multinode \
  --region us-east-1
```

---

## What We'll Learn

### 1. EFA Performance on hpc7a
- Does 300 Gbps EFA translate to low communication overhead?
- How does it compare to c8a with standard networking?

### 2. Multi-Node Scaling for C24
- Is 4-node (192 cores) faster than 1-node (96 cores)?
- Or do we hit communication limits even with EFA?
- What's the optimal node count for C24?

### 3. Domain Decomposition Impact
- Does NX×NY choice matter more on multi-node?
- Are some decompositions more EFA-friendly?

### 4. Production Readiness
- Can we confidently recommend 4-10 nodes for larger resolutions?
- What's the cost-performance sweet spot?

### 5. Validation for GCHP Team Recommendation
- Confirm why GCHP team prefers hpc7a
- Document best practices for community

---

## Expected Timeline

```
0:00 - Deploy cluster (8-10 minutes)
0:10 - Allocate nodes and validate environment (5 minutes)
0:15 - Run single-node baseline (5 minutes)
0:20 - Run 2-node test (5 minutes)
0:25 - Run 4-node test (5 minutes)
0:30 - Analyze results (10 minutes)
0:40 - Cleanup and document findings (5 minutes)
0:45 - Delete cluster

Total: 45 minutes active testing
Cost: ~$0.85 (0.75 hours × $1.13/hour)
```

---

## Troubleshooting

### Issue: Only 3 nodes available (Spot capacity)
**Solution:**
- Run tests with available nodes (better than nothing!)
- Or switch to ON-DEMAND temporarily

### Issue: EFA not detected
**Check:**
```bash
# On compute nodes
fi_info -p efa
lspci | grep EFA

# Verify PlacementGroup
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:ClusterName,Values=gchp-test-multinode" \
  --query 'Reservations[].Instances[].[InstanceId,Placement.GroupName]'
```

### Issue: MPI hangs on multi-node
**Debug:**
```bash
# Check network connectivity between nodes
srun -N 4 ping -c 3 <other-node-ip>

# Verify PMI2 plugin
srun -N 4 ls -la /opt/slurm/lib/slurm/mpi_pmi2.so

# Check for firewall issues (should be handled by ParallelCluster)
```

### Issue: Poor scaling performance
**Analyze:**
- Check GCHP component timings - which component is slow?
- If DYNAMICS or GCHPchem: likely computation-bound (good)
- If EXTDATA or HIST: likely I/O-bound (check FSx performance)
- If imbalanced: likely communication-bound (check domain decomp)

---

## Next Steps After Testing

### If Scaling is Good (>70% efficiency)
✅ Proceed with production cluster deployment
✅ Test larger resolutions (C48, C90)
✅ Run 3-4 day campaign on 4-10 nodes
✅ Document findings for GCHP community

### If Scaling is Poor (<70% efficiency)
⚠️ Investigate bottleneck (I/O, communication, domain decomp)
⚠️ Try different domain decompositions
⚠️ Consider sticking with single-node hpc7a.48xlarge for C24
⚠️ Use multi-node only for larger resolutions that don't fit in 384 GB

### Either Way
📊 **Document results** - helps GCHP community
📧 **Share with GCHP team** - validate their hpc7a recommendation
📝 **Update benchmarking guide** - include multi-node findings
🎯 **Optimize configurations** based on learnings

---

**Ready to validate hpc7a multi-node performance!** 🚀
