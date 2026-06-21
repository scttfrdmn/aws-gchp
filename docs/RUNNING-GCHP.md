# Running GCHP on AWS ParallelCluster

Complete, verified procedure for running GCHP 14.7.1 simulations on AWS using the
prebuilt validated software stacks. Validated June 2026 on both x86_64 (c7a) and
ARM64/Graviton (c7g) with a C24 TransportTracers 1-day simulation.

> **Design principle:** The expensive, brittle GCHP compilation is done **once** at
> stack-build time and shipped as a prebuilt binary on an FSx mount. Users never
> recompile GCHP — they create a run directory (pure config, no compile) and link
> the prebuilt binary into it.

---

## 1. Prerequisites

- A deployed run cluster (see `parallelcluster/configs/gchp-run-x86.yaml` or
  `gchp-run-arm64.yaml`). These mount:
  - `/fsx`   → validated software stack (S3 import, read-only)
  - `/input` → GEOS-Chem met/emissions data (permanent FSx, backed by `s3://gcgrid`)
- SSH access to the head node with `~/.ssh/aws-gchp.pem`.

Stack paths by architecture:
| Arch | Stack root (`$STACK`) |
|------|------------------------|
| x86_64 | `/fsx/stacks/x86_64/gchp14.7.1-validated` |
| aarch64 | `/fsx/stacks/aarch64/gchp14.7.1-validated` |

---

## 2. Deploy the run cluster

```bash
# x86_64
AWS_PROFILE=aws uv run pcluster create-cluster \
  --cluster-name gchp-run-x86 \
  --cluster-configuration parallelcluster/configs/gchp-run-x86.yaml \
  --region us-east-1

# ARM64 / Graviton
AWS_PROFILE=aws uv run pcluster create-cluster \
  --cluster-name gchp-run-arm64 \
  --cluster-configuration parallelcluster/configs/gchp-run-arm64.yaml \
  --region us-east-1
```

Both clusters use subnet `subnet-2eec4a71` (us-east-1a) to match the input-data FSx
availability zone. The input FSx supports concurrent mounts from multiple clusters.

---

## 3. Create a run directory

GCHP's run-directory tooling (`createRunDir.sh`) lives in the GCHP **source tree**,
which is not part of the binary-only stack. Clone it once on the head node.

> A future stack build will ship a reference run directory so this clone step can be
> skipped. Until then, clone the source.

```bash
# One-time: configure GEOS-Chem and SKIP the interactive registration prompt
mkdir -p ~/.geoschem
cat > ~/.geoschem/config <<'EOF'
export GC_DATA_ROOT=/input
export GC_USER_REGISTERED=true
EOF

# Clone GCHP 14.7.1 + the geos-chem submodule (holds createRunDir.sh + templates)
mkdir -p /fsx/scratch && cd /fsx/scratch
git clone --depth 1 --branch 14.7.1 https://github.com/geoschem/GCHP.git
cd GCHP
git submodule update --init --depth 1 src/GCHP_GridComp/GEOSChem_GridComp/geos-chem

# Install expect for non-interactive run-dir creation
sudo dnf install -y expect
```

### Run createRunDir.sh

> **Two gotchas (both required):**
> 1. **Run it from its own directory** — it derives source paths via `pwd`, so an
>    absolute-path invocation produces a broken run dir (`CodeDir -> /`).
> 2. **Pre-set `GC_USER_REGISTERED=true`** (done above) — otherwise a first-time
>    registration prompt appears *before* the simulation prompts and hangs automation.

For a **MERRA-2 TransportTracers** run, the prompt answers are:

| Prompt | Answer |
|--------|--------|
| Choose simulation type | `2` (TransportTracers) |
| Choose meteorology source | `1` (MERRA-2) |
| Enter path where run dir created | `/fsx/scratch` |
| Enter run directory name | *(return = default)* |
| Track run directory changes with git | `n` |

MERRA-2 has no further prompts (GEOS-FP/GEOS-IT ask about file type & advection).

Automated via `expect`:

```bash
cat > /tmp/crd.expect <<'EOF'
#!/usr/bin/expect -f
set timeout 300
cd /fsx/scratch/GCHP/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/run/GCHP
spawn ./createRunDir.sh
expect "Choose simulation type:"        { send "2\r" }
expect "Choose meteorology source:"      { send "1\r" }
expect "Enter path where the run directory will be created:" { send "/fsx/scratch\r" }
expect "Enter run directory name"        { send "\r" }
expect "track run directory changes with git" { send "n\r" }
expect eof
EOF
expect /tmp/crd.expect
```

Creates `/fsx/scratch/gchp_merra2_TransportTracers` with all config files
(`geoschem_config.yml`, `GCHP.rc`, `CAP.rc`, `HISTORY.rc`, `ExtData.rc`,
`HEMCO_Config.rc`, `setCommonRunSettings.sh`) and restart symlinks.

---

## 4. Configure the run

```bash
cd /fsx/scratch/gchp_merra2_TransportTracers

# Link the prebuilt binary (replaces the "make install" step — NO recompile).
# Use the path matching your architecture.
ln -sf /fsx/stacks/x86_64/gchp14.7.1-validated/gchp-14.7.1/bin/gchp ./gchp
```

Edit `setCommonRunSettings.sh` for a single-node C24, 1-day run:

```bash
sed -i 's/^TOTAL_CORES=.*/TOTAL_CORES=48/'          setCommonRunSettings.sh
sed -i 's/^NUM_NODES=.*/NUM_NODES=1/'               setCommonRunSettings.sh
sed -i 's/^NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=48/' setCommonRunSettings.sh
sed -i 's/^Run_Duration=.*/Run_Duration="00000001 000000"/' setCommonRunSettings.sh
# CS_RES=24 is the default already
```

Grid/core constraints (auto-layout via `AutoUpdate_NXNY=ON`): `TOTAL_CORES` must be
divisible by 6; for CS_RES=N require `N/NX >= 4` and `N*6/NY >= 4`.

---

## 5. Submit the job

Create `gchp.slurm` in the run directory (x86 paths shown — swap `x86_64`→`aarch64`
for Graviton):

```bash
#!/bin/bash
#SBATCH --job-name=gchp-c24
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --time=01:00:00
#SBATCH --output=gchp-slurm-%j.log
#SBATCH --exclusive

set -e
cd "$SLURM_SUBMIT_DIR"

# Load the validated stack. gchp-env.sh is relocatable (derives its own path) and
# sets OPAL_PREFIX/PMIX_PREFIX so OpenMPI/PMIx find their plugins regardless of
# where the stack is mounted — no manual prefix exports needed.
source /fsx/stacks/x86_64/gchp14.7.1-validated/gchp-env.sh

ulimit -s unlimited 2>/dev/null

# Configure run dir, set restart symlink, sanity check
source setCommonRunSettings.sh
source setRestartLink.sh
source checkRunSettings.sh

set +e
start_str=$(sed 's/ /_/g' cap_restart)
log=gchp.${start_str:0:13}z.log
time mpirun -n 48 ./gchp 2>&1 | tee ${log}
```

Submit:

```bash
sbatch gchp.slurm
squeue            # CF=configuring node, R=running
```

A compute node (c7a.48xlarge / c7g.16xlarge) provisions on demand (~3-5 min first
boot), then GCHP runs.

---

## 6. Verify success

A successful C24 1-day run:

```bash
cat cap_restart
# 20190102 000000   <- advanced one day from the 20190101 start

ls -lh Restarts/gcchem_internal_checkpoint
# ~55M internal checkpoint restart written at end of run

grep "GCHP Date: 2019/01/02" gchp.*.log
# confirms the time loop reached the end of the simulation day
```

Throughput (~1500 days/day for C24) is printed each step as
`Throughput(days/day)[Avg Tot Run]`.

> **Diagnostics note:** the default HISTORY frequency is **monthly**, so a 1-day run
> writes **no** diagnostic netCDF to `OutputDir/`. This is expected. To get
> diagnostic output from a short run, edit `HISTORY.rc` frequencies/durations.

### Known issue: benign abort at finalization

Both architectures finish the simulation and write all output, then abort during
MAPL **finalization** with:

```
double free or corruption (!prev)
... exited on signal 6 (Aborted)
```

This happens **after** the science completes, the restart is written, and the timing
report prints — so **results are valid**. It is a GCHP/MAPL 14.7.1 teardown issue
(reproduces identically on x86 and ARM64, independent of the stack). The only side
effect is a non-zero exit code, which makes SLURM mark the job `FAILED` despite a
successful run. Verify success via `cap_restart` and the restart file, not the job
exit code. Tracked for upstream investigation.

---

## 7. Cost notes

- Compute nodes scale to zero when idle (`MinCount: 0`); you pay only while jobs run.
- A C24 1-day run completes in ~2 min of compute once the node is up.
- The input-data FSx is a persistent shared resource (~$0.14/hr for 1.2 TB SCRATCH_2);
  delete it only if no clusters need GEOS-Chem input data.
- `s3://gcgrid` data transfer is free in-region (us-east-1).

---

## Appendix: changing resolution / duration / met source

- **Resolution:** set `CS_RES` (24, 48, 90, 180, 360...) in `setCommonRunSettings.sh`.
  Restart files for each resolution are symlinked in `Restarts/` automatically.
- **Duration:** `Run_Duration="YYYYMMDD HHmmSS"` (e.g. `"00000100 000000"` = 1 month).
- **Cores / multi-node:** scale `TOTAL_CORES`, `NUM_NODES`, `NUM_CORES_PER_NODE` and
  the SLURM `--nodes`/`--ntasks`; raise the config's `MaxCount`.
- **Met source:** re-run `createRunDir.sh` and choose MERRA-2 / GEOS-FP / GEOS-IT.
  GEOS-FP adds a convection-scheme date-boundary warning and asks about processed vs
  raw files and advection winds.
