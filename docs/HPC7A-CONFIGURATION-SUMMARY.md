# HPC7a Instance Configuration Summary

**Date:** January 28, 2026
**Purpose:** Document migration to hpc7a instances based on GCHP team recommendations and benchmark data

---

## Why HPC7a?

**Recommendation from GCHP Team:**
- GCHP team specifically likes hpc7a instances
- Optimized for HPC workloads with high memory bandwidth
- 4:1 memory-to-core ratio (4 GB/core) ideal for atmospheric chemistry

**Benchmark Data Alignment:**
- Our C24 benchmarks showed 96 cores as the sweet spot (c8a.24xlarge)
- hpc7a.48xlarge provides exactly 96 cores
- Beyond 96 cores, single-node scaling degraded significantly

**Use Case Requirements:**
- Single-node: C24 resolution runs (optimal at 96 cores)
- Multi-node: Larger resolutions, 3-4 day campaigns (up to 10 nodes)

---

## HPC7a Instance Specifications

### Available Sizes

| Instance Type | vCPUs | Cores | Memory | EFA | Use Case |
|--------------|-------|-------|---------|-----|----------|
| hpc7a.12xlarge | 24 | 24 | 96 GB | ❌ | Quick tests |
| hpc7a.24xlarge | 48 | 48 | 192 GB | ✅ | Development, small runs |
| hpc7a.48xlarge | 96 | 96 | 384 GB | ✅ | **Optimal for C24** |
| hpc7a.96xlarge | 192 | 192 | 768 GB | ✅ | Large resolutions, multi-node |

**Key Features:**
- **Processor:** AMD EPYC 9R14 (4th Gen, Zen 4 architecture - same as c7a)
- **Memory:** DDR5, 4 GB per core
- **Network:** 300 Gbps EFA bandwidth
- **Optimization:** HPC-optimized with high memory bandwidth
- **Region:** us-east-1 (Ohio), eu-west-1 (Ireland), GovCloud

---

## Updated Cluster Configurations

### Production Cluster (`gchp-production.yaml`)

**Region:** us-east-1 (changed from us-west-2)

**Queues:**

1. **hpc-single** (single-node optimal)
   - Instance: hpc7a.48xlarge (96 cores, 384 GB)
   - MaxCount: 5
   - EFA: Enabled
   - Use: C24 resolution, production runs

2. **hpc-multi** (multi-node scaling)
   - Instance: hpc7a.96xlarge (192 cores, 768 GB)
   - MaxCount: 10 nodes (1920 total cores)
   - EFA: Enabled, PlacementGroup: Required
   - Use: Larger resolutions, 3-4 day campaigns

3. **hpc-dev** (development/testing)
   - Instance: hpc7a.24xlarge (48 cores, 192 GB)
   - MaxCount: 2
   - EFA: Disabled
   - Use: Quick validation, development

**All queues:**
- CapacityType: SPOT (70% cost savings)
- AllocationStrategy: capacity-optimized (for stability)
- DisableSimultaneousMultithreading: true (physical cores only)

### Test Cluster - Minimal (`gchp-test-minimal.yaml`)

**Region:** us-east-1

**Queue:**
- Instance: hpc7a.12xlarge (24 cores, 96 GB)
- Purpose: Validate automation toolkit
- Cost: ~$0.50-1.00/hour
- Duration: 30 minutes end-to-end

### Test Cluster - Multi-Node (`gchp-test-multinode.yaml`)

**Region:** us-east-1

**Queue:**
- Instance: hpc7a.24xlarge (48 cores, 192 GB)
- MaxCount: 2 nodes (96 total cores)
- EFA: Enabled
- Purpose: Validate multi-node MPI, EFA performance
- Cost: ~$1.00-2.00/hour
- Duration: 20 minutes validation

---

## Benchmark Scaling Insights Applied

### Single-Node Scaling (from c8a benchmarks)

Our AMD benchmarks revealed:
- **8-48 cores:** Near-linear scaling
- **56-96 cores:** Sweet spot region (best performance)
- **108-144 cores:** Scaling efficiency degrades
- **150-180 cores:** Performance actively worsens (communication overhead dominates)

**Decision:** Use hpc7a.48xlarge (96 cores) for single-node C24 workloads

### Multi-Node Considerations

For larger simulations requiring >96 cores:
- Use hpc7a.96xlarge (192 cores/node)
- Scale out to 2-10 nodes
- EFA critical for low-latency inter-node communication
- PlacementGroup required for optimal EFA performance

**User Requirement:** "They run up to 10 nodes for 3-4 days"
- 10 × hpc7a.96xlarge = 1920 cores
- Suitable for C90+ resolutions
- EFA ensures efficient multi-node scaling

---

## Cost Analysis

### Spot Pricing Estimates (us-east-1, January 2026)

| Instance | Cores | On-Demand | Spot (~70% off) | Use Case |
|----------|-------|-----------|-----------------|----------|
| hpc7a.12xlarge | 24 | ~$0.40/hr | ~$0.12/hr | Testing |
| hpc7a.24xlarge | 48 | ~$0.80/hr | ~$0.24/hr | Development |
| hpc7a.48xlarge | 96 | ~$1.60/hr | ~$0.48/hr | C24 production |
| hpc7a.96xlarge | 192 | ~$3.20/hr | ~$0.96/hr | Large runs |

**C24 1-hour simulation cost:**
- Runtime: ~5 minutes (based on benchmarks)
- Instance: hpc7a.48xlarge Spot
- Cost: ~$0.04 per simulation

**3-4 day campaign (10 nodes):**
- Instance: 10 × hpc7a.96xlarge Spot
- Hourly: ~$9.60/hour
- 4 days (96 hours): ~$922
- With interruptions/restarts: ~$1,000-1,200

---

## Migration from c8a to hpc7a

### Compiler Compatibility

**Good News:** hpc7a uses Zen 4 architecture (same as c7a)

Our GCC builds used:
- c7a: `-march=znver3` (Zen 3 compatible with Zen 4)
- c8a: `-march=znver4` (Zen 4 architecture)

**For hpc7a:**
- Use `-march=znver4` for optimal performance
- Or `-march=znver3` for compatibility (still excellent performance)

### Data Transfer

**No action needed** if using FSx:
- FSx volumes are region-specific
- Will need to create new persistent FSx volume in us-east-1
- One-time data sync from S3 (same as before)

### Subnet Configuration

**Action Required:**
- Current subnet: `subnet-0a73ca94ed00cdaf9` (us-west-2)
- Need: New subnet in us-east-1
- Use default VPC subnet or create custom VPC

---

## Deployment Plan

### Phase 1: Minimal Test (hpc7a.12xlarge)
1. Update subnet ID for us-east-1
2. Set owner tag: `./scripts/set-owner-tag.sh your.email@example.com`
3. Deploy test cluster: `AWS_PROFILE=aws uv run pcluster create-cluster --cluster-name gchp-test-minimal --cluster-configuration parallelcluster/configs/gchp-test-minimal.yaml --region us-east-1`
4. Validate: basic SLURM functionality, FSx mount, data access
5. Cost: ~$0.50-1.00
6. Duration: 30 minutes

### Phase 2: Multi-Node EFA Test (hpc7a.24xlarge × 4)
1. Deploy multi-node test cluster
2. Run 4-node MPI test with EFA (192 total cores)
3. Validate inter-node communication performance
4. Test scaling efficiency vs single-node
5. Cost: ~$0.57-1.13
6. Duration: 30-60 minutes

### Phase 3: Production Validation (hpc7a.48xlarge)
1. Deploy production cluster
2. Run C24 benchmark on 96 cores
3. Compare with c8a benchmark results
4. Validate checkpointing, Spot recovery
5. Cost: ~$5-10
6. Duration: 1 hour

### Phase 4: Long-Duration Test (Optional)
1. Run 24-48 hour simulation
2. Validate Spot interruption handling
3. Test multi-node scaling (2-4 nodes)
4. Cost: ~$50-100
5. Duration: 2-3 days

---

## Required Actions Before Deployment

### 1. Get us-east-1 Subnet ID

```bash
# List available subnets in us-east-1
AWS_PROFILE=aws aws ec2 describe-subnets \
  --region us-east-1 \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' \
  --output table

# Or use default VPC's subnet
AWS_PROFILE=aws aws ec2 describe-subnets \
  --region us-east-1 \
  --filters "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' \
  --output text
```

Update all config files with the correct subnet ID.

### 2. Set Owner Tag

```bash
./scripts/set-owner-tag.sh your.email@example.com
```

### 3. Verify AWS Resources in us-east-1

```bash
# Check for existing ParallelCluster resources
AWS_PROFILE=aws uv run pcluster list-clusters --region us-east-1

# Check for existing FSx volumes
AWS_PROFILE=aws aws fsx describe-file-systems --region us-east-1
```

---

## Performance Expectations

### Based on c8a → hpc7a Comparison

**c8a.24xlarge (Zen 5, 96 cores):**
- C24 runtime: 51.76 seconds
- Architecture: Latest Zen 5

**hpc7a.48xlarge (Zen 4, 96 cores):**
- Expected runtime: ~60-65 seconds (10-15% slower than Zen 5)
- But: HPC-optimized, higher memory bandwidth
- May partially compensate for architecture difference

**Why potentially better for GCHP:**
- 300 Gbps EFA (vs c8a standard networking)
- HPC-optimized interconnect
- Higher sustained memory bandwidth
- Better for memory-intensive atmospheric chemistry

**GCHP team prefers hpc7a** - suggests real-world performance may be very competitive despite slightly older CPU architecture.

---

## Sources

- [Amazon EC2 Hpc7a Instances – AWS](https://aws.amazon.com/ec2/instance-types/hpc7a/)
- [Specifications for Amazon EC2 high-performance computing instances](https://docs.aws.amazon.com/ec2/latest/instancetypes/hpc.html)
- [New – Amazon EC2 Hpc7a Instances (AWS Blog)](https://aws.amazon.com/blogs/aws/new-amazon-ec2-hpc7a-instances-powered-by-4th-gen-amd-epyc-processors-optimized-for-high-performance-computing/)

---

## Next Steps

1. **Get subnet ID** for us-east-1
2. **Update all configs** with correct subnet
3. **Set owner tag** in configs
4. **Deploy test cluster** (Phase 1)
5. **Validate and iterate**
6. **Share results** with GCHP team

---

**Let's validate that hpc7a is indeed optimal for GCHP on AWS!** 🚀
