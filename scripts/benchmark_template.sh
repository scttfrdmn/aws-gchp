#!/bin/bash
#SBATCH --job-name=BENCHMARK_NAME
#SBATCH --nodes=NUM_NODES
#SBATCH --ntasks=TOTAL_CORES
#SBATCH --cpus-per-task=1
#SBATCH --partition=compute
#SBATCH --time=02:00:00
#SBATCH --output=benchmark_%j.log
#SBATCH --error=benchmark_%j.err

set -e

echo "=========================================="
echo "BENCHMARK_DESCRIPTION"
echo "=========================================="
echo "Job ID: $SLURM_JOB_ID"
echo "Node(s): $(hostname)"
echo "Cores: $SLURM_NTASKS"
echo "Start time: $(date)"
echo ""

# Load GCHP environment
STACK_DIR=/fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1
export GCHP_ROOT=$STACK_DIR/gchp-14.7.1

if [ -f "$STACK_DIR/gchp-env.sh" ]; then
    echo "✅ Loaded GCHP stack"
    source $STACK_DIR/gchp-env.sh
    gcc --version | head -1
    mpirun --version | head -1
else
    echo "❌ ERROR: GCHP environment not found"
    exit 1
fi

echo ""
echo "=== Configuration ==="
echo "Grid: GRID_RES"
grep "^BEG_DATE:\|^END_DATE:" CAP.rc
echo "Domain decomposition:"
grep "^NX:\|^NY:" GCHP.rc

echo ""
echo "=== Running GCHP ==="
START_TIME=$(date +%s)

log=gchp.$(date -u +%Y%m%d_%H%M%S).log
srun --mpi=pmix ./gchp | tee ${log}

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))

echo ""
echo "=========================================="
echo "Benchmark Complete"
echo "=========================================="
echo "End time: $(date)"
echo "Elapsed: ${ELAPSED}s (${MINUTES}m)"

# Verify simulation advanced
new_start=$(sed 's/ /_/g' cap_restart)
if [[ "$new_start" != "20190101_000000" ]]; then
    echo "✅ SUCCESS: Simulation completed"
    echo "Final time: $new_start"

    # Calculate throughput
    SIMULATED_DAYS=7
    THROUGHPUT=$(echo "scale=2; $SIMULATED_DAYS * 24 * 3600 / $ELAPSED" | bc)
    echo ""
    echo "=== Performance ==="
    echo "Wall time: ${ELAPSED}s (${MINUTES}m)"
    echo "Simulated: ${SIMULATED_DAYS} days"
    echo "Throughput: ${THROUGHPUT}x realtime"
    echo ""
    echo "=== Configuration ==="
    echo "Grid: GRID_RES"
    echo "Nodes: NUM_NODES"
    echo "Cores: TOTAL_CORES"
    echo "Domain decomposition: NX × NY × 6 faces"
    exit 0
else
    echo "❌ FAILED: cap_restart unchanged"
    exit 1
fi
