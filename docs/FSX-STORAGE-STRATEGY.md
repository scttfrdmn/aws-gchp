# FSx Lustre Storage Strategy for GCHP

## Overview

AWS ParallelCluster GCHP deployments use FSx Lustre file systems for high-performance shared storage. This document explains the three-FSx architecture and when to use S3-backed vs non-backed FSx volumes.

## Three-FSx Architecture

### 1. Software Stack FSx (REQUIRED: S3-backed)

**Purpose:** Shared software stack (compilers, libraries, GCHP)

**Configuration:**
```yaml
SharedStorage:
  - Name: software
    StorageType: FsxLustre
    MountDir: /fsx
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      ImportPath: s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
```

**Characteristics:**
- **S3-backed:** REQUIRED for persistence
- **Read-only:** Imported once, used by all clusters
- **Persistent:** Stack survives cluster deletion
- **Shared:** Same stack used across multiple clusters

**Cost:** ~$0.12/month S3 storage (~5GB)

---

### 2. Input Data FSx (REQUIRED: S3-backed)

**Purpose:** GEOS-Chem input data (meteorology, emissions, chemistry)

**Configuration Option A - GEOS-Chem RODA (Recommended):**
```yaml
SharedStorage:
  - Name: input-data
    StorageType: FsxLustre
    MountDir: /input
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      ImportPath: s3://gcgrid/
```

**Configuration Option B - Custom Data:**
```yaml
SharedStorage:
  - Name: input-data
    StorageType: FsxLustre
    MountDir: /input
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      ImportPath: s3://my-bucket/gchp-inputs/
      ExportPath: s3://my-bucket/gchp-inputs/
```

**Characteristics:**
- **S3-backed:** REQUIRED (data too large for local storage)
- **Read-only:** Input data doesn't change during simulation
- **Large:** Typically 500GB - 2TB
- **Region matters:** Use `s3://gcgrid/` in us-east-1 for free data transfer

**Cost:** 
- GEOS-Chem RODA: Free (requester pays, no transfer in us-east-1)
- Custom data: ~$10-40/month S3 storage (500GB-2TB)

---

### 3. Scratch FSx (OPTIONAL: S3-backed)

**Purpose:** User workspace, run directories, simulation outputs

This is where the **strategic choice** happens:

## S3-Backed Scratch (Production Runs)

**When to use:**
- Long simulations (hours to days)
- Production runs with valuable results
- Results needed after cluster deletion
- Multiple clusters accessing same outputs
- Regulatory/compliance requirements for data preservation

**Configuration:**
```yaml
SharedStorage:
  - Name: scratch
    StorageType: FsxLustre
    MountDir: /scratch
    FsxLustreSettings:
      StorageCapacity: 2400
      DeploymentType: SCRATCH_2
      ImportPath: s3://my-bucket/scratch/
      ExportPath: s3://my-bucket/scratch/
      AutoImportPolicy: NEW_CHANGED
```

**Pros:**
- ✅ Automatic backup - outputs preserved in S3
- ✅ Survives cluster deletion
- ✅ Easy data transfer between clusters
- ✅ Can analyze results without cluster running
- ✅ Cost-effective long-term storage (S3 < FSx)

**Cons:**
- ❌ Export overhead: 10-15 min sync for 100GB+ outputs
- ❌ S3 storage costs accumulate
- ❌ Must manage S3 lifecycle policies
- ❌ Temporary files unnecessarily backed up

**Typical workflow:**
1. Cluster starts → FSx imports existing S3 data
2. GCHP runs → outputs written to `/scratch/`
3. FSx automatically exports changed files to S3
4. Cluster deletes → outputs remain in S3
5. New cluster imports previous outputs

**Cost example:**
- FSx: $1,300/TB/month (while running)
- S3: $23/TB/month (archive)
- For 1TB output: ~$43/month if kept 30 days, ~$23/month if archived

---

## Non-S3-Backed Scratch (Testing/Development)

**When to use:**
- Quick test runs (minutes to hours)
- Code debugging and development
- Parameter sensitivity studies (many short runs)
- Iterative model development
- Runs where outputs aren't needed long-term

**Configuration:**
```yaml
SharedStorage:
  - Name: scratch
    StorageType: FsxLustre
    MountDir: /scratch
    FsxLustreSettings:
      StorageCapacity: 2400
      DeploymentType: SCRATCH_2
      # No ImportPath or ExportPath
```

**Pros:**
- ✅ Faster - no S3 sync overhead
- ✅ Cheaper - no S3 storage costs
- ✅ Simpler - no export configuration
- ✅ Clean slate each cluster
- ✅ No S3 clutter from test runs

**Cons:**
- ❌ All data lost when cluster deleted
- ❌ Must manually backup important results
- ❌ No automatic data protection
- ❌ Can't resume interrupted runs on new cluster

**Typical workflow:**
1. Cluster starts → empty `/scratch/`
2. GCHP runs → outputs written to `/scratch/`
3. **Before cluster delete:** manually copy important results:
   ```bash
   aws s3 sync /scratch/important-run/ s3://my-bucket/results/run-001/
   ```
4. Cluster deletes → `/scratch/` destroyed

**Cost example:**
- FSx only: $1,300/TB/month (while running)
- For 8-hour test cluster with 1TB: ~$14
- Zero S3 costs

---

## Decision Matrix

| Use Case | Recommendation | Reason |
|----------|---------------|--------|
| Production simulation | S3-backed | Outputs are valuable, must preserve |
| Long runs (>24 hours) | S3-backed | Investment protection, can resume |
| Compliance/audit | S3-backed | Required data retention |
| Code development | Non-backed | Fast iteration, outputs not needed |
| Quick tests (<2 hours) | Non-backed | Cheaper, faster, cleaner |
| Parameter sweep | Non-backed* | Many short runs, aggregate results manually |
| Debugging | Non-backed | Don't need outputs preserved |

*For parameter sweeps: Run non-backed, manually copy final aggregated results to S3

---

## Hybrid Strategy (Recommended)

**Create two cluster configurations:**

### 1. Production Cluster (`configs/gchp-production.yaml`)
```yaml
# Software stack (S3-backed) + Input data (S3-backed) + Scratch (S3-backed)
SharedStorage:
  - Name: software
    # ... S3-backed software stack
  - Name: input
    # ... S3-backed input data
  - Name: scratch
    # ... S3-backed scratch with ExportPath
```

### 2. Development Cluster (`configs/gchp-dev.yaml`)
```yaml
# Software stack (S3-backed) + Input data (S3-backed) + Scratch (NOT S3-backed)
SharedStorage:
  - Name: software
    # ... S3-backed software stack
  - Name: input
    # ... S3-backed input data
  - Name: scratch
    # ... Non-backed scratch, no ImportPath/ExportPath
```

**Usage:**
```bash
# Production run
pcluster create-cluster --cluster-name gchp-prod \
  --cluster-configuration configs/gchp-production.yaml

# Development/testing
pcluster create-cluster --cluster-name gchp-dev \
  --cluster-configuration configs/gchp-dev.yaml
```

---

## Best Practices

### For S3-Backed Scratch:

1. **Use lifecycle policies** to archive old outputs:
   ```bash
   aws s3api put-bucket-lifecycle-configuration \
     --bucket my-bucket \
     --lifecycle-configuration file://lifecycle.json
   ```

2. **Organize by date/run:**
   ```
   s3://my-bucket/scratch/
   ├── 2026-05/
   │   ├── run-001-c180-validation/
   │   └── run-002-sensitivity/
   └── 2026-06/
   ```

3. **Monitor S3 costs:**
   ```bash
   aws s3 ls s3://my-bucket/scratch/ --recursive --summarize
   ```

4. **Export takes time** - wait before deleting cluster:
   ```bash
   # Check export status
   aws fsx describe-data-repository-tasks --region us-east-1
   ```

### For Non-Backed Scratch:

1. **Create a results copy script:**
   ```bash
   #!/bin/bash
   # save-results.sh
   RUN_NAME=$1
   aws s3 sync /scratch/${RUN_NAME}/ \
     s3://my-bucket/results/${RUN_NAME}/ \
     --exclude "*.tmp" \
     --exclude "GEOSChem.Restart.*"
   ```

2. **Add to SLURM job script:**
   ```bash
   #SBATCH --job-name=gchp-test
   
   # Run GCHP
   mpirun -np 48 ./gchp
   
   # Save important outputs before cluster terminates
   ./save-results.sh test-run-001
   ```

3. **Document what to save:**
   - Keep: Final outputs, diagnostics, logs
   - Skip: Restart files (unless needed), intermediate outputs, checkpoint files

---

## Cost Comparison Example

**Scenario:** 7-day simulation, 1TB output

### Option A: S3-Backed Scratch
- FSx (7 days): 7 × $43/day = $301
- S3 export: Free (in-region)
- S3 storage (30 days): $23
- **Total: $324**
- **Benefit:** Outputs preserved permanently

### Option B: Non-Backed Scratch
- FSx (7 days): 7 × $43/day = $301
- Manual S3 copy: Free
- S3 storage (30 days): $23
- **Total: $324**
- **Difference:** Must manually copy before cluster delete

### Option C: Non-Backed, No Preservation
- FSx (7 days): $301
- **Total: $301**
- **Savings: $23/month ongoing**
- **Risk:** Data loss if not manually backed up

---

## Migration Between Strategies

### Moving from Non-Backed to S3-Backed:

Already have important results on non-backed scratch?

```bash
# Before deleting cluster, sync to S3
aws s3 sync /scratch/ s3://my-bucket/scratch-backup/

# Create new S3-backed cluster with ImportPath
# pointing to s3://my-bucket/scratch-backup/
```

### Cleaning Up S3-Backed Scratch:

Too much data accumulated in S3?

```bash
# Archive old runs to Glacier
aws s3 cp s3://my-bucket/scratch/2025/ \
  s3://my-bucket/scratch-archive/2025/ \
  --recursive --storage-class GLACIER

# Delete after archiving
aws s3 rm s3://my-bucket/scratch/2025/ --recursive
```

---

## Summary

- **Software & Input FSx:** Always S3-backed (required for functionality)
- **Scratch FSx:** Choose based on use case
  - **S3-backed:** Production runs, long simulations, valuable outputs
  - **Non-backed:** Testing, development, short runs, disposable outputs
- **Hybrid approach:** Maintain both cluster configs for different needs
- **Default recommendation:** S3-backed for safety, non-backed for cost optimization

The choice isn't permanent - you can switch strategies cluster-by-cluster based on your current needs.

---

## Cross-Account Sharing

### Architecture Principle

**Shared resources are read-only and can be shared across AWS accounts:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    Shared S3 Buckets                            │
│  ┌──────────────────────┐      ┌─────────────────────────┐     │
│  │ Software Stack       │      │ Input Data (RODA)       │     │
│  │ s3://shared/stacks/  │      │ s3://gcgrid/            │     │
│  └──────────────────────┘      └─────────────────────────┘     │
│         Read-Only                       Read-Only               │
└─────────────────────────────────────────────────────────────────┘
                       ↓ ImportPath                    ↓
              ┌────────────────────┐          ┌────────────────────┐
              │   Account A        │          │   Account B        │
              │                    │          │                    │
              │  FSx: /fsx (RO)    │          │  FSx: /fsx (RO)    │
              │  FSx: /input (RO)  │          │  FSx: /input (RO)  │
              │  FSx: /scratch (RW)│          │  FSx: /scratch (RW)│
              │     ↓ ExportPath   │          │     ↓ ExportPath   │
              │  s3://acctA/out/   │          │  s3://acctB/out/   │
              └────────────────────┘          └────────────────────┘
                   User A Data                      User B Data
```

### Example: Sharing Software Stack Across Accounts

**Account A (Infrastructure Team) - Builds and shares stack:**

1. Build stack in Account A
2. Stack exports to: `s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/`
3. Add bucket policy to allow read from Account B:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccountBReadAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:root"
      },
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::gchp-shared-storage-us-east-1/stacks/*",
        "arn:aws:s3:::gchp-shared-storage-us-east-1"
      ]
    }
  ]
}
```

**Account B (End User) - Uses shared stack:**

```yaml
# In Account B's cluster config
SharedStorage:
  - Name: software
    StorageType: FsxLustre
    MountDir: /fsx
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      # ImportPath points to Account A's bucket
      ImportPath: s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
      # No ExportPath - read-only
  
  - Name: input
    StorageType: FsxLustre
    MountDir: /input
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      # GEOS-Chem RODA - already publicly accessible
      ImportPath: s3://gcgrid/
  
  - Name: scratch
    StorageType: FsxLustre
    MountDir: /scratch
    FsxLustreSettings:
      StorageCapacity: 2400
      DeploymentType: SCRATCH_2
      # User's private bucket in Account B
      ImportPath: s3://user-b-results/scratch/
      ExportPath: s3://user-b-results/scratch/
```

### Benefits of This Architecture

1. **One-time build:** Infrastructure team builds stack once in Account A
2. **Multiple consumers:** Unlimited users across any number of accounts
3. **Version control:** Stack versions managed centrally
4. **Cost efficiency:** Users don't pay for software storage (Account A pays ~$0.12/month)
5. **Consistency:** Everyone uses identical, validated stack
6. **Security:** Users can't modify shared stack, only read it
7. **Data sovereignty:** Each user's outputs stay in their own account/bucket

### Use Cases

**Research Lab:**
- Lab maintains shared stack in central account
- Students/postdocs run simulations in personal accounts
- Everyone uses same validated software
- Individual research data stays in personal buckets

**Multi-Institution Collaboration:**
- Lead institution hosts stack in public S3 bucket
- Partner institutions import read-only
- Each institution's data remains in their own account
- No data transfer costs (all in same region)

**Consulting/Commercial:**
- Vendor provides validated GCHP stack to clients
- Clients import into their own accounts
- Client simulation data never leaves their account
- Vendor can update stack versions centrally
