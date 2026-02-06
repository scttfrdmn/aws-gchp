# ExtData Setup for GCHP Benchmarks on AWS

## Problem Statement

GCHP requires ~1.1TB of ExtData (meteorology, emissions, chemistry inputs). When setting up new clusters, incomplete data transfers cause benchmark failures with cryptic "file not found" errors.

## Solution: Use AWS Open Data Registry

The GEOS-Chem data is available on AWS Open Data Registry at `s3://gcgrid` with **no-sign-request** access (free, fast, in-region transfers).

**DO NOT** attempt to rsync ExtData between clusters - it's slow, error-prone, and incomplete.

## Complete ExtData Setup Procedure

### IMPORTANT: Two Options for ExtData

**Option A: Full HEMCO Dataset (Recommended for Default Config)**
- Includes ALL datasets including CEDS (716GB), CH4, GFAS, etc.
- Required if using default HEMCO_Config.rc with CEDSv2 enabled
- Total size: ~1TB
- Sync time: 2-3 hours
- FSx requirement: 1.2-1.5TB minimum

**Option B: Minimal Dataset (Requires HEMCO_Config.rc Modification)**
- Excludes large datasets (CEDS, CH4, GFAS, etc.)
- Requires disabling CEDSv2 and switching to alternative inventory (EDGAR, CMIP6, etc.)
- Total size: ~20-25GB
- Sync time: 30-60 minutes
- FSx requirement: 50-100GB

**This guide covers Option A (full dataset)** - see "Alternative Configuration" section for Option B.

### Step 1: Sync Complete HEMCO Dataset from S3

```bash
# Run this on the cluster head node
# Full sync - no exclusions
aws s3 sync s3://gcgrid/HEMCO/ /fsx/ExtData/HEMCO/ --no-sign-request

aws s3 sync s3://gcgrid/CHEM_INPUTS/ /fsx/ExtData/CHEM_INPUTS/ --no-sign-request
```

**Expected sync time**: 2-3 hours for complete HEMCO dataset
**Expected total size**: ~1TB HEMCO + 5GB CHEM_INPUTS

### Step 2: Verify Critical Data

```bash
# Check that key datasets exist
ls -lh /fsx/ExtData/HEMCO/{GFED4,DMS,IODINE,NH3,Yuan_XLAI,AEIC2019}/

# Verify 2019 data for July benchmark
ls /fsx/ExtData/HEMCO/GFED4/v2023-03/2019/
ls /fsx/ExtData/HEMCO/Yuan_XLAI/v2021-06/*2019.nc
```

### Step 3: Check Disk Space

```bash
df -h /fsx
du -sh /fsx/ExtData/{HEMCO,CHEM_INPUTS}
```

Ensure you have sufficient space:
- **Minimum FSx size**: 50GB for ExtData + rundirs + binaries
- **Recommended**: 200GB for safety margin

## Automated Script

Use the provided script for complete setup:

```bash
# Located at: aws-gchp/scripts/sync-extdata-from-s3.sh
./scripts/sync-extdata-from-s3.sh
```

## Troubleshooting

### Job fails with "File not found" error

**Symptom**: GCHP aborts with:
```
HEMCO ERROR: REQUIRED FILE NOT FOUND /fsx/ExtData/HEMCO/.../file.nc
```

**Solution**: Sync the specific missing directory from S3:
```bash
aws s3 sync s3://gcgrid/HEMCO/DATASET_NAME/ \
    /fsx/ExtData/HEMCO/DATASET_NAME/ --no-sign-request
```

### "No space left on device"

**Symptom**: Sync or job fails with disk space errors

**Solution**:
1. Check what's using space: `du -sh /fsx/* | sort -h`
2. Delete unused HEMCO datasets (see exclusion list above)
3. Or expand FSx capacity in ParallelCluster config

### Slow S3 sync

**Expected rates**:
- Small files (<1MB): ~5-10 MB/s
- Large files (>100MB): ~100-200 MB/s

If slower, check:
- Network connectivity: `ping s3.amazonaws.com`
- Region mismatch: Ensure cluster is in same region as s3://gcgrid (us-east-1)

## What NOT To Do

❌ **Don't rsync between clusters** - incomplete, slow, SSH key issues
❌ **Don't sync entire HEMCO/** - includes 700GB+ of unused data
❌ **Don't skip verification** - better to catch issues before submitting 100 jobs
❌ **Don't use default FSx size** - ParallelCluster's 1.2TB default fills up quickly

## Critical Files for C24 Benchmarks (July 2019)

These MUST exist for benchmarks to run:

**HEMCO (emissions)**:
- `HEMCO/GFED4/v2023-03/2019/` - Biomass burning
- `HEMCO/DMS/v2021-07/` - DMS ocean emissions
- `HEMCO/IODINE/v2019-05/` - Iodine chemistry
- `HEMCO/NH3/v2019-08/` - Ammonia emissions
- `HEMCO/Yuan_XLAI/v2021-06/*2019.nc` - Leaf area index
- `HEMCO/AEIC2019/v2022-03/2019_monmean/` - Aircraft emissions

**CHEM_INPUTS (chemistry/meteorology)**:
- `CHEM_INPUTS/FAST_JX/v2024-05/` - Photolysis
- `CHEM_INPUTS/Linoz_200910/` - Stratospheric chemistry
- `CHEM_INPUTS/MODIS_LAI_201204/` - Land cover

## FSx for Lustre Configuration

**Recommended ParallelCluster config**:

```yaml
SharedStorage:
  - MountDir: /fsx
    Name: fsx-gchp
    StorageType: FsxLustre
    FsxLustreSettings:
      StorageCapacity: 1200  # 1.2TB minimum
      DeploymentType: SCRATCH_2  # Cost-effective
      # Optional: Link to S3 for automatic data import
      # ImportPath: s3://gcgrid/
      # DataCompressionType: LZ4
```

## Performance Notes

- **S3 sync speed**: ~100-150 MB/s average
- **Within-region transfers**: Free (no data egress charges)
- **Parallel sync**: Safe to run multiple `aws s3 sync` commands simultaneously
- **Resume capability**: `aws s3 sync` is idempotent - rerun if interrupted

## Lessons Learned: Inter-Cluster Rsync Challenges

When copying ExtData between clusters in January 2026, we encountered significant issues:

### Problem: Silent Rsync Failures
- **Initial rsync**: Transferred 1.1TB but hit disk full at 99.9%
- **Result**: Created 32+ empty directory structures without files
- **Root cause**: Rsync created directories but failed to transfer files when disk filled
- **Impact**: Validation tests failed incrementally on different missing datasets

### Solution: Systematic Verification
1. After large rsync operations, verify critical directories have files:
   ```bash
   for dir in NH3 STRAT SOILNOX TIMEZONES LIGHTNOX IODINE MASKS UVALBEDO; do
     echo "$dir: $(find /fsx/ExtData/HEMCO/$dir -type f | wc -l) files"
   done
   ```

2. Check rsync logs for connection errors:
   ```bash
   grep -i "error\|connection closed" /tmp/sync-*.log
   ```

3. Re-sync failed directories individually:
   ```bash
   rsync -avz -e "ssh -i key" source:/path/DATASET/ dest:/path/DATASET/
   ```

### Recommendation: Use S3 Directly
For new cluster setup, prefer S3 sync over inter-cluster rsync:
- **Faster**: In-region S3 transfers are optimized
- **More reliable**: No SSH connection issues
- **Free**: No data transfer costs within region
- **Resumable**: S3 sync handles interruptions gracefully

```bash
# Recommended approach for new clusters
aws s3 sync s3://gcgrid/HEMCO/ /fsx/ExtData/HEMCO/ --no-sign-request
aws s3 sync s3://gcgrid/CHEM_INPUTS/ /fsx/ExtData/CHEM_INPUTS/ --no-sign-request
```

## Updates and Versioning

- **GEOS-Chem data versions**: Check s3://gcgrid for latest
- **This doc updated**: January 2026
- **GCHP version**: 14.4.3
- **ParallelCluster**: 3.14.0

## See Also

- GEOS-Chem Input Data: http://geoschem.github.io/input-data-catalogs/
- AWS Open Data Registry: https://registry.opendata.aws/geoschem-input-data/
- GCHP Documentation: https://gchp.readthedocs.io/
