# Availability Zone Issue: hpc7a Instance Types

**Date:** January 29, 2026
**Issue:** Compute nodes failed with "(Code:Unsupported)"
**Root Cause:** hpc7a.24xlarge only available in us-east-2b, not us-east-2a

---

## Problem Discovery

### Successful Head Node, Failed Compute Nodes
After fixing the ElasticIP issue, the cluster deployed successfully:
- ✅ Head node CREATE_COMPLETE (c7a.2xlarge)
- ✅ FSx Lustre CREATE_COMPLETE
- ✅ ElasticIP allocated and associated
- ✅ SLURM scheduler running
- ❌ Compute nodes failing to provision

### Error Message
```
NODELIST                       STATE REASON
multinode-test-dy-hpc7a-efa-1  down# (Code:Unsupported)Failed
multinode-test-dy-hpc7a-efa-2  down~ (Code:Unsupported)Test
multinode-test-dy-hpc7a-efa-3  down~ (Code:Unsupported)Test
multinode-test-dy-hpc7a-efa-4  down~ (Code:Unsupported)Test
```

**SLURM Error:**
```
srun: error: Node failure on multinode-test-dy-hpc7a-efa-1
srun: error: Nodes multinode-test-dy-hpc7a-efa-1 are still not ready
srun: error: Something is wrong with the boot of the nodes.
```

---

## Root Cause Analysis

### Instance Type Availability Investigation

**Query:** Check which AZs have hpc7a.24xlarge
```bash
AWS_PROFILE=aws aws ec2 describe-instance-type-offerings \
  --region us-east-2 \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=hpc7a.24xlarge" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table
```

**Result:**
```
-------------------------------
|DescribeInstanceTypeOfferings|
+-----------------------------+
|  us-east-2b                 |  ← ONLY us-east-2b!
+-----------------------------+
```

### Our Configuration
- **Head Node Subnet:** subnet-a7ef24cc → **us-east-2a** ❌
- **Compute Node Subnet:** subnet-a7ef24cc → **us-east-2a** ❌
- **hpc7a.24xlarge Available In:** us-east-2b only ❌

**Mismatch!** Trying to launch hpc7a.24xlarge in us-east-2a where it doesn't exist.

---

## HPC7a Availability by Instance Size

### Query All hpc7a Sizes
```bash
for size in 12xlarge 24xlarge 48xlarge 96xlarge; do
  echo "=== hpc7a.$size ==="
  AWS_PROFILE=aws aws ec2 describe-instance-type-offerings \
    --region us-east-2 \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=hpc7a.$size" \
    --query 'InstanceTypeOfferings[].Location' \
    --output text
done
```

**Results:**
| Instance Type | us-east-2a | us-east-2b | us-east-2c |
|---------------|------------|------------|------------|
| hpc7a.12xlarge | ❌ | ✅ | ❌ |
| hpc7a.24xlarge | ❌ | ✅ | ❌ |
| hpc7a.48xlarge | ❌ | ✅ | ❌ |
| hpc7a.96xlarge | ❌ | ✅ | ❌ |

**ALL hpc7a instances are ONLY in us-east-2b!**

---

## Why This Matters for EFA

### EFA Requires Single Availability Zone

From AWS ParallelCluster documentation:
> **Elastic Fabric Adapter (EFA) isn't supported over different availability zones.**

**This means:**
- Head node and compute nodes must be in the SAME AZ
- For hpc7a in us-east-2, that AZ MUST be us-east-2b
- Can't use head node in us-east-2a + compute in us-east-2b

**Implication:**
- **Head node subnet:** Must be in us-east-2b
- **Compute node subnet:** Must be in us-east-2b
- Can use same subnet or different subnets, but both in us-east-2b

---

## The Fix

### Update Subnet Configuration

**New Subnet:** subnet-cbdcddb1 (us-east-2b)

**Prepare subnet:**
```bash
# Disable MapPublicIpOnLaunch (for multi-NIC compute nodes)
AWS_PROFILE=aws aws ec2 modify-subnet-attribute \
  --subnet-id subnet-cbdcddb1 \
  --no-map-public-ip-on-launch \
  --region us-east-2
```

### Update Configuration Files

**gchp-test-multinode.yaml:**
```yaml
HeadNode:
  Networking:
    SubnetId: subnet-cbdcddb1  # us-east-2b (hpc7a.24xlarge only available here)
    ElasticIp: true

SlurmQueues:
  - Name: multinode-test
    Networking:
      SubnetIds:
        - subnet-cbdcddb1  # us-east-2b (same AZ required for EFA)
```

**gchp-production.yaml:**
```yaml
HeadNode:
  Networking:
    SubnetId: subnet-cbdcddb1  # us-east-2b (all hpc7a only available here)
    ElasticIp: true

SlurmQueues:
  - Name: hpc-single
    Networking:
      SubnetIds:
        - subnet-cbdcddb1  # us-east-2b

  - Name: hpc-multi
    Networking:
      SubnetIds:
        - subnet-cbdcddb1  # us-east-2b
```

---

## Other Instance Families

### c7a, c8a (AMD Compute)

**Query:**
```bash
AWS_PROFILE=aws aws ec2 describe-instance-type-offerings \
  --region us-east-2 \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=c7a.xlarge,c7a.48xlarge,c8a.xlarge" \
  --query 'InstanceTypeOfferings[].[InstanceType,Location]' \
  --output table
```

**Result:** c7a and c8a are available in **ALL us-east-2 AZs** (a, b, c)

**Implication:** c7a and c8a have more flexibility for AZ placement.

### c7i, c8i (Intel Compute)

Available in all AZs (us-east-2a, b, c)

### hpc7g (ARM Graviton HPC)

Not available in us-east-2 at all (only us-east-1, eu-west-1)

---

## Lessons Learned

### 1. Always Verify Instance Type Availability by AZ ⭐
Don't assume instance types are available in all AZs within a region. HPC instances in particular have limited AZ availability.

**Best Practice:**
```bash
# Check before configuring
AWS_PROFILE=aws aws ec2 describe-instance-type-offerings \
  --region <region> \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=<instance-type>" \
  --query 'InstanceTypeOfferings[].Location'
```

### 2. EFA + Instance Availability = Strict Constraints
- EFA requires single AZ
- Some instance types only in specific AZ
- These constraints compound
- Must check compatibility BEFORE deployment

### 3. Region-Level Availability ≠ AZ-Level Availability
- `describe-instance-types` shows region-wide availability
- Doesn't guarantee availability in YOUR chosen AZ
- Must use `describe-instance-type-offerings` with `--location-type availability-zone`

### 4. Document AZ Requirements in Configs
Added comments to all configs documenting AZ requirements:
```yaml
SubnetId: subnet-cbdcddb1  # us-east-2b (hpc7a only available here)
```

This prevents future confusion and deployment failures.

---

## Impact on Existing Clusters

### gchp-test-minimal (c7a.xlarge)
- **Current subnet:** subnet-a7ef24cc (us-east-2a)
- **Status:** ✅ Working fine
- **Action:** No change needed (c7a available in all AZs)
- **Can keep running**

### gchp-test-multinode (hpc7a.24xlarge)
- **Old subnet:** subnet-a7ef24cc (us-east-2a) ❌
- **New subnet:** subnet-cbdcddb1 (us-east-2b) ✅
- **Status:** Redeploying with correct AZ
- **Action:** Deleted and redeploying

### gchp-production (hpc7a.48xlarge, hpc7a.96xlarge)
- **Updated subnet:** subnet-cbdcddb1 (us-east-2b) ✅
- **Status:** Not yet deployed
- **Action:** Config updated before first deployment

---

## Verification Checklist

Before deploying EFA clusters:
- [ ] Verify instance type availability in target AZ
- [ ] Confirm head node and compute nodes in same AZ
- [ ] Check EFA is supported on chosen instance type
- [ ] Verify subnet configuration (MapPublicIpOnLaunch disabled)
- [ ] Document AZ requirements in config comments

---

## Updated Documentation

### Files Modified
- `/parallelcluster/configs/gchp-test-multinode.yaml` ✅
  - SubnetId: subnet-a7ef24cc → subnet-cbdcddb1
  - Added AZ comment

- `/parallelcluster/configs/gchp-production.yaml` ✅
  - SubnetId: subnet-a7ef24cc → subnet-cbdcddb1 (all queues)
  - Added AZ comment

### Files Created
- `/docs/AVAILABILITY-ZONE-ISSUE.md` (this file)

---

## Timeline

| Time | Event |
|------|-------|
| 23:12 PST | Cluster CREATE_COMPLETE with ElasticIP fix |
| 23:15 PST | Attempted first compute node job |
| 23:16 PST | SLURM reported "Node failure" |
| 23:17 PST | Investigated SLURM logs |
| 23:18 PST | Nodes showing "(Code:Unsupported)" |
| 23:19 PST | Queried instance type offerings |
| 23:20 PST | **Discovered:** hpc7a.24xlarge only in us-east-2b |
| 23:21 PST | Identified root cause |
| 23:22 PST | Found subnet-cbdcddb1 in us-east-2b |
| 23:23 PST | Configured new subnet |
| 23:24 PST | Updated configs |
| 23:25 PST | Started cluster deletion |
| 23:30 PST | Deletion in progress (FSx takes time) |

---

## Cost of This Issue

### Wasted Resources
- Deployment #2: 12 minutes runtime
- Head node (c7a.2xlarge): $0.07
- FSx Lustre: $0.05
- **Total wasted:** ~$0.12

Not significant, but highlights importance of validation before deployment.

---

## Prevention for Future Deployments

### Add Pre-Deployment Validation Script

**Script:** `/scripts/validate-cluster-config.sh` (to be created)

```bash
#!/usr/bin/env bash
# Validate cluster configuration before deployment

CONFIG_FILE="$1"
REGION=$(grep "Region:" "$CONFIG_FILE" | awk '{print $2}')

# Extract instance types and subnets
HEAD_INSTANCE=$(grep "InstanceType:" "$CONFIG_FILE" | head -1 | awk '{print $2}')
COMPUTE_INSTANCES=$(grep "InstanceType:" "$CONFIG_FILE" | tail -n +2 | awk '{print $2}')
SUBNETS=$(grep "SubnetId:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '#')

# Validate each instance type in each subnet's AZ
for INSTANCE in $HEAD_INSTANCE $COMPUTE_INSTANCES; do
  for SUBNET in $SUBNETS; do
    AZ=$(aws ec2 describe-subnets --subnet-ids $SUBNET --query 'Subnets[0].AvailabilityZone' --output text)
    AVAILABLE=$(aws ec2 describe-instance-type-offerings \
      --location-type availability-zone \
      --filters "Name=location,Values=$AZ" "Name=instance-type,Values=$INSTANCE" \
      --query 'InstanceTypeOfferings[0].InstanceType' \
      --output text)

    if [ "$AVAILABLE" != "$INSTANCE" ]; then
      echo "❌ ERROR: $INSTANCE not available in $AZ (subnet: $SUBNET)"
      exit 1
    fi
  done
done

echo "✅ All instance types available in configured AZs"
```

**Usage:**
```bash
./scripts/validate-cluster-config.sh parallelcluster/configs/gchp-test-multinode.yaml
```

---

## Summary

**Problem:** Cluster deployed successfully but compute nodes failed to provision
**Root Cause:** hpc7a.24xlarge only available in us-east-2b, not us-east-2a
**Solution:** Switch to subnet-cbdcddb1 (us-east-2b) for all hpc7a deployments
**Prevention:** Always verify instance type availability by AZ before deployment
**Cost Impact:** Minimal (~$0.12 wasted on failed deployment)
**Lesson:** Region-level availability checks are insufficient - must verify at AZ level

---

**Next:** Redeploy with correct AZ configuration and validate compute node provisioning.
