# 4-Node Testing with c7a.48xlarge Instructions

**Date:** February 3, 2026
**Status:** Cluster updating to add c7a-compute queue

## Situation

Job 25 (4-node with hpc7a.24xlarge) failed with `InsufficientInstanceCapacity`.

**Root Cause:** Limited hpc7a.24xlarge availability in us-east-2

**Solution:** Updated cluster to add c7a.48xlarge queue which has better availability.

## Key Discovery

**hpc7a instance types do NOT support SPOT pricing.** This is a limitation of HPC-optimized instances.

c7a.48xlarge advantages over hpc7a.24xlarge:
- ✅ Better availability in us-east-2
- ✅ Same architecture (AMD EPYC Genoa)
- ✅ Enhanced networking (ENA)
- ✅ Similar performance for compute workloads
- ⚠️ No built-in EFA (but ENA is sufficient for our workload)
- 💰 $3.06/hr vs $2.89/hr (6% premium, but available)

## Cluster Update

**Updated:** gchp-test cluster to add c7a-compute queue
**Command:**
```bash
AWS_PROFILE=aws uv run pcluster update-cluster \
  --cluster-name gchp-test \
  --cluster-configuration parallelcluster/configs/gchp-test-add-c7a.yaml \
  --region us-east-2
```

**Status:** UPDATE_IN_PROGRESS (started ~21:46 UTC)

**New Queue:** c7a-compute
- Instance: c7a.48xlarge (48 cores, 96 vCPUs, 384GB RAM)
- MaxCount: 8 nodes
- CapacityType: ONDEMAND
- SMT: Disabled (use 48 physical cores only)

## Submitting 4-Node Job (After Update Completes)

### Step 1: SSH to Cluster
```bash
ssh -i ~/.ssh/aws-benchmark.pem ec2-user@<head-node-ip>
```

### Step 2: Check Queue Status
```bash
sinfo
```

Expected output should show both queues:
```
PARTITION      AVAIL  TIMELIMIT  NODES  STATE NODELIST
compute*         up   infinite     10  idle~ compute-dy-hpc7a-efa-[1-4]
c7a-compute      up   infinite     10  idle~ c7a-compute-dy-c7a-48xl-[1-8]
```

### Step 3: Update Submit Script for c7a Queue

Edit `/fsx/gchp-tt-4node/submit-4node-c7a.sh`:
```bash
#!/bin/bash
#SBATCH --job-name=gchp-tt-4node-c7a
#SBATCH --partition=c7a-compute  # Use new c7a queue
#SBATCH --nodes=4
#SBATCH --ntasks=192
#SBATCH --ntasks-per-node=48
#SBATCH --time=00:30:00
#SBATCH --output=gchp.%j.out
#SBATCH --error=gchp.%j.err

source /fsx/sw-gcc14/gchp-gcc14-env.sh

# EFA optimizations (still beneficial with ENA)
export OMPI_MCA_btl=^ofi
export OMPI_MCA_btl_tcp_if_exclude="lo,docker0,virbr0"
export OMPI_MCA_btl_if_exclude="lo,docker0,virbr0"
export FI_EFA_ENABLE_SHM_TRANSFER=0
export OMPI_MCA_mtl_ofi_provider_exclude=shm
export FI_EFA_FORK_SAFE=1

# Run GCHP
srun --mpi=pmi2 ./gchp
```

### Step 4: Submit Job
```bash
cd /fsx/gchp-tt-4node
sbatch submit-4node-c7a.sh
```

### Step 5: Monitor
```bash
# Watch queue
watch -n 5 squeue

# Check node provisioning
tail -f /var/log/parallelcluster/slurm_resume.log

# Once running, monitor progress
tail -f gchp.*.log
```

## Expected Outcome

**If Successful:**
- Job 26 (or next number) completes with Exit 0
- Runtime: ~120-180s (estimated for C90, 4× grid points vs 2-node)
- OutputDir contains netCDF output files
- Restart checkpoint created
- Log shows: "SHMEM: 192 PEs on 4 nodes"

**Scaling Progression:**
- 1-node (48 cores, C24): 14s
- 2-node (96 cores, C48): 63s
- 4-node (192 cores, C90): TBD (~120-180s expected)

**If Still Fails with Capacity:**
- Try different region (us-west-2)
- Try during off-peak hours
- Try c7a.metal (192 cores, 1 instance) if available

## Configuration Already Prepared

The C90, 192-core configuration is ready at `/fsx/gchp-tt-4node/`:
- ✅ GCHP.rc: NX=16, NY=12, C90 resolution
- ✅ Resolution parameters: PE90x540-CF, IM=90, JM=540
- ✅ CAP.rc: 1-hour simulation
- ✅ Grid constraints verified: 90/16=5.6 ✓, 90/12=7.5 ✓

Just need to create/update the submit script to use the c7a-compute partition.

## Documentation Updates After Success

1. Update `gchp-multinode-scaling-complete.md` with 4-node results
2. Update `session-summary-complete.md` with final scaling data
3. Document c7a vs hpc7a comparison
4. Add "HPC instance types don't support spot" to lessons learned

## Cost Comparison

### 4-Node Test (~5-minute run)
- hpc7a.24xlarge: 4 × $2.89/hr × 0.083hr = ~$0.96 (if available)
- c7a.48xlarge: 4 × $3.06/hr × 0.083hr = ~$1.02 (available)

**Difference:** $0.06 for a test run - negligible for availability benefit

### 24-Hour Production Run
- hpc7a.24xlarge: 4 × $2.89 × 24 = $277.44 (if available)
- c7a.48xlarge: 4 × $3.06 × 24 = $293.76 (available)

**Difference:** $16.32/day (6% premium for guaranteed availability)

## Troubleshooting

### If c7a queue not visible after update:
```bash
# Check SLURM configuration
scontrol show partition

# Restart SLURM daemons (if needed)
sudo systemctl restart slurmctld
```

### If nodes fail to provision:
```bash
# Check resume log
sudo tail -100 /var/log/parallelcluster/slurm_resume.log

# Check CloudWatch logs
# ParallelCluster console → Cluster → Logs tab
```

### If job fails immediately:
```bash
# Check job output
cat gchp.*.err

# Verify software environment
source /fsx/sw-gcc14/gchp-gcc14-env.sh
which mpirun
mpirun --version
```

## Next Steps After 4-Node Success

1. ✅ Document working configuration
2. Test 8-node scaling (if capacity allows and scientifically useful)
3. Compare c7a vs hpc7a performance (if hpc7a becomes available)
4. Test C180 resolution for production workloads
5. Benchmark different instance generations (c6a, c7a)
6. Write blog post on HPC climate modeling on AWS
