#!/bin/bash
#
# Create All GCHP Benchmark Run Directories
#
# This script creates 15 benchmark configurations:
# - Phase 1: Transport Tracers (C24, C48, C90, C180) on 1, 2, 4, 8 nodes
# - Phase 2: Full Chemistry (same grids and node counts) - Future work
#
# Each benchmark is a 7-day simulation (2019-01-01 to 2019-01-08)

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BENCHMARK_ROOT="/scratch/benchmarks"

# Benchmark configurations
# Format: "name:grid:nodes:cores:description"
BENCHMARKS=(
    "bench01:c24:1:48:C24 Transport Tracers, 1 node"
    "bench02:c24:2:96:C24 Transport Tracers, 2 nodes"
    "bench03:c48:1:48:C48 Transport Tracers, 1 node"
    "bench04:c48:2:96:C48 Transport Tracers, 2 nodes"
    "bench05:c48:4:192:C48 Transport Tracers, 4 nodes"
    "bench06:c90:2:96:C90 Transport Tracers, 2 nodes"
    "bench07:c90:4:192:C90 Transport Tracers, 4 nodes"
    "bench08:c90:8:384:C90 Transport Tracers, 8 nodes"
    "bench09:c180:4:192:C180 Transport Tracers, 4 nodes"
    "bench10:c180:8:384:C180 Transport Tracers, 8 nodes"
)

echo "=========================================="
echo "GCHP Benchmark Suite Creation"
echo "=========================================="
echo "Total benchmarks: ${#BENCHMARKS[@]}"
echo "Location: $BENCHMARK_ROOT"
echo ""

# Check if on cluster
if ! ssh -i ~/.ssh/aws-gchp.pem ec2-user@54.224.221.95 "echo 'Connected'" &>/dev/null; then
    echo "ERROR: Cannot connect to cluster"
    echo "Make sure gchp-benchmark cluster is running"
    exit 1
fi

# Copy scripts to cluster
echo "=== Copying scripts to cluster ==="
scp -i ~/.ssh/aws-gchp.pem \
    "$SCRIPT_DIR/create_rundir_automated.sh" \
    "$SCRIPT_DIR/benchmark_template.sh" \
    ec2-user@54.224.221.95:$BENCHMARK_ROOT/

echo ""
echo "=== Creating benchmark directories ==="

for bench_config in "${BENCHMARKS[@]}"; do
    IFS=':' read -r name grid nodes cores description <<< "$bench_config"

    echo ""
    echo "[$name] $description"
    echo "  Grid: $grid, Nodes: $nodes, Cores: $cores"

    rundir="$BENCHMARK_ROOT/${name}_${grid}_${nodes}node"

    # Create run directory using automated script
    ssh -i ~/.ssh/aws-gchp.pem ec2-user@54.224.221.95 bash << EOF
        set -e
        cd $BENCHMARK_ROOT

        # Remove old directory if exists
        rm -rf $rundir

        # Create run directory
        ./create_rundir_automated.sh TransportTracers GEOS-FP $grid $rundir

        cd $rundir

        # Update compute resources for this benchmark
        sed -i "s/TOTAL_CORES=.*/TOTAL_CORES=$cores/" setCommonRunSettings.sh
        sed -i "s/NUM_NODES=.*/NUM_NODES=$nodes/" setCommonRunSettings.sh
        sed -i "s/NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=\$((cores / nodes))/" setCommonRunSettings.sh

        # Re-run setCommonRunSettings to calculate NX/NY for this core count
        source setCommonRunSettings.sh

        # Verify NX and NY
        echo "  Domain decomposition: NX=\$(grep '^NX:' GCHP.rc | awk '{print \$2}'), NY=\$(grep '^NY:' GCHP.rc | awk '{print \$2}')"

        # Create job script from template
        sed -e "s/BENCHMARK_NAME/${name}/g" \
            -e "s/NUM_NODES/$nodes/g" \
            -e "s/TOTAL_CORES/$cores/g" \
            -e "s/BENCHMARK_DESCRIPTION/$description/g" \
            -e "s/GRID_RES/$grid/g" \
            $BENCHMARK_ROOT/benchmark_template.sh > run_benchmark.sh
        chmod +x run_benchmark.sh

        echo "  ✅ Created: $rundir"
EOF

    if [ $? -ne 0 ]; then
        echo "  ❌ Failed to create $name"
        exit 1
    fi
done

echo ""
echo "=========================================="
echo "✅ All benchmarks created successfully!"
echo "=========================================="
echo ""
echo "To run benchmarks:"
echo "  ssh to cluster: ssh -i ~/.ssh/aws-gchp.pem ec2-user@54.224.221.95"
echo "  cd $BENCHMARK_ROOT/bench01_c24_1node"
echo "  sbatch run_benchmark.sh"
echo ""
echo "To run all benchmarks sequentially:"
echo "  for bench in bench{01..10}_*/; do"
echo "    cd \$bench && sbatch run_benchmark.sh && cd .."
echo "  done"
