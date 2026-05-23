# Building GCHP Software Stack

**Duration:** ~3.5 hours on c7a.8xlarge (32 cores)
**Location:** us-east-1 (free access to GEOS-Chem RODA data)  
**Output:** `s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/`  
**Optimizations:** `-O3 -march=znver3 -mtune=znver3` (Zen 3+ compatible)

## Prerequisites

- AWS CLI with `AWS_PROFILE=aws`
- SSH key: `~/.ssh/aws-gchp.pem`
- ParallelCluster 3.15.0

## Step 1: Create Builder Cluster

```bash
AWS_PROFILE=aws ~/.local/bin/pcluster create-cluster \
  --cluster-name gchp-builder \
  --cluster-configuration parallelcluster/configs/builder-us-east-1.yaml \
  --region us-east-1
```

**Wait 5-8 minutes** for cluster creation (FSx provisioning takes time).

## Step 2: Get Head Node IP

```bash
AWS_PROFILE=aws ~/.local/bin/pcluster describe-cluster \
  --cluster-name gchp-builder \
  --region us-east-1 \
  --query 'headNode.publicIpAddress' \
  --output text
```

## Step 3: SSH to Cluster

```bash
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<IP-ADDRESS>
```

## Step 4: Start Build

```bash
# On cluster head node
aws s3 cp s3://gchp-shared-storage-us-east-1/scripts/build-gchp-stack.sh /fsx/
chmod +x /fsx/build-gchp-stack.sh
cd /fsx

# Start build in background
nohup bash build-gchp-stack.sh > build.log 2>&1 &

# Verify process started
ps aux | grep build-gchp-stack

# Exit SSH (build continues)
exit
```

## Step 5: Monitor Build Progress

Check every 10-15 minutes:

```bash
# From your laptop
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<IP-ADDRESS> \
  'tail -20 /fsx/build-gcc12.3-ompi4.1.7-gchp14.7.1.log'
```

**Or** use SSM (no SSH key needed):

```bash
AWS_PROFILE=aws aws ssm send-command \
  --instance-ids <INSTANCE-ID> \
  --region us-east-1 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["tail -20 /fsx/build-gcc12.3-ompi4.1.7-gchp14.7.1.log"]' \
  --output text \
  --query 'Command.CommandId'

# Then get output (wait 3 seconds):
AWS_PROFILE=aws aws ssm get-command-invocation \
  --command-id <COMMAND-ID> \
  --instance-id <INSTANCE-ID> \
  --region us-east-1 \
  --query 'StandardOutputContent' \
  --output text
```

## Build Timeline (c7a.8xlarge - 32 cores)

| Component | Duration | Progress Indicator | Optimizations |
|-----------|----------|-------------------|---------------|
| System packages | 2 min | "Installing system prerequisites" | N/A |
| GCC 12.3.0 | ~30 min | "Building GCC" | Built from source |
| CMake 3.28.3 | 10 min | "Building CMake" | N/A |
| OpenMPI 4.1.7 | 5 min | "Building OpenMPI" | znver3 |
| HDF5 1.14.6 | 2 min | "Building HDF5" | znver3 |
| NetCDF-C 4.10.0 | 1 min | "Building NetCDF-C" | znver3 |
| NetCDF-Fortran 4.6.2 | 1 min | "Building NetCDF-Fortran" | znver3 |
| udunits2 2.2.28 | <1 min | "Building udunits2" | znver3 |
| ESMF 8.9.1 | 4 min | "Building ESMF" | znver3 |
| GCHP 14.7.1 | 15 min | "Building GCHP" | Inherits from dependencies |

**Total:** ~3.5 hours

**Optimization Flags:** All components built with `-O3 -march=znver3 -mtune=znver3` for AMD Zen 3+ compatibility (c6a, c7a, c8a, hpc6a, hpc7a)

## Step 6: Verify Build Complete

```bash
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<IP-ADDRESS>

# Check completion
tail /fsx/build-gcc12.3-ompi4.1.7-gchp14.7.1.log
# Should show: "Build complete!"

# Verify stack
source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh
gcc --version  # Should show: gcc (GCC) 12.3.0
mpirun --version  # Should show: mpirun (Open MPI) 4.1.7
```

## Step 7: Stack Auto-Exports to S3

FSx automatically exports to S3 via `ExportPath` configuration. **No manual sync needed.**

Verify:
```bash
AWS_PROFILE=aws aws s3 ls \
  s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/ \
  --recursive --human-readable --summarize
```

## Step 8: Delete Builder Cluster

```bash
AWS_PROFILE=aws ~/.local/bin/pcluster delete-cluster \
  --cluster-name gchp-builder \
  --region us-east-1
```

**Note:** FSx exports to S3 before deletion. Your build is preserved in S3.

## Troubleshooting

### Build Failed - Curl Package Conflict
If you see `curl-minimal conflicts with curl`:

The build script includes `--allowerasing` flag. If still failing, manually run:
```bash
sudo dnf install -y --allowerasing curl wget
```

### Build Process Died
Check if process is still running:
```bash
ps aux | grep build-gchp-stack
```

If not running, check error in log:
```bash
tail -50 /fsx/build.log
```

Common issues:
- Out of disk space: FSx needs 1.2TB minimum
- Out of memory: Build requires at least 8GB RAM
- Network timeout: EFA installation may fail, retry

### FSx Not Mounting
Check FSx status:
```bash
df -h | grep fsx
mount | grep fsx
```

If not mounted, check cluster status - FSx takes 5-8 minutes to provision.

## Cost

- **Builder cluster:** c7a.8xlarge (32 vCPUs, 64GB RAM)  
- **Duration:** ~3.5 hours (actual build time May 2026)
- **Cost:** ~$4.27 (3.5h @ $1.22/h)
- **S3 storage:** ~5-6GB (~$0.12-0.14/month)

**Note:** 32-core instance provides optimal balance of build speed and cost

## Using the Built Stack

See `docs/UPGRADE-TO-GCHP-14.7.1.md` for instructions on creating clusters that import this stack.

Quick summary:
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

Then on compute cluster:
```bash
source /fsx/gchp-env.sh
gcc --version  # Verify: 12.3.0
```

## AMD Zen Optimizations

The stack is built with AMD Zen 3 optimizations for broad compatibility:

### Optimization Flags
```bash
-O3 -march=znver3 -mtune=znver3
```

### Why Zen 3?
- **Compatibility:** Works on Zen 3, 4, and 5 architectures
- **Instance Coverage:** c6a, c7a, c8a, hpc6a, hpc7a
- **Performance:** Near-optimal performance across all Zen generations
- **Pragmatic:** Build once, deploy anywhere on AMD

### Alternative Optimizations

For generation-specific optimization (advanced users):
- **Zen 4:** `-march=znver4 -mtune=znver4` (c7a, c8a, hpc7a)
- **Zen 5:** `-march=znver5 -mtune=znver5` (c8a)

Modify `OPTFLAGS` in `build-gchp-stack.sh` before building.
