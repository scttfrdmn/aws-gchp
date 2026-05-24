# GCHP on AWS: User Guide for Researchers

**A step-by-step guide for running GCHP simulations on AWS ParallelCluster**

**⚠️ DRAFT - NOT YET VALIDATED**

This guide describes the intended workflow. Steps have NOT been tested end-to-end yet.
Use with caution and report issues.

**Last Updated:** 2026-05-24  
**Status:** Draft (awaiting validation)  
**Target Audience:** Researchers, graduate students, anyone running GCHP simulations

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Understanding the Infrastructure](#understanding-the-infrastructure)
3. [Creating Your First Cluster](#creating-your-first-cluster)
4. [Running a GCHP Simulation](#running-a-gchp-simulation)
5. [Monitoring Your Simulation](#monitoring-your-simulation)
6. [Retrieving Results](#retrieving-results)
7. [Cleaning Up](#cleaning-up)
8. [Cost Management](#cost-management)
9. [Troubleshooting](#troubleshooting)
10. [Advanced Topics](#advanced-topics)

---

## Prerequisites

### What You Need

**1. AWS Account Access**
- AWS account with programmatic access (Access Key ID + Secret Access Key)
- Sufficient permissions to create EC2 instances, FSx volumes, and VPCs
- Ask your administrator if unsure

**2. Local Computer Setup**
- macOS, Linux, or Windows with WSL2
- Python 3.9 or newer
- SSH client (built-in on macOS/Linux)

**3. AWS Configuration**
- AWS CLI installed
- AWS credentials configured (see below)
- SSH key pair created (see below)

### Initial Setup (One-Time)

**Step 1: Install AWS CLI**

```bash
# macOS (via Homebrew)
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Windows WSL2
# Same as Linux above
```

**Step 2: Configure AWS Credentials**

Ask your administrator for:
- AWS Access Key ID
- AWS Secret Access Key
- Default region: `us-east-1` (required for this project)

```bash
aws configure --profile gchp
# Enter Access Key ID when prompted
# Enter Secret Access Key when prompted
# Enter region: us-east-1
# Enter output format: json
```

**Step 3: Create SSH Key Pair**

```bash
# Create SSH key (press Enter for defaults)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/aws-gchp

# Import to AWS
aws ec2 import-key-pair \
  --key-name aws-gchp \
  --public-key-material fileb://~/.ssh/aws-gchp.pub \
  --region us-east-1 \
  --profile gchp
```

**Step 4: Install ParallelCluster CLI**

```bash
# Install uv (modern Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install ParallelCluster
uv pip install aws-parallelcluster==3.15.0
```

**Verify Installation:**

```bash
AWS_PROFILE=gchp pcluster version
# Should show: 3.15.0
```

---

## Understanding the Infrastructure

Before creating your cluster, understand what you're using:

### Permanent Infrastructure (Shared)

**You don't create these - they already exist, you just reference them:**

1. **Software FSx (`fs-0d3ce3d7a149c6026`)**
   - Mounted at `/fsx`
   - Contains: GCC compiler, GCHP 14.7.1, all dependencies
   - Read-only
   - Cost: $0 to you (shared infrastructure)

2. **Input Data FSx (`fs-089602874f226827c`)**
   - Mounted at `/input`
   - Contains: Meteorology, emissions, chemistry data from s3://gcgrid
   - Read-only
   - Cost: $0 to you (shared infrastructure)

### Your Resources (Created Per-Cluster)

**You create and pay for these:**

1. **Scratch FSx**
   - Mounted at `/scratch`
   - Your private workspace for run directories and outputs
   - Read-write
   - Cost: ~$140/month while cluster exists

2. **Head Node**
   - Small server that manages your cluster
   - Always running while cluster exists
   - Cost: ~$75/month (~$2.50/day)

3. **Compute Nodes**
   - Large servers that run your simulation
   - Only exist while jobs are running
   - Cost: $1.22/hour per node

**Total Cost Example:**
- Small test (1 day, 1 node, 8 hours): ~$15
- Medium run (1 week, 2 nodes average): ~$250
- Large campaign (1 month, 4 nodes continuous): ~$3,700

---

## Creating Your First Cluster

### Step 1: Download Cluster Configuration Template

Create a file `my-cluster.yaml`:

```yaml
# GCHP Cluster Configuration
# Save this as: my-cluster.yaml

Region: us-east-1

Image:
  Os: alinux2023

HeadNode:
  InstanceType: t3.xlarge
  Networking:
    SubnetId: subnet-2eec4a71  # us-east-1a
  Ssh:
    KeyName: aws-gchp
  Iam:
    AdditionalIamPolicies:
      - Policy: arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

Scheduling:
  Scheduler: slurm
  SlurmQueues:
    - Name: compute
      ComputeResources:
        - Name: c7a-nodes
          InstanceType: c7a.48xlarge  # 96 cores per node
          MinCount: 0
          MaxCount: 8  # Up to 8 nodes = 768 cores
          Efa:
            Enabled: false  # EFA disabled (known issue)
      Networking:
        SubnetIds:
          - subnet-2eec4a71
        PlacementGroup:
          Enabled: true
      CapacityType: ONDEMAND

SharedStorage:
  # Software stack (permanent, shared)
  - Name: software
    StorageType: FsxLustre
    MountDir: /fsx
    FsxLustreSettings:
      FileSystemId: fs-0d3ce3d7a149c6026  # GCHP 14.7.1

  # Input data (permanent, shared)
  - Name: input
    StorageType: FsxLustre
    MountDir: /input
    FsxLustreSettings:
      FileSystemId: fs-089602874f226827c  # s3://gcgrid data

  # Your scratch workspace (created with cluster)
  - Name: scratch
    StorageType: FsxLustre
    MountDir: /scratch
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
      DataCompressionType: LZ4

Tags:
  - Key: Project
    Value: GCHP
  - Key: Owner
    Value: YOUR-NAME-HERE  # Change this!
```

### Step 2: Create Cluster

```bash
# Choose a unique cluster name
CLUSTER_NAME="gchp-myproject-$(date +%Y%m%d)"

# Create cluster
AWS_PROFILE=gchp pcluster create-cluster \
  --cluster-name $CLUSTER_NAME \
  --cluster-configuration my-cluster.yaml \
  --region us-east-1
```

**Expected output:**
```json
{
  "cluster": {
    "clusterName": "gchp-myproject-20260524",
    "clusterStatus": "CREATE_IN_PROGRESS",
    ...
  }
}
```

### Step 3: Wait for Cluster Creation

**This takes 5-10 minutes** (FSx volumes need to be created and mounted)

```bash
# Monitor creation status
watch -n 30 "AWS_PROFILE=gchp pcluster describe-cluster \
  --cluster-name $CLUSTER_NAME \
  --region us-east-1 | grep clusterStatus"
```

**Wait until you see:**
```
"clusterStatus": "CREATE_COMPLETE"
```

Press `Ctrl+C` to exit watch.

### Step 4: Get Head Node IP Address

```bash
AWS_PROFILE=gchp pcluster describe-cluster \
  --cluster-name $CLUSTER_NAME \
  --region us-east-1 \
  | grep publicIpAddress

# Save this IP address!
```

---

## Running a GCHP Simulation

### Step 1: Connect to Head Node

```bash
# Replace X.X.X.X with your head node IP
ssh -i ~/.ssh/aws-gchp ec2-user@X.X.X.X
```

**First time connecting:** You'll see a security warning, type `yes` and press Enter.

### Step 2: Verify Environment

```bash
# Check mounted filesystems
df -h | grep -E "fsx|input|scratch"

# Expected output:
# /fsx     - 1.1T available (software)
# /input   - 1.1T available (input data)
# /scratch - 1.1T available (your workspace)

# Load GCHP environment
source /fsx/gchp-env.sh

# Verify software
gcc --version      # Should show: 12.3.0
mpirun --version   # Should show: Open MPI 4.1.7

# Check compute nodes are available
sinfo
# Should show: compute* with nodes in idle~ state
```

### Step 3: Create GCHP Run Directory

**GCHP provides an official script to create properly configured run directories.**

```bash
# Change to your scratch workspace
cd /scratch

# Run GCHP's run directory creation script
/fsx/gchp-14.7.1/run/createRunDir.sh
```

**The script will ask you questions:**

```
-----------------------------------------------------------
Choose simulation type:
-----------------------------------------------------------
  1. Full chemistry
  2. TransportTracers
  3. Carbon
  4. Tagged O3
```

**For your first test, choose `2` (TransportTracers) - it's simpler and faster.**

```
-----------------------------------------------------------
Choose meteorology source:
-----------------------------------------------------------
  1. MERRA-2 (Recommended)
  2. GEOS-FP
  3. GEOS-IT
```

**Choose `1` (MERRA-2 - recommended)**

```
-----------------------------------------------------------
Enter path where the run directory will be created:
-----------------------------------------------------------
```

**Type:** `/scratch`

```
-----------------------------------------------------------
Enter run directory name, or press return to use default:
-----------------------------------------------------------
```

**Type:** `my-first-run` (or press Enter for default)

```
-----------------------------------------------------------
Do you want to track run directory changes with git? (y/n)
-----------------------------------------------------------
```

**Type:** `n` (not needed for first test)

**Expected output:**
```
Created /scratch/my-first-run

  -- See CreateRunDirLogs/rundir_vars.txt for summary of default run directory settings
  -- This run directory is set up for simulation start date 20190101
  -- Restart files for this date at different grid resolutions are in the
     Restarts subdirectory
```

### Step 4: Configure Your Simulation

```bash
# Go to your run directory
cd /scratch/my-first-run

# Check current configuration
cat GCHP.rc | grep -E "^NX:|^NY:"
# Shows: NX: 4, NY: 24 (= 96 cores, matches one c7a.48xlarge node)

# Check simulation period
cat CAP.rc
# Shows: Start date, end date, and segment length
```

**For a quick test**, the default configuration is fine:
- **Resolution:** C24 (coarse, fast)
- **Duration:** Depends on what's in CAP.rc
- **Cores:** 96 (4 × 24) = one compute node

**To change duration** (optional):

```bash
# Edit CAP.rc
nano CAP.rc

# Change these lines:
BEG_DATE:     20190101 000000
END_DATE:     20190101 010000  # 1 hour run
JOB_SGMT:     00000000 010000  # 1 hour segments

# Save: Ctrl+O, Enter, Ctrl+X
```

### Step 5: Create Job Submission Script

Create `run-gchp.sh`:

```bash
nano run-gchp.sh
```

**Paste this content:**

```bash
#!/bin/bash
#SBATCH --job-name=gchp-test
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=96
#SBATCH --time=01:00:00
#SBATCH --output=gchp-%j.out
#SBATCH --error=gchp-%j.err

# Exit on error
set -e

# Unlimited stack
ulimit -s unlimited

# Load environment
source /fsx/gchp-env.sh

# Log configuration
echo "=========================================="
echo "GCHP Simulation"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_NODELIST"
echo "Cores: $SLURM_NTASKS"
echo "Start time: $(date)"
echo "=========================================="

# Configure run settings
source setCommonRunSettings.sh
source setRestartLink.sh

# Run GCHP
echo "Starting GCHP..."
mpirun -np 96 ./gchp

# Check success
if [ $? -eq 0 ]; then
  echo "=========================================="
  echo "GCHP completed successfully!"
  echo "End time: $(date)"
  echo "=========================================="
  echo ""
  echo "Output files:"
  ls -lh OutputDir/
else
  echo "GCHP failed with exit code $?"
  exit 1
fi
```

**Save:** `Ctrl+O`, `Enter`, `Ctrl+X`

**Make executable:**

```bash
chmod +x run-gchp.sh
```

### Step 6: Submit Job

```bash
sbatch run-gchp.sh
```

**Expected output:**
```
Submitted batch job 1
```

**Note the job number!**

---

## Monitoring Your Simulation

### Check Job Queue

```bash
squeue
```

**Output columns:**
- `JOBID` - Job number
- `ST` - Status (PD=pending, R=running, CF=configuring)
- `TIME` - Runtime so far
- `NODES` - Number of nodes
- `NODELIST` - Which nodes (or why waiting)

### Monitor Compute Nodes

```bash
sinfo
```

**Node states:**
- `idle~` - Powered off, ready to start
- `alloc` - Running your job
- `mix` - Partially used

**Note:** First job takes 2-3 minutes to boot compute nodes.

### Watch Log Files

```bash
# Main GCHP log (live updates)
tail -f gchp-1.out

# SLURM job output
tail -f slurm-*.out

# Check for errors
tail -f gchp-1.err
```

**Press `Ctrl+C` to stop following.**

### Check GCHP Progress

```bash
# GCHP creates timestamped logs
ls -lh *.log

# Watch simulation progress
tail -f gchp.*.log

# Look for lines like:
# YYYY-MM-DD HH:MM:SS - Current simulation time: 20190101 000000
```

---

## Retrieving Results

### Step 1: Check Output Files

```bash
# List outputs
ls -lh OutputDir/

# Should see NetCDF files:
# GEOSChem.Restart.20190101_010000z.c24.nc4
# GCHP.SpeciesConc.20190101_0000z.nc4
# etc.
```

### Step 2: Transfer to S3

**Create your personal results bucket** (one-time, from your laptop):

```bash
AWS_PROFILE=gchp aws s3 mb s3://my-gchp-results-YOUR-NAME --region us-east-1
```

**Upload results** (from cluster):

```bash
# On cluster
aws s3 sync OutputDir/ s3://my-gchp-results-YOUR-NAME/experiment-20260524/

# Verify upload
aws s3 ls s3://my-gchp-results-YOUR-NAME/experiment-20260524/
```

### Step 3: Download to Your Computer (Optional)

```bash
# From your laptop
AWS_PROFILE=gchp aws s3 sync \
  s3://my-gchp-results-YOUR-NAME/experiment-20260524/ \
  ~/gchp-results/experiment-20260524/
```

---

## Cleaning Up

**IMPORTANT:** Remember to delete your cluster when done to avoid ongoing charges!

### Step 1: Save Everything Important

```bash
# On cluster - make sure all results are in S3
aws s3 ls s3://my-gchp-results-YOUR-NAME/ --recursive
```

### Step 2: Exit Cluster

```bash
# Disconnect from head node
exit
```

### Step 3: Delete Cluster

```bash
# From your laptop
AWS_PROFILE=gchp pcluster delete-cluster \
  --cluster-name $CLUSTER_NAME \
  --region us-east-1
```

**This will:**
- Terminate head node
- Terminate any running compute nodes
- Delete your scratch FSx volume (**data lost!**)
- Keep software and input FSx (permanent infrastructure)

**Verify deletion:**

```bash
AWS_PROFILE=gchp pcluster list-clusters --region us-east-1
```

---

## Cost Management

### Estimating Costs Before Running

**Use this calculator:**

```
Head Node Cost:
  $75/month × (days running / 30) = Head node cost

Scratch FSx Cost:
  $140/month × (days running / 30) = Scratch FSx cost

Compute Cost:
  Nodes × Hours × $1.22/hour = Compute cost

Total = Head Node + Scratch FSx + Compute
```

**Examples:**

**1-day test (8 hours, 1 node):**
- Head: $75 × (1/30) = $2.50
- Scratch: $140 × (1/30) = $4.67
- Compute: 1 × 8 × $1.22 = $9.76
- **Total: ~$17**

**1-week campaign (7 days, 4 nodes average, 24/7):**
- Head: $75 × (7/30) = $17.50
- Scratch: $140 × (7/30) = $32.67
- Compute: 4 × 168 × $1.22 = $819.84
- **Total: ~$870**

### Monitoring Current Costs

```bash
# Check running resources
AWS_PROFILE=gchp pcluster list-clusters --region us-east-1

# See cluster details
AWS_PROFILE=gchp pcluster describe-cluster \
  --cluster-name $CLUSTER_NAME \
  --region us-east-1
```

**View costs in AWS Console:**
1. Go to https://console.aws.amazon.com/billing/
2. Click "Cost Explorer"
3. Filter by: Service = EC2, FSx
4. Group by: Tag:Owner (if you set tags)

### Cost-Saving Tips

1. **Delete clusters when not in use** - Head node + Scratch FSx cost ~$215/month
2. **Use smaller instance types for development** - c7a.2xlarge (8 cores) for testing
3. **Batch your simulations** - Create cluster once, run multiple jobs
4. **Test with short runs first** - 1-hour runs to validate configuration
5. **Monitor actively** - Check `squeue` regularly, cancel failed jobs

---

## Troubleshooting

### Cluster Creation Failed

**Check errors:**

```bash
AWS_PROFILE=gchp pcluster describe-cluster \
  --cluster-name $CLUSTER_NAME \
  --region us-east-1 \
  | grep -A 10 failures
```

**Common issues:**
- **VPC quota exceeded:** Contact AWS support to increase limit
- **FSx creation failed:** Check subnet availability zone (must support FSx)
- **SSH key not found:** Make sure you created and imported `aws-gchp` key

### Can't SSH to Head Node

**Check:**

```bash
# Verify cluster is running
AWS_PROFILE=gchp pcluster describe-cluster \
  --cluster-name $CLUSTER_NAME \
  --region us-east-1 \
  | grep clusterStatus
# Must be: CREATE_COMPLETE

# Verify SSH key permissions
chmod 600 ~/.ssh/aws-gchp

# Try verbose SSH
ssh -v -i ~/.ssh/aws-gchp ec2-user@X.X.X.X
```

### FSx Mounts Missing

**Check:**

```bash
df -h | grep -E "fsx|input|scratch"

# If missing, check FSx status
sudo dmesg | grep -i lustre

# Remount if needed (contact administrator)
```

### Compute Nodes Not Starting

**Check:**

```bash
sinfo

# If nodes stuck in idle~:
squeue
# Look for job status

# Check logs
tail -100 /var/log/slurmctld.log
```

**Common cause:** First job takes 2-3 minutes to boot nodes. Be patient!

### GCHP Job Failed

**Check error log:**

```bash
cat gchp-*.err
tail -100 slurm-*.out
```

**Common errors:**

**1. "Error in Read_Drydep_Inputs"**
- **Cause:** Input data not accessible
- **Fix:** Check symlinks: `ls -l *Dir`

**2. "MPI was not built with SLURM's PMI support"**
- **Cause:** Using `srun` instead of `mpirun`
- **Fix:** Change job script to use `mpirun -np XX ./gchp`

**3. "Restart file not found"**
- **Cause:** Wrong date or resolution
- **Fix:** Check `Restarts/` directory for available files

### Getting Help

1. **Check logs first:**
   - `gchp-*.err` - GCHP errors
   - `slurm-*.out` - Job scheduler output
   - `/var/log/slurmctld.log` - Cluster logs

2. **Search GCHP documentation:**
   - https://gchp.readthedocs.io/

3. **Contact support:**
   - GCHP: support@geos-chem.org
   - AWS/Cluster: Your administrator

4. **Project issues:**
   - https://github.com/scttfrdmn/aws-gchp/issues

---

## Advanced Topics

### Running Multi-Node Simulations

**Step 1: Understand grid constraints**

```
For CX resolution with NX × NY cores:
- X / NX >= 4
- X / NY >= 4
- NY divisible by 6

Examples:
- C90: NX=12, NY=42 = 504 cores (6 nodes × 96 cores = 576 cores available)
- C180: NX=30, NY=90 = 2,700 cores (29 nodes)
```

**Step 2: Update GCHP.rc**

```bash
cd /scratch/my-run

# Edit GCHP.rc
nano GCHP.rc

# Change:
NX: 12
NY: 42
IM: 90  # C90 resolution

# Save and exit
```

**Step 3: Update job script**

```bash
nano run-gchp.sh

# Change:
#SBATCH --nodes=6
#SBATCH --ntasks=504

# And:
mpirun -np 504 ./gchp
```

**Step 4: Submit**

```bash
sbatch run-gchp.sh
```

### Using Different GCHP Versions

**Check available versions:**

See project README for list of available `FileSystemId`s for different GCHP versions.

**In your cluster config:**

```yaml
SharedStorage:
  - Name: software
    FsxLustreSettings:
      FileSystemId: fs-XYZ123...  # Different version
```

### Archiving Entire Run Directories

```bash
# Archive complete run directory
cd /scratch
tar czf my-run-20260524.tar.gz my-run/

# Upload to S3
aws s3 cp my-run-20260524.tar.gz s3://my-gchp-results-YOUR-NAME/archives/

# Download later and extract
aws s3 cp s3://my-gchp-results-YOUR-NAME/archives/my-run-20260524.tar.gz .
tar xzf my-run-20260524.tar.gz
```

---

## Checklist for Success

**Before creating cluster:**
- [ ] AWS credentials configured (`aws configure`)
- [ ] SSH key created and imported (`aws-gchp`)
- [ ] Cluster config file edited with your name in tags
- [ ] Budget/cost estimate approved

**After cluster created:**
- [ ] Can SSH to head node
- [ ] All FSx volumes mounted (`/fsx`, `/input`, `/scratch`)
- [ ] Environment loads (`source /fsx/gchp-env.sh`)
- [ ] Compute nodes available (`sinfo`)

**Before submitting job:**
- [ ] Run directory created with `createRunDir.sh`
- [ ] Configuration reviewed (GCHP.rc, CAP.rc)
- [ ] Job script created and tested (`bash -n run-gchp.sh`)
- [ ] Monitoring plan ready (`tail -f` commands)

**After simulation completes:**
- [ ] Output files exist (`ls OutputDir/`)
- [ ] Results copied to S3 (`aws s3 sync ...`)
- [ ] S3 upload verified (`aws s3 ls ...`)
- [ ] Cluster deleted if no more work (`pcluster delete-cluster`)

---

## Quick Reference

### Essential Commands

```bash
# Cluster
pcluster list-clusters --region us-east-1
pcluster create-cluster --cluster-name NAME --cluster-configuration FILE.yaml --region us-east-1
pcluster delete-cluster --cluster-name NAME --region us-east-1

# SSH
ssh -i ~/.ssh/aws-gchp ec2-user@HEAD-NODE-IP

# On Cluster
source /fsx/gchp-env.sh                    # Load environment
sinfo                                       # View nodes
squeue                                      # View jobs
sbatch SCRIPT.sh                            # Submit job
scancel JOB-ID                              # Cancel job
tail -f gchp-*.out                          # Monitor output
aws s3 sync OutputDir/ s3://bucket/path/    # Archive results
```

### File Locations

```
/fsx/                    - Software stack (read-only)
/fsx/gchp-env.sh        - Environment setup script
/fsx/gchp-14.7.1/       - GCHP installation
/input/                  - Input data (read-only)
/scratch/                - Your workspace (read-write)
```

### Getting Unstuck

1. **"I can't SSH"** → Check cluster status, check SSH key permissions
2. **"No compute nodes"** → Wait 2-3 minutes, check `sinfo`
3. **"Job failed immediately"** → Check `gchp-*.err` file
4. **"GCHP can't find data"** → Check symlinks `ls -l *Dir`
5. **"How much is this costing?"** → Use cost calculator above

---

**Questions?** Contact your administrator or open an issue at https://github.com/scttfrdmn/aws-gchp/issues

**Last Updated:** 2026-05-24  
**Guide Version:** 1.0
