# Clean Deployment Guide

**Purpose:** End-to-end cluster deployment validation
**Date:** January 30, 2026

## Quick Start: Automated Deployment

```bash
./scripts/deploy-multinode-cluster.sh [cluster-name] [region]
```

Default: `gchp-test-multinode` in `us-east-2`

### What It Does
1. Validates AWS credentials and tools
2. Checks configuration and validates AZs
3. Verifies VPC endpoints exist
4. Deploys cluster
5. Monitors deployment (15 min)
6. Validates SSH, SLURM, FSx
7. Submits test job
8. Reports success

## Prerequisites

1. AWS credentials: `AWS_PROFILE=aws`
2. Tools: uv, pcluster 3.14.0+
3. SSH key: `~/.ssh/aws-benchmark.pem`
4. VPC endpoints (see `/docs/VPC-ENDPOINTS-SOLUTION.md`)

## Manual Deployment Steps

### 1. Validate Configuration
```bash
./scripts/validate-cluster-az.sh parallelcluster/configs/gchp-test-multinode.yaml us-east-2
```

### 2. Deploy
```bash
AWS_PROFILE=aws uv run pcluster create-cluster \
  --cluster-name gchp-test-multinode \
  --cluster-configuration parallelcluster/configs/gchp-test-multinode.yaml \
  --region us-east-2
```

### 3. Monitor
```bash
AWS_PROFILE=aws uv run pcluster describe-cluster \
  --cluster-name gchp-test-multinode \
  --region us-east-2
```

Watch for: `"clusterStatus": "CREATE_COMPLETE"`

### 4. Test
SSH to head node and submit test job to validate compute node bootstrap.

## Success Criteria

- Head node accessible via SSH
- SLURM running
- FSx mounted at /fsx
- Compute node bootstrap: ~1-2 minutes
- Job executes successfully

## Cleanup

```bash
AWS_PROFILE=aws uv run pcluster delete-cluster \
  --cluster-name gchp-test-multinode \
  --region us-east-2
```

## Documentation

- `/docs/VPC-ENDPOINTS-SOLUTION.md` - Compute connectivity
- `/docs/AVAILABILITY-ZONE-ISSUE.md` - AZ constraints
- `/scripts/deploy-multinode-cluster.sh` - Automation
