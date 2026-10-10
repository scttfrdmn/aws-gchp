# AWS GCHP Benchmarking Project

## Project Overview
Comprehensive benchmarking of GCHP (GEOS-Chem High Performance) on AWS ParallelCluster across multiple instance types, generations (5-8), and architectures (Intel, AMD, Graviton).

**Date Context:** Started January 2026; current state as of October 2026 (see Current Phase)

## Documentation Policy
**DO NOT create session logs, build summaries, or update documents** (e.g., BUILD-SESSION-*.md, SESSION-SUMMARY-*.md). Only update existing documentation when significant architectural changes occur. Focus on getting work done, not documenting every session.

## CRITICAL RULES: NO GUESSING

**NEVER GUESS OR ASSUME** - When working with complex scientific software like GCHP:

1. **ALWAYS follow official documentation** - GCHP has comprehensive docs at https://gchp.readthedocs.org
2. **NEVER create custom run directories** - Use GCHP's official `createRunDir.sh` script
3. **NEVER modify configurations without understanding** - Read the docs first, understand what each parameter does
4. **NEVER waste time debugging custom setups** - If something doesn't work, use the official setup procedure
5. **ASK before proceeding** if you don't know the correct procedure - Don't waste time AND money on trial-and-error

**Remember:** You are spending REAL MONEY on AWS compute. Every failed job costs money. Every wrong guess wastes time. When in doubt about GCHP configuration, STOP and consult documentation or ask the user.

## Goals
1. **Definitive benchmarking for GCHP on AWS** - Start from 8th generation instances and work backwards
2. **Performance progression analysis** - Track application performance across hardware generations

## GCHP Run Directory Setup

**ALWAYS use the official GCHP procedure** - Do not create custom run directories or copy templates manually.

### Official Documentation
- **Main docs:** https://gchp.readthedocs.org
- **Run directory setup:** https://gchp.readthedocs.io/en/latest/user-guide/rundir-init.html
- **Configuration:** https://gchp.readthedocs.io/en/latest/user-guide/rundir-config.html

### Creating Run Directories

**Method 1: Using GCHP's createRunDir.sh (PREFERRED)**
```bash
cd /path/to/GCHP/run
./createRunDir.sh
# Follow interactive prompts
```

**Method 2: Copy existing official example (if available)**
```bash
# Find official examples in GCHP installation
find /sw/gchp-14.7.1 -name "*TransportTracers*" -type d
# Copy and follow GCHP docs to configure
```

**NEVER:**
- Manually copy individual .rc files
- Create custom CAP.rc, GCHP.rc, or HISTORY.rc from scratch
- Modify configurations without understanding what they do
- Assume default values are correct for your use case

## Environment Setup

### Region Selection
**Deploy in us-east-1** - GEOS-Chem RODA data (`s3://gcgrid`) is in us-east-1 for free in-region transfers. Other regions incur cross-region data transfer costs ($0.02/GB).

**Capacity is AZ-specific.** m9g.48xlarge has been empty in us-east-1a and available in us-east-1c, so probe AZs before
committing a cluster to one. FSx SCRATCH_2 is not offered in us-east-1e; `scripts/find-fsx-subnet.sh` is only needed
if you create an FSx volume (the default input layer is now lith, which has no AZ constraint).

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
AWS_PROFILE=aws uv run pcluster list-clusters --region us-east-1
```

## Software Stack

### Current Production Stack (GCHP 14.7.1 Validated) ✅
**Status:** Production-ready, built May 2026

- **AWS ParallelCluster:** 3.15.0
- **Compiler:** GCC 12.2.0 (built from source)
- **MPI:** OpenMPI 4.1.7 with EFA support
  - Libfabric 1.22.0 with EFA provider
  - hwloc 2.11.1, PMIx 5.0.3, libevent 2.1.12
- **HDF5:** 1.14.0
- **NetCDF-C:** 4.9.2
- **NetCDF-Fortran:** 4.6.0
- **udunits2:** 2.2.28
- **ESMF:** 8.6.1 (validated version from GCHP Spack scope)
- **GCHP:** 14.7.1

**Key Feature:** Self-contained stack - all dependencies built from source, no OS package dependencies

#### x86_64 Stack
- **S3:** `s3://gchp-shared-storage-us-east-1/stacks/x86_64/gchp14.7.1-validated/`
- **Optimization:** `-O2 -g`
- **GCHP Binary:** 266 MB
- **Compatibility:** AMD (c5a, c6a, c7a, c8a, hpc6a, hpc7a), Intel (c5, c6i, c7i, c8i, hpc6id)

#### ARM64/aarch64 Stack
- **S3:** `s3://gchp-shared-storage-us-east-1/stacks/aarch64/gchp14.7.1-validated/`
- **Optimization:** `-O2 -g -mcpu=neoverse-v1`
- **GCHP Binary:** 257 MB
- **Compatibility:** Graviton 2/3/4/5 (c7g, c7gn, hpc7g, c8g, c8gn, m8gn, m8gb, m9g); the same binary runs on m9g (Graviton5)

### Usage on Deployed Cluster

The stack is synced from S3 to the `/sw` EBS volume at boot by `s3://gchp-shared-storage-us-east-1/bootstrap/sync-stack-arm.sh`
(or `sync-stack-x86.sh`). These live in S3; only the x86 copy is in `parallelcluster/bootstrap/`. `gchp-env.sh` is
relocatable and sets `OPAL_PREFIX`/`PMIX_PREFIX` itself.

```bash
# Load environment
source /sw/gchp-env.sh

# Verify GCHP
ls -la /sw/gchp-14.7.1/bin/gchp

# Check MPI
mpirun --version

# Verify GCC
gcc --version  # Should show 12.2.0
```

### Future Toolchains (Planned)
- **Intel Toolchain:** oneAPI 2025.3
- **AMD Toolchain:** AOCC 5.0.0 (Zen 5 support)
- **ARM Toolchain:** ACfL 24.04

## Architecture: S3-Backed Stack, lith Input, EBS Scratch

**Current approach (since 2026-10-04):** standard Amazon Linux 2023 AMI, no custom AMI, **no FSx by default**.

1. **Software stack (`/sw`, EBS).** The self-contained 14.7.1 stack is stored in
   `s3://gchp-shared-storage-us-east-1/stacks/<arch>/gchp14.7.1-validated/` and synced to `/sw` at boot. The head node
   NFS-exports `/sw` to compute nodes. Multiple stack versions can coexist under `stacks/`.
2. **Input data (`s3://gcgrid` via lith).** `s3://.../bootstrap/install-lith.sh` installs lith and FUSE3 on every node
   and creates `/input-lith`. The run scripts then mount the five prefix-scoped gcgrid trees (two MERRA2 months,
   HEMCO, CHEM_INPUTS, GEOSCHEM_RESTARTS) with their index files. See `scripts/lith/gate-streams-gchp.sh` or
   `scripts/spawn/gchp-spawn-run.sh` for the pattern.
   Results are byte-identical to FSx (TT and fullchem), lith reads the live bucket, and there is no standing cost.
   See `docs/LITH-VALUE-FOR-GCHP.md` and `docs/lith-input-layer-analysis.md`.
   - Pass `--no-sign-request` on gcgrid mounts unless signing is the variable under test.
   - Size `--mem-cache` per node: lith's RSS is the cache plus in-flight prefetch.
   - When a run must match the older FSx-based benchmark rows, create a fresh FSx instead. It must be Lustre 2.15
     with the Lustre-ports SG (`sg-09d153889e75c86cb`), pre-created (not inline) and referenced by ID, then
     pre-hydrated with a scoped `lfs hsm_restore`.
3. **Scratch (`/scratch`, gp3 EBS on the head node, NFS to compute).** Run directories and outputs. Nothing GCHP does
   needs Lustre. The multi-node checkpoint failure turned out to be the stale-file `NC_EEXIST` bug, not the filesystem.
   Copy results you want to keep to S3 yourself.

**History:** the original design was three S3-linked FSx volumes (`/fsx` software, `/input` data, `/scratch`). It was
retired because each 1.2 TB volume cost about $168/month standing, or about 33 min to create and hydrate per cluster,
and pinned the cluster to one AZ. The `docs/FSX-*.md` files and the `gchp-*fsx*.yaml` / older `bench-*.yaml` configs
describe that era and are kept as records.

### Build Strategy
- Build on latest generation instances (fastest build times)
- Generic optimization for maximum compatibility:
  - **x86_64:** `-O2 -g` (works on all AMD and Intel instances)
  - **ARM64:** `-O2 -g -mcpu=neoverse-v1` (works on Graviton 2/3/4)
- Build scripts:
  - **x86_64:** `parallelcluster/post-install/build-gchp-stack-validated.sh`
  - **ARM64:** `parallelcluster/post-install/build-gchp-stack-validated-arm64.sh`
- ESMF 8.6.1 fix: Automated installation (no manual intervention)

## Project Structure

```
aws-gchp/
├── parallelcluster/
│   ├── configs/        # Cluster configs. Live: bench-lith-input-m9g-use1.yaml (gchp-lith-ab)
│   │                   # bench-matrix-use1.template.yaml = publication matrix; bench-* = historical runs
│   ├── bootstrap/      # Node bootstrap scripts (canonical copies live in s3://.../bootstrap/)
│   └── post-install/   # Stack build scripts (build-gchp-stack-validated*.sh)
├── scripts/
│   ├── gchp-matrix-run.sh, gchp-campaign-sweep.sh, launch-matrix-cluster.sh   # benchmark matrix
│   ├── gchp_aws/       # GCHP→AWS calculator (intent → instance/layout/$), append_benchmark.py
│   ├── lith/           # lith gate harnesses + scorers (5f-* gates)
│   ├── spawn/          # GCHP on spawn (no ParallelCluster): launchers + run wrappers
│   ├── stream/         # STREAM memory-bandwidth probe
│   └── *s3*, *phase1*  # decoupled-chemistry transports, workers, microbenchmarks
├── patches/            # GCHP source patches (decoupled chemistry, instrumentation)
├── docs/               # Guides and results (see Current Phase for the current ones)
├── data/
│   └── lith-gates/     # Raw gate data; inregion-streams.txt = every pre-registration + result
└── BENCHMARK-TRACKER.md, gchp-decoupled-chemistry-design.md
```

## Infrastructure Details

### Live cluster: `gchp-lith-ab` (us-east-1)
- **Config:** `parallelcluster/configs/bench-lith-input-m9g-use1.yaml` (PC 3.15)
- **Head node:** c7g.4xlarge (Graviton). It is also the free test box for lith gates: 16 cores, ~15 Gbps.
- **Compute:** one `compute` queue, EFA, dynamic, max 2 nodes, c8g.48xlarge (384 GiB) or m9g.48xlarge (768 GiB)
- **Storage:** `/sw` EBS (stack), `/scratch` 200 GB gp3 EBS; no FSx
- **SSH key:** `aws-gchp`. **Shared bucket:** `s3://gchp-shared-storage-us-east-1/` (stacks, bootstrap, spawn bundles, results)
- **Compute nodes have no internet egress.** Mirror artifacts to S3, and give each queue its own IAM for S3 custom
  actions. A self-terminating compute node reports why in CloudWatch `<node>.bootstrap_error_msg`.

### Without ParallelCluster: spawn
`scripts/spawn/launch-spawn-smoke.sh` launches a 2-node EFA cohort with spawn (>= 0.120.0). It syncs the stack, mounts
lith, NFS-shares node 0's `/scratch` and runs GCHP. Use a fresh `--job-array-name` per launch. Never use `set -u` in a
wrapper that sources GCHP's `setCommonRunSettings.sh`, which dereferences `$4`.

### Other regions
`bench-matrix-use2*.template.yaml` exist for capacity fallback in us-east-2. Cross-region reads of gcgrid cost
$0.02/GB, and the lith evidence gate is off cross-region by design.

## Common Commands

### ParallelCluster Management
```bash
# List clusters
AWS_PROFILE=aws ~/.local/bin/pcluster list-clusters --region us-east-1

# Create cluster
AWS_PROFILE=aws uv run pcluster create-cluster \
  --cluster-name <name> \
  --cluster-configuration parallelcluster/configs/<config>.yaml \
  --region us-east-1

# Delete cluster (check for non-project resources first: rsdemo, loop-*, keel-*)
AWS_PROFILE=aws uv run pcluster delete-cluster \
  --cluster-name <name> \
  --region us-east-1

# SSH to head node
ssh -i ~/.ssh/aws-gchp.pem ec2-user@<head-node-ip>
```

### Stack and input checks
```bash
# Stacks in S3
aws s3 ls s3://gchp-shared-storage-us-east-1/stacks/ --recursive --human-readable

# On a node: lith mounts healthy (5 expected) and their metrics (ports 9210-9214 are our scripts' convention)
mount | grep -c fuse.lith
curl -s localhost:9210/metrics | grep -E '^lith_(s3_bytes_total|ttfb_seconds_count|readahead_evidence_ratio) '
```

## Current Phase

**Status (October 2026):** GCHP 14.7.1 validated on x86_64 and Graviton. The C180 multi-node
benchmarks, the decoupled-chemistry prototype, and the lith S3 input layer are all measured. The
publication-quality study is costed and awaiting approval. Per-gate detail lives in
`data/lith-gates/inregion-streams.txt`, and the lith summary is in `docs/LITH-VALUE-FOR-GCHP.md`.

**Live infrastructure:** see Infrastructure Details.

**Completed:**
- ✅ GCC 12.2.0 + OpenMPI 4.1.7/EFA + ESMF 8.6.1 + GCHP 14.7.1 self-contained stacks (x86_64, aarch64)
- ✅ EFA multi-node proven on 14.7.1 (2026-06-27); multi-node needs RDMA (EFA): over TCP GCHP aborts at `MPI_Win_create`
- ✅ C180 multi-node benchmarks: Graviton5 m9g.48xl fastest and cheapest (~$0.80/sim-day); first clean,
  restartable C180 multi-node checkpoint (2026-07-15); C180 fullchem runs on m9g (556 GB high-water)
- ✅ Decoupled chemistry: Phases 0/1a/1b byte-identical; C180 chemistry off-node over S3 byte-identical at 1.31× wall
- ✅ GCHP→AWS calculator (`scripts/gchp_aws/`); scaling-campaign Phases 0–1 (no spend)
- ✅ lith input layer: TT + fullchem byte-identical off `s3://gcgrid`; cold start 1.73–4.92× faster than a
  fresh FSx, tied when warm; FSx input layer retired
- ✅ GCHP on spawn without ParallelCluster: 2-node EFA C24 TT run passed (spawn 0.120.0, launch→result 4:42)

**Next Steps:**
1. Publication study (5-rep stats across instances + decoupling modes): proposal costed, **no spend without approval**
2. One multi-node C180 fullchem validation over lith before relying on it for long production runs
3. Harden the off-node chemistry sidecar's S3 PUTs (22/192 failed at C180 → in-process re-solve)
4. Re-measure the handoff-bound off-node numbers on m8gn.48xl (768 GB, 2 NICs) instead of single-NIC m9g
5. GCHP 14.8.1 (when released): rebuild both stacks, re-verify C24, drop the finalization-abort workaround

**Measurement rules learned the hard way:**
- Never quote a cold first run.
- Compare arms simultaneously, not minutes apart.
- Hold core count constant across architectures.
- Score byte-identity, not completion.
- Re-read the upstream issue thread right before launching any paid cell.

## Key Design Decisions

1. **No custom AMI.** Standard AL2023, with the self-contained stack synced from S3 to `/sw`.
2. **lith over `s3://gcgrid` as the default input layer.** Byte-identical results, live data, no standing cost, no
   AZ pin. FSx only when matching older rows.
3. **EBS scratch.** Nothing needs Lustre.
4. **EFA/RDMA for multi-node.** GCHP aborts at `MPI_Win_create` over TCP. AWS calls placement groups optional for EFA; we use them where capacity allows.
5. **Compatibility flags first:** `-O2 -g`, plus `-mcpu=neoverse-v1` on ARM, before microarchitecture tuning.
6. **Grid resolution constraints:** X/NX >= 4, X/NY >= 4, NY divisible by 6.
7. **Ephemeral clusters are the normal case.** That's why cold-start behaviour (lith vs fresh FSx) is the honest comparison.

## Key Findings & Traps

### Performance
- **C180:** Graviton5 m9g.48xlarge is fastest per node and cheapest (~$0.80/sim-day), with no OOM at 768 GB. Graviton4
  is close. Intel trails. 2-node is super-linear on 192-core Graviton.
- **Memory:** HISTORY output is the main driver (~1.7 GB/core). C180 fullchem peaks at 556 GB on one node and needs
  `domains_stack_size 64M` and a large `/dev/shm`.
- **Decoupled chemistry:** byte-identical at every phase. Off-node over S3 costs 2.0× wall at C90 and 1.31× at C180,
  amortizing as the chemistry fraction grows.
- **lith:** 1.73× (C24 TT) to 4.92× (C180 restart) faster cold start than a fresh FSx, tied warm. HEMCO over-fetches
  2.46× (its data is 98% netCDF-4/HDF5, read as scattered chunks).

### Methodology (each of these cost real money or time once)
- Hold core count constant across architectures. Graviton and c7a/c8a have vCPU = core; Intel is hyperthreaded.
- Score byte-identity (checkpoint md5), never completion.
- Never quote a cold first run. Compare arms simultaneously, not minutes apart.
- Pre-register predictions and the scoring rule before running.
- Auto-teardown must delete only on affirmative success, never on an empty `squeue`.
- Re-read the upstream issue thread right before launching any paid cell.

### GCHP 14.7.1 traps
- `setCommonRunSettings.sh` has three independent rank knobs (`TOTAL_CORES`, `NUM_NODES`, `NUM_CORES_PER_NODE`), and
  `Run_Duration` is `YYYYMMDD`, so its default is a month.
- Multi-node checkpoint: delete stale checkpoints, or the pnc4 create fails with `NC_EEXIST`. Measure throughput from
  GCHP's own timer, and don't wait on the finalization abort (a benign double free).
- fullchem on gcgrid restarts needs `Require_Species_in_Restart=0` and the newest GC-version restart. It also needs the
  5 GMI alias files, which are in live gcgrid but not in old FSx snapshots.
- ESMF 8.6.1's `libesmf.so` lacks a SONAME (fix with `patchelf`). A relocated OpenMPI needs `OPAL_PREFIX` and
  `PMIX_PREFIX`; `gchp-env.sh` sets both.
