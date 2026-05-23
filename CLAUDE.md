# AWS GCHP Benchmarking Project

## Project Overview
Comprehensive benchmarking of GCHP (GEOS-Chem High Performance) on AWS ParallelCluster across multiple instance types, generations (5-8), and architectures (Intel, AMD, Graviton).

**Date Context:** January 2026 - Using latest software versions

## Documentation Policy
**DO NOT create session logs, build summaries, or update documents** (e.g., BUILD-SESSION-*.md, SESSION-SUMMARY-*.md). Only update existing documentation when significant architectural changes occur. Focus on getting work done, not documenting every session.

## Goals
1. **Definitive benchmarking for GCHP on AWS** - Start from 8th generation instances and work backwards
2. **Performance progression analysis** - Track application performance across hardware generations

## Environment Setup

### Region Selection
**Deploy in us-east-1** - GEOS-Chem RODA data (`s3://gcgrid`) is in us-east-1 for free in-region transfers. Other regions incur cross-region data transfer costs ($0.02/GB).

**Important:** Use **us-east-1a** subnet - FSx SCRATCH_2 is not available in us-east-1e. Use `scripts/find-fsx-subnet.sh` to find compatible subnets.

### AWS Profile
**ALWAYS use:** `AWS_PROFILE=aws` for all AWS CLI and ParallelCluster commands

### SSH Key
**Standard key:** `aws-gchp` - All configs use this key pair. Private key: `~/.ssh/aws-gchp.pem`

### Python Environment
**Use uv exclusively** - Project has `.venv` in root directory

```bash
# Run ParallelCluster commands:
AWS_PROFILE=aws uv run pcluster <command>

# Example:
AWS_PROFILE=aws uv run pcluster list-clusters --region us-west-2
```

## Software Stack

### Current Production Stack (GCC 12.3 + GCHP 14.7.1) ✅
**Status:** Production-ready, built May 2026

- **AWS ParallelCluster:** 3.15.0
- **Compiler:** GCC 12.3.0 (built from source, Zen 3 optimizations: -O3 -march=znver3 -mtune=znver3)
- **MPI:** OpenMPI 4.1.7
  - **mtl:ofi** (EFA fabric transport) ✅
  - **ess:pmi** (SLURM process management) ✅
  - Libfabric with EFA provider
- **HDF5:** 1.14.6
- **NetCDF-C:** 4.10.0
- **NetCDF-Fortran:** 4.6.2
- **udunits2:** 2.2.28
- **ESMF:** 8.9.1
- **GCHP:** 14.7.1

**Location:** `/fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/`
**S3:** `s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/`

**Compatibility:** Zen 3+ AMD instances (c6a, c7a, c8a, hpc6a, hpc7a)

### Future Toolchains (Planned)
- **Intel Toolchain:** oneAPI 2025.3
- **AMD Toolchain:** AOCC 5.0.0 (Zen 5 support)
- **ARM Toolchain:** ACfL 24.04

## Architecture: FSx-Based Software Stack

**Current Approach:** Everything on FSx Lustre (no custom AMI required)
- **Simplicity:** Use standard Amazon Linux 2023 AMI
- **Maintainability:** Multiple software versions can coexist on /sw
- **Cost:** S3-backed FSx volumes (~$1-2/month storage)
- **Flexibility:** Easy to update, test different toolchains

### Three-FSx Architecture

**Core principle:** Shared, read-only resources (software + data) hydrate from S3. User workspace (scratch) is private and local.

1. **Software Stack** (`/sw` or `/fsx`)
   - Built once by infrastructure team
   - **S3-backed (REQUIRED):** ImportPath from shared S3 bucket
   - Example: `s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/`
   - **Read-only:** Imported at cluster creation, never modified
   - **Cross-account capable:** Can share via S3 bucket policy
   - Contains: GCC + OpenMPI + HDF5 + NetCDF + ESMF + GCHP
   - **Persistent:** Stack lives in S3, independent of any cluster

2. **Input Data** (`/input`)
   - Met fields, emissions, chemistry data
   - **S3-backed (REQUIRED):** ImportPath from GEOS-Chem RODA or shared bucket
   - Example: `s3://gcgrid/` (GEOS-Chem RODA - publicly accessible)
   - **Read-only:** Imported at cluster creation, never modified
   - **Cross-account capable:** GEOS-Chem RODA already shared globally
   - **Permanent shared resource:** Multiple users/accounts access same data

3. **User Scratch** (`/scratch`)
   - **Private per-user/job:** Each user/cluster has own scratch space
   - **Local to cluster:** Not shared across accounts or clusters
   - Run directories, simulation outputs, temporary files
   - **S3-backing (OPTIONAL):** User's choice based on needs
   
   **Key principle:** Scratch is where the actual work happens - it's writable and user-specific
   
   **S3-Backed Scratch (Production runs):**
   - User's personal S3 bucket: `s3://my-bucket/scratch/`
   - ✅ Outputs preserved for long-term analysis
   - ✅ Can resume interrupted simulations
   - ❌ S3 costs for all outputs
   - **Use for:** Long simulations, important results
   
   **Non-S3-Backed Scratch (Development/Testing):**
   - No S3 backing - pure ephemeral storage
   - ✅ Fast, cheap, simple
   - ❌ All data lost on cluster deletion
   - User manually copies important results to their own S3
   - **Use for:** Quick tests, development iterations
   
   **Default:** Non-backed (user owns backup decision), optionally S3-backed for production

### Build Strategy
- Build on latest generation instances (fastest build times)
- Compatibility flags for backward compatibility:
  - **AMD:** znver3 (works on Zen 3/4/5: c6a, c7a, c8a, hpc6a, hpc7a)
  - **Intel:** icelake-server (works on: c6i, c7i, c8i, hpc6id)
  - **ARM:** neoverse-v1 (works on: c7g, c7gn, c8g, hpc7g)

## Project Structure

```
aws-gchp/
├── parallelcluster/
│   ├── configs/              # Cluster configurations
│   │   ├── gchp-test.yaml        # Working config (hpc7a + c7a queues)
│   │   ├── gchp-test-add-c7a.yaml # Multi-queue example
│   │   └── builder-cluster.yaml   # Software stack builder
│   ├── post-install/         # Software stack build scripts
│   │   ├── amd-toolchain-setup.sh    # GCC 14 + OpenMPI + EFA
│   │   ├── intel-toolchain-setup.sh  # oneAPI stack
│   │   └── arm-toolchain-setup.sh    # ACfL stack
│   └── job-scripts/          # SLURM job scripts
├── scripts/
│   ├── build-gchp.sh        # GCHP compilation
│   ├── run-benchmark.sh     # Benchmark execution
│   └── collect-metrics.sh   # Performance data collection
├── docs/                     # Documentation
│   ├── COMPLETE-DEPLOYMENT-GUIDE.md  # Complete workflow
│   ├── 4-node-success-final.md       # Scaling validation
│   └── gchp-*.md                     # Historical learnings
└── data/                     # Benchmark results
```

## Infrastructure Details

### Validated Cluster (gchp-test)
**Region:** us-east-1 (GEOS-Chem RODA native region)
**Head Node:** t3.xlarge
**SSH Key:** aws-gchp
**S3 Bucket:** s3://gchp-shared-storage-us-east-1/
**Compute Queues:**
- **compute:** hpc7a.24xlarge (max 4, EFA enabled)
- **c7a-compute:** c7a.48xlarge (max 8, ENA)

**Storage:**
- `/fsx` - FSx Lustre SCRATCH_2 (1.2TB, S3-backed)
- `/input` - FSx Lustre (S3-backed, GEOS-IT met fields)
- `/sw-gcc14` - Software stack location

**Working Configurations:**
- `/fsx/gchp-tt-proper/` - Single-node (C24, 48 cores)
- `/fsx/gchp-tt-2node/` - 2-node (C48, 96 cores)
- `/fsx/gchp-tt-4node/` - 4-node (C90, 192 cores) ✅

### Planned Infrastructure (us-west-2)
**Region:** us-west-2
**Subnet:** subnet-0a73ca94ed00cdaf9
**Security Group:** sg-025793e5909030cc3
**SSH Key:** aws-benchmark
**S3 Bucket:** s3://aws-instance-benchmarks-data/gchp/

## Common Commands

### ParallelCluster Management
```bash
# List clusters
AWS_PROFILE=aws ~/.local/bin/pcluster list-clusters --region us-east-1

# Create cluster
AWS_PROFILE=aws uv run pcluster create-cluster \
  --cluster-name <name> \
  --cluster-configuration parallelcluster/configs/<config>.yaml \
  --region us-west-2

# Delete cluster
AWS_PROFILE=aws uv run pcluster delete-cluster \
  --cluster-name <name> \
  --region us-west-2

# SSH to head node
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<head-node-ip>
```

### FSx Lustre S3 Integration
```bash
# FSx automatically exports to S3 via ExportPath configuration
# No manual sync needed for most cases

# Check what's in S3
aws s3 ls s3://gchp-shared-storage-us-east-1/stacks/ --recursive --human-readable

# User clusters automatically import via FSx ImportPath
```

## Current Phase

**Status:** ✅ Multi-node scaling validated (February 2026)

**Completed:**
- ✅ GCC 14.2.1 + OpenMPI 4.1.7 + EFA stack built and validated
- ✅ GCHP 14.5.0 compiled and running on AWS
- ✅ Single-node validation (48 cores, C24, 14s runtime)
- ✅ 2-node validation (96 cores, C48, 63s runtime)
- ✅ 4-node validation (192 cores, C90, 116s runtime, 95% scaling efficiency)
- ✅ FSx-based deployment architecture proven
- ✅ Multi-queue strategy (hpc7a + c7a) implemented

**Current Cluster:**
- **Name:** gchp-test
- **Region:** us-east-2
- **Head Node:** t3.xlarge
- **Compute Queues:**
  - compute: hpc7a.24xlarge (max 4 nodes, EFA)
  - c7a-compute: c7a.48xlarge (max 8 nodes, ENA)
- **Storage:** 3× FSx Lustre volumes (software, input data, scratch)

**Next Steps:**
1. Extended runtime tests (24-hour simulations)
2. C180 resolution testing (8-16 nodes)
3. Alternative instance type benchmarking (c7a vs hpc7a)
4. Investigate c7a configuration issues (Job 27 status=56)
5. Compare toolchain performance (GCC vs Intel vs AMD vs ARM)

## Key Design Decisions

1. **FSx-based software stack (no custom AMI)** - Simpler, more maintainable, allows multiple toolchain versions to coexist
2. **Three-FSx architecture** - Shared resources (/sw, /input) always S3-backed + user workspace (/scratch) optionally S3-backed
3. **Hybrid scratch strategy** - S3-backed for production, non-backed for development (see `docs/FSX-STORAGE-STRATEGY.md`)
4. **Multi-queue strategy** - hpc7a (EFA, optimal) + c7a (ENA, better availability) for flexibility
5. **Compatibility flags first** - Pragmatic approach (znver3, icelake-server) before microarchitecture-specific optimization
6. **Standard Amazon Linux 2023** - No custom AMI required, all software on /sw
7. **Grid resolution constraints validated** - X/NX >= 4, X/NY >= 4, NY divisible by 6

## Success Metrics & Key Findings

### Validated Performance
- **95% scaling efficiency** (2→4 nodes, 96→192 cores)
- **Grid constraint formula proven** across C24, C48, C90 resolutions
- **EFA networking validated** across 4 nodes, 300 Gbps RDMA
- **Cost-effective testing**: ~$25 for complete validation (Jobs 1-28)

### Architecture Insights
- **FSx + S3 architecture works** - No custom AMI needed
- **Multi-queue flexibility essential** - hpc7a capacity variable, c7a as fallback
- **Domain decomposition matters** - Square-ish layouts (NY=12) work well
- **Initialization overhead dominates short runs** - Better efficiency at production scales

### Deployment Model
- **Infrastructure builders** create shared resources (/sw, /input)
- **End users** import read-only + create personal /scratch
- **S3-backed FSx** provides persistence and automatic sync
- **Standard AMI** simplifies deployment and maintenance

## Notes for Blog Post
- FSx-based deployment model (no custom AMI required)
- Multi-node scaling results (95% efficiency achieved)
- Grid resolution constraint analysis (critical for users)
- Multi-queue strategy for capacity management
- Cost analysis and optimization strategies
- Complete deployment guide from zero to production
- Contribute findings back to GCHP development team
