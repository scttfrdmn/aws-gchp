#!/bin/bash
#
# Monitor GCHP build progress via SSM
# Usage: AWS_PROFILE=aws bash monitor-build.sh [instance-id] [check-interval-seconds]
#
# Checks build log periodically and alerts on:
# - Build completion
# - Build failures
# - Process died unexpectedly

INSTANCE_ID=${1:-i-0fd015a17f55b0491}
CHECK_INTERVAL=${2:-300}  # 5 minutes default
REGION="us-east-1"
LOG_FILE="/fsx/build-gcc12.3-ompi4.1.7-gchp14.7.1.log"
BUILD_SCRIPT="build-gchp-stack.sh"

echo "=== GCHP Build Monitor ==="
echo "Instance: $INSTANCE_ID"
echo "Region: $REGION"
echo "Check interval: ${CHECK_INTERVAL}s"
echo "Start time: $(date)"
echo ""

# Track state
LAST_LOG_SIZE=0
STALL_COUNT=0
MAX_STALLS=3  # Alert after 3 checks with no progress

check_build() {
    local CHECK_NUM=$1

    echo "[$(date +'%H:%M:%S')] Check #$CHECK_NUM"

    # Send SSM command to check status
    COMMAND_ID=$(AWS_PROFILE=aws aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["ps aux | grep '"$BUILD_SCRIPT"' | grep bash | grep -v grep","echo ---","tail -30 '"$LOG_FILE"' 2>/dev/null || echo Log not found","echo ---","wc -l '"$LOG_FILE"' 2>/dev/null || echo 0"]' \
        --output text \
        --query 'Command.CommandId' 2>&1)

    if [[ $COMMAND_ID == *"error"* ]] || [[ $COMMAND_ID == *"Error"* ]]; then
        echo "  ❌ SSM command failed: $COMMAND_ID"
        return 1
    fi

    # Wait for command to complete
    sleep 5

    # Get results
    OUTPUT=$(AWS_PROFILE=aws aws ssm get-command-invocation \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'StandardOutputContent' \
        --output text 2>&1)

    if [[ $OUTPUT == *"error"* ]] || [[ $OUTPUT == *"Error"* ]]; then
        echo "  ⚠️  Could not retrieve output"
        return 1
    fi

    # Parse output (format: process info --- log tail --- line count)
    PROCESS_INFO=$(echo "$OUTPUT" | awk '/^---/{flag=1;next}/^---/{flag=0}!flag')
    LOG_TAIL=$(echo "$OUTPUT" | awk '/^---/{flag++;next}flag==1')
    LOG_SIZE=$(echo "$OUTPUT" | awk '/^---/{flag++;next}flag==2' | awk '{print $1}')

    # Check if process is running
    if [[ -z "$PROCESS_INFO" ]]; then
        # Process not running - check if build completed or failed
        if echo "$LOG_TAIL" | grep -q "Build complete!"; then
            echo ""
            echo "✅ ============================================"
            echo "✅ BUILD COMPLETED SUCCESSFULLY!"
            echo "✅ ============================================"
            echo ""
            echo "Final log:"
            echo "$LOG_TAIL"
            echo ""
            echo "Next steps:"
            echo "1. Verify stack: source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh && gcc --version"
            echo "2. Check S3: aws s3 ls s3://gchp-shared-storage-us-east-1/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/"
            echo "3. Delete cluster: AWS_PROFILE=aws ~/.local/bin/pcluster delete-cluster --cluster-name gchp-builder --region us-east-1"
            return 2  # Success exit
        elif echo "$LOG_TAIL" | grep -qE "Error|ERROR|error:|failed|FAILED|Fatal"; then
            echo ""
            echo "❌ ============================================"
            echo "❌ BUILD FAILED!"
            echo "❌ ============================================"
            echo ""
            echo "Error in log:"
            echo "$LOG_TAIL"
            echo ""
            echo "Troubleshooting:"
            echo "1. SSH to cluster: ssh -i ~/.ssh/aws-gchp.pem ec2-user@$(AWS_PROFILE=aws ~/.local/bin/pcluster describe-cluster --cluster-name gchp-builder --region us-east-1 --query 'headNode.publicIpAddress' --output text)"
            echo "2. Check full log: tail -100 $LOG_FILE"
            echo "3. Fix issue and restart: cd /fsx && nohup bash build-gchp-stack.sh > build.log 2>&1 &"
            return 3  # Failure exit
        elif [[ "$LOG_SIZE" -gt 0 ]]; then
            echo "  ⚠️  Build process died (but log exists - may have crashed)"
            echo ""
            echo "Last log entries:"
            echo "$LOG_TAIL"
            echo ""
            echo "Action needed: SSH to cluster and investigate"
            return 3
        else
            echo "  ℹ️  Build not started yet"
        fi
    else
        # Process is running
        echo "  ✓ Build process running (PID: $(echo "$PROCESS_INFO" | awk '{print $2}'))"

        # Check for progress
        if [[ "$LOG_SIZE" -gt "$LAST_LOG_SIZE" ]]; then
            STALL_COUNT=0
            local LINES_ADDED=$((LOG_SIZE - LAST_LOG_SIZE))
            echo "  📝 Progress: +$LINES_ADDED lines (total: $LOG_SIZE)"
            LAST_LOG_SIZE=$LOG_SIZE

            # Show current stage
            CURRENT_STAGE=$(echo "$LOG_TAIL" | grep -E "Building|Installing|Downloading" | tail -1)
            if [[ -n "$CURRENT_STAGE" ]]; then
                echo "  🔨 Current: $CURRENT_STAGE"
            fi
        else
            STALL_COUNT=$((STALL_COUNT + 1))
            echo "  ⏸️  No progress since last check (stall count: $STALL_COUNT/$MAX_STALLS)"

            if [[ $STALL_COUNT -ge $MAX_STALLS ]]; then
                echo ""
                echo "  ⚠️  WARNING: Build appears stalled!"
                echo "  Last activity: $(echo "$LOG_TAIL" | tail -5)"
                echo ""
            fi
        fi

        # Show last few log lines
        echo ""
        echo "  Recent log:"
        echo "$LOG_TAIL" | tail -5 | sed 's/^/    /'
    fi

    echo ""
}

# Main monitoring loop
CHECK_NUM=0
while true; do
    CHECK_NUM=$((CHECK_NUM + 1))

    check_build $CHECK_NUM
    EXIT_CODE=$?

    if [[ $EXIT_CODE -eq 2 ]]; then
        # Build completed successfully
        exit 0
    elif [[ $EXIT_CODE -eq 3 ]]; then
        # Build failed
        exit 1
    fi

    # Wait before next check
    echo "Sleeping ${CHECK_INTERVAL}s until next check..."
    echo ""
    sleep $CHECK_INTERVAL
done
