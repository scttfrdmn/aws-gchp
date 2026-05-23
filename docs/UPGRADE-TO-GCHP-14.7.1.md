# Upgrade to GCHP 14.7.1 - Complete Guide

**Date:** May 22, 2026
**Status:** Ready to build
**Estimated Duration:** 3-4 hours (build) + 1 hour (validation)

---

## Executive Summary

Upgrading from GCHP 14.5.0 to 14.7.1 requires **rebuilding the entire software stack** due to GCC compatibility constraints.

### Critical Constraint

**GCHP 14.7.1 requires GCC 10.x, 11.x, or 12.x (strictly <13)**

- ❌ Current stack: GCC 14.2.1 (incompatible)
- ✅ New stack: GCC 12.3.0 (compatible)
- ✅ Action: Build self-contained stack with everything including GCC

### What Changed

| Component | Old Version | New Version | Reason |
|-----------|-------------|-------------|--------|
| **GCC** | 14.2.1 | **12.3.0** | GCHP incompatible with GCC 13+ |
| **GCHP** | 14.5.0 | **14.7.1** | Target upgrade |
| **CMake** | 3.x | **3.28.3** | GCHP 14.7+ requires >=3.24 |
| **ESMF** | 8.6.1 | **8.9.1** | Updates available |
| **HDF5** | 1.14.3 | **1.14.6** | Patch release |
| **NetCDF-C** | 4.9.2 | **4.10.0** | Minor update |
| **NetCDF-Fortran** | 4.6.1 | **4.6.2** | Patch release |
| **OpenMPI** | 4.1.7 | **4.1.7** | No change (works) |

---

## Architecture Changes

### Old Approach (Deprecated)
```
s3://gchp-shared-storage-us-east-2/
├── sw/              # Unversioned, GCC 14 (incompatible)
└── GCHP/            # GCHP 14.5.0 source
```

### New Approach (Versioned Stacks)
```
s3://gchp-shared-storage-us-east-2/
└── stacks/
    └── gcc12.3-ompi4.1.7-gchp14.7.1/     # Self-contained, versioned
        ├── gcc-12.3.0/
        ├── cmake-3.28.3/
        ├── openmpi-4.1.7/
        ├── hdf5-1.14.6/
        ├── netcdf-c-4.10.0/
        ├── netcdf-fortran-4.6.2/
        ├── esmf-8.9.1/
        ├── gchp-14.7.1/
        ├── manifest.yaml             # Version tracking
        └── gchp-env.sh              # Environment setup
```

**Benefits:**
- ✅ Multiple stacks can coexist (test vs production)
- ✅ Complete version documentation in manifest.yaml
- ✅ Self-contained (no system dependencies)
- ✅ Easy rollback (change FSx ImportPath)
- ✅ S3-backed (persistent, survives cluster deletion)

---

## Step-by-Step Build Process

### Prerequisites

- AWS CLI configured with `AWS_PROFILE=aws`
- ParallelCluster 3.14+ installed (`uv tool install aws-parallelcluster`)
- S3 bucket: `s3://gchp-shared-storage-us-east-2/`
- SSH key: `~/.ssh/aws-gchp.pem`

### Step 1: Upload Build Script to S3

```bash
# From aws-gchp project root
AWS_PROFILE=aws aws s3 cp \
  parallelcluster/post-install/build-gchp-stack.sh \
  s3://gchp-shared-storage-us-east-2/scripts/build-gchp-stack.sh
```

### Step 2: Create Builder Cluster

```bash
AWS_PROFILE=aws uv run pcluster create-cluster \
  --cluster-name gchp-builder \
  --cluster-configuration parallelcluster/configs/builder-cluster.yaml \
  --region us-east-2
```

**Wait 5-10 minutes for cluster creation.**

### Step 3: SSH to Head Node

```bash
# Get head node IP from AWS console or:
AWS_PROFILE=aws uv run pcluster describe-cluster \
  --cluster-name gchp-builder \
  --region us-east-2 \
  --query headNode.publicIpAddress

# SSH in
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<HEAD-NODE-IP>
```

### Step 4: Run Build Script

```bash
# On head node
cd /fsx
bash build-gchp-stack.sh 2>&1 | tee build.log
```

**Expected duration:** 3-4 hours
- GCC 12.3: ~2 hours
- OpenMPI: ~20 min
- HDF5/NetCDF: ~30 min
- ESMF: ~30 min
- GCHP: ~30 min

**Monitor progress:**
```bash
# In another terminal
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<HEAD-NODE-IP>
tail -f /fsx/build-gcc12.3-ompi4.1.7-gchp14.7.1.log
```

### Step 5: Verify Build

```bash
# On head node, source environment
source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh

# Check versions
gcc --version          # Should show 12.3.0
mpirun --version       # Should show 4.1.7
ompi_info | grep -E "MCA mtl|MCA ess"  # Verify EFA (ofi) and PMI
```

**Expected output:**
```
✅ Loaded GCHP stack: gcc12.3-ompi4.1.7-gchp14.7.1
gcc (GCC) 12.3.0
mpirun (Open MPI) 4.1.7
```

### Step 6: Sync to S3

```bash
# On head node
AWS_PROFILE=aws aws s3 sync \
  /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/ \
  s3://gchp-shared-storage-us-east-2/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/ \
  --exclude "*.o" --exclude "*.mod" --exclude "*.a" \
  --exclude "**/build/*"
```

**Verify sync:**
```bash
AWS_PROFILE=aws aws s3 ls \
  s3://gchp-shared-storage-us-east-2/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/ \
  --recursive --human-readable --summarize
```

### Step 7: Delete Builder Cluster

```bash
# From local machine
AWS_PROFILE=aws uv run pcluster delete-cluster \
  --cluster-name gchp-builder \
  --region us-east-2
```

---

## Testing the New Stack

### Create Test Cluster

Update your cluster config to use new stack:

```yaml
SharedStorage:
  - Name: software-stack
    StorageType: FsxLustre
    MountDir: /fsx
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      ImportPath: s3://gchp-shared-storage-us-east-2/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
      ExportPath: s3://gchp-shared-storage-us-east-2/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
      AutoImportPolicy: NEW_CHANGED
```

Create cluster:
```bash
AWS_PROFILE=aws uv run pcluster create-cluster \
  --cluster-name gchp-test-14-7 \
  --cluster-configuration parallelcluster/configs/gchp-test.yaml \
  --region us-east-2
```

### Validation Tests

**1. Single-node test (C24, 48 cores)**
```bash
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<HEAD-NODE-IP>
source /fsx/gchp-env.sh

# Create run directory
cd /fsx
cp -r $GCHP_ROOT/run/GCHP.TransportTracers gchp-test-c24
cd gchp-test-c24

# Configure for C24, 48 cores (NX=8, NY=6)
# Submit job
sbatch submit.sh
```

**Expected:** ~14 seconds runtime (same as 14.5.0 baseline)

**2. Multi-node test (C48, 96 cores)**
- 2 nodes × 48 cores
- Expected: ~60-70 seconds
- Validates EFA + MPI load balancing

**3. Large-scale test (C90, 192 cores)**
- 4 nodes × 48 cores
- Expected: ~110-120 seconds
- Should see improved performance with MPI_LOAD_BALANCE

---

## Rollback Plan

If the new stack has issues:

```yaml
# Revert cluster config to use system GCC 11 (AL2023 default)
SharedStorage:
  - Name: workspace
    StorageType: FsxLustre
    MountDir: /fsx
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      # No ImportPath - start fresh
```

Then build GCHP 14.5.0 with system GCC 11.3.1.

---

## Cost Estimate

**Builder cluster:**
- c7a.4xlarge head node: $0.6144/hour
- Duration: 4 hours
- Total: ~$2.50

**S3 storage:**
- Software stack: ~5 GB
- Cost: ~$0.12/month

**Testing:**
- Single-node (1 hour): ~$0.19
- Multi-node (1 hour): ~$0.75

**Total upgrade cost:** ~$3.50

---

## Key GCHP 14.7.1 Features

### MPI Load Balancing (New)
- Enabled by default (`MPI_LOAD_BALANCE=ON`)
- Improves chemistry performance on multi-node runs
- Expected 5-10% improvement at scale

### CMake Requirement Change
- Minimum CMake version increased from 3.13 to 3.24
- Our stack includes CMake 3.28.3

### Compatibility Notes
- Works with OpenMPI 4.x (no upgrade needed)
- HDF5 1.14.x compatible (no migration to 2.x required)
- ESMF 8.6.1+ required (we use 8.9.1)

---

## Documentation Updates Needed

After successful validation:

1. Update `README.md`:
   - GCHP version badge: 14.5.0 → 14.7.1
   - GCC version: 14.2.1 → 12.3.0
   - Stack location in S3

2. Update `CLAUDE.md`:
   - Software stack versions
   - S3 paths for new versioned structure
   - Build strategy notes

3. Update cluster configs:
   - All `gchp-*.yaml` files to use new ImportPath
   - Document versioned stack approach

4. Create changelog:
   - Performance improvements observed
   - Any breaking changes from upgrade

---

## Success Criteria

✅ Build completes without errors
✅ GCC 12.3.0 installed and working
✅ All dependencies built successfully
✅ Environment script loads correctly
✅ Stack synced to S3
✅ Single-node C24 test runs successfully
✅ Multi-node C48 test shows expected scaling
✅ 4-node C90 test completes (MPI load balancing validated)

---

## Next Steps

1. **Phase 1:** Build new software stack (this document)
2. **Phase 2:** Validate performance on test cluster
3. **Phase 3:** Update all production configs
4. **Phase 4:** Document performance improvements
5. **Phase 5:** Blog post about GCHP on AWS

---

## References

- GCHP Documentation: https://gchp.readthedocs.io/
- GCHP 14.7.1 Release: https://github.com/geoschem/GCHP/releases/tag/14.7.1
- Software Stack Versioning: `docs/SOFTWARE-STACK-VERSIONING.md`
- Build Script: `parallelcluster/post-install/build-gchp-stack.sh`
- Builder Config: `parallelcluster/configs/builder-cluster.yaml`
