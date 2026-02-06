# 4-Node Testing Alternatives

**Date:** February 3, 2026
**Goal:** Successfully test GCHP 4-node (192 cores) scaling
**Blocker:** InsufficientInstanceCapacity for 4× hpc7a.24xlarge in us-east-2

## Current Status

✅ **Working Configurations:**
- 1-node (48 cores, C24): Job 15, 14s runtime
- 2-node (96 cores, C48): Job 24, 63s runtime

❌ **Blocked:**
- 4-node (192 cores, C90): Job 25 - AWS capacity constraint

## Alternative Approaches

### Option 1: Try Spot Instances (RECOMMENDED - Quick Win)

**Rationale:**
- Spot instances use a different capacity pool
- Often have better availability than on-demand
- 60-70% cost savings
- Acceptable for research/testing workloads

**Requirements:**
- Update ParallelCluster configuration to enable spot for compute nodes
- Add spot interruption handling (optional for short tests)

**Steps:**
1. Check current cluster configuration
2. Update cluster with spot instance support
3. Resubmit 4-node test with spot instances

**Risk:** Spot interruption during test (low for short runs)

### Option 2: Try c7a.48xlarge Instances

**Rationale:**
- c7a.48xlarge (96 vCPUs, 192GB RAM) more widely available
- Similar AMD EPYC architecture (Genoa 7R13 vs 9R14)
- 2× c7a.48xlarge = 96 cores (equivalent to 2× hpc7a.24xlarge)
- 4× c7a.48xlarge = 192 cores (our 4-node target)
- Better capacity availability according to AWS patterns

**Configuration:**
- 4× c7a.48xlarge = 384 vCPUs = 192 physical cores
- Each instance: 48 physical cores (96 vCPUs with SMT)
- Same C90 resolution configuration

**Steps:**
1. Update cluster configuration to use c7a.48xlarge
2. Disable hyperthreading or configure for 48 tasks per node
3. Resubmit 4-node test

**Cost:** $3.06/hour per instance vs $2.89/hour for hpc7a.24xlarge

### Option 3: Deploy Test Cluster in us-west-2

**Rationale:**
- us-west-2 typically has better HPC instance capacity
- Aligns with benchmarking project (CLAUDE.md specifies us-west-2)
- Can keep current cluster running

**Requirements:**
- ParallelCluster configuration for us-west-2
- Network resources (VPC, subnet, security group) in us-west-2
- S3 bucket access from us-west-2

**Steps:**
1. Create us-west-2 ParallelCluster configuration
2. Deploy test cluster
3. Copy working GCHP configuration
4. Submit 4-node test

**Timeline:** 10-15 minutes for cluster creation

### Option 4: Mixed Instance Type Fleet

**Rationale:**
- Use available capacity across multiple instance types
- AWS allows mixed instance types in same compute queue
- 2× hpc7a.24xlarge + 2× c7a.48xlarge = 192 cores

**Complexity:** Medium (requires careful configuration)

## Recommended Path Forward

### Phase 1: Immediate (5 minutes)
**Try spot instances with existing cluster configuration**

1. Check if cluster already supports spot instances
2. If not, update cluster configuration to add spot compute queue
3. Submit 4-node test to spot queue

**Advantages:**
- Fastest to implement
- 60-70% cost savings
- Different capacity pool

### Phase 2: If Spot Fails (15 minutes)
**Try c7a.48xlarge instances**

1. Update cluster configuration to add c7a queue
2. Configure for 48 cores per node
3. Submit 4-node test

**Advantages:**
- Better availability
- Similar architecture to hpc7a
- Still in us-east-2

### Phase 3: If Both Fail (30 minutes)
**Deploy test cluster in us-west-2**

1. Use us-west-2 configuration (aligns with CLAUDE.md)
2. Fresh cluster with better capacity region
3. Submit 4-node test

**Advantages:**
- Best HPC capacity
- Aligns with benchmarking project location
- Can test multiple instance types

## Configuration Updates Needed

### For Spot Instances (Option 1)
```yaml
# Add to ParallelCluster configuration
Scheduling:
  SlurmQueues:
    - Name: spot-compute
      CapacityType: SPOT
      ComputeResources:
        - Name: hpc7a-spot
          InstanceType: hpc7a.24xlarge
          MinCount: 0
          MaxCount: 8
      Networking:
        SubnetIds:
          - subnet-0a73ca94ed00cdaf9
        PlacementGroup:
          Enabled: true
```

### For c7a Instances (Option 2)
```yaml
# Add to ParallelCluster configuration
Scheduling:
  SlurmQueues:
    - Name: c7a-compute
      ComputeResources:
        - Name: c7a-nodes
          InstanceType: c7a.48xlarge
          MinCount: 0
          MaxCount: 8
          DisableSimultaneousMultithreading: true
      Networking:
        SubnetIds:
          - subnet-0a73ca94ed00cdaf9
        PlacementGroup:
          Enabled: true
```

### SLURM Job Script Updates

For c7a.48xlarge (if using SMT):
```bash
#SBATCH --nodes=4
#SBATCH --ntasks=192
#SBATCH --ntasks-per-node=48
#SBATCH --cpus-per-task=2  # Use 2 vCPUs per task (SMT)
```

Or disable SMT in cluster config and use:
```bash
#SBATCH --nodes=4
#SBATCH --ntasks=192
#SBATCH --ntasks-per-node=48
```

## Success Criteria

- Job 25 (or equivalent) completes successfully
- Runtime: ~120-180s (estimated for C90)
- Exit code: 0
- Output files created in OutputDir/
- Restart checkpoint created
- EFA multi-node communication validated

## Validation Steps

After successful 4-node run:

1. **Check output files:**
   ```bash
   ls -lh /fsx/gchp-tt-4node/OutputDir/
   ```

2. **Verify all nodes participated:**
   ```bash
   grep "SHMEM" gchp.*.log
   # Should show: "192 PEs on 4 nodes"
   ```

3. **Check for errors:**
   ```bash
   grep -i "error\|fatal\|fail" gchp.*.log
   ```

4. **Compare scaling:**
   - 1-node (48 cores, C24): 14s
   - 2-node (96 cores, C48): 63s
   - 4-node (192 cores, C90): TBD

Expected: ~120-180s (4× grid points, 2× cores relative to 2-node)

## Next Steps After 4-Node Success

1. Document working 4-node configuration
2. Update gchp-multinode-scaling-complete.md with 4-node results
3. Test 8-node if capacity allows
4. Begin instance type performance comparison
5. Test C180 resolution for production workloads

## Files and Locations

- **Current working config:** `/fsx/gchp-tt-4node/` (C90, 192 cores)
- **Cluster:** gchp-test (us-east-2)
- **Software stack:** `/fsx/sw-gcc14/gchp-gcc14-env.sh`
- **Documentation:** `/Users/scttfrdmn/src/aws-gchp/docs/`

## Cost Analysis

### On-Demand (per hour)
- hpc7a.24xlarge: 4 × $2.89 = $11.56/hour
- c7a.48xlarge: 4 × $3.06 = $12.24/hour (6% premium)

### Spot (60-70% savings)
- hpc7a.24xlarge spot: 4 × ~$1.15 = ~$4.60/hour
- c7a.48xlarge spot: 4 × ~$1.22 = ~$4.88/hour

**Recommendation:** Use spot for testing, on-demand for production runs

## Timeline Estimate

- **Option 1 (Spot):** 5-10 minutes to update cluster + 5 minutes for test = **15 minutes**
- **Option 2 (c7a):** 10-15 minutes to update cluster + 5 minutes for test = **20 minutes**
- **Option 3 (us-west-2):** 20-30 minutes to create cluster + 5 minutes for test = **35 minutes**

## Decision

Starting with **Option 1 (Spot Instances)** as it's the quickest path to success with minimal infrastructure changes.
