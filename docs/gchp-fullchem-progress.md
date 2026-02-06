# GCHP fullchem Progress Report

**Date:** February 3, 2026
**Status:** 🔄 IN PROGRESS - Configuration issues remain

## Executive Summary

Successfully transitioned from TransportTracers (simple, working) to fullchem (complex, partially working). Made significant progress on fullchem configuration but encountered initialization errors that require further investigation.

## Accomplishments

### ✅ TransportTracers: FULLY WORKING
- **Job 15:** 1-hour simulation, Exit 0, 14s runtime
- All components initialized successfully
- Infrastructure validated (GCC 14 + EFA + PMI + SLURM)
- Configuration documented and reproducible

### ⚠️ fullchem: PARTIAL SUCCESS
- **Jobs 19-21:** Progressed through multiple configuration fixes
- Infrastructure works correctly
- Major subsystems initializing:
  - MAPL components
  - ESMF framework
  - HEMCO emissions
  - LINOZ stratospheric ozone
  - Cloud-J photolysis
  - Chemistry mechanisms

## Job History: fullchem Attempts

| Job | Issue | Fix Applied | Result |
|-----|-------|-------------|--------|
| 19  | Missing LINOZ data | ChemDir symlink needed | 10s, Exit 0 (premature) |
| 20  | Wrong HISTORY.rc | ChemDir + HcoDir symlinks | 17s, Exit 0 (premature) |
| 21  | Init errors | fullchem HISTORY.rc | Hung ~18min, status=56 |

## Configuration Fixes Applied

### 1. Data Directory Symlinks
```bash
cd /fsx/gchp-fullchem-1hr
ln -s /input/CHEM_INPUTS ChemDir    # LINOZ, chemistry data
ln -s /input/HEMCO HcoDir            # Emissions data
```
**Result:** ✅ LINOZ errors resolved

### 2. fullchem-Specific Templates
```bash
cp /fsx/GCHP/run/HEMCO_Config.rc.templates/HEMCO_Config.rc.fullchem HEMCO_Config.rc
cp /fsx/GCHP/run/HEMCO_Diagn.rc.templates/HEMCO_Diagn.rc.fullchem HEMCO_Diagn.rc
cp /fsx/GCHP/run/geoschem_config.yml.templates/geoschem_config.yml.fullchem geoschem_config.yml
cp /fsx/GCHP/run/ExtData.rc.templates/ExtData.rc.fullchem ExtData.rc
cp /fsx/GCHP/run/HISTORY.rc.templates/HISTORY.rc.fullchem HISTORY.rc
```
**Result:** ✅ SpeciesConcVV errors resolved

### 3. Template Variable Substitution
All ${RUNDIR_*} variables replaced in:
- ✅ geoschem_config.yml (complete)
- ✅ ExtData.rc (complete)
- ⚠️ HEMCO_Config.rc (309 remain in data paths - normal)

### 4. Domain Decomposition
- NX=4, NY=12 (48 cores)
- CoresPerNode=48 in all config files
- C24 resolution

## Current Blocker: Job 21 Initialization Errors

**Error:** status=56 (ESMF_RC_ATTR_NOTSET) in MAPL_Generic.F90

**Symptoms:**
- Job appeared to run for ~18 minutes
- Actually hung in initialization loop
- Init_Species_Database error
- QFYAML error: "Could not open YAML file for output!"
- All 48 PEs failing at same location

**Root Cause:** Unknown - likely one of:
1. Missing or incorrectly configured species database
2. YAML output file permissions/path issue
3. Incompatibility between configuration files
4. Missing restart file or initialization data

## Comparison: TransportTracers vs fullchem

| Aspect | TransportTracers | fullchem |
|--------|-----------------|----------|
| Complexity | Simple (passive tracers) | Complex (full chemistry) |
| Species | ~20 | ~200+ |
| Configuration | Minimal | Extensive |
| Data Requirements | Low | High |
| Status | ✅ Working | ⚠️ Partial |

## Files Created

### Working Run Directory
**Location:** `/fsx/gchp-fullchem-1hr/`

**Key Files:**
- `gchp` - GCHP 14.5.0 binary (107MB)
- `CAP.rc` - 1-hour simulation (2019-07-01 00:00 - 01:00)
- `GCHP.rc` - NX=4, NY=12, 48 cores
- `HISTORY.rc` - fullchem template, CoresPerNode=48
- `geoschem_config.yml` - fullchem, all variables replaced
- `HEMCO_Config.rc` - fullchem, all critical variables replaced
- `ExtData.rc` - fullchem, all variables replaced
- `species_database.yml` - Species definitions
- `ChemDir` → `/input/CHEM_INPUTS` (symlink)
- `HcoDir` → `/input/HEMCO` (symlink)
- `submit-fullchem.sh` - SLURM job script

## Lessons Learned

### What Works
1. **Infrastructure is solid:** GCC 14 + EFA + PMI validated
2. **TransportTracers configuration:** Fully understood and reproducible
3. **Data directory strategy:** Symlinks work well
4. **Template identification:** Know which templates are needed

### Challenges
1. **fullchem complexity:** 10x more configuration than TransportTracers
2. **Interdependencies:** Config files are tightly coupled
3. **Error messages:** Sometimes cryptic or misleading
4. **Initialization sequence:** Complex startup dependencies
5. **Manual configuration:** createRunDir.sh automation still needed

## Next Steps

### Option 1: Debug Job 21 Issues (Technical Deep Dive)
1. Investigate QFYAML error - check file paths and permissions
2. Verify species_database.yml matches fullchem requirements
3. Check for missing restart files or initial conditions
4. Enable more verbose logging
5. Compare with known-working fullchem configuration

### Option 2: Automate createRunDir.sh (Proper Solution)
1. Invest time in properly automating the official script
2. Use expect/pexpect or modify script for batch mode
3. Ensures all configuration files are correctly generated
4. Eliminates manual template variable management
5. More maintainable long-term

### Option 3: Contact GCHP Community
1. Join GCHP Slack/Forum
2. Ask about AWS deployment experiences
3. Share configuration files for review
4. Request guidance on fullchem initialization errors
5. Contribute findings back to community

### Option 4: Document and Move Forward
1. TransportTracers is working (control experiment achieved)
2. Document infrastructure as validated
3. Defer fullchem to future work with community support
4. Focus on multi-node scaling tests with TransportTracers
5. Return to fullchem with more guidance

## Recommendations

**Immediate (Tonight):**
- ✅ Document current progress (this file)
- ✅ Preserve working TransportTracers configuration
- ⏸️ Pause fullchem troubleshooting (diminishing returns)

**Short-term (This Week):**
- Engage GCHP community for fullchem guidance
- Test multi-node TransportTracers scaling (2-4 nodes)
- Explore createRunDir.sh automation options
- Review GCHP documentation for initialization best practices

**Long-term (This Month):**
- Get fullchem working with community help
- Complete benchmarking suite (c5a, c6a, c7a, c8a, hpc7a)
- Write blog post on HPC climate modeling on AWS
- Contribute AWS deployment guide to GCHP project

## Value Delivered

Despite fullchem issues, significant value has been delivered:

1. **✅ Validated Infrastructure**
   - GCC 14.2.1 + Zen 4 optimizations working
   - OpenMPI 4.1.7 with EFA (mtl:ofi) + SLURM PMI (ess:pmi)
   - ESMF 8.6.1, complete NetCDF stack
   - 48-core domain decomposition validated

2. **✅ Working TransportTracers**
   - Control experiment successful
   - Reproducible configuration
   - Can proceed with scaling tests

3. **✅ Deep Understanding**
   - GCHP configuration requirements
   - AWS ParallelCluster deployment patterns
   - Template variable management
   - Data staging strategies

4. **✅ Documentation**
   - Comprehensive troubleshooting history
   - Configuration file examples
   - Lessons learned for community

## Conclusion

**Success Criteria Met:**
- Infrastructure validated ✅
- Control experiment working ✅
- Configuration approach documented ✅

**Success Criteria Partial:**
- fullchem simulation ⚠️ (initialization issues)

**Next Milestone:**
Resolve fullchem initialization with community support, then proceed to multi-node scaling tests.

---

**Files:**
- Working config: `/fsx/gchp-fullchem-1hr/`
- Logs: `gchp-fullchem.{19,20,21}.{out,err}`
- Documentation: `/Users/scttfrdmn/src/aws-gchp/docs/`
