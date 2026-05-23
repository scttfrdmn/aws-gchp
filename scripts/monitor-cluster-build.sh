#!/bin/bash
#
# Monitor GCHP builder cluster creation and build progress
# Usage: AWS_PROFILE=aws bash monitor-cluster-build.sh [cluster-name]

CLUSTER_NAME=${1:-gchp-builder}
REGION="us-east-2"

echo "Monitoring cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo ""

# Check if pcluster is available
if ! command -v pcluster &> /dev/null; then
    if [ -f "$HOME/.local/bin/pcluster" ]; then
        PCLUSTER="$HOME/.local/bin/pcluster"
    else
        echo "ERROR: pcluster not found"
        exit 1
    fi
else
    PCLUSTER="pcluster"
fi

echo "Using: $PCLUSTER version"
$PCLUSTER version
echo ""

# Function to get cluster status
get_cluster_status() {
    $PCLUSTER describe-cluster \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" 2>&1 | \
        grep '"clusterStatus"' | \
        cut -d'"' -f4
}

# Function to get head node IP
get_head_node_ip() {
    $PCLUSTER describe-cluster \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" 2>&1 | \
        grep '"publicIpAddress"' | \
        cut -d'"' -f4 | head -1
}

# Monitor cluster creation
echo "=== Cluster Creation Status ==="
while true; do
    STATUS=$(get_cluster_status)

    if [ -z "$STATUS" ]; then
        echo "[$(date +'%H:%M:%S')] Cluster not found"
        break
    fi

    echo "[$(date +'%H:%M:%S')] Status: $STATUS"

    case "$STATUS" in
        "CREATE_COMPLETE")
            echo ""
            echo "✅ Cluster created successfully!"
            HEAD_IP=$(get_head_node_ip)
            echo "Head node IP: $HEAD_IP"
            echo ""
            echo "Next steps:"
            echo "1. SSH to head node:"
            echo "   ssh -i ~/.ssh/aws-gchp.pem ec2-user@$HEAD_IP"
            echo ""
            echo "2. Run build script:"
            echo "   aws s3 cp s3://gchp-shared-storage-us-east-2/scripts/build-gchp-stack.sh /fsx/"
            echo "   cd /fsx"
            echo "   nohup bash build-gchp-stack.sh > build.log 2>&1 &"
            echo ""
            echo "3. Monitor build progress:"
            echo "   tail -f /fsx/build-gcc12.3-ompi4.1.7-gchp14.7.1.log"
            break
            ;;
        "CREATE_FAILED")
            echo ""
            echo "❌ Cluster creation failed"
            echo "Check logs with:"
            echo "  $PCLUSTER get-cluster-stack-events --cluster-name $CLUSTER_NAME --region $REGION"
            exit 1
            ;;
        "DELETE_COMPLETE"|"DELETE_FAILED")
            echo "Cluster deleted"
            break
            ;;
    esac

    sleep 30
done
