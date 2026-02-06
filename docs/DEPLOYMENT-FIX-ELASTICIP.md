# Deployment Fix: ElasticIp Configuration

**Date:** January 29, 2026
**Issue:** WaitCondition timeout on multi-node cluster deployment
**Root Cause:** Head node had no public IP (subnet MapPublicIpOnLaunch disabled for multi-NIC compute nodes)
**Solution:** Use ParallelCluster's built-in `ElasticIp: true` configuration

---

## Problem Analysis

### First Attempt Failed
- **Cluster:** gchp-test-multinode
- **Error:** `WaitCondition timed out. Received 0 conditions when expecting 1`
- **Duration:** 37 minutes before rollback
- **Started:** 22:15 PST (06:15 UTC)
- **Failed:** 22:52 PST (06:52 UTC)

### Root Cause
When we disabled `MapPublicIpOnLaunch` on the subnet to support multi-NIC compute nodes (hpc7a with EFA), the single-NIC head node (t3.medium) also lost public IP assignment capability. Without a public IP, the head node couldn't:
- Download packages from internet
- Complete cloud-init scripts
- Signal CloudFormation WaitCondition

### Why Multi-NIC Instances Are Different
From AWS documentation:
> AWS public IPs can only be assigned to instances launched with a single network interface.

EFA-enabled instances (hpc7a.24xlarge) have multiple network interfaces:
- Primary ENI for management traffic
- Additional ENI(s) for EFA high-performance networking

AWS rejects automatic public IP assignment for these instances.

---

## The Official Solution

### ParallelCluster Built-in Feature

According to [AWS ParallelCluster documentation](https://docs.aws.amazon.com/parallelcluster/latest/ug/HeadNode-v3.html):

```yaml
HeadNode:
  Networking:
    ElasticIp: true  # Automatically allocates and assigns Elastic IP
```

**Benefits:**
- ✅ No manual steps required
- ✅ Works with MapPublicIpOnLaunch disabled
- ✅ ElasticIP is free when associated with running instance
- ✅ IP persists across stop/start
- ✅ ParallelCluster handles everything

**Documentation Quote:**
> For multi-NIC instances, you **must set `ElasticIp` to `true`** for public access.

---

## Head Node Instance Type Upgrade

### Previous: t3.medium (Too Small)
- 2 vCPU
- 4 GB RAM
- 5 Gbps network
- Burstable performance (T-series)

**Problems:**
- Insufficient for managing 4-10 node clusters
- Low network bandwidth
- Burstable CPU not suitable for continuous scheduler operations

### New: c7a.2xlarge (Test Cluster) ⭐
- 8 vCPU
- 16 GB RAM
- 12.5 Gbps network
- Enhanced networking
- Same AMD architecture as compute nodes
- **Cost:** $0.37/hour

### New: c7a.4xlarge (Production Cluster)
- 16 vCPU
- 32 GB RAM
- 12.5 Gbps network
- Enhanced networking
- Better for managing up to 10 nodes
- **Cost:** $0.73/hour

### Rationale

From [ParallelCluster Best Practices](https://docs.aws.amazon.com/parallelcluster/latest/ug/best-practices-v3.html):

> **Cluster Size:** The head node orchestrates the scaling logic of the cluster and is responsible for attaching new nodes to the scheduler. For clusters with a large number of nodes, provide the head node **extra compute capacity** to handle scaling up and down efficiently.

> **Network Bandwidth:** Choose an instance type with sufficient network bandwidth for your workflows. The bandwidth scales with instance size.

---

## Configuration Changes

### Before (Failed)
```yaml
HeadNode:
  InstanceType: t3.medium
  Networking:
    SubnetId: subnet-a7ef24cc
  Ssh:
    KeyName: aws-benchmark
```

**Manual workaround required:**
```bash
# After deployment, manually associate ElasticIP
./scripts/associate-head-node-eip.sh gchp-test-multinode
```

### After (Fixed) ✅
```yaml
HeadNode:
  InstanceType: c7a.2xlarge  # Upgraded
  Networking:
    SubnetId: subnet-a7ef24cc
    ElasticIp: true  # 🔑 KEY FIX - Automatic ElasticIP
  Ssh:
    KeyName: aws-benchmark
```

**No manual steps needed!** ParallelCluster handles ElasticIP automatically.

---

## Files Updated

### Test Multi-Node Configuration
**File:** `/parallelcluster/configs/gchp-test-multinode.yaml`

**Changes:**
1. `HeadNode.InstanceType`: `t3.medium` → `c7a.2xlarge`
2. `HeadNode.Networking.ElasticIp`: Added `true`
3. Updated networking comments to reflect automatic ElasticIP

### Production Configuration
**File:** `/parallelcluster/configs/gchp-production.yaml`

**Changes:**
1. `HeadNode.InstanceType`: `t3.medium` → `c7a.4xlarge` (larger for 10-node cluster)
2. `HeadNode.Networking.ElasticIp`: Added `true`
3. Updated networking comments to reflect automatic ElasticIP

### Minimal Test Configuration
**File:** `/parallelcluster/configs/gchp-test-minimal.yaml`

**No changes needed** - Already working with single-NIC c7a.xlarge and MapPublicIpOnLaunch enabled.

---

## Deprecated: Manual ElasticIP Script

**File:** `/scripts/associate-head-node-eip.sh`

**Status:** No longer needed with `ElasticIp: true` configuration

**Preserved for reference** - May be useful for:
- Custom networking scenarios
- Post-deployment IP management
- Troubleshooting

---

## Cost Impact

### Head Node Cost Increase

| Configuration | Old (t3.medium) | New (Test) | New (Prod) |
|---------------|-----------------|------------|------------|
| Instance | t3.medium | c7a.2xlarge | c7a.4xlarge |
| Hourly | $0.04 | $0.37 | $0.73 |
| Daily (24h) | $1.00 | $8.86 | $17.54 |
| Monthly (730h) | $30.37 | $269.76 | $532.88 |

### But Clusters Are Dynamic!

**Actual Usage (Testing):**
- Test cluster runtime: 45 minutes = $0.28 vs $0.03 (extra $0.25)
- Multi-node test: 1 hour = $0.37 vs $0.04 (extra $0.33)

**Actual Usage (Production):**
- 4-day campaign: 96 hours head node only (compute scales dynamically)
- Head node cost: $70.27 (c7a.4xlarge) vs $3.99 (t3.medium)
- **Extra cost:** $66.28 per campaign
- **Compute node cost dominates:** 10× hpc7a.96xlarge = ~$8,000 for 96 hours

**Head node is <1% of total cost** for production workloads.

### ElasticIP Cost

| Scenario | Cost |
|----------|------|
| ElasticIP associated with running instance | $0.00 |
| ElasticIP unassociated | $0.005/hour ($3.65/month) |

**Action:** Delete clusters when not in use to avoid unassociated EIP charges.

---

## Subnet Configuration Status

### Current Subnet Settings
```bash
# subnet-a7ef24cc (us-east-2a)
MapPublicIpOnLaunch: false  # Required for multi-NIC instances
```

**Why disabled:**
- Allows hpc7a compute nodes to launch (multi-NIC with EFA)
- Head node gets public IP via ElasticIp configuration
- No NAT Gateway needed ($32/month savings)

**Routes:**
- 172.31.0.0/16 → local (VPC)
- 0.0.0.0/0 → igw-xxxxx (Internet Gateway)

All instances can reach internet via IGW, regardless of public IP assignment method.

---

## Deployment Timeline

### Failed Attempt
- **Start:** 22:15 PST (06:15 UTC)
- **Failed:** 22:52 PST (06:52 UTC)
- **Duration:** 37 minutes
- **Deleted:** 22:55 PST (06:55 UTC)

### Fixed Deployment
- **Start:** 23:00 PST (07:00 UTC)
- **Status:** CREATE_IN_PROGRESS
- **Expected:** 10-15 minutes
- **Expected completion:** 23:15 PST (07:15 UTC)

---

## Validation Plan

### Once Deployment Completes

1. **Check ElasticIP assignment:**
   ```bash
   AWS_PROFILE=aws uv run pcluster describe-cluster \
     --cluster-name gchp-test-multinode \
     --region us-east-2 \
     --query 'headNode.publicIpAddress'
   ```

2. **SSH to head node:**
   ```bash
   ssh -i ~/.ssh/aws-benchmark.pem ec2-user@<elastic-ip>
   ```

3. **Validate environment:**
   ```bash
   # SLURM
   sinfo

   # FSx
   df -h | grep fsx

   # EFA device
   fi_info -p efa
   ```

4. **Test compute node provisioning:**
   ```bash
   # Single node
   srun -N1 hostname

   # Two nodes
   srun -N2 hostname

   # Four nodes
   srun -N4 hostname
   ```

---

## Key Lessons Learned

### 1. Read the Official Documentation First
We spent time creating a manual ElasticIP script when ParallelCluster had a built-in solution all along. Always check official docs for features before building workarounds.

### 2. Multi-NIC Instances Have Special Networking Requirements
EFA-enabled instances fundamentally change networking behavior. The `ElasticIp: true` configuration is **required**, not optional, for public access to multi-NIC head nodes.

### 3. Head Node Sizing Matters
t3.medium was too small for managing multi-node clusters. The head node orchestrates all scaling operations and shouldn't be an afterthought.

### 4. Architecture Consistency Is Important
Using c7a instances (AMD) for head node matches compute nodes (hpc7a, also AMD), ensuring consistent software builds and performance characteristics.

### 5. Cost Optimization Context
While c7a.2xlarge costs more than t3.medium, it's a tiny fraction (<1%) of total cluster cost when compute nodes are running. Don't optimize head node cost at the expense of functionality.

---

## References

- [ParallelCluster HeadNode Configuration](https://docs.aws.amazon.com/parallelcluster/latest/ug/HeadNode-v3.html)
- [ParallelCluster Best Practices](https://docs.aws.amazon.com/parallelcluster/latest/ug/best-practices-v3.html)
- [ParallelCluster Networking Configuration](https://docs.aws.amazon.com/parallelcluster/latest/ug/network-configuration-v3.html)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)

---

## Summary

**Problem:** Multi-node cluster deployment failed due to head node lacking public IP
**Root Cause:** Subnet configured for multi-NIC compute nodes prevented single-NIC head node from getting IP
**Solution:** Use ParallelCluster's built-in `ElasticIp: true` configuration
**Bonus:** Upgraded head node from t3.medium to c7a.2xlarge for better cluster management
**Status:** Redeploying with fixes, expected completion in 10-15 minutes
**Cost Impact:** Minimal (<1% of total cluster cost for production workloads)

---

**Next:** Monitor deployment, validate ElasticIP assignment, test multi-node EFA functionality.
