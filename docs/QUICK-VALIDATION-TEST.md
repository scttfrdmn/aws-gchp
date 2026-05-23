# Quick Stack Validation Test

## Goal

Validate the GCC 12.3 + GCHP 14.7.1 software stack with a minimal single-node test.

## Prerequisites

- ✅ Software stack exported to S3
- ✅ Builder cluster deleted
- ✅ Benchmark cluster created

## Test Configuration

**Instance:** c7a.48xlarge (1 node, 96 vCPUs, AMD Zen 4)  
**Resolution:** C24 (manageable size, quick test)  
**Duration:** 1 hour simulation  
**Chemistry:** TransportTracers (lightweight)  
**Cores:** 48 (half of instance)  
**Expected Runtime:** ~15-20 seconds  
**Cost:** ~$0.03 (5 min test @ $4.85/hr)

## Step-by-Step

### 1. Create Cluster

```bash
AWS_PROFILE=aws ~/.local/bin/pcluster create-cluster \
  --cluster-name gchp-validate \
  --cluster-configuration parallelcluster/configs/gchp-benchmark-1node.yaml \
  --region us-east-1
```

**Wait time:** ~8-10 minutes (FSx provisioning)

### 2. Get Head Node IP

```bash
AWS_PROFILE=aws ~/.local/bin/pcluster describe-cluster \
  --cluster-name gchp-validate \
  --region us-east-1 \
  --query 'headNode.publicIpAddress' \
  --output text
```

### 3. SSH to Cluster

```bash
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<IP-ADDRESS>
```

### 4. Run Validation Script

```bash
# Copy validation script from repo
curl -O https://raw.githubusercontent.com/scttfrdmn/aws-gchp/main/scripts/validate-stack.sh
chmod +x validate-stack.sh

# Run validation
./validate-stack.sh
```

**Expected output:**
```
==========================================
GCHP Stack Validation
==========================================

1. Loading environment...
✅ Loaded GCHP stack: gcc12.3-ompi4.1.7-gchp14.7.1
gcc (GCC) 12.3.0
mpirun (Open MPI) 4.1.7

2. Verifying GCC version...
   gcc (GCC) 12.3.0
   ✅ PASSED

3. Verifying OpenMPI version...
   mpirun (Open MPI) 4.1.7
   ✅ PASSED

... (additional checks)

==========================================
✅ ALL VALIDATION CHECKS PASSED
==========================================
```

### 5. Create Simple Test Run (Optional)

If validation passes and you want to run actual GCHP:

```bash
# Create run directory
cd /scratch
cp -r /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-14.7.1/run/GCHP c24-test
cd c24-test

# Configure for single-node C24
cat > setCommonRunSettings.sh << 'SETTINGS'
#!/bin/bash

# Simulation settings
CS_RES=24
TOTAL_CORES=48
NUM_NODES=1
NUM_CORES_PER_NODE=48

# Time settings
Start_Time="20190701 000000"
End_Time="20190701 010000"
Duration="00000001 000000"

# Grid decomposition (C24, 48 cores)
NX=8
NY=6

SETTINGS

# Initialize run directory
./createRunDir.sh

# Submit test
sbatch run.sh
```

Monitor:
```bash
squeue                    # Check job status
tail -f gchp.log         # Watch GCHP output
tail -f slurm-*.out      # Watch SLURM output
```

### 6. Save Results (If Test Run)

Before deleting cluster:

```bash
# Save any important outputs
aws s3 sync /scratch/c24-test/OutputDir/ \
  s3://my-bucket/validation-test/outputs/
```

### 7. Delete Cluster

```bash
# From local machine
AWS_PROFILE=aws ~/.local/bin/pcluster delete-cluster \
  --cluster-name gchp-validate \
  --region us-east-1
```

## Success Criteria

### Minimum (Validation Script Only)

- ✅ All validation checks pass
- ✅ GCC 12.3.0 verified
- ✅ OpenMPI 4.1.7 verified
- ✅ GCHP executable exists
- ✅ FSx mounts working

**Result:** Stack is functional, ready for real benchmarking

### Full (With Test Run)

- ✅ Validation checks pass
- ✅ GCHP completes 1-hour simulation
- ✅ No errors in logs
- ✅ Output files generated
- ✅ Runtime comparable to baseline (~15-20s)

**Result:** Stack fully validated, proceed to multi-node scaling tests

## Troubleshooting

### Validation Script Fails

**Check mounts:**
```bash
df -h | grep -E "fsx|input|scratch"
mount | grep fsx
```

**Check environment:**
```bash
which gcc
which mpirun
echo $LD_LIBRARY_PATH
```

### GCHP Fails to Run

**Check input data:**
```bash
ls -lh /input/
```

**Check logs:**
```bash
tail -100 gchp.log
tail -100 slurm-*.out
```

**Common issues:**
- Input data not imported from S3 yet (FSx lazy loading)
- Memory exhausted (try fewer cores)
- Domain decomposition invalid (check NX×NY = 48, constraints satisfied)

## Cost Estimate

| Activity | Duration | Cost |
|----------|----------|------|
| Cluster creation | 10 min | $0.81 |
| Validation only | 2 min | $0.16 |
| Test run (optional) | 5 min | $0.40 |
| **Total** | **~15 min** | **~$1.40** |

## Next Steps

**If validation succeeds:**
→ Proceed to `docs/BENCHMARKING-PLAN.md` for full test suite

**If validation fails:**
→ Debug and fix stack before expensive multi-node tests

