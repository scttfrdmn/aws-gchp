# FSx Export Policy: Builder vs User Clusters

## Critical Distinction

**Software and input data must be READ-ONLY on user clusters.**

### The Two Roles

| Role | Purpose | Software FSx | Input FSx | Scratch FSx |
|------|---------|--------------|-----------|-------------|
| **Builder** | Create software stack | ✅ ExportPath | N/A | N/A |
| **User** | Run GCHP simulations | ❌ NO ExportPath | ❌ NO ExportPath | User's choice |

---

## Builder Cluster Configuration

**Purpose:** Build software stack and export to S3

```yaml
# builder-us-east-1.yaml
SharedStorage:
  - Name: fsx
    MountDir: /fsx
    FsxLustreSettings:
      ImportPath: s3://gchp-shared-storage-us-east-1/
      ExportPath: s3://gchp-shared-storage-us-east-1/  # ✅ NEEDS export
```

**Why ExportPath is required:**
- Builder's job is to **create** the software stack
- Stack must be written to `/fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/`
- FSx exports to S3 so other clusters can import it
- **This is the ONLY time ExportPath should be used for software**

---

## User Cluster Configuration

**Purpose:** Import software stack (read-only) and run simulations

```yaml
SharedStorage:
  # 1. Software Stack - READ-ONLY
  - Name: software
    MountDir: /fsx
    FsxLustreSettings:
      ImportPath: s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
      # ❌ NO ExportPath - immutable resource

  # 2. Input Data - READ-ONLY
  - Name: input
    MountDir: /input
    FsxLustreSettings:
      ImportPath: s3://gcgrid/
      # ❌ NO ExportPath - immutable resource
  
  # 3. Scratch - USER'S CHOICE
  - Name: scratch
    MountDir: /scratch
    FsxLustreSettings:
      # Option A: No S3 backing (ephemeral)
      DeploymentType: SCRATCH_2
      
      # Option B: S3-backed (if user wants persistence)
      # ExportPath: s3://user-bucket/scratch/
      # AutoExportPolicy:
      #   Events: [NEW, CHANGED]
```

**Why NO ExportPath for software/input:**
- ✅ **Prevents accidental modification** - software and data are immutable
- ✅ **Faster performance** - no export overhead during operation
- ✅ **Clearer semantics** - FSx mount is explicitly read-only
- ✅ **No wasted exports** - nothing should ever be written back
- ✅ **No S3 pollution** - shared buckets stay clean

---

## What If Software Gets Modified?

**Q:** What happens if someone writes to /fsx/stacks/... on a user cluster without ExportPath?

**A:** The write succeeds locally in FSx, but:
- ❌ Never synced to S3
- ❌ Lost when cluster deletes
- ❌ Not visible to other clusters
- ✅ **This is exactly what we want!** - prevents corruption of shared resources

**Example scenario:**
```bash
# User accidentally creates a file in software stack
echo "test" > /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/test.txt

# File exists locally
ls /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/test.txt  # ✅ exists

# But it's NOT in S3
aws s3 ls s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/test.txt
# ❌ Not found

# Cluster deletes
pcluster delete-cluster --cluster-name my-cluster

# File is gone (as it should be)
# Original S3 stack is unchanged ✅
```

---

## FSx Export Behavior Summary

### With ExportPath

| Event | FSx Behavior | S3 Behavior |
|-------|--------------|-------------|
| File created in FSx | ✅ Exists | ❌ Not synced (unless AutoExportPolicy) |
| Manual export triggered | ✅ Exists | ✅ Synced to S3 |
| Cluster deleted | ❌ Lost | ✅ Persists (if exported) |

### Without ExportPath

| Event | FSx Behavior | S3 Behavior |
|-------|--------------|-------------|
| File created in FSx | ✅ Exists locally | ❌ Never synced |
| Cluster deleted | ❌ Lost | N/A |

---

## Builder Workflow

**The ONE time ExportPath is needed:**

```bash
# 1. Create builder cluster (has ExportPath)
pcluster create-cluster --cluster-name gchp-builder \
  --cluster-configuration configs/builder-us-east-1.yaml

# 2. SSH and build software stack
ssh ec2-user@builder
cd /fsx
bash build-gchp-stack.sh

# 3. Verify stack created
ls /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/

# 4. **CRITICAL:** Manually export before cluster delete
# Get FSx filesystem ID
aws fsx describe-file-systems --region us-east-1 \
  --query 'FileSystems[?Tags[?Key==`Name` && Value==`gchp-builder-fsx`]].FileSystemId' \
  --output text

# Trigger export
aws fsx create-data-repository-task \
  --file-system-id fs-XXXXXXXXX \
  --type EXPORT_TO_REPOSITORY \
  --paths /stacks/gcc12.3-ompi4.1.7-gchp14.7.1 \
  --region us-east-1

# Wait for export to complete (5-15 minutes)
aws fsx describe-data-repository-tasks --region us-east-1

# 5. Verify export succeeded
aws s3 ls s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/ \
  --recursive --human-readable

# 6. Delete cluster (safe now)
pcluster delete-cluster --cluster-name gchp-builder
```

---

## User Workflow

**Software/input are read-only - no export needed:**

```bash
# 1. Create user cluster (NO ExportPath on software/input)
pcluster create-cluster --cluster-name gchp-run \
  --cluster-configuration configs/gchp-benchmark-template.yaml

# 2. SSH and verify mounts
ssh ec2-user@cluster
ls /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/  # ✅ Software stack
ls /input/                                      # ✅ Input data
ls /scratch/                                    # ✅ Empty workspace

# 3. Load environment (read-only operation)
source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh

# 4. Run GCHP (writes to /scratch only)
cd /scratch
cp -r /fsx/stacks/.../gchp-14.7.1/run/GCHP my-run
cd my-run
sbatch run.sh

# 5. Before cluster delete, save important results
aws s3 sync /scratch/my-run/OutputDir/ s3://my-bucket/results/run-001/

# 6. Delete cluster
# - Software/input: Unchanged in S3 ✅
# - Scratch: Lost (as intended) ✅
pcluster delete-cluster --cluster-name gchp-run
```

---

## Security Benefits

### Without ExportPath on Software/Input

✅ **Immutability enforced** - Even if user tries to modify, changes never propagate  
✅ **No accidental corruption** - Shared resources protected  
✅ **Audit trail clean** - S3 bucket only changes when builder runs  
✅ **Multi-tenant safe** - Each user can't affect others  
✅ **Cost optimized** - No wasted export operations  

---

## Recommended Configurations by Cluster Type

### 1. Builder Cluster
```yaml
SharedStorage:
  - Name: fsx
    MountDir: /fsx
    FsxLustreSettings:
      ImportPath: s3://bucket/
      ExportPath: s3://bucket/  # ✅ Required
```

### 2. Benchmark Cluster (Ephemeral Scratch)
```yaml
SharedStorage:
  - Name: software
    FsxLustreSettings:
      ImportPath: s3://bucket/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
      # NO ExportPath ❌
  - Name: input
    FsxLustreSettings:
      ImportPath: s3://gcgrid/
      # NO ExportPath ❌
  - Name: scratch
    FsxLustreSettings:
      # NO ImportPath/ExportPath ❌ - pure ephemeral
```

### 3. Production Cluster (Persistent Scratch)
```yaml
SharedStorage:
  - Name: software
    FsxLustreSettings:
      ImportPath: s3://bucket/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
      # NO ExportPath ❌
  - Name: input
    FsxLustreSettings:
      ImportPath: s3://gcgrid/
      # NO ExportPath ❌
  - Name: scratch
    FsxLustreSettings:
      ImportPath: s3://user-bucket/scratch/
      ExportPath: s3://user-bucket/scratch/  # ✅ User's data
      AutoExportPolicy:
        Events: [NEW, CHANGED]
```

---

## Summary

| FSx Volume | Builder Cluster | User Cluster |
|------------|----------------|--------------|
| Software | ✅ ExportPath | ❌ NO ExportPath |
| Input Data | N/A | ❌ NO ExportPath |
| Scratch | N/A | User's choice |

**Golden Rule:** Only use ExportPath when you **intend** to write data back to S3. Software and input data are **immutable** on user clusters.
