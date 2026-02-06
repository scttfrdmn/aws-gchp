# GCHP on AWS - Automated Toolkit

**Making atmospheric chemistry modeling "just work" on AWS**

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Python 3.8+](https://img.shields.io/badge/python-3.8+-blue.svg)](https://www.python.org/downloads/)

---

## Overview

This project provides production-ready automation for running [GCHP (GEOS-Chem High Performance)](https://gchp.readthedocs.io/) on AWS. It eliminates the manual configuration complexity that typically requires 4-8 hours of setup, reducing it to **15 minutes**.

**Key Features:**
- 🚀 **One-command execution** - Run simulations without AWS expertise
- 📦 **Intelligent data management** - Downloads exactly what you need (prevents 5TB disasters)
- ⚙️ **Automated configuration** - Fills 300+ template placeholders automatically
- 💰 **Cost-optimized** - Spot instances with auto-recovery, optimal instance selection
- 📊 **Performance-validated** - Based on 291 benchmarks across AMD/Intel/ARM

**Time Savings:** 3.5-7.5 hours per simulation
**Cost:** ~$1.28/hour while running (Spot pricing)

---

## Quick Start

### 1. Install Dependencies

```bash
# Clone repository
git clone https://github.com/scttfrdmn/aws-gchp.git
cd aws-gchp

# Set up Python environment
uv venv
source .venv/bin/activate
uv pip install boto3 pyyaml jinja2 click rich

# Configure AWS
export AWS_PROFILE=aws
export AWS_REGION=us-west-2

# Verify setup
./scripts/test-setup.sh
```

### 2. Create Infrastructure

```bash
# Create persistent data volume (one-time, ~10 minutes)
./gchp-aws cluster create --cluster-name gchp-data-bootstrap

# Populate with data
ssh -i ~/.ssh/gchp-benchmark.pem ec2-user@<head-node>
./scripts/gchp-data-sync.py --config examples/c24-fullchem.yml --yes

# Delete bootstrap cluster (FSx volume survives)
./gchp-aws cluster delete --cluster-name gchp-data-bootstrap

# Create production cluster with existing data volume
./gchp-aws cluster create
```

### 3. Run Simulation

```bash
# Run C24 benchmark (5 minutes on 96 cores)
./gchp-aws run examples/c24-fullchem.yml

# Monitor progress
./gchp-aws status
./gchp-aws logs c24-fullchem

# Download results
./gchp-aws results download c24-fullchem
```

**That's it!** No manual config editing, no trial-and-error data downloads.

---

## Documentation

| Document | Description |
|----------|-------------|
| [**IT JUST WORKS**](README-IT-JUST-WORKS.md) | Main overview - problem/solution, architecture |
| [**Quick Start Guide**](docs/QUICK-START-GUIDE.md) | Detailed 15-minute walkthrough |
| [**FSx Data Volume Setup**](docs/FSX-DATA-VOLUME-SETUP.md) | One-time persistent volume creation |
| [**AMD Benchmark Summary**](docs/AMD-GCC-BENCHMARK-SUMMARY.md) | Performance results (291 benchmarks) |
| [**Automation Implementation**](docs/AUTOMATION-IMPLEMENTATION-SUMMARY.md) | Technical details, testing plan |

---

## Tools

### `gchp-aws` - Main Command-Line Interface

One command for all operations:

```bash
# Cluster management
./gchp-aws cluster create
./gchp-aws cluster status
./gchp-aws cluster ssh
./gchp-aws cluster delete

# Run simulations
./gchp-aws run examples/c24-fullchem.yml

# Monitor and retrieve results
./gchp-aws status
./gchp-aws logs <simulation-name>
./gchp-aws results download <simulation-name>
```

### `gchp-data-sync.py` - Intelligent Data Downloader

Prevents accidental multi-TB downloads:

```bash
# Dry run (see what would be downloaded)
./scripts/gchp-data-sync.py --config examples/c24-fullchem.yml --dry-run

# Download (with confirmation)
./scripts/gchp-data-sync.py --config examples/c24-fullchem.yml --yes
```

**Features:**
- Calculates exact data requirements from config
- Shows total size before downloading
- Validates data after download
- Prevents 5.1 TB disasters

### `gchp-setup.py` - Automated Run Directory Creation

Replaces 6+ hours of manual configuration:

```bash
./scripts/gchp-setup.py \
  --config examples/c24-fullchem.yml \
  --output /fsx/scratch/rundirs/test
```

**Features:**
- Processes all templates (CAP.rc, GCHP.rc, ExtData.rc, HEMCO_Config.rc, etc.)
- Fills 300+ placeholders automatically
- Auto-calculates domain decomposition
- Generates SLURM submit script
- Validates completeness

---

## Performance Results

Based on 291 benchmarks across 4 AMD EPYC generations (C24 resolution, 1-hour simulation):

| Generation | Architecture | Runtime | Cost/Sim | Optimal Cores |
|------------|--------------|---------|----------|---------------|
| c5a | Zen 2 | 86.70s | $0.089 | 48 |
| c6a | Zen 3 | 78.32s | $0.080 | 48 |
| c7a | Zen 4 | 75.28s | $0.077 | 48 |
| **c8a** | **Zen 5** | **51.76s** | **$0.037** | **96** ⚡ |

**Recommendation:** c8a.24xlarge (96 cores) for C24 simulations
- 31% faster than c7a (previous generation)
- 2.4x cheaper per simulation than c5a
- Best price-performance

See [AMD-GCC-BENCHMARK-SUMMARY.md](docs/AMD-GCC-BENCHMARK-SUMMARY.md) for complete analysis.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ FSx Persistent Data Volume (Read-Only, S3-backed)           │
│ /fsx/data - Survives cluster deletion                        │
│ ├── GEOS_FP/           (meteorology, ~10GB/day)             │
│ ├── HEMCO/             (emissions, ~10GB/year)               │
│ ├── CHEM_INPUTS/       (chemistry data, ~5GB)                │
│ ├── bin/gchp           (GCC 14 binary)                       │
│ └── gchp-templates/    (template files)                      │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ FSx Scratch Volume (Ephemeral)                               │
│ /fsx/scratch - Deleted with cluster                          │
│ ├── rundirs/           (run directories)                     │
│ ├── output/            (simulation results)                  │
│ └── checkpoints/       (Spot recovery)                       │
└─────────────────────────────────────────────────────────────┘

Spot Instances with Auto-Recovery:
- 70% cost savings vs on-demand
- Automatic checkpointing
- Transparent restart after interruption
```

**Cost:** ~$177/month for persistent volume + ~$1.28/hour when running

---

## Project Structure

```
aws-gchp/
├── gchp-aws                        # Main CLI tool
├── gchp-data-manifest.yml          # Complete data catalog
├── CLAUDE.md                       # Project instructions
├── README.md                       # This file
├── README-IT-JUST-WORKS.md        # Detailed overview
│
├── scripts/
│   ├── gchp-data-sync.py          # Intelligent data downloader
│   ├── gchp-setup.py              # Automated run directory creation
│   ├── test-setup.sh              # Environment validation
│   └── analyze-benchmarks.py      # Results analysis
│
├── examples/
│   └── c24-fullchem.yml           # Example simulation config
│
├── parallelcluster/
│   └── configs/
│       ├── gchp-production.yaml   # Production cluster config
│       ├── gchp-amd-c5a.yaml      # AMD legacy instances
│       ├── gchp-intel-*.yaml      # Intel instances
│       └── gchp-graviton-*.yaml   # ARM instances
│
├── docs/
│   ├── QUICK-START-GUIDE.md
│   ├── FSX-DATA-VOLUME-SETUP.md
│   ├── AMD-GCC-BENCHMARK-SUMMARY.md
│   ├── AUTOMATION-IMPLEMENTATION-SUMMARY.md
│   ├── INTEL-SESSION-FINAL-ABORT.md  # What led to automation
│   └── EXTDATA-SETUP.md
│
├── data/                           # Benchmark results
│   ├── c5a-uswest2/
│   ├── c6a-uswest2/
│   ├── c7a-uswest2/
│   └── c8a-uswest2/
│
└── archive/                        # Historical files
    ├── intel-session/              # Intel benchmarking attempt
    ├── old-docs/                   # Superseded documentation
    └── old-configs/                # Old cluster configs
```

---

## Why This Project Exists

**From the Intel benchmarking session (January 28-29, 2026):**

After building a complete Intel-optimized GCHP software stack (100% functional), we spent **6+ hours** trying to get a validation run working. The problem wasn't the software - it was GCHP's configuration complexity:

- 300+ placeholders across 15+ template files
- Manual editing required for every simulation
- Cryptic error messages (status=39, status=56, no explanation)
- No indication of what data was missing
- 20+ validation attempts, never succeeded

**Quote:** *"This is stupid - just kill the whole thing"*

We turned this frustration into a systematic solution. This toolkit eliminates the pain points and makes GCHP accessible to atmospheric scientists who want to focus on science, not infrastructure.

---

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

---

## Support

- **GCHP Questions:** support@geos-chem.org
- **Toolkit Issues:** https://github.com/scttfrdmn/aws-gchp/issues
- **AWS Support:** Open support case

---

## License

Apache 2.0 - See LICENSE file

---

## Acknowledgments

- **GEOS-Chem Team** at Harvard and Washington University for developing GCHP
- **AWS HPC Team** for ParallelCluster and infrastructure support
- **Atmospheric science community** for feedback and testing

---

**Let atmospheric scientists do science, not cloud engineering.** 🌍☁️⚡

For detailed usage, see [README-IT-JUST-WORKS.md](README-IT-JUST-WORKS.md)
