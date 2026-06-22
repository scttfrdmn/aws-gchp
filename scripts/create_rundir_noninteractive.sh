#!/bin/bash
#
# Non-interactive GCHP Run Directory Creation
# For automated benchmarking workflows
#
# Usage: ./create_rundir_noninteractive.sh <sim_name> <met_field> <grid_res> <output_dir>
#
# Example: ./create_rundir_noninteractive.sh TransportTracers GEOS-FP c24 ./c24_transport
#

set -e

# Check arguments
if [ $# -ne 4 ]; then
    echo "Usage: $0 <sim_name> <met_field> <grid_res> <output_dir>"
    echo ""
    echo "Arguments:"
    echo "  sim_name:    TransportTracers, fullchem, carbon, tagO3"
    echo "  met_field:   GEOS-FP, MERRA2"
    echo "  grid_res:    c24, c48, c90, c180, c360, etc."
    echo "  output_dir:  Path to create run directory"
    echo ""
    echo "Example: $0 TransportTracers GEOS-FP c24 /scratch/benchmarks/c24_transport"
    exit 1
fi

SIM_NAME=$1
MET_FIELD=$2
GRID_RES=$3
RUNDIR=$4

# Convert grid resolution to uppercase for file matching
GRID_RES_LOWER=$(echo $GRID_RES | tr '[:upper:]' '[:lower:]')
GRID_RES_UPPER=$(echo $GRID_RES | tr '[:lower:]' '[:upper:]')

# Extract numeric resolution (e.g., c24 -> 24)
CS_RES=$(echo $GRID_RES_LOWER | sed 's/c//')

echo "=========================================="
echo "GCHP Non-Interactive Run Directory Setup"
echo "=========================================="
echo "Simulation:  $SIM_NAME"
echo "Met field:   $MET_FIELD"
echo "Grid res:    $GRID_RES_LOWER (C$CS_RES)"
echo "Output dir:  $RUNDIR"
echo ""

# Source directory (GCHP installation)
GCHP_ROOT=/fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-14.7.1
GCHP_RUN=$GCHP_ROOT/run

if [ ! -d "$GCHP_ROOT" ]; then
    echo "ERROR: GCHP installation not found at $GCHP_ROOT"
    exit 1
fi

# Create run directory
mkdir -p $RUNDIR
cd $RUNDIR

echo "=== Copying template files ==="

# Copy base files
cp $GCHP_RUN/ESMF.rc .
cp $GCHP_RUN/input.nml .
cp $GCHP_RUN/logging.yml .
cp $GCHP_RUN/archiveRun.sh .
cp $GCHP_RUN/checkRunSettings.sh .
cp $GCHP_RUN/setRestartLink.sh .
cp $GCHP_RUN/setEnvironmentLink.sh .
cp $GCHP_RUN/setCommonRunSettings.sh.template setCommonRunSettings.sh

# Copy simulation-specific templates
cp $GCHP_RUN/geoschem_config.yml.templates/geoschem_config.yml.${SIM_NAME} geoschem_config.yml
cp $GCHP_RUN/ExtData.rc.templates/ExtData.rc.${SIM_NAME} ExtData.rc
cp $GCHP_RUN/HEMCO_Config.rc.templates/HEMCO_Config.rc.${SIM_NAME} HEMCO_Config.rc
cp $GCHP_RUN/HEMCO_Diagn.rc.templates/HEMCO_Diagn.rc.${SIM_NAME} HEMCO_Diagn.rc

# Copy HISTORY.rc
if [ -f $GCHP_RUN/HISTORY.rc.templates/HISTORY.rc.${SIM_NAME} ]; then
    cp $GCHP_RUN/HISTORY.rc.templates/HISTORY.rc.${SIM_NAME} HISTORY.rc
else
    cp $GCHP_RUN/HISTORY.rc.templates/HISTORY.rc.default HISTORY.rc 2>/dev/null || \
    echo "WARNING: No HISTORY.rc found, you'll need to create one"
fi

# Copy configuration templates
cp $GCHP_RUN/GCHP.rc.template GCHP.rc
cp $GCHP_RUN/CAP.rc.template CAP.rc

# Copy species database
SPECIES_DB=$(find $GCHP_ROOT -path "*/geos-chem/run/shared/species_database.yml" | head -1)
if [ ! -z "$SPECIES_DB" ]; then
    cp $SPECIES_DB .
fi

# Link GCHP executable
ln -sf $GCHP_ROOT/build/bin/gchp .

# Link chemistry data directory
echo "=== Linking data directories ==="
DATA_ROOT="/input"
ln -sf $DATA_ROOT/CHEM_INPUTS ChemDir
echo "Created link: ChemDir -> $DATA_ROOT/CHEM_INPUTS"

echo "=== Setting configuration variables ==="

# Default values for Transport Tracers benchmark
DATA_ROOT="/input"
SIM_DUR_YYYYMMDD="00000007"  # 7 days
SIM_DUR_HHmmSS="000000"
CHEMISTRY_TS="1200"
TRANSPORT_TS="600"
USE_NLPBL="false"

# Met field settings (for GEOS-FP processed files)
MET_WIND_IS_TOP_DOWN="false"
MET_HUMIDITY_IS_TOP_DOWN="false"
MET_NONADVECTION_IS_TOP_DOWN="false"
MET_MASS_FLUX_IS_TOP_DOWN="false"
IMPORT_MASS_FLUX="false"
USE_TOTAL_AIR_PRESSURE="0"

# Adjust for full chemistry if needed
if [ "$SIM_NAME" == "fullchem" ]; then
    SIM_DUR_YYYYMMDD="00000007"  # Still 7 days for benchmark
    CHEMISTRY_TS="1200"
fi

echo "=== Substituting variables in templates ==="

# CAP.rc
sed -i "s/\${RUNDIR_SIM_DUR_YYYYMMDD}/$SIM_DUR_YYYYMMDD/" CAP.rc
sed -i "s/\${RUNDIR_SIM_DUR_HHmmSS}/$SIM_DUR_HHmmSS/" CAP.rc
sed -i "s/BEG_DATE:     .*/BEG_DATE:     20190101 000000/" CAP.rc
sed -i "s/END_DATE:     .*/END_DATE:     20190108 000000/" CAP.rc
sed -i "s/^JOB_SGMT:       $/JOB_SGMT:     $SIM_DUR_YYYYMMDD $SIM_DUR_HHmmSS/" CAP.rc

# geoschem_config.yml
sed -i "s/\${RUNDIR_SIM_NAME}/$SIM_NAME/" geoschem_config.yml
sed -i "s/\${RUNDIR_MET}/$MET_FIELD/" geoschem_config.yml
sed -i "s/\${RUNDIR_CHEMISTRY_TS}/$CHEMISTRY_TS/" geoschem_config.yml
sed -i "s/\${RUNDIR_TRANSPORT_TS}/$TRANSPORT_TS/" geoschem_config.yml
sed -i "s/\${RUNDIR_USE_NLPBL}/$USE_NLPBL/" geoschem_config.yml

# GCHP.rc
sed -i "s/\${RUNDIR_MET_WIND_IS_TOP_DOWN}/$MET_WIND_IS_TOP_DOWN/" GCHP.rc
sed -i "s/\${RUNDIR_MET_HUMIDITY_IS_TOP_DOWN}/$MET_HUMIDITY_IS_TOP_DOWN/" GCHP.rc
sed -i "s/\${RUNDIR_MET_NONADVECTION_IS_TOP_DOWN}/$MET_NONADVECTION_IS_TOP_DOWN/" GCHP.rc
sed -i "s/\${RUNDIR_MET_MASS_FLUX_IS_TOP_DOWN}/$MET_MASS_FLUX_IS_TOP_DOWN/" GCHP.rc
sed -i "s/\${RUNDIR_IMPORT_MASS_FLUX_FROM_EXTDATA}/$IMPORT_MASS_FLUX/" GCHP.rc
sed -i "s/\${RUNDIR_USE_TOTAL_AIR_PRESSURE_IN_ADVECTION}/$USE_TOTAL_AIR_PRESSURE/" GCHP.rc

# Update grid resolution in GCHP.rc
sed -i "s/GCHP.IM_WORLD: .*/GCHP.IM_WORLD: $CS_RES/" GCHP.rc
sed -i "s/GCHP.IM: .*/GCHP.IM: $CS_RES/" GCHP.rc
sed -i "s/IM: .*/IM: $CS_RES/" GCHP.rc

# HEMCO_Config.rc
sed -i "s|\${RUNDIR_DATA_ROOT}|$DATA_ROOT|g" HEMCO_Config.rc
sed -i "s|\${RUNDIR_OCEAN_MASK}|$DATA_ROOT/HEMCO/OCEAN_MASK.geos.1x1.nc|" HEMCO_Config.rc

# ExtData.rc
sed -i "s/\${RUNDIR_MET_EXTDATA_PRIMARY_EXPORTS}//" ExtData.rc
sed -i "s/\${RUNDIR_MET_EXTDATA_DERIVED_EXPORTS}//" ExtData.rc

# setCommonRunSettings.sh - set CS_RES and compute resources
sed -i "s/CS_RES=\${RUNDIR_CS_RES}/CS_RES=$CS_RES/" setCommonRunSettings.sh

# Calculate default compute resources for single-node benchmark
# For C24: Use 48 cores (1 node, 48 cores/node)
# NX and NY will be auto-calculated by setCommonRunSettings.sh
NUM_CORES=48
NUM_NODES=1
CORES_PER_NODE=48

sed -i "s/TOTAL_CORES=\${RUNDIR_NUM_CORES}/TOTAL_CORES=$NUM_CORES/" setCommonRunSettings.sh
sed -i "s/NUM_NODES=\${RUNDIR_NUM_NODES}/NUM_NODES=$NUM_NODES/" setCommonRunSettings.sh
sed -i "s/NUM_CORES_PER_NODE=\${RUNDIR_CORES_PER_NODE}/NUM_CORES_PER_NODE=$CORES_PER_NODE/" setCommonRunSettings.sh

echo "=== Setting up initial conditions ==="

# Create output directories
mkdir -p OutputDir Restarts

# Create cap_restart (initial time)
echo "20190101 000000" > cap_restart

# Link restart file
RESTART_FILE="GEOSChem.Restart.${SIM_NAME}.20190101_0000z.${GRID_RES_LOWER}.nc4"
RESTART_SRC="/input/GEOSCHEM_RESTARTS/GC_14.7.0/$RESTART_FILE"

if [ -f "$RESTART_SRC" ]; then
    ln -sf $RESTART_SRC Restarts/GEOSChem.Restart.20190101_0000z.${GRID_RES_LOWER}.nc4
    echo "Linked restart file: $RESTART_FILE"
else
    echo "WARNING: Restart file not found: $RESTART_SRC"
    echo "You will need to provide a restart file manually"
fi

echo ""
echo "=========================================="
echo "✅ Run directory created successfully!"
echo "=========================================="
echo "Location: $RUNDIR"
echo ""
echo "Files created:"
ls -1 | head -20
echo ""
echo "Next steps:"
echo "1. cd $RUNDIR"
echo "2. Review and adjust setCommonRunSettings.sh for your configuration"
echo "3. Submit your SLURM job"
