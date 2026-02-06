# GCHP TransportTracers - Successful Configuration

**Date:** February 3, 2026
**Cluster:** gchp-test (hpc7a.24xlarge, us-east-2)
**GCHP Version:** 14.5.0
**Status:** ✅ WORKING

## Executive Summary

After 15 job attempts, successfully configured and ran GCHP 14.5.0 TransportTracers simulation on AWS ParallelCluster with:
- **GCC 14.2.1** + Zen 4 optimizations (-march=znver4 -mtune=znver4)
- **OpenMPI 4.1.7** with EFA (mtl:ofi) + SLURM PMI (ess:pmi)
- **ESMF 8.6.1**, HDF5 1.14.3, NetCDF-C 4.9.2, NetCDF-Fortran 4.6.1
- **48 cores** (NX=4, NY=12 domain decomposition)

**Job 15 Results:**
- Runtime: 14 seconds
- Exit Code: 0 (SUCCESS)
- Simulation: C24 resolution, 1-hour duration (2019/07/01 00:00 - 01:00)

## Configuration Issues Fixed

### 1. CAP.rc - Incorrect Dates
**Error:** ESMF_RC_NOT_FOUND (Code 41) - Clock value out of range
**Root Cause:** BEG_DATE was 19600101 (1960) instead of 20190701
**Fix:**
```
BEG_DATE:     20190701 000000
END_DATE:     20190701 010000
```

### 2. HEMCO_Diagn.rc - Missing File
**Error:** `Cannot read file - it does not exist: HEMCO_Diagn.rc`
**Fix:**
```bash
cp /fsx/GCHP/run/HEMCO_Diagn.rc.templates/HEMCO_Diagn.rc.TransportTracers \
   /fsx/gchp-tt-proper/HEMCO_Diagn.rc
```

### 3. Domain Decomposition - Invalid Configuration
**Error:** `mpp_domains_define.inc: At least one pe in pelist is not used`
**Root Cause:** NX=6, NY=8 invalid (NY must be divisible by 6 for cubed-sphere)
**Fix:**
```
NX: 4
NY: 12
```
**Rationale:** For C24 with 48 cores, NX=4, NY=12 gives 4×2 regions per face (more square than alternatives)

### 4. HISTORY.rc - Wrong CoresPerNode
**Error:** ESMF_RC_ATTR_NOTSET (Code 56) - Clock alarm error
**Root Cause:** CoresPerNode was 6 instead of 48
**Fix:**
```
CoresPerNode: 48
```

### 5. geoschem_config.yml - Template Variables Not Substituted
**Error:** `${RUNDIR_SIM_NAME is not a valid simulation`
**Fix:** Replace all template variables:
```bash
sed -i 's/${RUNDIR_SIM_NAME}/TransportTracers/g' geoschem_config.yml
sed -i 's/${RUNDIR_MET}/GEOS-IT/g' geoschem_config.yml
sed -i 's/${RUNDIR_TRANSPORT_TS}/600/g' geoschem_config.yml
sed -i 's/${RUNDIR_CHEMISTRY_TS}/1200/g' geoschem_config.yml
sed -i 's/${RUNDIR_USE_NLPBL}/true/g' geoschem_config.yml
```

### 6. species_database.yml - Missing File
**Error:** `Could not open file: ./species_database.yml`
**Fix:**
```bash
cp /fsx/GCHP/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/run/shared/species_database.yml .
```

### 7. HEMCO_Config.rc - Wrong Template and Variables
**Error:** `cID negative in HEMCO Get_cID - Cannot find ScalID 1000`
**Root Cause:** Using wrong HEMCO_Config.rc template
**Fix:**
```bash
# Copy correct TransportTracers template
cp /fsx/GCHP/run/HEMCO_Config.rc.templates/HEMCO_Config.rc.TransportTracers HEMCO_Config.rc

# Replace all template variables
sed -i 's|${RUNDIR_DATA_ROOT}|/input|g' HEMCO_Config.rc
sed -i 's|${RUNDIR_MET_DIR}|/input/GEOS_0.5x0.625/GEOS_IT|g' HEMCO_Config.rc
sed -i 's|${RUNDIR_MET}|GEOS-IT|g' HEMCO_Config.rc
sed -i 's|${RUNDIR_MET_LOWERCASE}|geos-it|g' HEMCO_Config.rc
sed -i 's|${RUNDIR_MET_DIR_NATIVE}|/input/GEOS_0.5x0.625_IT/GEOS_IT|g' HEMCO_Config.rc
sed -i 's|${RUNDIR_SIM_NAME}|TransportTracers|g' HEMCO_Config.rc
sed -i 's|${RUNDIR_GRID_DIR}|/input/HEMCO|g' HEMCO_Config.rc
sed -i 's|${RUNDIR_BC_DIR}|/input/HEMCO|g' HEMCO_Config.rc
```

### 8. OCEAN_CH3I Extension - Missing Ocean Mask
**Error:** Template variable `${RUNDIR_OCEAN_MASK}` not resolved
**Fix:** Disable OCEAN_CH3I extension:
```bash
sed -i 's/^    --> OCEAN_CH3I             :       true/    --> OCEAN_CH3I             :       false/' HEMCO_Config.rc
```

## Working Configuration Files

### `/fsx/gchp-tt-proper/CAP.rc`
```
ROOT_NAME: GCHP
ROOT_CF: GCHP.rc
HIST_CF: HISTORY.rc

BEG_DATE:     20190701 000000
END_DATE:     20190701 010000
JOB_SGMT:     00000000 010000
NUM_SGMT:     1
HEARTBEAT_DT: 600

MAPL_ENABLE_TIMERS: YES
MAPL_ENABLE_MEMUTILS: YES
```

### `/fsx/gchp-tt-proper/GCHP.rc`
```
NX: 4
NY: 12
CoresPerNode: 48

# EFA optimizations
NUM_WRITERS: 6
WRITE_RESTART_BY_OSERVER: YES
MAPL_ENABLE_BOOTSTRAP: YES
```

### `/fsx/gchp-tt-proper/HISTORY.rc`
```
CoresPerNode: 48
```

### `/fsx/gchp-tt-proper/geoschem_config.yml`
```yaml
simulation:
  name: TransportTracers
  met_field: GEOS-IT

timesteps:
  transport_timestep_in_s: 600
  chemistry_timestep_in_s: 1200

operations:
  chemistry:
    use_non_local_pbl: true
```

### `/fsx/gchp-tt-proper/HEMCO_Config.rc`
Key settings:
```
ROOT: /input/HEMCO
MET:  /input/GEOS_0.5x0.625/GEOS_IT

--> OCEAN_CH3I: false
```

### `/fsx/gchp-tt-proper/submit.sh`
```bash
#!/bin/bash
#SBATCH --job-name=gchp-tt-proper
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --time=00:30:00
#SBATCH --output=gchp.%j.out
#SBATCH --error=gchp.%j.err

source /fsx/sw-gcc14/gchp-gcc14-env.sh

# EFA optimizations
export OMPI_MCA_btl=^ofi
export OMPI_MCA_btl_tcp_if_exclude="lo,docker0,virbr0"
export OMPI_MCA_btl_if_exclude="lo,docker0,virbr0"
export FI_EFA_ENABLE_SHM_TRANSFER=0
export OMPI_MCA_mtl_ofi_provider_exclude=shm

srun --mpi=pmi2 ./gchp
```

## Software Stack

### Environment: `/fsx/sw-gcc14/gchp-gcc14-env.sh`
- **Compiler:** GCC 14.2.1 with Zen 4 optimizations
- **MPI:** OpenMPI 4.1.7
  - EFA support: mtl:ofi with libfabric
  - SLURM support: ess:pmi
- **HDF5:** 1.14.3
- **NetCDF-C:** 4.9.2
- **NetCDF-Fortran:** 4.6.1
- **ESMF:** 8.6.1

### GCHP Binary
- **Location:** `/fsx/GCHP/build/bin/gchp`
- **Size:** 107 MB
- **Architecture:** ELF 64-bit x86-64 (AMD EPYC Genoa)

## Initialization Success

Job 15 log shows successful initialization of all components:

```
✅ CAP restart read correctly (Date: 2019/07/01)
✅ MAPL initialization complete
✅ pFIO input/output servers started
✅ SHMEM: 48 PEs on 1 node
✅ All 12 output streams initialized:
   - Emissions
   - CloudConvFlux
   - DryDep
   - FV3Dynamics
   - GCHPctmEnvLevCenter
   - GCHPctmEnvLevEdge
   - LevelEdgeDiags
   - RadioNuclide
   - SpeciesConc
   - StateMet
   - WetLossConv
   - WetLossLS
✅ EXTDATA component active
✅ HEMCO initialized
```

## Key Learnings

1. **GCHP requires complete configuration file set** - All files are interdependent and must be properly configured
2. **Template variable substitution is critical** - Manual run directory setup must replace all ${RUNDIR_*} variables
3. **Domain decomposition must follow cubed-sphere rules** - NY must be divisible by 6
4. **Correct HEMCO template matters** - Must use simulation-specific template (TransportTracers vs fullchem)
5. **ESMF detailed logging helps debugging** - Set `ESMF_LOGKIND_MULTI_ON_ERROR` in ESMF.rc
6. **Extensions need their data files** - Disable extensions if required data is missing

## Performance Metrics

- **1-hour simulation:** 14 seconds wall time
- **Speedup:** ~257x real-time
- **Memory usage:** ~30 GB across 48 cores
- **Initialization overhead:** ~10-12 seconds

## Next Steps

1. **Longer stability test:** Run 24-hour or 7-day simulation to validate stability
2. **Fullchem configuration:** Apply lessons learned to fullchem with:
   - Disable LightNOx and ParaNOx extensions
   - Fix obsolete GMI species in ExtData.rc
   - Allow restart from any date
3. **Multi-node scaling:** Test 2-4 nodes with higher resolutions (C48, C90)
4. **Production benchmarking:** C180+ for climate research use cases

## Files Location

- **Run Directory:** `/fsx/gchp-tt-proper/`
- **Source Code:** `/fsx/GCHP/`
- **Software Stack:** `/fsx/sw-gcc14/`
- **Input Data:** `/input/`

## Contact

This configuration was validated on AWS ParallelCluster 3.14.0 with hpc7a.24xlarge instances (AMD EPYC 9R14 Genoa, 48 cores).
