# GCHP on AWS: Architecture and Design Rationale

**Last Updated:** 2026-05-24  
**Status:** Production Architecture (3-FSx Model)  
**Version:** 2.0

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Diagram](#architecture-diagram)
3. [Component Details](#component-details)
4. [Design Rationale](#design-rationale)
5. [Cost Analysis](#cost-analysis)
6. [Lifecycle Management](#lifecycle-management)
7. [Troubleshooting](#troubleshooting)

---

## Executive Summary

This project implements a **production-ready, multi-user GCHP deployment on AWS** using ParallelCluster with a **three-FSx Lustre architecture** that separates:

1. **Permanent Infrastructure** (shared): Software stack + input data FSx
2. **Ephemeral Workspace** (per-cluster): Scratch FSx

**Key Innovations:**
- **Zero data duplication**: Everything S3-backed with lazy loading
- **Versioned software stacks**: Multiple GCHP versions coexist
- **Cost sharing**: $280/month infrastructure shared across unlimited users
- **No custom AMI**: Standard Amazon Linux 2023 + FSx
- **Clean lifecycle**: Automatic workspace cleanup

**Architecture Achievement:** First known production deployment of GCHP on AWS with shared, versioned infrastructure and proper read-only enforcement.

---

## Architecture Diagram

```
┌───────────────────────────────────────────────────────────────┐
│              Permanent Infrastructure (Shared)                 │
│                    $280/month total                            │
├───────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────┐     ┌──────────────────────────┐   │
│  │ Software FSx         │     │ Input Data FSx           │   │
│  │ fs-0d3ce3d7a149c6026 │     │ fs-089602874f226827c     │   │
│  ├──────────────────────┤     ├──────────────────────────┤   │
│  │ Type: SCRATCH_2      │     │ Type: SCRATCH_2          │   │
│  │ Size: 1.2TB          │     │ Size: 1.2TB              │   │
│  │ Cost: ~$140/month    │     │ Cost: ~$140/month        │   │
│  ├──────────────────────┤     ├──────────────────────────┤   │
│  │ ImportPath:          │     │ ImportPath:              │   │
│  │   s3://.../stacks/   │     │   s3://gcgrid/           │   │
│  │   gcc12.3-ompi4.1.7- │     │                          │   │
│  │   gchp14.7.1/        │     │ (GEOS-Chem RODA)         │   │
│  ├──────────────────────┤     ├──────────────────────────┤   │
│  │ ExportPath:          │     │ ExportPath:              │   │
│  │   (intentionally     │     │   s3://gcgrid/...        │   │
│  │    fails - RO)       │     │   (intentionally fails)  │   │
│  ├──────────────────────┤     ├──────────────────────────┤   │
│  │ Mount: /fsx          │     │ Mount: /input            │   │
│  │ Access: Read-Only    │     │ Access: Read-Only        │   │
│  └──────────────────────┘     └──────────────────────────┘   │
│                                                                 │
│  Contents:                     Contents:                       │
│  • GCC 12.3.0                  • GEOS meteorology             │
│  • OpenMPI 4.1.7               • HEMCO emissions              │
│  • GCHP 14.7.1                 • Chemistry inputs             │
│  • All dependencies            • Restart files                │
└───────────────────────────────────────────────────────────────┘
                               ↓
              Referenced by FileSystemId (EXISTING)
                               ↓
┌───────────────────────────────────────────────────────────────┐
│           Per-Cluster Resources (Ephemeral)                    │
│                ~$140/month + compute                           │
├───────────────────────────────────────────────────────────────┤
│                                                                 │
│  ParallelCluster: gchp-benchmark (or user-specific)           │
│  ├─ Head Node: t3.xlarge (~$2.50/day)                         │
│  ├─ Compute: c7a.48xlarge × 1-8 nodes (96 cores each)         │
│  ├─ Network: ENA 100 Gbps (EFA disabled - known issue)        │
│  └─ Scheduler: SLURM                                           │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐   │
│  │ Three Mounted FSx Volumes:                             │   │
│  ├────────────────────────────────────────────────────────┤   │
│  │ /fsx     → Software FSx (EXISTING, permanent)          │   │
│  │ /input   → Input FSx (EXISTING, permanent)             │   │
│  │ /scratch → Scratch FSx (NEW, managed, ephemeral)       │   │
│  │            ├─ Type: SCRATCH_2                           │   │
│  │            ├─ Size: 1.2TB                               │   │
│  │            ├─ No S3 backing                             │   │
│  │            ├─ Read-Write                                │   │
│  │            └─ Deleted with cluster                      │   │
│  └────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────┘
```

---

## Component Details

### 1. Software FSx (Permanent Infrastructure)

**FileSystemId:** `fs-0d3ce3d7a149c6026`  
**Purpose:** Shared, versioned software stack storage

**Specification:**
- **Type:** FSx Lustre SCRATCH_2
- **Size:** 1.2TB
- **ImportPath:** `s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/`
- **ExportPath:** Intentionally set to fail (read-only enforcement)
- **Mount Point:** `/fsx` on all clusters
- **Access Mode:** Read-only (enforced by S3 permissions)
- **Monthly Cost:** ~$140

**Contents:**
```
/fsx/
├── gcc-12.3.0/              # Compiler (built from source)
├── cmake-3.28.3/            # Build system
├── openmpi-4.1.7/           # MPI with PMI + EFA support
├── hdf5-1.14.6/             # Parallel HDF5
├── netcdf-c-4.10.0/         # NetCDF C library
├── netcdf-fortran-4.6.2/    # NetCDF Fortran bindings
├── udunits-2.2.28/          # Units library
├── esmf-8.9.1/              # Earth System Modeling Framework
├── gchp-14.7.1/             # GCHP source + build/bin/gchp
└── gchp-env.sh              # Environment setup script
```

**Optimization:** Built with `-O3 -march=znver3 -mtune=znver3` (AMD Zen 3+ compatible: c6a, c7a, c8a, hpc6a, hpc7a)

**Lazy Loading Behavior:**
- FSx imports file metadata immediately (instant mount)
- Actual file data pulled from S3 on first access
- Cached in Lustre for subsequent reads
- Example: `source /fsx/gchp-env.sh` triggers S3 fetch on first use

**Versioning Strategy:**
- Multiple software FSx volumes coexist (one per GCHP version)
- Users select version by referencing appropriate FileSystemId
- Old versions remain available for reproducibility

### 2. Input Data FSx (Permanent Infrastructure)

**FileSystemId:** `fs-089602874f226827c`  
**Purpose:** Shared GEOS-Chem input data (meteorology, emissions, chemistry)

**Specification:**
- **Type:** FSx Lustre SCRATCH_2
- **Size:** 1.2TB
- **ImportPath:** `s3://gcgrid/` (GEOS-Chem Registry of Open Data on AWS)
- **ExportPath:** `s3://gcgrid/FSxLustre...` (fails - read-only bucket, by design)
- **Mount Point:** `/input` on all clusters
- **Access Mode:** Read-only (gcgrid is public read-only)
- **Monthly Cost:** ~$140

**Contents (lazy-loaded):**
```
/input/
├── CHEM_INPUTS/              # Chemistry lookup tables
├── HEMCO/                    # Emissions inventories
├── GEOSCHEM_RESTARTS/        # Initial conditions (various dates/resolutions)
├── GEOS_0.5x0.625/MERRA2/    # 0.5° meteorology
├── GEOS_2x2.5/               # 2°×2.5° meteorology
└── GEOS_4x5/                 # 4°×5° meteorology
```

**Update Mechanism:**
- GEOS-Chem team updates `s3://gcgrid/` directly
- FSx automatically pulls new data on first access
- No FSx recreation needed
- Users always get latest data

### 3. Scratch FSx (Per-Cluster, Ephemeral)

**Purpose:** Private workspace for run directories and outputs

**Specification:**
- **Type:** FSx Lustre SCRATCH_2
- **Size:** 1.2TB
- **S3 Backing:** None (pure ephemeral storage)
- **Mount Point:** `/scratch`
- **Access Mode:** Read-write
- **Lifecycle:** Created with cluster, deleted with cluster
- **Monthly Cost:** ~$140 (while cluster exists)

**Typical Contents:**
```
/scratch/
└── gchp-fullchem/            # User run directory
    ├── CAP.rc                # Simulation timing
    ├── GCHP.rc               # Grid resolution (NX, NY)
    ├── geoschem_config.yml   # Simulation type
    ├── HEMCO_Config.rc       # Emissions
    ├── gchp -> /fsx/gchp-14.7.1/build/bin/gchp  # Symlink
    ├── ChemDir -> /input/CHEM_INPUTS
    ├── HcoDir -> /input/HEMCO
    ├── MetDir -> /input/GEOS_0.5x0.625/MERRA2
    ├── OutputDir/            # NetCDF outputs (10s-100s GB)
    └── Restarts/             # Checkpoint files
```

**Why No S3 Backing?**
- Outputs are large and simulation-specific
- User explicitly chooses what to archive
- No automatic S3 sync costs
- Faster (no background writes to S3)
- Clean ephemeral workspace

**User Archival Pattern:**
```bash
# Save important results before cluster deletion
aws s3 cp /scratch/OutputDir/ s3://my-bucket/results/ --recursive
```

---

## Design Rationale

### Why Three FSx Volumes?

**Alternatives Considered:**

**Option A: Single FSx with Data Repository Associations (DRAs)**
- ❌ Requires PERSISTENT_2 (~$175/TB/month vs $140/TB for SCRATCH_2)
- ❌ 25% more expensive: $525/month vs $420/month for 3×1.2TB
- ❌ Unnecessary: We don't need FSx-level replication (data is in S3)

**Option B: Copy gcgrid Data to Our S3 Bucket**
- ❌ `s3://gcgrid` is 10+ TB (petascale dataset)
- ❌ $230+/month just for S3 storage
- ❌ Must sync updates from gcgrid
- ❌ Lazy loading via ImportPath is far superior

**Option C: Custom AMI with Software Pre-Installed**
- ❌ Maintenance burden (rebuild AMI for every update)
- ❌ Can't have multiple versions simultaneously
- ❌ Region-specific (AMIs don't cross regions)
- ❌ Large AMI size (10s of GB)

**✅ Chosen: Three SCRATCH_2 FSx Volumes**
- ✅ Cheaper than PERSISTENT_2
- ✅ Data safety from S3 backing (FSx is just a cache)
- ✅ Clean separation of concerns
- ✅ Works within ParallelCluster limits (1 NEW + 20 EXISTING FSx)

### Why SCRATCH_2 Instead of PERSISTENT_2?

**SCRATCH_2 Characteristics:**
- ✅ $140/TB/month (vs $175/TB for PERSISTENT_2)
- ✅ Single S3 ImportPath (sufficient for our use)
- ✅ 200 MB/s/TB throughput
- ❌ No replication (single copy)
- ❌ Hardware failure = data lost (on FSx)

**BUT:** All our data lives in S3 (durable), FSx is just a cache!
- Software stack: `s3://gchp-shared-storage-us-east-1/stacks/...`
- Input data: `s3://gcgrid/` (managed by GEOS-Chem team)
- Scratch: Ephemeral by design (no backing needed)

**Decision:** SCRATCH_2 is the right choice. If an FSx fails, we recreate it and it re-imports from S3.

### Why Reference Existing FSx Instead of Creating New?

**ParallelCluster 3.15.0 Quotas:**
- **1 NEW** (managed) FSx Lustre per cluster
- **20 EXISTING** (external) FSx Lustre per cluster
- **21 total** FSx Lustre per cluster

**Our Model:**
- **Infrastructure team** creates permanent FSx once
- **All users** reference by FileSystemId (counts as EXISTING)
- **ParallelCluster** creates scratch FSx (counts as NEW)
- **Result:** 2 EXISTING + 1 NEW = 3 total ✅

**Benefits:**
- Consistent environment across all users
- Zero data duplication
- Infrastructure cost shared
- Simple user experience (just reference an ID)

### Why No S3 Backing for Scratch?

**With S3 Backing (ExportPath set):**
- FSx automatically syncs all writes to S3
- ❌ Costs: $0.005 per 1,000 PUT requests
- ❌ Everything exported (temp files, logs, intermediate outputs)
- ❌ User loses control over what to archive
- ❌ Slower (background sync overhead)

**Without S3 Backing (Current):**
- User explicitly archives important results
- ✅ No automatic sync costs
- ✅ User controls what to save
- ✅ Faster I/O (no background writes)
- ✅ Clean ephemeral workspace

**User Pattern:**
```bash
# At end of simulation
aws s3 sync /scratch/OutputDir/ s3://my-results/experiment-123/
```

---

## Cost Analysis

### Permanent Infrastructure (Shared)

| Component | Type | Size | Cost/Month | Shared? |
|-----------|------|------|------------|---------|
| Software FSx | SCRATCH_2 | 1.2TB | $140 | Yes (all users) |
| Input FSx | SCRATCH_2 | 1.2TB | $140 | Yes (all users) |
| Software S3 | Standard | ~5GB | $0.12 | Yes (all users) |
| **Total** | | | **~$280** | **Split across users** |

**Cost per User:**
- 10 users: $28/user/month for infrastructure
- 50 users: $5.60/user/month for infrastructure
- 100 users: $2.80/user/month for infrastructure

### Per-Cluster Costs (While Running)

| Component | Spec | Metric | Cost |
|-----------|------|--------|------|
| Head Node | t3.xlarge | 24/7 | ~$2.50/day = $75/month |
| Scratch FSx | SCRATCH_2 1.2TB | While exists | ~$140/month (prorated) |
| Compute | c7a.48xlarge | Per node-hour | $1.22/hour |

**Example Scenarios:**

**Scenario A: Light user (8 hours/month, 1 node)**
- Head node (delete after use): $0.67
- Scratch FSx (1 day): $4.67
- Compute: 8 hours × $1.22 = $9.76
- **Total:** ~$15/month + $5.60 infrastructure share = **$20.60/month**

**Scenario B: Heavy user (160 hours/month, 4 nodes avg)**
- Head node (always on): $75
- Scratch FSx (always on): $140
- Compute: 160 hours × 4 nodes × $1.22 = $780.80
- **Total:** ~$996/month + $5.60 infrastructure share = **$1,001/month**

### Data Transfer Costs

**All in us-east-1:**
- S3 → FSx: **FREE** (in-region)
- FSx → Compute: **FREE** (VPC internal)
- Compute → S3: **FREE** (in-region uploads)

**Why us-east-1?**
- `s3://gcgrid` is in us-east-1
- Other regions pay $0.02/GB cross-region transfer
- For 100GB simulation: us-east-1 = $0, us-west-2 = $2.00

---

## Lifecycle Management

### Infrastructure Team: One-Time Setup

**Step 1: Build New GCHP Version**
```bash
# On builder cluster
cd /fsx
bash build-gchp-stack.sh  # Builds to /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.8.0/

# FSx auto-exports to S3 (if ExportPath configured)
# Or manually sync:
aws s3 sync /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.8.0/ \
  s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.8.0/
```

**Step 2: Create Permanent Software FSx**
```bash
# Create FSx pointing to new stack
aws fsx create-file-system \
  --file-system-type LUSTRE \
  --storage-capacity 1200 \
  --subnet-ids subnet-2eec4a71 \
  --lustre-configuration \
    DeploymentType=SCRATCH_2,\
    ImportPath=s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.8.0/,\
    DataCompressionType=LZ4

# Note the FileSystemId: fs-xyz123abc...
```

**Step 3: Configure Security Group**
```bash
# Get network interface and security group
FSX_ENI=$(aws fsx describe-file-systems --file-system-ids fs-xyz123abc... \
  --query 'FileSystems[0].NetworkInterfaceIds[0]' --output text)

FSX_SG=$(aws ec2 describe-network-interfaces --network-interface-ids $FSX_ENI \
  --query 'NetworkInterfaces[0].Groups[0].GroupId' --output text)

# Allow port 988 from VPC CIDR
aws ec2 authorize-security-group-ingress \
  --group-id $FSX_SG \
  --protocol tcp \
  --port 988 \
  --cidr 172.31.0.0/16  # Adjust to your VPC CIDR
```

**Step 4: Document for Users**
Update project README or wiki:
```
Available GCHP Versions:
- fs-0d3ce3d7a149c6026 → GCHP 14.7.1 (gcc 12.3, openmpi 4.1.7)
- fs-xyz123abc...     → GCHP 14.8.0 (gcc 12.3, openmpi 4.1.7)

Input Data:
- fs-089602874f226827c → s3://gcgrid/ (GEOS-Chem RODA)
```

### End Users: Cluster Creation and Usage

**Step 1: Choose GCHP Version**

Edit cluster config `my-cluster.yaml`:
```yaml
SharedStorage:
  # Software (choose your version)
  - Name: software
    StorageType: FsxLustre
    MountDir: /fsx
    FsxLustreSettings:
      FileSystemId: fs-0d3ce3d7a149c6026  # GCHP 14.7.1
  
  # Input data (shared by all)
  - Name: input
    StorageType: FsxLustre
    MountDir: /input
    FsxLustreSettings:
      FileSystemId: fs-089602874f226827c
  
  # Scratch (created fresh)
  - Name: scratch
    StorageType: FsxLustre
    MountDir: /scratch
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
```

**Step 2: Create Cluster**
```bash
pcluster create-cluster \
  --cluster-name my-research-may2026 \
  --cluster-configuration my-cluster.yaml \
  --region us-east-1
```

**Step 3: Run GCHP**
```bash
# SSH to head node
ssh -i ~/.ssh/key.pem ec2-user@<head-node-ip>

# Load environment
source /fsx/gchp-env.sh

# Create run directory (following GCHP documentation)
cd /scratch
/fsx/gchp-14.7.1/run/createRunDir.sh
# ... follow prompts ...

cd /scratch/gchp-fullchem
sbatch gchp.run
```

**Step 4: Archive Results**
```bash
# Save outputs before cluster deletion
aws s3 sync /scratch/gchp-fullchem/OutputDir/ \
  s3://my-results/experiment-20260524/
```

**Step 5: Clean Up**
```bash
# From laptop
pcluster delete-cluster --cluster-name my-research-may2026 --region us-east-1

# Scratch FSx automatically deleted
# Software and input FSx remain (permanent infrastructure)
```

---

## Troubleshooting

### FSx Mount Failure: Port 988

**Symptom:**
```
ExistingFsxNetworkingValidator: The current security group settings on file storage 
'fs-089602874f226827c' does not satisfy mounting requirement. The file storage must be 
associated to a security group that allows inbound and outbound TCP traffic through 
ports [988]. Missing ports: [988]
```

**Cause:** Security group doesn't allow FSx Lustre protocol (port 988) from compute nodes

**Fix:**
```bash
# Get FSx security group
FSX_SG=$(aws ec2 describe-network-interfaces \
  --network-interface-ids $ENI_ID \
  --query 'NetworkInterfaces[0].Groups[0].GroupId' \
  --output text)

# Add VPC CIDR to security group
aws ec2 authorize-security-group-ingress \
  --group-id $FSX_SG \
  --protocol tcp \
  --port 988 \
  --cidr 172.31.0.0/16  # Replace with your VPC CIDR
```

### GCHP Data Access Error

**Symptom:**
```
GEOS-Chem ERROR [0000]: Error encountered in "Read_Drydep_Inputs"!
```

**Cause:** Input data not accessible (FSx not mounted or symlinks wrong)

**Diagnosis:**
```bash
# Check FSx mounts
df -h | grep -E "/fsx|/input|/scratch"

# Check run directory symlinks
ls -l /scratch/gchp-fullchem/
# Should show:
# ChemDir -> /input/CHEM_INPUTS
# HcoDir -> /input/HEMCO  
# MetDir -> /input/GEOS_0.5x0.625/MERRA2
```

**Fix:** Use official `createRunDir.sh` script, which creates correct symlinks automatically

### EFA Bootstrap Failure (Known Issue)

**Symptom:**
- Compute nodes stuck in `MIXED+CLOUD+NOT_RESPONDING+POWERING_UP` state
- `scontrol show node` shows `SlurmdStartTime=None` after 10+ minutes
- Only when `Efa: Enabled: true` with c7a.48xlarge instances

**Root Cause:** Unknown. Possibly ParallelCluster 3.15.0 + c7a + EFA driver interaction.

**Workaround:**
```yaml
ComputeResources:
  - Name: c7a-nodes
    InstanceType: c7a.48xlarge
    Efa:
      Enabled: false  # Use ENA instead (still 100 Gbps)
```

**Status:** Under investigation. Multi-node MPI works fine with ENA. EFA resolution deferred.

### MPI Launch: srun vs mpirun

**Symptom:**
```
The application appears to have been direct launched using "srun",
but OMPI was not built with SLURM's PMI support
```

**Cause:** Our OpenMPI IS built with PMI (`ess:pmi` confirmed), but `srun` requires additional PMIx configuration

**Fix:** Use `mpirun` instead:
```bash
# Wrong:
srun -n 96 ./gchp

# Correct:
mpirun -np 96 ./gchp
```

**Why:** Our OpenMPI build has PMI support but ParallelCluster's SLURM expects mpirun for job launching.

---

## References

- **GCHP Documentation:** https://gchp.readthedocs.io/
- **AWS ParallelCluster:** https://docs.aws.amazon.com/parallelcluster/
- **FSx for Lustre:** https://docs.aws.amazon.com/fsx/latest/LustreGuide/
- **GEOS-Chem RODA:** https://registry.opendata.aws/geoschem/
- **Project Repository:** https://github.com/scttfrdmn/aws-gchp

---

**Document Version:** 2.0  
**Architecture Version:** 3-FSx Production Model  
**Author:** Scott Friedman  
**License:** MIT
