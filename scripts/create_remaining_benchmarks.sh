#!/bin/bash
#
# Create remaining GCHP benchmarks by copying and modifying c24_proper
#
# Phase 1: Transport Tracers only
# - C24: 1, 2 nodes (48, 96 cores)
# - C48: 1, 2, 4 nodes (48, 96, 192 cores)
# - C90: 2, 4, 8 nodes (96, 192, 384 cores)
# - C180: 4, 8 nodes (192, 384 cores)

set -e

HEAD_NODE="ec2-user@54.224.221.95"
SSH_KEY="~/.ssh/aws-gchp.pem"

echo "=========================================="
echo "Creating GCHP Benchmark Suite"
echo "=========================================="

# Benchmark configurations: "name:grid:nodes:cores:nx:ny"
# NX and NY must satisfy: NX × NY / 6 × 6 = cores
BENCHMARKS=(
    "bench01:c24:1:48:2:24"
    "bench02:c48:1:48:2:24"
    "bench03:c90:2:96:2:48"
    "bench04:c180:4:192:4:48"
)

for config in "${BENCHMARKS[@]}"; do
    IFS=':' read -r name grid nodes cores nx ny <<< "$config"

    rundir="bench${name#bench}_${grid}_${nodes}node"

    echo ""
    echo "=== Creating $rundir ==="
    echo "Grid: $grid, Nodes: $nodes, Cores: $cores, NX: $nx, NY: $ny"

    ssh -i $SSH_KEY $HEAD_NODE bash << EOF
        set -e
        cd /scratch/benchmarks

        # Copy from c24_proper template
        rm -rf $rundir
        cp -r c24_proper $rundir

        cd $rundir

        # Update grid resolution
        CS_RES=\${grid#c}
        sed -i "s/CS_RES=.*/CS_RES=\$CS_RES/" setCommonRunSettings.sh
        sed -i "s/^GCHP.IM_WORLD: .*/GCHP.IM_WORLD: \$CS_RES/" GCHP.rc
        sed -i "s/^GCHP.IM: .*/GCHP.IM: \$CS_RES/" GCHP.rc
        sed -i "s/^IM: .*/IM: \$CS_RES/" GCHP.rc

        # Update compute resources
        sed -i "s/TOTAL_CORES=.*/TOTAL_CORES=$cores/" setCommonRunSettings.sh
        sed -i "s/NUM_NODES=.*/NUM_NODES=$nodes/" setCommonRunSettings.sh
        sed -i "s/NUM_CORES_PER_NODE=.*/NUM_CORES_PER_NODE=\$((cores / nodes))/" setCommonRunSettings.sh

        # Set domain decomposition
        sed -i "s/^NX: .*/NX: $nx/" GCHP.rc
        sed -i "s/^NY: .*/NY: $ny/" GCHP.rc

        # Reset cap_restart
        echo "20190101 000000" > cap_restart

        # Create job script
        cat > run_benchmark.sh << 'JOBSCRIPT'
#!/bin/bash
#SBATCH --job-name=$name-$grid
#SBATCH --nodes=$nodes
#SBATCH --ntasks=$cores
#SBATCH --cpus-per-task=1
#SBATCH --partition=compute
#SBATCH --time=04:00:00
#SBATCH --output=benchmark_%j.log
#SBATCH --error=benchmark_%j.err

set -e

echo "=========================================="
echo "$name: $grid Transport Tracers, $nodes node(s)"
echo "=========================================="
echo "Job ID: \\\$SLURM_JOB_ID"
echo "Start time: \\\$(date)"

source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh

echo "=== Configuration ==="
grep "^BEG_DATE:\|^END_DATE:" CAP.rc
grep "^NX:\|^NY:" GCHP.rc

START_TIME=\\\$(date +%s)
log=gchp.\\\$(date -u +%Y%m%d_%H%M%S).log
srun --mpi=pmix ./gchp | tee \\\${log}
END_TIME=\\\$(date +%s)
ELAPSED=\\\$((END_TIME - START_TIME))

echo "Elapsed: \\\${ELAPSED}s (\\\$((ELAPSED / 60))m)"
new_start=\\\$(sed 's/ /_/g' cap_restart)
if [[ "\\\$new_start" != "20190101_000000" ]]; then
    THROUGHPUT=\\\$(echo "scale=2; 7 * 24 * 3600 / \\\$ELAPSED" | bc)
    echo "✅ SUCCESS - Throughput: \\\${THROUGHPUT}x realtime"
else
    echo "❌ FAILED"
    exit 1
fi
JOBSCRIPT

        chmod +x run_benchmark.sh

        echo "✅ Created $rundir"
        echo "   NX=$nx, NY=$ny, Cores=$cores"
EOF

done

echo ""
echo "=========================================="
echo "✅ Benchmarks created!"
echo "=========================================="
echo ""
echo "To submit all benchmarks:"
echo "  ssh -i $SSH_KEY $HEAD_NODE"
echo "  cd /scratch/benchmarks"
echo "  for dir in bench*_*node; do"
echo "    echo \"Submitting \$dir\""
echo "    cd \$dir && sbatch run_benchmark.sh && cd .."
echo "  done"
