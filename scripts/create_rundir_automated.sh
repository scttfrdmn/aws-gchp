#!/bin/bash
#
# Automated GCHP Run Directory Creation
# Uses the official createRunDir.sh with pre-answered prompts
#
# Usage: ./create_rundir_automated.sh <sim_name> <met> <grid_res> <output_path>
#
# Example: ./create_rundir_automated.sh TransportTracers GEOS-FP c24 /scratch/benchmarks/c24_auto

set -e

if [ $# -ne 4 ]; then
    echo "Usage: $0 <sim_name> <met> <grid_res> <output_path>"
    echo ""
    echo "sim_name: TransportTracers, fullchem, carbon, tagO3"
    echo "met:      GEOS-FP, MERRA2, GEOS-IT"
    echo "grid_res: c24, c48, c90, c180, etc."
    echo "output_path: Full path where run directory will be created"
    exit 1
fi

SIM_NAME=$1
MET=$2
GRID_RES=$3
OUTPUT_PATH=$4

# GCHP installation location
GCHP_ROOT=/fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-14.7.1

if [ ! -d "$GCHP_ROOT" ]; then
    echo "ERROR: GCHP not found at $GCHP_ROOT"
    exit 1
fi

# Map simulation names to menu numbers
case $SIM_NAME in
    fullchem) SIM_NUM=1 ;;
    TransportTracers) SIM_NUM=2 ;;
    carbon) SIM_NUM=3 ;;
    tagO3) SIM_NUM=4 ;;
    *)
        echo "ERROR: Unknown simulation type: $SIM_NAME"
        exit 1
        ;;
esac

# Map met field to menu numbers
case $MET in
    MERRA2|merra2) MET_NUM=1 ;;
    GEOS-FP|geosfp) MET_NUM=2 ;;
    GEOS-IT|geosit) MET_NUM=3 ;;
    *)
        echo "ERROR: Unknown met field: $MET"
        exit 1
        ;;
esac

echo "=========================================="
echo "Automated GCHP Run Directory Creation"
echo "=========================================="
echo "Simulation:  $SIM_NAME (menu: $SIM_NUM)"
echo "Met field:   $MET (menu: $MET_NUM)"
echo "Grid res:    $GRID_RES"
echo "Output:      $OUTPUT_PATH"
echo ""

# Create parent directory if it doesn't exist
mkdir -p $(dirname "$OUTPUT_PATH")

# Prepare responses for createRunDir.sh
# The script asks:
# 1. Simulation type (1-4)
# 2. Met field (1-3)
# 3. For GEOS-FP: acknowledge warning (y), file type (1=processed), advection (1=3hr wind)
# 4. Run directory path
# 5. Run directory name (empty for default)

RESPONSES=""
RESPONSES+="$SIM_NUM\n"      # Simulation type
RESPONSES+="$MET_NUM\n"      # Met field

# GEOS-FP specific prompts
if [ "$MET_NUM" == "2" ]; then
    RESPONSES+="y\n"         # Acknowledge GEOS-FP warning
    RESPONSES+="1\n"         # Processed files
    RESPONSES+="1\n"         # 3-hour winds for advection
fi

# GEOS-IT specific prompts
if [ "$MET_NUM" == "3" ]; then
    RESPONSES+="n\n"         # Not using Discover
    RESPONSES+="2\n"         # Raw files (assuming standard setup)
    RESPONSES+="2\n"         # 3-hour winds
fi

RESPONSES+="$(dirname $OUTPUT_PATH)\n"  # Parent directory path
RESPONSES+="$(basename $OUTPUT_PATH)\n" # Run directory name

echo "=== Running createRunDir.sh with automated responses ==="

cd $GCHP_ROOT/run
printf "$RESPONSES" | ./createRunDir.sh

if [ ! -d "$OUTPUT_PATH" ]; then
    echo "ERROR: Run directory was not created at $OUTPUT_PATH"
    exit 1
fi

echo ""
echo "=== Configuring for grid resolution $GRID_RES ==="
cd $OUTPUT_PATH

# Extract numeric resolution (e.g., c24 -> 24)
CS_RES=$(echo $GRID_RES | sed 's/c//' | sed 's/C//')

# Update setCommonRunSettings.sh with specific values for benchmarking
# For single-node benchmarks, use 48 cores
sed -i "s/CS_RES=.*/CS_RES=$CS_RES/" setCommonRunSettings.sh
sed -i "s/TOTAL_CORES=.*/TOTAL_CORES=48/" setCommonRunSettings.sh
sed -i "s/NUM_NODES=.*/NUM_NODES=1/" setCommonRunSettings.sh
sed -i "s/NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=48/" setCommonRunSettings.sh

# Configure CAP.rc for 7-day benchmark (2019-01-01 to 2019-01-08)
echo "=== Configuring simulation dates ==="
sed -i "s/^BEG_DATE:.*/BEG_DATE:     20190101 000000/" CAP.rc
sed -i "s/^END_DATE:.*/END_DATE:     20190108 000000/" CAP.rc
sed -i "s/^JOB_SGMT:.*/JOB_SGMT:     00000007 000000/" CAP.rc

# Set initial time in cap_restart
echo "20190101 000000" > cap_restart

# Run setCommonRunSettings.sh to auto-calculate NX/NY and update config files
echo "=== Running configuration scripts ==="
source setCommonRunSettings.sh
source setRestartLink.sh

# Link GCHP executable
ln -sf $GCHP_ROOT/build/bin/gchp .

# Verify NX and NY were set correctly
echo ""
echo "=== Verification ==="
echo "Grid resolution: C$CS_RES"
echo "Domain decomposition:"
grep "^NX:\|^NY:" GCHP.rc | head -2
echo "Compute resources:"
grep "^TOTAL_CORES\|^NUM_NODES\|^NUM_CORES" setCommonRunSettings.sh | grep -v "^#"

# Check CAP.rc dates
echo "Simulation dates:"
grep "^BEG_DATE:\|^END_DATE:\|^JOB_SGMT:" CAP.rc

# Check for restart file
RESTART_FILE="Restarts/GEOSChem.Restart.20190101_000000z.c${CS_RES}.nc4"
if [ -L "$RESTART_FILE" ]; then
    echo "Restart file: $(readlink $RESTART_FILE)"
else
    echo "WARNING: Restart file not linked at $RESTART_FILE"
fi

# Check cap_restart
if [ -f "cap_restart" ]; then
    echo "Initial time: $(cat cap_restart)"
else
    echo "WARNING: cap_restart file not found"
fi

# Check GCHP executable
if [ -L "gchp" ]; then
    echo "GCHP executable: $(readlink gchp)"
else
    echo "WARNING: GCHP executable not linked"
fi

echo ""
echo "=========================================="
echo "✅ Run directory created successfully!"
echo "=========================================="
echo "Location: $OUTPUT_PATH"
echo ""
echo "Next steps:"
echo "1. Review configuration files"
echo "2. Create and submit SLURM job script"
