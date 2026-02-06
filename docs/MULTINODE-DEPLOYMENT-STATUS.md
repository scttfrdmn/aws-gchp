# Multi-Node HPC7a Deployment Status

**Cluster:** gchp-test-multinode
**Started:** January 28, 2026 22:15 PST (06:15 UTC)
**Status:** CREATE_IN_PROGRESS (19+ minutes, still deploying)
**Region:** us-east-2 (Ohio)

**Current Progress:**
- ✅ CloudFormation stack created
- ✅ FSx Lustre volume created and AVAILABLE (fs-05847dbba61c020f3)
- ✅ Head node instance launched and running (i-0eaf6af34ee249fd0)
- 🔄 Head node initialization scripts still executing (WaitCondition pending)
- ⏱️ Taking longer than typical 10-15 minutes (possibly due to EFA/placement group setup)

---

## Cluster Specification

### Compute Resources
- **Instance Type:** hpc7a.24xlarge
- **Nodes:** 4 (dynamic, scale on demand)
- **Total Cores:** 192 (48 cores per node)
- **Total Memory:** 768 GB (192 GB per node)
- **Network:** EFA 300 Gbps per node
- **Placement:** Placement Group enabled (required for EFA)

### Head Node
- **Instance Type:** t3.medium
- **Access:** ElasticIP (to be associated after deployment)

### Storage
- **FSx Lustre:** 1200 GB SCRATCH_2
- **Mount:** /fsx
- **Compression:** LZ4

### Cost
- **Capacity Type:** ON-DEMAND (for testing)
- **Hourly Cost:** ~$3.20/hr (when all nodes running)
- **Test Duration:** 45 minutes
- **Estimated Cost:** ~$2.40

---

## Deployment Configuration

### Networking Setup (Multi-NIC/EFA)
✅ **Subnet auto-assign disabled** - Required for multi-NIC instances
```bash
# Executed:
aws ec2 modify-subnet-attribute \
  --subnet-id subnet-a7ef24cc \
  --no-map-public-ip-on-launch \
  --region us-east-2
```

### Post-Deployment Steps
1. Wait for cluster CREATE_COMPLETE (~10-15 minutes)
2. Associate ElasticIP to head node:
   ```bash
   ./scripts/associate-head-node-eip.sh gchp-test-multinode us-east-2
   ```
3. SSH to head node
4. Validate SLURM, FSx, EFA
5. Run multi-node MPI tests

---

## Comparison with Minimal Test Cluster

| Aspect | gchp-test-minimal | gchp-test-multinode |
|--------|------------------|---------------------|
| **Instance** | c7a.xlarge | hpc7a.24xlarge |
| **Cores** | 4 | 48 per node |
| **Nodes** | 1 | 4 (192 cores total) |
| **EFA** | No | Yes (300 Gbps) |
| **Networking** | Single-NIC (auto-IP) | Multi-NIC (ElasticIP) |
| **Purpose** | Toolkit validation | Multi-node MPI validation |
| **Status** | ✅ Complete | 🔄 Deploying |

---

## Expected Timeline

### Deployment Phase (10-15 minutes)
- ☐ CloudFormation stack creation
- ☐ Head node launch
- ☐ FSx Lustre volume creation
- ☐ SLURM configuration
- ☐ Health checks

### Post-Deployment (5 minutes)
- ☐ Associate ElasticIP
- ☐ SSH access verification
- ☐ SLURM validation
- ☐ FSx mount verification

### Testing Phase (30 minutes)
- ☐ Single-node baseline (48 cores)
- ☐ 2-node scaling test (96 cores)
- ☐ 4-node scaling test (192 cores)
- ☐ EFA performance validation
- ☐ MPI over EFA validation

**Total Time:** ~45-50 minutes

---

## Validation Tests

### Test 1: SLURM and FSx
```bash
# SSH to head node
ssh -i ~/.ssh/aws-benchmark.pem ec2-user@<public-ip>

# Check SLURM
sinfo

# Check FSx
df -h | grep fsx

# Check EFA device
fi_info -p efa
```

### Test 2: Single-Node Job (48 cores)
```bash
# Submit job to 1 node
srun -N1 --exclusive hostname

# Expected: 1 hpc7a.24xlarge node provisions
```

### Test 3: Multi-Node Job (96 cores, 2 nodes)
```bash
# Submit job to 2 nodes
srun -N2 --exclusive hostname

# Expected: 2 hpc7a.24xlarge nodes provision, MPI over EFA
```

### Test 4: Full Cluster (192 cores, 4 nodes)
```bash
# Submit job to 4 nodes
srun -N4 --exclusive hostname

# Expected: All 4 nodes provision
```

### Test 5: EFA Performance
```bash
# Load Intel MPI benchmarks (if available) or OSU benchmarks
module load osu-micro-benchmarks

# Run latency test over EFA
mpirun -n 2 -ppn 1 osu_latency

# Expected: <2 microsecond latency with EFA
```

---

## Key Differences from c7a.xlarge Test

### 1. Networking
- **c7a.xlarge:** Single NIC, subnet auto-assigns public IP
- **hpc7a.24xlarge:** Multiple NICs for EFA, ElasticIP required

### 2. Instance Type
- **c7a.xlarge:** General compute, 4 cores, no EFA
- **hpc7a.24xlarge:** HPC-optimized, 48 cores, 300 Gbps EFA

### 3. Scaling
- **c7a.xlarge:** Single node only (4 cores)
- **hpc7a.24xlarge:** Up to 4 nodes (192 cores)

### 4. Cost
- **c7a.xlarge:** ~$0.18/hr per node
- **hpc7a.24xlarge:** ~$0.80/hr per node

### 5. Purpose
- **c7a.xlarge:** Automation toolkit validation
- **hpc7a.24xlarge:** Multi-node MPI and EFA validation

---

## Success Criteria

### Deployment
- ✅ Cluster CREATE_COMPLETE within 15 minutes
- ✅ Head node accessible via ElasticIP
- ✅ SLURM scheduler running
- ✅ FSx Lustre mounted
- ✅ EFA device detected: `fi_info -p efa`

### Scaling
- ✅ Dynamic nodes provision within 2-3 minutes
- ✅ All 4 nodes can run simultaneously
- ✅ Jobs complete successfully across all nodes

### Performance
- ✅ EFA latency < 2 microseconds
- ✅ Multi-node MPI bandwidth > 100 Gbps
- ✅ Scaling efficiency > 85% for 2 nodes
- ✅ Identify optimal node count for C24 resolution

---

## Known Issues and Mitigations

### Issue 1: Multi-NIC Public IP Assignment
**Problem:** AWS doesn't allow subnet auto-assign with multi-NIC instances
**Mitigation:** ✅ Disabled auto-assign, using ElasticIP script

### Issue 2: EFA Requires Placement Group
**Problem:** EFA performance degrades without placement group
**Mitigation:** ✅ PlacementGroup enabled in config

### Issue 3: Long Boot Time
**Problem:** Large FSx volumes take time to create
**Mitigation:** ✅ Using minimal 1200 GB size for testing

---

## Monitoring Commands

### Check Cluster Status
```bash
# Overall status
AWS_PROFILE=aws uv run pcluster describe-cluster \
  --cluster-name gchp-test-multinode \
  --region us-east-2 \
  --query 'clusterStatus'

# CloudFormation events (if issues)
AWS_PROFILE=aws uv run pcluster get-cluster-stack-events \
  --cluster-name gchp-test-multinode \
  --region us-east-2
```

### Check Compute Fleet
```bash
AWS_PROFILE=aws uv run pcluster describe-compute-fleet \
  --cluster-name gchp-test-multinode \
  --region us-east-2
```

---

## Next Steps

### After Successful Deployment
1. Run multi-node MPI validation tests
2. Measure EFA performance
3. Test GCHP C24 benchmark on 96 cores (2 nodes)
4. Compare against single-node benchmark data
5. Document findings

### If Tests Successful
1. Update production config with lessons learned
2. Switch to SPOT instances for cost savings
3. Deploy production cluster
4. Run full 3-4 day campaign

### If Issues Encountered
1. Document error messages
2. Check CloudFormation events
3. Verify subnet/security group configuration
4. Test with smaller cluster (2 nodes)

---

## Files Created/Updated

### Documentation
- `/docs/HPC-NETWORKING-GUIDE.md` - Comprehensive networking guide
- `/docs/MULTINODE-DEPLOYMENT-STATUS.md` - This file
- `/docs/DEPLOYMENT-LOG.md` - Minimal cluster deployment log

### Scripts
- `/scripts/associate-head-node-eip.sh` - ElasticIP automation ✅

### Configuration Files
- `/parallelcluster/configs/gchp-test-multinode.yaml` - Updated with networking notes ✅
- `/parallelcluster/configs/gchp-production.yaml` - Updated with networking notes ✅

---

## CloudFormation Stack Details

**Stack Name:** gchp-test-multinode
**Stack ARN:** arn:aws:cloudformation:us-east-2:942542972736:stack/gchp-test-multinode/e9d81280-fcd9-11f0-92de-06d38de8edc1
**Status:** CREATE_IN_PROGRESS
**ParallelCluster Version:** 3.14.0

---

**Status:** 🔄 Deployment in progress
**Expected Completion:** ~22:30 PST (15 minutes from start)
**Next:** Monitor status, associate ElasticIP, validate environment
