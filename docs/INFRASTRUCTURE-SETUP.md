# GCHP Infrastructure Setup Guide

Complete guide to setting up the shared GCHP infrastructure on AWS.

## Prerequisites

- AWS CLI configured with appropriate permissions
- AWS_PROFILE=aws configured
- SSH key: aws-gchp (private key at ~/.ssh/aws-gchp.pem)
- Region: us-east-1

## One-Time Infrastructure Setup

These resources are created once and shared by all users.

### 1. S3 Bucket for Software Stacks

```bash
AWS_PROFILE=aws aws s3 mb s3://gchp-shared-storage-us-east-1 --region us-east-1
```

**Cost:** ~$0.12/month (storage for 3.5GB software stack)

### 2. Permanent Input Data FSx

**Purpose:** GEOS-Chem input data (meteorology, emissions, chemistry)

**FileSystemId:** `fs-079ecada1405aa360`  
**ImportPath:** `s3://gcgrid/` (GEOS-Chem RODA)  
**Region:** us-east-1  
**Subnet:** subnet-2eec4a71 (us-east-1a)  
**Size:** 1.2TB SCRATCH_2  
**Cost:** ~$35/month  

**Status:** ✅ Created (May 2026)

This FSx stays running permanently. All users reference it by FileSystemId in their cluster configs.

**To stop/start for cost savings:**

```bash
# Stop (when not in use)
AWS_PROFILE=aws aws fsx update-file-system \
  --file-system-id fs-079ecada1405aa360 \
  --lustre-configuration AutomaticBackupRetentionDays=0 \
  --region us-east-1

# Note: SCRATCH_2 cannot be stopped - must delete to save costs
# Recreate when needed with same ImportPath
```

### 3. Software Stack in S3

**Current version:** gcc12.3-ompi4.1.7-gchp14.7.1  
**Location:** s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/  
**Size:** 3.5 GiB, 28,970 files  
**Status:** ✅ Built and exported (May 2026)

**Contents:**
- GCC 12.3.0
- OpenMPI 4.1.7 (EFA-enabled)
- HDF5 1.14.6
- NetCDF-C 4.10.0
- NetCDF-Fortran 4.6.2
- ESMF 8.9.1
- GCHP 14.7.1

**To rebuild:** See `docs/BUILD-GCHP-STACK.md`

## User Cluster Creation

Users create clusters that reference the shared infrastructure.

### Cluster Configuration

Use template: `parallelcluster/configs/gchp-benchmark-2fsx.yaml`

**Key sections:**

```yaml
SharedStorage:
  # Software stack - NEW FSx per cluster
  - Name: software
    MountDir: /fsx
    FsxLustreSettings:
      ImportPath: s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/

  # Input data - EXISTING permanent FSx
  - Name: input
    MountDir: /input
    FsxLustreSettings:
      FileSystemId: fs-079ecada1405aa360
```

### Create Cluster

```bash
AWS_PROFILE=aws ~/.local/bin/pcluster create-cluster \
  --cluster-name my-gchp-cluster \
  --cluster-configuration parallelcluster/configs/gchp-benchmark-2fsx.yaml \
  --region us-east-1
```

**Wait time:** ~8-10 minutes

### SSH to Cluster

```bash
# Get head node IP
AWS_PROFILE=aws ~/.local/bin/pcluster describe-cluster \
  --cluster-name my-gchp-cluster \
  --region us-east-1 | grep publicIpAddress

# SSH
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<IP>
```

### Load Environment

```bash
source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh
```

### Verify Setup

```bash
# Run validation script
curl -O https://raw.githubusercontent.com/scttfrdmn/aws-gchp/main/scripts/validate-stack.sh
chmod +x validate-stack.sh
./validate-stack.sh
```

## Infrastructure Costs

### Permanent (Always Running)

| Resource | Monthly Cost |
|----------|--------------|
| Input data FSx (1.2TB) | ~$35 |
| Software stack S3 (3.5GB) | ~$0.12 |
| **Total** | **~$35/month** |

### Per-User (While Cluster Running)

| Resource | Cost |
|----------|------|
| Software FSx (1.2TB) | ~$35/month |
| Head node (t3.xlarge) | ~$0.17/hour |
| Compute (hpc7a.24xlarge) | ~$2.89/hour/node |

**Example:** 4-node, 8-hour simulation = $92 compute + $4.70 head node + $9.33 FSx = **$106**

## Updating Software Stack

When new GCHP version or libraries are needed:

1. **Build new stack** (see `docs/BUILD-GCHP-STACK.md`)
2. **Export to S3** with new version name
3. **Update user configs** to reference new S3 path
4. **Old stack remains** in S3 for reproducibility

**Versioning:** `gcc{VERSION}-ompi{VERSION}-gchp{VERSION}`

## Disaster Recovery

### Software Stack Lost
- Rebuild from `parallelcluster/post-install/build-gchp-stack.sh`
- ~1.5 hours on c7a.8xlarge
- Cost: ~$1.80

### Input Data FSx Deleted
- Recreate with same ImportPath: s3://gcgrid/
- ~10 minutes to create
- Data immediately available (lazy-loaded from S3)

### S3 Bucket Deleted
- Software stack must be rebuilt
- No recovery for S3 data

## Security

### S3 Bucket Policy

Software stack can be shared across AWS accounts:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::ACCOUNT-ID:root"},
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::gchp-shared-storage-us-east-1/stacks/*",
      "arn:aws:s3:::gchp-shared-storage-us-east-1"
    ]
  }]
}
```

### FSx Access

Input data FSx can be shared via VPC peering or PrivateLink if needed for cross-account access.

## Monitoring

### Check FSx Status

```bash
# Input data FSx
AWS_PROFILE=aws aws fsx describe-file-systems \
  --file-system-ids fs-079ecada1405aa360 \
  --region us-east-1

# List all FSx filesystems
AWS_PROFILE=aws aws fsx describe-file-systems --region us-east-1
```

### Check S3 Stack

```bash
AWS_PROFILE=aws aws s3 ls \
  s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/ \
  --recursive --human-readable --summarize
```

### Check Costs

```bash
# FSx monthly costs
AWS_PROFILE=aws aws ce get-cost-and-usage \
  --time-period Start=2026-05-01,End=2026-05-31 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --filter file://fsx-filter.json
```

## Support

- **Issues:** https://github.com/scttfrdmn/aws-gchp/issues
- **GCHP Support:** support@geos-chem.org
- **AWS ParallelCluster:** https://docs.aws.amazon.com/parallelcluster/

## References

- Architecture: `docs/ARCHITECTURE.md`
- Building stacks: `docs/BUILD-GCHP-STACK.md`
- Benchmarking: `docs/BENCHMARKING-PLAN.md`
- Validation: `docs/QUICK-VALIDATION-TEST.md`
