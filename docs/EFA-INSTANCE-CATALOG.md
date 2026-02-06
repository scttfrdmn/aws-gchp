# AWS EFA-Enabled Instance Catalog for GCHP

**Date:** January 28, 2026
**Region Tested:** us-east-2 (Ohio)
**Purpose:** Catalog EFA-capable instances for multi-node GCHP benchmarking

---

## What is EFA?

**Elastic Fabric Adapter (EFA)** is a network interface for Amazon EC2 instances that enables:
- Low-latency inter-node communication
- High throughput for MPI workloads
- OS-bypass technology (kernel bypass)
- Essential for multi-node HPC scaling

**Cost:** EFA is available at **no additional charge** on supported instances.

**Limitation:** EFA requires instances be in the **same Availability Zone** (use PlacementGroup).

---

## EFA Support by Instance Family (us-east-2)

### AMD EPYC Instances

#### HPC7a - HPC Optimized (Zen 4) ⭐ **BEST FOR GCHP**

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | Use Case |
|--------------|-------|--------|---------------|---------|----------|
| **hpc7a.12xlarge** | 24 | 96 GB | **150 Gbps** | 4 | Small multi-node |
| **hpc7a.24xlarge** | 48 | 192 GB | **150 Gbps** | 4 | Medium multi-node |
| **hpc7a.48xlarge** | 96 | 384 GB | **150 Gbps** | 4 | **Optimal for C24** |
| **hpc7a.96xlarge** | 192 | 768 GB | **150 Gbps** | 4 | Large multi-node |

**Key Features:**
- ✅ **ALL sizes support EFA** (optimized for HPC)
- ✅ 150 Gbps EFA bandwidth on all sizes
- ✅ 4:1 memory ratio (4 GB/core)
- ✅ GCHP team recommendation
- ✅ Best price-performance for atmospheric chemistry

#### C8a - Compute Optimized (Zen 5)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c8a.xlarge - c8a.24xlarge | 4-96 | 8-192 GB | N/A | N/A | ❌ No EFA |
| **c8a.48xlarge** | 192 | 384 GB | **75 Gbps** | 24 | ✅ EFA |
| **c8a.metal-48xl** | 192 | 384 GB | **75 Gbps** | 24 | ✅ EFA |

**Key Features:**
- ⚠️ Only 48xlarge and metal support EFA
- ⚠️ Lower EFA bandwidth than hpc7a (75 vs 150 Gbps)
- ✅ Latest Zen 5 architecture (faster single-core)
- ⚠️ 2:1 memory ratio (2 GB/core) - may be tight for GCHP

#### C7a - Compute Optimized (Zen 4)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c7a.xlarge - c7a.24xlarge | 4-96 | 8-192 GB | N/A | N/A | ❌ No EFA |
| **c7a.48xlarge** | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |
| **c7a.metal-48xl** | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |

**Key Features:**
- ⚠️ Only 48xlarge and metal support EFA
- ⚠️ Lower EFA bandwidth (50 Gbps)
- ✅ Same architecture as hpc7a (Zen 4)
- ⚠️ 2:1 memory ratio

#### C6a - Compute Optimized (Zen 3)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c6a.xlarge - c6a.32xlarge | 4-128 | 8-256 GB | N/A | N/A | ❌ No EFA |
| **c6a.48xlarge** | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |
| **c6a.metal** | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |

### Intel Xeon Instances

#### C8i - Compute Optimized (Emerald Rapids, Gen 5)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c8i.xlarge - c8i.32xlarge | 4-128 | 8-256 GB | N/A | N/A | ❌ No EFA |
| **c8i.48xlarge** | 192 | 384 GB | **75 Gbps** | 24 | ✅ EFA |
| **c8i.96xlarge** | 384 | 768 GB | **100 Gbps** | 24 | ✅ EFA |
| **c8i.metal-48xl** | 192 | 384 GB | **75 Gbps** | 24 | ✅ EFA |
| **c8i.metal-96xl** | 384 | 768 GB | **100 Gbps** | 24 | ✅ EFA |

**Key Features:**
- ✅ 48xlarge and larger support EFA
- ✅ Up to 100 Gbps EFA (96xlarge)
- ✅ Latest Intel architecture
- ⚠️ 2:1 memory ratio

#### C7i - Compute Optimized (Sapphire Rapids, Gen 4)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c7i.xlarge - c7i.32xlarge | 4-128 | 8-256 GB | N/A | N/A | ❌ No EFA |
| **c7i.48xlarge** | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |
| **c7i.metal-48xl** | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |

#### C6i/C6id - Compute Optimized (Ice Lake, Gen 3)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c6i.32xlarge | 128 | 256 GB | **50 Gbps** | 15 | ✅ EFA |
| c6id.32xlarge | 128 | 256 GB | **50 Gbps** | 15 | ✅ EFA |
| c6i.metal | 128 | 256 GB | **50 Gbps** | 15 | ✅ EFA |
| c6id.metal | 128 | 256 GB | **50 Gbps** | 15 | ✅ EFA |

#### C6in - Network Optimized (Ice Lake)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| **c6in.32xlarge** | 128 | 256 GB | **200 Gbps** ⚡ | 16 | ✅ EFA |
| **c6in.metal** | 128 | 256 GB | **200 Gbps** ⚡ | 16 | ✅ EFA |

**Key Features:**
- ✅ Highest EFA bandwidth in Intel family (200 Gbps)
- ✅ Network-optimized variant

### ARM Graviton Instances

#### C8g/C8gd - Compute Optimized (Graviton 4)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c8g.24xlarge | 96 | 192 GB | **40 Gbps** | 15 | ✅ EFA |
| c8g.48xlarge | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |
| c8gd.24xlarge | 96 | 192 GB | **40 Gbps** | 15 | ✅ EFA |
| c8gd.48xlarge | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |
| c8g.metal-24xl | 96 | 192 GB | **40 Gbps** | 15 | ✅ EFA |
| c8g.metal-48xl | 192 | 384 GB | **50 Gbps** | 15 | ✅ EFA |

#### C8gn - Network Optimized (Graviton 4)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c8gn.16xlarge | 64 | 128 GB | **200 Gbps** ⚡ | 16 | ✅ EFA |
| c8gn.24xlarge | 96 | 192 GB | **300 Gbps** 🚀 | 24 | ✅ EFA |
| **c8gn.48xlarge** | 192 | 384 GB | **300 Gbps** 🚀 | 24 | ✅ EFA |

**Key Features:**
- ✅ **Highest EFA bandwidth available** (300 Gbps on c8gn.48xlarge)
- ✅ Cost-effective ARM architecture
- ⚠️ Requires ARM-compiled binaries (GCC ARM toolchain)
- ✅ Excellent for cost-sensitive multi-node workloads

#### C7g/C7gd - Compute Optimized (Graviton 3)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c7g.16xlarge | 64 | 128 GB | **30 Gbps** | 15 | ✅ EFA |
| c7gd.16xlarge | 64 | 128 GB | **30 Gbps** | 15 | ✅ EFA |
| c7g.metal | 64 | 128 GB | **30 Gbps** | 15 | ✅ EFA |
| c7gd.metal | 64 | 128 GB | **30 Gbps** | 15 | ✅ EFA |

#### C7gn - Network Optimized (Graviton 3)

| Instance Type | Cores | Memory | EFA Bandwidth | Max ENI | EFA Support |
|--------------|-------|--------|---------------|---------|-------------|
| c7gn.16xlarge | 64 | 128 GB | **200 Gbps** ⚡ | 15 | ✅ EFA |
| c7gn.metal | 64 | 128 GB | **200 Gbps** ⚡ | 15 | ✅ EFA |

---

## EFA Bandwidth Comparison

| EFA Speed | Instance Types | Use Case |
|-----------|---------------|----------|
| **300 Gbps** 🚀 | c8gn.24xlarge, c8gn.48xlarge | Maximum bandwidth, ARM only |
| **200 Gbps** ⚡ | c6in.32xlarge, c7gn.16xlarge, c8gn.16xlarge | High bandwidth, network-optimized |
| **150 Gbps** | **hpc7a.*** (all sizes) | **HPC-optimized, consistent across all sizes** |
| **100 Gbps** | c8i.96xlarge | Latest Intel, large memory |
| **75 Gbps** | c8a.48xlarge, c8i.48xlarge | Latest gen, good bandwidth |
| **50 Gbps** | c6a/c7a/c7i/c8g.48xlarge | Standard for 48xlarge tier |
| **40 Gbps** | c8g.24xlarge | Mid-size ARM |
| **30 Gbps** | c7g.16xlarge | Smaller Graviton 3 |

---

## Recommendations for GCHP

### Single-Node Workloads (C24 resolution)
**Best:** hpc7a.48xlarge (96 cores, 384 GB, 150 Gbps EFA)
- ✅ Perfect core count (matches our 96-core sweet spot)
- ✅ 4:1 memory ratio (GCHP needs memory)
- ✅ EFA ready for future multi-node testing
- ✅ GCHP team validated

**Alternative:** c8a.48xlarge (192 cores, 384 GB, 75 Gbps EFA)
- ✅ Faster single-core (Zen 5 vs Zen 4)
- ⚠️ More cores than optimal for C24 (diminishing returns)
- ⚠️ Half the EFA bandwidth of hpc7a
- ⚠️ 2:1 memory ratio

### Multi-Node Workloads (4-10 nodes)
**Best:** hpc7a.96xlarge (192 cores/node, 150 Gbps EFA)
- ✅ High core count per node
- ✅ 150 Gbps EFA bandwidth
- ✅ 4:1 memory ratio
- ✅ HPC-optimized interconnect

**Alternative (Maximum Bandwidth):** c8gn.48xlarge (192 cores/node, 300 Gbps EFA)
- ✅ **2x EFA bandwidth** of hpc7a
- ✅ High core count
- ⚠️ Requires ARM build (ACfL toolchain)
- ⚠️ 2:1 memory ratio
- 💰 Cost-effective

**Alternative (Intel):** c8i.48xlarge (192 cores/node, 75 Gbps EFA)
- ✅ Latest Intel architecture
- ✅ x86 compatibility
- ⚠️ Half the EFA bandwidth of hpc7a
- ⚠️ 2:1 memory ratio

### Cost-Optimized Testing
**For initial validation:** c7a.xlarge (4 cores, no EFA)
- ✅ Single NIC (no public IP complications)
- ✅ Cheap for automation testing
- ✅ Validates ParallelCluster setup
- ⚠️ Not suitable for real GCHP benchmarks

---

## Key Insights

### Pattern 1: EFA Only on Largest Sizes (Compute Optimized)
For Cxa families (C6a, C7a, C8a, C6i, C7i, C8i, C8g):
- ❌ Small/medium sizes: **No EFA**
- ✅ 48xlarge and larger: **EFA supported**
- Exception: C6in, C7gn, C8gn (network-optimized) have EFA at smaller sizes

### Pattern 2: HPC Instances Always Have EFA
- ✅ hpc7a: **ALL sizes** support EFA (12xl, 24xl, 48xl, 96xl)
- ✅ Consistent 150 Gbps across all sizes
- ✅ Designed specifically for multi-node HPC

### Pattern 3: Memory Ratios Matter
- **HPC instances:** 4:1 (4 GB per core) - ideal for memory-bound workloads like GCHP
- **Compute instances:** 2:1 (2 GB per core) - may be tight for atmospheric chemistry

### Pattern 4: Network Bandwidth Increases with Size
- 48xlarge: typically 50-75 Gbps
- 96xlarge: up to 100-150 Gbps
- Network-optimized (`n` suffix): 200-300 Gbps

---

## Networking Configuration Requirements

### Single-NIC Instances (No EFA)
- c7a.xlarge, c8a.xlarge, etc.
- ✅ Can use subnet auto-assign public IPs
- ✅ Simple networking setup
- ✅ No NAT Gateway needed

### Multi-NIC Instances (EFA-capable)
- All EFA-capable instances have multiple network interfaces
- ❌ Cannot use subnet auto-assign public IPs
- ✅ **Solution:** All nodes in public subnet (use security groups for access control)
- ❌ **Expensive option:** NAT Gateway ($32/month + data)
- ✅ **For head node with EFA:** Use `ElasticIp: true` setting

**ParallelCluster Best Practice:**
```yaml
HeadNode:
  Networking:
    SubnetId: subnet-public
    ElasticIp: true  # For multi-NIC head node

SlurmQueues:
  - Name: compute
    Networking:
      SubnetIds:
        - subnet-public  # Same subnet, all get public IPs
```

---

## How to Query EFA Support

```bash
# List all EFA-enabled instances in a region
AWS_PROFILE=aws aws ec2 describe-instance-types \
  --region us-east-2 \
  --filters "Name=network-info.efa-supported,Values=true" \
  --query 'InstanceTypes[].InstanceType' \
  --output text | sort

# Get details for specific instance family
AWS_PROFILE=aws aws ec2 describe-instance-types \
  --region us-east-2 \
  --filters "Name=instance-type,Values=hpc7a*" \
  --query 'InstanceTypes[?NetworkInfo.EfaSupported==`true`].{
    Type:InstanceType,
    Cores:VCpuInfo.DefaultCores,
    Memory:MemoryInfo.SizeInMiB,
    EFABandwidth:NetworkInfo.NetworkCards[0].BaselineBandwidthInGbps
  }' \
  --output table
```

---

## Sources

- [Elastic Fabric Adapter - AWS Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [AWS ParallelCluster EFA Guide](https://docs.aws.amazon.com/parallelcluster/latest/ug/efa-v3.html)
- [Amazon EC2 Hpc7a Instances](https://aws.amazon.com/ec2/instance-types/hpc7a/)
- [Amazon EC2 C8a Instances](https://aws.amazon.com/ec2/instance-types/c8a/)
- [Optimizing MPI on hpc7a with EFA](https://aws.amazon.com/blogs/hpc/optimizing-mpi-application-performance-on-hpc7a-by-effectively-using-both-efa-devices/)
- [Identify EFA-enabled instances - AWS PCS](https://docs.aws.amazon.com/pcs/latest/userguide/working-with_networking_efa_identify-instances.html)

---

**Last Updated:** January 28, 2026
**Tested Region:** us-east-2 (Ohio)
**ParallelCluster Version:** 3.14.0
