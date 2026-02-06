# AWS GCHP Benchmarking Project

## Project Overview
Comprehensive benchmarking of GCHP (GEOS-Chem High Performance) on AWS ParallelCluster across multiple instance types, generations (5-8), and architectures (Intel, AMD, Graviton).

**Date Context:** January 2026 - Using latest software versions

## Goals
1. **Definitive benchmarking for GCHP on AWS** - Start from 8th generation instances and work backwards
2. **Performance progression analysis** - Track application performance across hardware generations

## Environment Setup

### AWS Profile
**ALWAYS use:** `AWS_PROFILE=aws` for all AWS CLI and ParallelCluster commands

### Python Environment
**Use uv exclusively** - Project has `.venv` in root directory

```bash
# Run ParallelCluster commands:
AWS_PROFILE=aws uv run pcluster <command>

# Example:
AWS_PROFILE=aws uv run pcluster list-clusters --region us-west-2
```

## Software Stack (January 2026)

- **AWS ParallelCluster:** 3.14.0 (September 2025 release)
- **Intel Toolchain:** oneAPI 2025.3 (latest)
- **AMD Toolchain:** AOCC 5.0.0 (latest, Zen 5 support)
- **ARM Toolchain:** ACfL 24.04 (stable)
- **OpenMPI:** 5.0.3 with UCX support
- **HDF5:** 1.14.3
- **NetCDF:** 4.9.2 (C), 4.6.1 (Fortran)
- **ESMF:** 8.6.1
- **CMake:** 3.28.1

## Custom AMI Strategy

**Best Practice:** Pre-baked custom AMIs instead of post-install scripts
- **Boot Time:** 1-2 minutes vs 15-30 minutes
- **Reliability:** No health check timeouts
- **Cost:** ~$6 one-time vs $280+ per deployment

### Build Strategy
- Build on 8th generation instances (fastest build times)
- Compatibility flags for backward compatibility:
  - **AMD:** znver3 (works on Zen 3/4/5: c6a, c7a, c8a, hpc6a, hpc7a)
  - **Intel:** icelake-server (works on: c6i, c7i, c8i, hpc6id)
  - **ARM:** neoverse-v1 (works on: c7g, c7gn, c8g, hpc7g)

### Current AMI Build Status

**Check build status:**
```bash
AWS_PROFILE=aws uv run pcluster describe-image --image-id <image-id> --region us-west-2
```

**Active Builds:**
1. `gchp-intel-oneapi2025` - Intel oneAPI 2025.3 (BUILD_IN_PROGRESS)
2. `gchp-arm-acfl2404` - ARM ACfL 24.04 (BUILD_IN_PROGRESS)
3. `gchp-amd-aocc50` - AMD AOCC 5.0 (BUILD_FAILED - needs investigation)

**Expected build time:** 30-40 minutes per AMI

## Project Structure

```
aws-gchp/
├── parallelcluster/
│   ├── configs/              # Cluster configurations
│   │   ├── gchp-amd-*.yaml
│   │   ├── gchp-intel-*.yaml
│   │   └── gchp-arm-*.yaml
│   ├── image-configs/        # Custom AMI build configs
│   │   ├── gchp-amd-image.yaml
│   │   ├── gchp-intel-image.yaml
│   │   └── gchp-arm-image.yaml
│   ├── post-install/         # Toolchain setup scripts
│   │   ├── amd-toolchain-setup.sh
│   │   ├── intel-toolchain-setup.sh
│   │   └── arm-toolchain-setup.sh
│   └── job-scripts/          # SLURM job scripts
├── scripts/
│   ├── build-gchp.sh        # GCHP compilation
│   ├── run-benchmark.sh     # Benchmark execution
│   └── collect-metrics.sh   # Performance data collection
├── docs/                     # Documentation
└── data/                     # Benchmark results
```

## Infrastructure Details

**Region:** us-west-2
**Subnet:** subnet-0a73ca94ed00cdaf9
**Security Group:** sg-025793e5909030cc3
**SSH Key:** aws-benchmark
**S3 Bucket:** s3://aws-instance-benchmarks-data/gchp/

## Common Commands

### ParallelCluster Management
```bash
# List clusters
AWS_PROFILE=aws uv run pcluster list-clusters --region us-west-2

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
ssh -i ~/.ssh/aws-benchmark.pem ec2-user@<head-node-ip>
```

### Custom AMI Management
```bash
# Build custom AMI
AWS_PROFILE=aws uv run pcluster build-image \
  --image-id <image-id> \
  --image-configuration parallelcluster/image-configs/<config>.yaml \
  --region us-west-2

# Check build status
AWS_PROFILE=aws uv run pcluster describe-image \
  --image-id <image-id> \
  --region us-west-2

# List AMI builds
AWS_PROFILE=aws uv run pcluster list-images --region us-west-2

# Get build logs
AWS_PROFILE=aws uv run pcluster list-image-log-streams \
  --image-id <image-id> \
  --region us-west-2
```

## Current Phase

**Status:** Building custom AMIs with latest toolchains (January 2026)

**Next Steps:**
1. Monitor Intel and ARM AMI builds to completion (~30-40 min)
2. Investigate AMD AMI build failure
3. Once AMIs complete, deploy test clusters
4. Validate toolchains on each architecture
5. Begin benchmarking on 8th gen instances (c8a, c8i, c8g)
6. Work backwards through generations 7, 6, 5

## Key Design Decisions

1. **Custom AMIs over post-install scripts** - Faster, more reliable, cost-effective
2. **Build on 8-series with compatibility flags** - Pragmatic approach before microarchitecture-specific optimization
3. **Parallel builds** - Build Intel and ARM simultaneously for time efficiency
4. **Latest versions** - Use most recent stable toolchains as of January 2026
5. **FSx Lustre** - SCRATCH_2 deployment type for cost-effective high-performance storage

## Notes for Blog Post
- Document custom AMI best practices for HPC on AWS
- Compare toolchain performance (Intel oneAPI vs AMD AOCC vs ARM ACfL)
- Analyze cost-performance across instance generations
- Provide definitive guidance for GCHP users on AWS
- Contribute findings back to GCHP development team
