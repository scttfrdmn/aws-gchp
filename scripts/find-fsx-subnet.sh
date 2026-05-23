#!/bin/bash
#
# Find a subnet that supports FSx SCRATCH_2
# Usage: AWS_PROFILE=aws bash find-fsx-subnet.sh [region]

REGION=${1:-us-east-1}

echo "Finding FSx SCRATCH_2-compatible subnet in $REGION..."
echo ""

# Get all subnets
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" --query 'Subnets[*].[SubnetId,AvailabilityZone]' --output text)

# Known working AZs (excluding us-east-1e which lacks SCRATCH_2)
# Test by attempting FSx creation (dry-run not available for FSx)
# Based on AWS documentation and testing:
# - us-east-1a, 1b, 1c, 1d, 1f: Support SCRATCH_2 ✅
# - us-east-1e: No SCRATCH_2 support ❌

echo "Subnets (avoiding us-east-1e):"
echo "$SUBNETS" | grep -v "us-east-1e" | while read SUBNET AZ; do
    echo "  $SUBNET - $AZ"
done

echo ""
echo "Recommended subnet (us-east-1a):"
echo "$SUBNETS" | grep "us-east-1a" | head -1

echo ""
echo "Note: FSx SCRATCH_2 availability varies by AZ."
echo "Known issue: us-east-1e lacks SCRATCH_2 support."
