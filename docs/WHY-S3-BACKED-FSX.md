# Why S3-Backed FSx for GCHP? A Paradigm Shift

**Date:** January 30, 2026
**Context:** Deploying GCHP on AWS ParallelCluster

---

## The Traditional HPC Approach (and its problems)

### Method 1: Custom AMIs
**How it works:**
1. Launch base instance
2. Install all software dependencies
3. Build GCHP
4. Create AMI snapshot (~30-40 minutes)
5. Deploy cluster with custom AMI
6. Each node boots from custom AMI

**Problems:**
- ❌ AMI build time: 30-40 minutes per architecture
- ❌ AMI storage costs: $0.05/GB-month per AMI
- ❌ Multiple AMIs: Need separate AMI per architecture (AMD, Intel, ARM)
- ❌ Updates are painful: Rebuild entire AMI for any change
- ❌ Version management: Track multiple AMI IDs across regions
- ❌ Software on local disk: Not shared, each node has duplicate
- ❌ Data staging: Must handle separately from software

### Method 2: Post-Install Scripts
**How it works:**
1. Deploy cluster with base AMI
2. Run post-install script on head node
3. Build GCHP (~2 hours)
4. Software on head node local disk
5. Share via NFS or rebuild on compute nodes

**Problems:**
- ❌ Build every deployment: 2+ hours wasted
- ❌ Health check timeouts: ParallelCluster expects nodes ready in 15 min
- ❌ NFS from head node: Bottleneck, not Lustre-fast
- ❌ No persistence: Software lost when cluster deleted
- ❌ Rebuild for each cluster: Can't reuse across clusters
- ❌ No S3 backup: Software exists only on cluster

### Method 3: Separate Build Cluster + NFS Export
**How it works:**
1. Deploy permanent build cluster
2. Build GCHP once
3. Export /apps via NFS
4. Compute clusters mount via NFS

**Problems:**
- ❌ Cost: Build cluster runs 24/7 (~$700/month)
- ❌ NFS over network: Latency, not Lustre-fast
- ❌ Single point of failure: If build cluster down, all clusters affected
- ❌ Region-locked: Can't easily replicate to other regions
- ❌ No auto-scaling: Build cluster must be sized for max concurrent mounts

---

## The S3-Backed FSx Approach (This Project)

### How It Works
1. **Build once** on FSx Lustre
2. **FSx auto-exports** to S3 (continuous, automatic)
3. **Delete cluster** (FSx deleted, S3 persists)
4. **Deploy new cluster** → FSx auto-imports from S3
5. **Software available** immediately after import (5-10 min)

### Architecture
```
┌─────────────────────────────────────────────┐
│  Cluster A      Cluster B      Cluster C    │
│  ┌─────┐       ┌─────┐        ┌─────┐      │
│  │ FSx │       │ FSx │        │ FSx │      │
│  │ /fsx│       │ /fsx│        │ /fsx│      │
│  └──┬──┘       └──┬──┘        └──┬──┘      │
│     │             │              │          │
│     └─────────────┼──────────────┘          │
│                   │                         │
│                   ▼                         │
│           ┌───────────────┐                 │
│           │      S3       │                 │
│           │   Bucket      │                 │
│           │ (persistent)  │                 │
│           └───────────────┘                 │
│             ~/software/                     │
│             ~/results/                      │
└─────────────────────────────────────────────┘
```

---

## Advantages Over Traditional Methods

### 1. Zero Build Time (After First Build)
- ✅ Build GCHP once: ~2 hours
- ✅ Every subsequent deployment: 0 hours build time
- ✅ Software imports from S3: 5-10 minutes
- **Time saved per deployment:** 2 hours → 10 minutes

### 2. No AMI Management
- ✅ No AMI builds: Save 30-40 minutes
- ✅ No AMI storage costs: $0 vs $0.05/GB-month per AMI
- ✅ No version tracking: S3 objects are versioned automatically
- ✅ Updates trivial: Just modify /fsx, auto-exports to S3

### 3. True Shared Storage
- ✅ FSx Lustre: 100+ GB/s throughput
- ✅ All nodes see same filesystem
- ✅ No NFS bottlenecks
- ✅ Parallel I/O: GCHP runs at full speed

### 4. Persistence Without Cost
- ✅ S3 storage: $0.023/GB-month (vs $0.18/GB-month FSx)
- ✅ GCHP software: ~7 GB = **$0.16/month**
- ✅ FSx only exists when cluster running
- ✅ No permanent infrastructure costs

### 5. Multi-Cluster Efficiency
- ✅ Build once, deploy N clusters
- ✅ Each cluster imports from same S3 bucket
- ✅ No data duplication
- ✅ Parallel testing: Deploy Intel + AMD + ARM simultaneously

### 6. Multi-Region Ready
- ✅ S3 cross-region replication
- ✅ Deploy same GCHP in any region
- ✅ No AMI copying between regions

### 7. Version Control
- ✅ S3 versioning: Track every change
- ✅ Rollback: Deploy cluster with previous S3 version
- ✅ Testing: Deploy cluster with S3 version tag
- ✅ Production: Deploy cluster with "stable" version

### 8. AWS Open Data Compatible
- ✅ S3 bucket can be public
- ✅ GCHP team publishes canonical data
- ✅ Users import without replicating data
- ✅ Community benefits: Zero data transfer costs

---

## Real-World Scenarios

### Scenario 1: Benchmarking Multiple Architectures
**Traditional (AMI):**
1. Build AMD AMI: 30 min
2. Build Intel AMI: 30 min
3. Build ARM AMI: 30 min
4. Deploy 3 clusters: 15 min each
5. **Total: 135 minutes**

**S3-Backed FSx:**
1. Build GCHP once: 2 hours (one time)
2. Deploy 3 clusters simultaneously: 15 min each
3. FSx imports in parallel: 10 min
4. **Total (first time): 145 minutes**
5. **Total (subsequent): 25 minutes** ← 81% faster

### Scenario 2: Development Workflow
**Traditional:**
1. Modify GCHP code locally
2. Deploy cluster: 15 min
3. Post-install + rebuild: 2 hours
4. Test
5. Delete cluster
6. Repeat for next change
7. **Per iteration: 2 hours 15 min**

**S3-Backed FSx:**
1. Modify GCHP code locally
2. Deploy cluster: 15 min
3. SSH, `cd /fsx/GCHP && git pull && make`: 5 min
4. Test
5. Changes auto-export to S3
6. Delete cluster
7. Next cluster already has changes
8. **Per iteration: 20 minutes** ← 85% faster

### Scenario 3: Multi-User Team (5 users)
**Traditional:**
- Option A: Each builds own software: 5 × 2 hours = 10 hours wasted
- Option B: Shared build cluster: $700/month ongoing cost

**S3-Backed FSx:**
- User 1 builds once: 2 hours
- Auto-exports to shared S3 bucket
- Users 2-5 deploy clusters: Software appears from S3
- **Cost: $0.16/month** (S3 storage)
- **Time saved: 8 hours**

### Scenario 4: Production Science Runs
**Traditional:**
- Deploy cluster with pre-built AMI
- Run simulation
- Copy results off cluster before deletion
- **Problem:** If results copy fails, data lost

**S3-Backed FSx:**
- Deploy cluster (software from S3)
- Run simulation
- Results auto-export to S3 continuously
- **Benefit:** Results in S3 even if cluster dies

---

## Cost Comparison

### Custom AMI Approach
```
Software storage:
  3 AMIs (AMD, Intel, ARM) × 10 GB × $0.05/GB-month = $1.50/month

Per deployment:
  AMI build time: 30 min × $0.40/hour (c7a.2xlarge) = $0.20
  No ongoing FSx costs (software on local disk)

Data staging:
  Separate process, manage independently
```

### S3-Backed FSx Approach
```
Software storage:
  S3: 7 GB × $0.023/GB-month = $0.16/month

Per deployment:
  No build time
  FSx costs: $0.25/hour while cluster running
  FSx only exists during cluster lifetime

Data staging:
  Same FSx approach, shared across clusters
```

**Winner:** S3-backed FSx is cheaper and faster

---

## Why FSx Lustre Specifically?

### FSx Lustre Advantages
1. **S3 Integration:** Native, automatic import/export
2. **Performance:** 100+ GB/s throughput, sub-millisecond latency
3. **Compatibility:** POSIX filesystem, works with any application
4. **Lazy Load:** Files imported from S3 on first access
5. **Parallel I/O:** GCHP can use full HPC capabilities

### Why Not EFS?
- ❌ No S3 integration (manual sync required)
- ❌ Lower throughput (~10 GB/s max)
- ❌ Higher latency
- ❌ Not optimized for HPC workloads

### Why Not EBS?
- ❌ No S3 integration
- ❌ Not shared across nodes
- ❌ Must use NFS for sharing (bottleneck)

---

## ParallelCluster Integration

### FSx Configuration
```yaml
SharedStorage:
  - Name: workspace
    StorageType: FsxLustre
    MountDir: /fsx
    FsxLustreSettings:
      StorageCapacity: 1200  # 1.2 TB
      DeploymentType: SCRATCH_2  # Cost-effective
      ImportPath: s3://gchp-shared-storage/
      ExportPath: s3://gchp-shared-storage/
      AutoImportPolicy: NEW_CHANGED  # Auto-sync S3 changes
```

### How It Works
1. **Cluster creates** → FSx creates with ImportPath
2. **FSx mounts** → Lazy-loads files from S3 on access
3. **Files modified** → Auto-exports to S3 on close
4. **Cluster deletes** → FSx deletes, S3 persists

### Export Behavior
- **NEW_CHANGED:** Export new/modified files automatically
- **Export on close:** File closed → uploaded to S3 within minutes
- **Export on FSx delete:** All files exported before filesystem deletion

---

## Best Practices

### 1. Separate Buckets for Software vs Data
```
s3://gchp-shared-storage/     # Software + results (read-write)
s3://gchp-input-data/         # Input data (read-only)
```

### 2. Use S3 Versioning
Enable versioning on software bucket for rollback capability.

### 3. Lifecycle Policies
- Software: Keep forever ($0.16/month is negligible)
- Results: Archive to Glacier after 30 days

### 4. Multi-User Setup
- Shared data FSx (persistent)
- Per-user workspace FSx (temporary)
- Each user has own S3 workspace bucket

### 5. Cross-Region
Replicate S3 bucket to other regions for global deployment.

---

## Limitations and Considerations

### FSx Import Time
- **Small datasets (<10 GB):** ~5 minutes
- **Large datasets (100+ GB):** ~30 minutes
- **Mitigation:** Software is small (7 GB), input data staged once

### FSx Costs While Running
- SCRATCH_2: $0.18/GB-month = ~$0.25/hour for 1.2 TB
- Only pay while cluster running
- Delete cluster → FSx deleted → no ongoing cost

### S3 Consistency
- FSx sees S3 changes with AutoImportPolicy: NEW_CHANGED
- May take a few minutes to sync
- Generally not an issue for software deployment

---

## Conclusion

**The S3-backed FSx approach is a paradigm shift for HPC on AWS:**

1. ✅ **Faster deployments:** 10 minutes vs 2+ hours
2. ✅ **Lower costs:** $0.16/month vs $1.50+/month
3. ✅ **Better performance:** Lustre vs NFS
4. ✅ **Easier management:** No AMIs, automatic versioning
5. ✅ **Multi-user ready:** Shared data, private workspaces
6. ✅ **Cloud-native:** S3 persistence, auto-scaling

**This approach should be the standard for deploying scientific applications on AWS ParallelCluster.**

---

## Related Documentation

- [CLEAN-DEPLOYMENT-PROCESS.md](../CLEAN-DEPLOYMENT-PROCESS.md) - Full deployment guide
- [TWO-FSX-ARCHITECTURE.md](../TWO-FSX-ARCHITECTURE.md) - Architecture details
- [QUICKSTART.md](../QUICKSTART.md) - Quick reference

---

**Author:** Scott Friedman (scofri@amazon.com)
**Project:** GCHP Benchmarking on AWS
**Date:** January 2026
