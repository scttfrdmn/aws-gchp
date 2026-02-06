# ParallelCluster Networking Guide for EFA/Multi-NIC Instances

**Date:** January 28, 2026
**Context:** Lessons learned from deploying hpc7a and other EFA-capable instances

---

## The Multi-NIC Challenge

### Problem
EFA-capable instances (hpc7a, hpc7g, c7a.48xlarge+, etc.) have multiple network interfaces:
- Primary ENI (Elastic Network Interface) for management
- Additional ENI(s) for EFA (high-performance networking)

AWS **does not allow** subnet auto-assign public IPs for multi-NIC instances.

### Error Encountered
```
The queue test contains an instance type with multiple network interfaces
however the subnets ['subnet-a7ef24cc'] is configured to automatically
assign public IPs. AWS public IPs can only be assigned to instances
launched with a single network interface.
```

---

## Networking Strategies

### Strategy 1: Single Public Subnet (Recommended) ⭐

**Best for:** Cost-conscious HPC clusters
**Cost:** $0 (no NAT Gateway)
**Complexity:** Low

#### Configuration

**Subnet Setup:**
```bash
# Disable auto-assign public IPs
aws ec2 modify-subnet-attribute \
  --subnet-id subnet-a7ef24cc \
  --no-map-public-ip-on-launch \
  --region us-east-2

# Subnet must have route to Internet Gateway (default VPC does)
# Route: 0.0.0.0/0 -> igw-xxxxx
```

**ParallelCluster Config:**
```yaml
HeadNode:
  InstanceType: t3.medium  # Single NIC, will get public IP manually
  Networking:
    SubnetId: subnet-a7ef24cc
    # Note: ElasticIp not directly supported in PC 3.14
    # Workaround: Manually assign ElasticIP after deployment
  Ssh:
    KeyName: aws-benchmark

SlurmQueues:
  - Name: compute
    ComputeResources:
      - Name: hpc7a-efa
        InstanceType: hpc7a.48xlarge  # Multi-NIC with EFA
        Efa:
          Enabled: true
    Networking:
      SubnetIds:
        - subnet-a7ef24cc  # Same subnet as head node
      PlacementGroup:
        Enabled: true  # Required for EFA
```

**Access Pattern:**
1. Deploy cluster
2. Head node gets private IP only (initially)
3. Manually allocate and associate ElasticIP to head node
4. SSH via ElasticIP
5. Compute nodes communicate via private IPs within VPC
6. All nodes can reach internet via IGW (subnet is public)

#### Manual ElasticIP Association

```bash
# After cluster deployment
HEAD_NODE_ID=$(AWS_PROFILE=aws aws ec2 describe-instances \
  --region us-east-2 \
  --filters "Name=tag:Name,Values=*HeadNode*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Allocate ElasticIP
ALLOC_ID=$(AWS_PROFILE=aws aws ec2 allocate-address \
  --region us-east-2 \
  --domain vpc \
  --query 'AllocationId' \
  --output text)

# Associate with head node
AWS_PROFILE=aws aws ec2 associate-address \
  --region us-east-2 \
  --instance-id $HEAD_NODE_ID \
  --allocation-id $ALLOC_ID

# Get public IP
PUBLIC_IP=$(AWS_PROFILE=aws aws ec2 describe-addresses \
  --region us-east-2 \
  --allocation-ids $ALLOC_ID \
  --query 'Addresses[0].PublicIp' \
  --output text)

echo "Head node accessible at: $PUBLIC_IP"
```

**Pros:**
- ✅ Zero NAT Gateway cost
- ✅ Works with multi-NIC instances
- ✅ Simple subnet configuration
- ✅ All nodes can reach internet

**Cons:**
- ⚠️ Manual ElasticIP association required
- ⚠️ Head node not immediately accessible (need to wait for EIP)

---

### Strategy 2: Two-Subnet with NAT Gateway

**Best for:** Production environments requiring strict network isolation
**Cost:** ~$32/month + data transfer (~$0.045/GB)
**Complexity:** Medium

#### Configuration

**Subnet Setup:**
- **Public subnet:** Head node only, auto-assign public IPs enabled
- **Private subnet:** Compute nodes, route to NAT Gateway

```yaml
HeadNode:
  Networking:
    SubnetId: subnet-public  # Auto-assigns public IP

SlurmQueues:
  - Name: compute
    Networking:
      SubnetIds:
        - subnet-private  # Routes through NAT Gateway
      PlacementGroup:
        Enabled: true
```

**Pros:**
- ✅ Head node immediately accessible
- ✅ Compute nodes fully isolated
- ✅ No manual IP management

**Cons:**
- ❌ $32/month NAT Gateway cost (per AZ)
- ❌ Data transfer costs
- ❌ More complex networking

**Recommendation:** NOT cost-effective for research clusters

---

### Strategy 3: Single-NIC Head Node + Multi-NIC Compute

**Best for:** Initial testing/validation
**Cost:** $0 (auto-assign public IPs)
**Complexity:** Low

This is what we used for `gchp-test-minimal`:

```yaml
HeadNode:
  InstanceType: t3.medium  # Single NIC

SlurmQueues:
  - Name: compute
    ComputeResources:
      - InstanceType: c7a.xlarge  # Single NIC (no EFA)
    Networking:
      SubnetIds:
        - subnet-a7ef24cc  # Auto-assign enabled
```

**Pros:**
- ✅ Simplest configuration
- ✅ Zero cost
- ✅ Immediate access

**Cons:**
- ❌ Can't use EFA on compute nodes
- ❌ Limited to single-NIC instance types

**Use Case:** Validation testing only

---

## Recommended Approach by Use Case

### Testing/Development
**Use:** Strategy 3 (Single-NIC)
- Fast iteration
- No networking complexity
- Good for toolkit validation

### Single-Node HPC Workloads (No EFA)
**Use:** Strategy 3 (Single-NIC)
- Works for hpc7a.48xlarge if EFA not needed
- But EFA is the main advantage of hpc7a...

### Multi-Node HPC with EFA
**Use:** Strategy 1 (Single Public Subnet + Manual EIP)
- Cost-effective
- Full EFA support
- One-time manual step (can be scripted)

### Production Multi-Node with Network Isolation
**Use:** Strategy 2 (Two-Subnet + NAT)
- Only if budget allows NAT Gateway cost
- Or if security policy requires compute isolation

---

## Implementation Plan

### Phase 1: Testing (Complete) ✅
- Deployed `gchp-test-minimal` with Strategy 3
- Validated SLURM, FSx, job submission
- Single-NIC c7a.xlarge

### Phase 2: Multi-Node EFA Testing (Next)
- Deploy `gchp-test-multinode` with Strategy 1
- 4x hpc7a.24xlarge with EFA
- Manual ElasticIP for head node
- Validate MPI over EFA

### Phase 3: Production Deployment
- Deploy `gchp-production` with Strategy 1
- Multiple queues (single-node + multi-node)
- Scripted ElasticIP management
- Switch to SPOT after validation

---

## Configuration Files Status

### gchp-test-minimal.yaml ✅
- **Status:** Deployed successfully
- **Strategy:** Single-NIC (Strategy 3)
- **Networking:** Subnet auto-assign enabled
- **No changes needed**

### gchp-test-multinode.yaml 🔄
- **Status:** Ready for deployment
- **Strategy:** Single Public Subnet (Strategy 1)
- **Required Change:** Document ElasticIP procedure
- **Action:** Update documentation, add post-deployment script

### gchp-production.yaml 🔄
- **Status:** Ready for deployment
- **Strategy:** Single Public Subnet (Strategy 1)
- **Required Change:** Same as multinode
- **Action:** Update documentation

---

## Post-Deployment Scripts

### Associate ElasticIP to Head Node

Save as: `/scripts/associate-head-node-eip.sh`

```bash
#!/usr/bin/env bash
# Associate ElasticIP with ParallelCluster head node
set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <cluster-name> [region]"
    exit 1
fi

CLUSTER_NAME="$1"
REGION="${2:-us-east-2}"

echo "Finding head node for cluster: $CLUSTER_NAME"

HEAD_NODE_ID=$(AWS_PROFILE=aws aws ec2 describe-instances \
  --region $REGION \
  --filters "Name=tag:parallelcluster:cluster-name,Values=$CLUSTER_NAME" \
            "Name=tag:parallelcluster:node-type,Values=HeadNode" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [ "$HEAD_NODE_ID" = "None" ] || [ -z "$HEAD_NODE_ID" ]; then
    echo "Error: Head node not found for cluster $CLUSTER_NAME"
    exit 1
fi

echo "Head node ID: $HEAD_NODE_ID"

# Check if already has public IP
EXISTING_IP=$(AWS_PROFILE=aws aws ec2 describe-instances \
  --region $REGION \
  --instance-ids $HEAD_NODE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

if [ "$EXISTING_IP" != "None" ] && [ -n "$EXISTING_IP" ]; then
    echo "Head node already has public IP: $EXISTING_IP"
    exit 0
fi

# Allocate ElasticIP
echo "Allocating ElasticIP..."
ALLOC_ID=$(AWS_PROFILE=aws aws ec2 allocate-address \
  --region $REGION \
  --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$CLUSTER_NAME-head-eip},{Key=parallelcluster:cluster-name,Value=$CLUSTER_NAME}]" \
  --query 'AllocationId' \
  --output text)

echo "ElasticIP allocation ID: $ALLOC_ID"

# Associate with head node
echo "Associating ElasticIP with head node..."
AWS_PROFILE=aws aws ec2 associate-address \
  --region $REGION \
  --instance-id $HEAD_NODE_ID \
  --allocation-id $ALLOC_ID

# Get public IP
PUBLIC_IP=$(AWS_PROFILE=aws aws ec2 describe-addresses \
  --region $REGION \
  --allocation-ids $ALLOC_ID \
  --query 'Addresses[0].PublicIp' \
  --output text)

echo ""
echo "✅ Success! Head node is now accessible at:"
echo ""
echo "  ssh -i ~/.ssh/aws-benchmark.pem ec2-user@$PUBLIC_IP"
echo ""
echo "ElasticIP will persist across cluster stop/start cycles."
echo "Remember to release it when cluster is deleted:"
echo ""
echo "  AWS_PROFILE=aws aws ec2 release-address --region $REGION --allocation-id $ALLOC_ID"
echo ""
```

**Usage:**
```bash
# After deploying cluster with multi-NIC instances
chmod +x scripts/associate-head-node-eip.sh

# Associate EIP
./scripts/associate-head-node-eip.sh gchp-test-multinode us-east-2

# Wait 30 seconds for networking to propagate
sleep 30

# SSH to cluster
ssh -i ~/.ssh/aws-benchmark.pem ec2-user@<public-ip>
```

---

## Validation Checklist

### Before Deployment
- [ ] Subnet has route to Internet Gateway (0.0.0.0/0 -> igw-xxx)
- [ ] Security group allows SSH (port 22) from your IP
- [ ] SSH key exists in AWS region
- [ ] Disable MapPublicIpOnLaunch if using multi-NIC instances

### After Deployment
- [ ] Cluster status is CREATE_COMPLETE
- [ ] Associate ElasticIP to head node
- [ ] SSH access working
- [ ] SLURM scheduler running: `sinfo`
- [ ] FSx mounted: `df -h | grep fsx`
- [ ] Compute nodes can provision: `srun hostname`
- [ ] For EFA clusters: `fi_info -p efa` shows EFA device

---

## Cost Comparison Summary

| Strategy | Monthly Cost | Use Case |
|----------|-------------|----------|
| Single Public Subnet (Strategy 1) | $0 | ✅ Recommended for research |
| Two-Subnet + NAT (Strategy 2) | ~$32 + data | Production with isolation |
| Single-NIC (Strategy 3) | $0 | ✅ Testing only |

**For GCHP benchmarking:** Strategy 1 saves ~$32/month with minimal extra effort.

---

## Summary

**Current Status:**
- ✅ Strategy 3 validated with `gchp-test-minimal`
- 🔄 Strategy 1 ready for `gchp-test-multinode` deployment
- 📝 Post-deployment script created for ElasticIP management

**Next Steps:**
1. Update configs with networking notes
2. Deploy 4-node hpc7a test with EFA
3. Validate EFA performance
4. Document lessons learned
