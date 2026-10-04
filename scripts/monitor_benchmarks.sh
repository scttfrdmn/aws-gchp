#!/bin/bash
#
# Monitor GCHP Benchmark Progress
#

SSH_KEY="~/.ssh/aws-gchp.pem"
HEAD_NODE="ec2-user@54.224.221.95"

echo "=========================================="
echo "GCHP Benchmark Monitor"
echo "=========================================="
echo "Start time: $(date)"
echo ""

while true; do
    clear
    echo "=========================================="
    echo "GCHP Benchmark Status - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    echo ""

    # Show queue status
    echo "=== SLURM Queue ==="
    ssh -i $SSH_KEY $HEAD_NODE "squeue -o '%.10i %.12j %.10u %.2t %.10M %.6D %R'"

    echo ""
    echo "=== Benchmark Progress ==="

    for bench in bench01_c24_1node bench02_c48_1node bench03_c90_2node bench04_c180_4node; do
        ssh -i $SSH_KEY $HEAD_NODE bash << EOF
            cd /scratch/benchmarks/$bench 2>/dev/null || exit 0
            cap=\$(cat cap_restart 2>/dev/null || echo "No cap_restart")
            echo "$bench: \$cap"
EOF
    done

    echo ""
    echo "=== Completed Benchmarks ==="
    ssh -i $SSH_KEY $HEAD_NODE bash << 'EOF'
        cd /scratch/benchmarks
        for bench in bench*/benchmark_*.log; do
            if grep -q "✅ SUCCESS" "$bench" 2>/dev/null; then
                dir=$(dirname "$bench")
                jobid=$(basename "$bench" .log | sed 's/benchmark_//')
                throughput=$(grep "Throughput:" "$bench" | tail -1 | awk '{print $2}')
                walltime=$(grep "Elapsed:" "$bench" | grep -o '[0-9]*s' | head -1)
                echo "  $dir (Job $jobid): $walltime, $throughput"
            fi
        done
EOF

    echo ""
    echo "Press Ctrl+C to exit"
    sleep 30
done
