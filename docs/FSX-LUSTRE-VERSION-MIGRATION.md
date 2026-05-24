# FSx Lustre Version Migration (2.10 → 2.15)

**Date:** May 24, 2026  
**Status:** ✅ COMPLETED

## Problem

Amazon Linux 2023 ships with Lustre client 2.15, which **cannot mount** FSx Lustre 2.10 filesystems due to client/server version incompatibility.

### Compatibility Matrix

| OS | Lustre Client | FSx 2.10 | FSx 2.12 | FSx 2.15 |
|----|---------------|----------|----------|----------|
| AL2023 | 2.15 | ❌ NO | ✅ YES | ✅ YES |
| AL2 | 2.12 | ✅ YES | ✅ YES | ✅ YES |

## Solution

Migrated from FSx Lustre 2.10 to **Lustre 2.15** to enable AL2023 compatibility.

## Migration Steps

### 1. Delete Old FSx Filesystems (Lustre 2.10)

```bash
aws fsx delete-file-system --file-system-id fs-0d3ce3d7a149c6026  # Software
aws fsx delete-file-system --file-system-id fs-089602874f226827c  # Input
```

### 2. Create New FSx Filesystems (Lustre 2.15)

**Software Stack FSx:**
```bash
aws fsx create-file-system \
  --file-system-type LUSTRE \
  --file-system-type-version 2.15 \
  --storage-capacity 1200 \
  --subnet-ids subnet-2eec4a71 \
  --security-group-ids sg-b8fbc380 \
  --lustre-configuration "DeploymentType=SCRATCH_2,DataCompressionType=LZ4,ImportPath=s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/,AutoImportPolicy=NONE" \
  --tags "Key=Name,Value=gchp-software-stack-v2"
```

**Result:** `fs-0cd42f74bd682d07f`

**Input Data FSx:**
```bash
aws fsx create-file-system \
  --file-system-type LUSTRE \
  --file-system-type-version 2.15 \
  --storage-capacity 1200 \
  --subnet-ids subnet-2eec4a71 \
  --security-group-ids sg-b8fbc380 \
  --lustre-configuration "DeploymentType=SCRATCH_2,DataCompressionType=LZ4,ImportPath=s3://gcgrid/,AutoImportPolicy=NONE" \
  --tags "Key=Name,Value=gchp-input-data-v2"
```

**Result:** `fs-0ab32d8b6872eab86`

### 3. Update Cluster Configuration

**File:** `parallelcluster/configs/gchp-3fsx.yaml`

Changes:
- OS: `alinux2` → `alinux2023`
- Software FSx ID: `fs-0d3ce3d7a149c6026` → `fs-0cd42f74bd682d07f`
- Input FSx ID: `fs-089602874f226827c` → `fs-0ab32d8b6872eab86`

## New Infrastructure

### FSx Filesystems (Lustre 2.15)

| Purpose | FSx ID | Mount | Size | S3 Import Path |
|---------|--------|-------|------|----------------|
| Software Stack | `fs-0cd42f74bd682d07f` | `/fsx` | 1200 GB | `s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/` |
| Input Data | `fs-0ab32d8b6872eab86` | `/input` | 1200 GB | `s3://gcgrid/` |
| Scratch (ephemeral) | Created per-cluster | `/scratch` | 1200 GB | None (local only) |

### Cluster Configuration

- **OS:** Amazon Linux 2023
- **Region:** us-east-1
- **Subnet:** subnet-2eec4a71 (us-east-1a)
- **Security Group:** sg-b8fbc380

## Benefits

✅ **Full AL2023 Support**
- Modern OS with latest security updates
- GLIBC 2.33-2.35 (matches software stack)
- Lustre client 2.15 fully compatible

✅ **Software Stack Compatibility**
- GCC 12.3.0 built on AL2023 requires GLIBC 2.33+
- No rebuild required - existing stack works immediately

✅ **Future-Proof**
- Lustre 2.15 is the latest version (May 2026)
- Backwards compatible with future AL2023 updates

## Size Optimization Note

**Current:** 1200 GB minimum (FSx SCRATCH_2 limitation)
**Actual Usage:**
- Software stack: ~4 GB (0.3% utilization)
- Input data: TBD (GEOS-Chem data size varies)

**Future Optimization:**
Consider PERSISTENT_1 deployment type which allows smaller sizes (1200 GB minimum remains, but persistent filesystems have different cost structure).

## Cost Impact

**Before (Lustre 2.10):**
- Software FSx: ~$140/month
- Input FSx: ~$140/month
- Total: ~$280/month

**After (Lustre 2.15):**
- Same pricing (same deployment type and size)
- No cost change

## References

- [AWS FSx Lustre Client Compatibility Matrix](https://docs.aws.amazon.com/fsx/latest/LustreGuide/lustre-client-matrix.html)
- [FSx for Lustre Version 2.15 Release Notes](https://docs.aws.amazon.com/fsx/latest/LustreGuide/whatsnew.html)
