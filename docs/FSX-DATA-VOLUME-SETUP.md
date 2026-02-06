# FSx Persistent Data Volume Setup

**One-time setup:** Create a persistent FSx volume that survives cluster deletion and is shared across all GCHP clusters.

## Why Persistent Data Volume?

**Traditional approach (bad):**
- Each cluster downloads 24+ GB of ExtData
- Takes 10-30 minutes per cluster
- Wastes time and bandwidth
- Data deleted when cluster deleted

**Persistent volume (good):**
- Download data once
- Instant access for all clusters
- Survives cluster deletion
- S3-backed for durability

**Cost:** ~$210/month for 1.2TB persistent volume (shared across unlimited clusters)

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ FSx Persistent Data Volume (READ-ONLY)                   │
│ /fsx/data                                                 │
│                                                           │
│ ├── GEOS_0.25x0.3125/  (meteorology)                    │
│ │   └── GEOS_FP/2019/07/ (9.5 GB/day)                   │
│ ├── HEMCO/              (emissions)                       │
│ │   └── CEDS/v2021-06/2019/ (9.5 GB/year)               │
│ ├── CHEM_INPUTS/        (chemistry data, 5.2 GB)         │
│ ├── bin/gchp            (GCC 14 optimized binary)        │
│ └── gchp-templates/     (template files)                 │
│                                                           │
│ S3 Integration:                                           │
│ - Auto-import from s3://gcgrid-aws/                      │
│ - Lazy loading (files downloaded on first access)        │
│ - Auto-export (new files synced back to S3)              │
└──────────────────────────────────────────────────────────┘
```

**How it works:**
1. FSx linked to S3 bucket (`s3://gcgrid-aws/`)
2. Files lazy-loaded on first access (instant mount, download as needed)
3. Multiple clusters can mount the same FSx volume (read-only)
4. Changes sync back to S3 (for updates/new data)

---

## Step 1: Create S3 Data Repository Bucket

```bash
# Create S3 bucket for GCHP data
aws s3 mb s3://gcgrid-aws --region us-west-2

# Set lifecycle policy (optional - move old data to Glacier)
cat > lifecycle-policy.json <<'EOF'
{
  "Rules": [
    {
      "Id": "ArchiveOldData",
      "Status": "Enabled",
      "Transitions": [
        {
          "Days": 90,
          "StorageClass": "GLACIER_IR"
        }
      ],
      "Filter": {
        "Prefix": "GEOS_FP/"
      }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket gcgrid-aws \
  --lifecycle-configuration file://lifecycle-policy.json
```

---

## Step 2: Create FSx Persistent Volume

### Option A: Using AWS Console

1. Go to FSx console: https://console.aws.amazon.com/fsx/
2. Click "Create file system"
3. Choose "Amazon FSx for Lustre"
4. Configuration:
   - **Deployment type:** PERSISTENT_2 (or PERSISTENT_1 for lower cost)
   - **Storage capacity:** 1200 GiB (1.2 TB)
   - **Throughput:** 250 MB/s/TiB
   - **Data compression:** LZ4
   - **Drive cache:** READ
5. Data repository association:
   - **Import path:** `s3://gcgrid-aws/`
   - **Import bucket:** `gcgrid-aws`
   - **Auto import policy:** NEW_CHANGED
   - **Export path:** `s3://gcgrid-aws/`
   - **Auto export policy:** NEW_CHANGED
6. Network:
   - **VPC:** (select your VPC)
   - **Subnet:** `subnet-0a73ca94ed00cdaf9` (or your subnet)
   - **Security groups:** Default or GCHP-specific
7. Tags:
   - Name: `gchp-persistent-data`
   - Project: `GCHP-Benchmarking`
8. Create file system (~10 minutes)

### Option B: Using AWS CLI

```bash
# Get VPC and subnet
VPC_ID="vpc-XXXXXXXX"
SUBNET_ID="subnet-0a73ca94ed00cdaf9"

# Get default security group
SG_ID=$(aws ec2 describe-security-groups \
  --region us-west-2 \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=group-name,Values=default" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

# Create FSx filesystem
aws fsx create-file-system \
  --region us-west-2 \
  --file-system-type LUSTRE \
  --storage-capacity 1200 \
  --subnet-ids $SUBNET_ID \
  --security-group-ids $SG_ID \
  --lustre-configuration "\
    DeploymentType=PERSISTENT_2,\
    PerUnitStorageThroughput=250,\
    DataCompressionType=LZ4,\
    DriveCacheType=READ,\
    DataRepositoryAssociations=[\
      {\
        DataRepositoryPath=s3://gcgrid-aws/,\
        FileSystemPath=/,\
        ImportedFileChunkSize=1024,\
        AutoImportPolicy=NEW_CHANGED,\
        AutoExportPolicy=NEW_CHANGED\
      }\
    ]" \
  --tags "Key=Name,Value=gchp-persistent-data" \
         "Key=Project,Value=GCHP-Benchmarking"

# Get filesystem ID
FSX_ID=$(aws fsx describe-file-systems \
  --region us-west-2 \
  --query 'FileSystems[?Tags[?Key==`Name` && Value==`gchp-persistent-data`]].FileSystemId' \
  --output text)

echo "FSx Filesystem ID: $FSX_ID"
```

### Option C: Using ParallelCluster (Temporary Bootstrap Cluster)

Create a minimal cluster just to populate the data volume:

```yaml
# fsx-data-bootstrap.yaml
Region: us-west-2
Image:
  Os: alinux2023

HeadNode:
  InstanceType: t3.medium
  Networking:
    SubnetId: subnet-0a73ca94ed00cdaf9
  Ssh:
    KeyName: gchp-benchmark

Scheduling:
  Scheduler: slurm
  SlurmQueues:
    - Name: compute
      ComputeResources:
        - Name: bootstrap
          InstanceType: c8a.xlarge
          MinCount: 0
          MaxCount: 1
      Networking:
        SubnetIds:
          - subnet-0a73ca94ed00cdaf9

SharedStorage:
  - Name: data
    StorageType: FsxLustre
    MountDir: /fsx/data
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: PERSISTENT_2
      DataCompressionType: LZ4
      PerUnitStorageThroughput: 250
      DriveCacheType: READ
      ImportPath: s3://gcgrid-aws/
      AutoImportPolicy: NEW_CHANGED
      ExportPath: s3://gcgrid-aws/
      AutoExportPolicy: NEW_CHANGED
```

```bash
# Create bootstrap cluster
AWS_PROFILE=aws uv run pcluster create-cluster \
  --cluster-name gchp-data-bootstrap \
  --cluster-configuration fsx-data-bootstrap.yaml \
  --region us-west-2

# Wait for creation
AWS_PROFILE=aws uv run pcluster describe-cluster \
  --cluster-name gchp-data-bootstrap \
  --region us-west-2
```

---

## Step 3: Populate Data Volume

SSH to the cluster (bootstrap or production):

```bash
ssh -i ~/.ssh/gchp-benchmark.pem ec2-user@<head-node-ip>
```

### Download GCHP Data

```bash
cd /fsx/data

# Option 1: Use intelligent downloader (recommended)
./scripts/gchp-data-sync.py \
  --config examples/c24-fullchem.yml \
  --data-root /fsx/data \
  --yes

# Option 2: Manual download (specific datasets)
# Meteorology (1 day = 9.5 GB)
aws s3 sync s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/07/ \
  ./GEOS_0.25x0.3125/GEOS_FP/2019/07/ \
  --no-progress

# Emissions (1 year = 9.5 GB)
aws s3 sync s3://gcgrid/HEMCO/CEDS/v2021-06/2019/ \
  ./HEMCO/CEDS/v2021-06/2019/ \
  --no-progress

# Chemistry data (5.2 GB)
aws s3 sync s3://gcgrid/CHEM_INPUTS/ ./CHEM_INPUTS/ \
  --exclude '*' \
  --include 'FAST_JX/v2024-05/*' \
  --include 'Linoz_200910/*' \
  --include 'OFFLINE_FIELDS/v2024-04/*' \
  --no-progress
```

### Install GCHP Binary (GCC 14)

```bash
# Copy pre-built binary from build artifacts
aws s3 cp s3://aws-instance-benchmarks-data/gchp/bin/gchp-gcc14 \
  /fsx/data/bin/gchp

chmod +x /fsx/data/bin/gchp

# Verify
ldd /fsx/data/bin/gchp
```

### Copy Template Files

```bash
# Copy GCHP templates to shared location
cd /tmp
git clone https://github.com/geoschem/GCHP.git
cd GCHP
git checkout 14.4.3

cp -r run/* /fsx/data/gchp-templates/

# Set permissions
chmod -R a+rX /fsx/data/gchp-templates/
```

### Verify Data Volume

```bash
du -sh /fsx/data/*

# Expected:
# 9.5G  /fsx/data/GEOS_0.25x0.3125
# 9.5G  /fsx/data/HEMCO
# 5.2G  /fsx/data/CHEM_INPUTS
# 81M   /fsx/data/bin
# 50M   /fsx/data/gchp-templates
# ~24.5 GB total
```

---

## Step 4: Get FSx Filesystem ID

```bash
# Get filesystem ID (needed for production cluster config)
FSX_ID=$(aws fsx describe-file-systems \
  --region us-west-2 \
  --query 'FileSystems[?Tags[?Key==`Name` && Value==`gchp-persistent-data`]].FileSystemId' \
  --output text)

echo "FSx Filesystem ID: $FSX_ID"

# Example output: fs-0123456789abcdef0
```

---

## Step 5: Delete Bootstrap Cluster (Keep FSx Volume)

If you used the bootstrap cluster approach:

```bash
# Delete cluster (FSx volume survives)
AWS_PROFILE=aws uv run pcluster delete-cluster \
  --cluster-name gchp-data-bootstrap \
  --region us-west-2

# Verify FSx still exists
aws fsx describe-file-systems \
  --region us-west-2 \
  --file-system-ids $FSX_ID
```

**Important:** ParallelCluster creates FSx with `DeletionPolicy: Retain` - the volume is NOT deleted when you delete the cluster.

---

## Step 6: Update Production Cluster Config

Edit `parallelcluster/configs/gchp-production.yaml`:

```yaml
SharedStorage:
  # Persistent data volume (mount existing)
  - Name: data
    StorageType: FsxLustre
    MountDir: /fsx/data
    FsxLustreSettings:
      FileSystemId: fs-0123456789abcdef0  # <-- SET THIS

  # Ephemeral scratch (created/deleted with cluster)
  - Name: scratch
    StorageType: FsxLustre
    MountDir: /fsx/scratch
    FsxLustreSettings:
      StorageCapacity: 1200
      DeploymentType: SCRATCH_2
```

---

## Step 7: Create Production Cluster

Now create the actual production cluster (mounts existing data volume):

```bash
./gchp-aws cluster create
```

This cluster will:
- Mount existing `/fsx/data` (instant, data already there)
- Create new `/fsx/scratch` (ephemeral, deleted with cluster)
- Have immediate access to all GCHP data

---

## Cost Analysis

### Persistent Data Volume (24/7)

**FSx PERSISTENT_2 (1.2 TB, 250 MB/s/TiB):**
- Storage: 1200 GB × $0.145/GB/month = $174/month
- Throughput: 250 MB/s × 1.2 TiB × $2.40/month = $2.88/month
- **Total: ~$177/month**

**FSx PERSISTENT_1 (1.2 TB, 200 MB/s/TiB) - lower cost alternative:**
- Storage: 1200 GB × $0.14/GB/month = $168/month
- Throughput: 200 MB/s × 1.2 TiB × $2.40/month = $2.30/month
- **Total: ~$170/month**

**S3 backup:**
- 25 GB × $0.023/GB/month = $0.58/month

**Grand total: ~$170-177/month** (shared across all clusters)

### Per-Cluster Costs (When Running)

**c8a.24xlarge Spot (96 cores):**
- Compute: ~$1.11/hour (70% discount)
- Scratch FSx: 1.2TB SCRATCH_2 = $0.17/hour
- **Total: ~$1.28/hour**

**Example: 100 simulations/month:**
- Compute time: 100 × 5 min = 8.3 hours
- Compute cost: 8.3 × $1.28 = **$10.60**
- Data volume: **$177/month** (persistent)
- **Monthly total: $187.60**

**Without persistent volume (download data each time):**
- Same 100 simulations
- Data download: 100 × 15 min = 25 hours
- Idle cost: 25 × $1.11 = **$27.75 extra**
- **Monthly total: $215.35** (+ wasted time)

**Savings: $27.75/month + convenience**

---

## Maintenance

### Add More Meteorology Data

```bash
# Download additional months
ssh -i ~/.ssh/gchp-benchmark.pem ec2-user@<head-node>

cd /fsx/data
aws s3 sync s3://gcgrid/GEOS_0.25x0.3125/GEOS_FP/2019/08/ \
  ./GEOS_0.25x0.3125/GEOS_FP/2019/08/

# Data auto-exported to S3 (available to all clusters immediately)
```

### Update GCHP Binary

```bash
# Copy new binary
aws s3 cp s3://my-bucket/gchp-new ./bin/gchp-new
chmod +x ./bin/gchp-new

# Test
./bin/gchp-new --version

# Swap
mv ./bin/gchp ./bin/gchp-old
mv ./bin/gchp-new ./bin/gchp
```

### Monitor FSx Usage

```bash
# Check capacity
df -h /fsx/data

# Check S3 sync status
sudo lfs df -h
```

### Backup to S3 (Automatic)

With `AutoExportPolicy: NEW_CHANGED`, all new/modified files automatically sync to S3.

Manual export if needed:
```bash
# Export specific directory
nohup find /fsx/data/GEOS_FP/2019/12 -type f -exec sudo lfs hsm_archive {} \; &
```

---

## Troubleshooting

### Data Not Accessible

```bash
# Check mount
df -h | grep /fsx/data

# Check FSx state
aws fsx describe-file-systems --file-system-ids $FSX_ID

# Force import from S3
sudo lfs hsm_restore /fsx/data/GEOS_FP/2019/07/GEOSFP.20190701.A1.025x03125.nc
```

### Slow First Access

FSx lazy-loads from S3. First access is slow, subsequent access is fast.

Prefetch commonly-used data:
```bash
# Warm cache for entire month
find /fsx/data/GEOS_FP/2019/07 -type f -exec sudo lfs hsm_restore {} \;

# Check prefetch status
lfs hsm_state /fsx/data/GEOS_FP/2019/07/*.nc
# Archived: not yet loaded
# Released: loaded but cache evicted
# Exists: in cache
```

### Out of Space

```bash
# Check usage
df -h /fsx/data

# Find large directories
du -sh /fsx/data/* | sort -rh | head -20

# Delete old data (also deletes from S3 with auto-export!)
rm -rf /fsx/data/GEOS_FP/2018/
```

### FSx Performance Issues

```bash
# Check FSx metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/FSx \
  --metric-name DataReadBytes \
  --dimensions Name=FileSystemId,Value=$FSX_ID \
  --start-time 2026-01-28T00:00:00Z \
  --end-time 2026-01-28T23:59:59Z \
  --period 3600 \
  --statistics Average

# Consider increasing throughput
aws fsx update-file-system \
  --file-system-id $FSX_ID \
  --lustre-configuration PerUnitStorageThroughput=500
```

---

## Summary

**One-time setup (10 minutes):**
1. Create S3 bucket (`s3://gcgrid-aws/`)
2. Create FSx persistent volume (1.2 TB)
3. Populate with GCHP data (24.5 GB)
4. Note FSx filesystem ID

**Every new cluster (2 minutes):**
1. Update config with FSx ID
2. Launch cluster (instant data access)
3. Start simulations

**Cost: ~$177/month** for persistent volume + **~$1.28/hour** when running simulations

**Time savings: 15-30 minutes per cluster launch**

---

**Next:** [Quick Start Guide](QUICK-START-GUIDE.md) for running your first simulation
