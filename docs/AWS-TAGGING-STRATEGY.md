# AWS Resource Tagging Strategy

**Date:** January 28, 2026
**Purpose:** Ensure all AWS resources are properly tagged for cost tracking, management, and compliance

---

## Why Tagging Matters

**Cost Tracking:**
- Attribute costs to specific projects, teams, or environments
- Generate cost reports by tag
- Set up cost allocation tags

**Resource Management:**
- Find resources by owner, project, or purpose
- Automate resource lifecycle (e.g., auto-delete test resources)
- Track which resources belong together

**Compliance:**
- Identify resource owners
- Track managed vs manual resources
- Audit resource usage

---

## Standard Tags for GCHP Project

All AWS resources (clusters, FSx volumes, EC2 instances, etc.) use these tags:

### Required Tags

| Tag Key | Description | Example Values |
|---------|-------------|----------------|
| `Project` | Project identifier | `GCHP-Benchmarking` |
| `Application` | Application name | `Atmospheric-Chemistry` |
| `Purpose` | Specific purpose of resource | `Production-Research-Cluster`, `Automation-Testing` |
| `Environment` | Environment type | `Production`, `Test`, `Development` |
| `ManagedBy` | Management method | `ParallelCluster-Automation` |
| `Owner` | Resource owner email | `your.name@example.com` |
| `CostCenter` | Cost allocation | `Research`, `Operations` |

### Recommended Tags

| Tag Key | Description | Example Values |
|---------|-------------|----------------|
| `Compiler` | Compiler used | `GCC-14`, `Intel-oneAPI-2025`, `AOCC-5.0` |
| `GitRepo` | Source repository | `aws-gchp` |
| `Documentation` | Documentation URL | `https://github.com/aws/aws-gchp` |
| `TestType` | For test resources | `EFA-Multi-Node-MPI`, `Single-Node-Validation` |
| `TemporaryResource` | Mark for deletion | `true`, `false` |
| `AutoDelete` | Auto-deletion policy | `After-Testing`, `After-30-Days`, `Manual` |
| `CreatedDate` | Creation timestamp | `2026-01-28` |

---

## Configuration Files

Tags are defined in ParallelCluster YAML configs:

```yaml
Tags:
  - Key: Project
    Value: GCHP-Benchmarking
  - Key: Application
    Value: Atmospheric-Chemistry
  - Key: Purpose
    Value: Production-Research-Cluster
  - Key: Environment
    Value: Production
  - Key: ManagedBy
    Value: ParallelCluster-Automation
  - Key: Compiler
    Value: GCC-14
  - Key: Owner
    Value: "your.email@example.com"
  - Key: CostCenter
    Value: Research
  - Key: GitRepo
    Value: aws-gchp
```

### Placeholder for Owner

Configs use a placeholder for the Owner tag:
```yaml
  - Key: Owner
    Value: "{{ OWNER_EMAIL }}"
```

**Before deploying**, replace this with your email using the helper script:

```bash
./scripts/set-owner-tag.sh your.email@example.com
```

Or manually edit the configs.

---

## Tagged Resources

### ParallelCluster Resources

When you create a cluster, tags propagate to:

- **EC2 Instances** (head node and compute nodes)
- **FSx Lustre filesystems**
- **EBS volumes**
- **Security groups** (if created by ParallelCluster)
- **Placement groups** (if used)
- **Network interfaces**

### Manual Resources

For resources created outside ParallelCluster (e.g., persistent FSx volumes):

```bash
# Tag FSx volume
aws fsx tag-resource \
  --resource-arn arn:aws:fsx:us-west-2:123456789012:file-system/fs-0123456789abcdef0 \
  --tags Key=Project,Value=GCHP-Benchmarking \
         Key=Purpose,Value=Persistent-Data-Volume \
         Key=Owner,Value=your.email@example.com

# Tag S3 bucket
aws s3api put-bucket-tagging \
  --bucket my-gchp-data \
  --tagging 'TagSet=[{Key=Project,Value=GCHP-Benchmarking},{Key=Owner,Value=your.email@example.com}]'
```

---

## Cost Allocation Tags

Enable cost allocation tags in AWS Cost Explorer:

1. Go to AWS Console → Billing → Cost Allocation Tags
2. Activate these tags:
   - `Project`
   - `Environment`
   - `Owner`
   - `CostCenter`
   - `Purpose`

3. Wait 24 hours for tags to appear in Cost Explorer
4. Create cost reports filtering by tag

---

## Tag-Based Automation

### Auto-Delete Test Resources

Tag test resources for automatic cleanup:

```yaml
Tags:
  - Key: TemporaryResource
    Value: "true"
  - Key: AutoDelete
    Value: After-Testing
```

Then use a Lambda function or script to find and delete:

```bash
# Find temporary clusters
aws ec2 describe-instances \
  --filters "Name=tag:TemporaryResource,Values=true" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0]]'

# Delete with ParallelCluster
pcluster delete-cluster --cluster-name <name>
```

### Cost Alerts by Tag

Set up billing alerts for specific tags:

```bash
# CloudWatch alarm for costs by Project tag
aws cloudwatch put-metric-alarm \
  --alarm-name gchp-cost-alert \
  --alarm-description "Alert if GCHP costs exceed $500/month" \
  --metric-name BlendedCost \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --evaluation-periods 1 \
  --threshold 500 \
  --dimensions Name=Currency,Value=USD Name=LinkedAccount,Value=123456789012
```

---

## Querying Resources by Tags

### AWS CLI

```bash
# Find all GCHP resources
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=GCHP-Benchmarking \
  --region us-west-2

# Find production clusters
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=GCHP-Benchmarking" \
            "Name=tag:Environment,Values=Production" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Find test resources to clean up
aws ec2 describe-instances \
  --filters "Name=tag:TemporaryResource,Values=true" \
  --query 'Reservations[].Instances[].[InstanceId,LaunchTime,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

### AWS Console

1. Go to **Resource Groups & Tag Editor**
2. Create a saved search:
   - Tag: `Project = GCHP-Benchmarking`
   - Resource types: All
3. View all GCHP resources in one place

---

## Environment-Specific Tags

### Test Cluster Tags

```yaml
Tags:
  - Key: Environment
    Value: Test
  - Key: Purpose
    Value: Automation-Testing
  - Key: TemporaryResource
    Value: "true"
  - Key: AutoDelete
    Value: After-Testing
```

### Production Cluster Tags

```yaml
Tags:
  - Key: Environment
    Value: Production
  - Key: Purpose
    Value: Production-Research-Cluster
  - Key: TemporaryResource
    Value: "false"
  - Key: AutoDelete
    Value: Manual
```

### Multi-Node Test Tags

```yaml
Tags:
  - Key: Environment
    Value: Test
  - Key: Purpose
    Value: Multi-Node-MPI-Testing
  - Key: TestType
    Value: EFA-Multi-Node-MPI
  - Key: TemporaryResource
    Value: "true"
```

---

## Best Practices

### 1. Always Tag New Resources

Before creating any AWS resource:
- Set Owner tag to your email
- Set Environment tag (Test/Production/Development)
- Set Purpose tag (what it's for)
- Set TemporaryResource tag if it's temporary

### 2. Review Tags Regularly

Monthly review:
```bash
# Find untagged resources
aws resourcegroupstaggingapi get-resources \
  --resource-type-filters ec2:instance \
  --region us-west-2 \
  --query 'ResourceTagMappingList[?length(Tags)==`0`]'
```

### 3. Use Consistent Values

- **Environments:** Production, Test, Development (capitalized)
- **TemporaryResource:** "true" or "false" (quoted string)
- **Owner:** Always use email addresses

### 4. Tag Shared Resources

FSx persistent data volumes, S3 buckets, etc. should also be tagged:
- Even if shared across environments
- Use most appropriate Environment tag (usually Production)
- List all relevant owners if multiple teams use it

---

## Cost Analysis Examples

### Monthly Cost by Environment

```bash
# Production costs
aws ce get-cost-and-usage \
  --time-period Start=2026-01-01,End=2026-02-01 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --filter file://filter-production.json

# filter-production.json:
{
  "And": [
    {"Tags": {"Key": "Project", "Values": ["GCHP-Benchmarking"]}},
    {"Tags": {"Key": "Environment", "Values": ["Production"]}}
  ]
}
```

### Cost by Owner

Useful for multi-user environments:

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-01-01,End=2026-02-01 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=TAG,Key=Owner
```

---

## Compliance and Audit

### Required Tag Report

Generate report of resources missing required tags:

```bash
#!/bin/bash
# check-required-tags.sh

REQUIRED_TAGS=("Project" "Owner" "Environment" "CostCenter")

for tag in "${REQUIRED_TAGS[@]}"; do
    echo "Checking for missing $tag tag..."
    aws resourcegroupstaggingapi get-resources \
      --region us-west-2 \
      --query "ResourceTagMappingList[?!contains(keys(Tags[]), '$tag')].[ResourceARN]" \
      --output text
done
```

### Tag Value Compliance

Ensure tag values follow standards:

```python
# validate-tags.py
import boto3

VALID_ENVIRONMENTS = ['Production', 'Test', 'Development']
VALID_PROJECTS = ['GCHP-Benchmarking']

client = boto3.client('resourcegroupstaggingapi')

# Get all resources with Project tag
resources = client.get_resources(
    TagFilters=[{'Key': 'Project', 'Values': VALID_PROJECTS}]
)

for resource in resources['ResourceTagMappingList']:
    tags = {tag['Key']: tag['Value'] for tag in resource['Tags']}

    # Check Environment tag validity
    if 'Environment' in tags:
        if tags['Environment'] not in VALID_ENVIRONMENTS:
            print(f"Invalid Environment tag: {resource['ResourceARN']}")
```

---

## Summary

**All GCHP AWS resources must be tagged with:**
1. Project = GCHP-Benchmarking
2. Owner = your.email@example.com
3. Environment = Production/Test/Development
4. Purpose = (specific purpose)
5. CostCenter = Research

**Use helper script before deployment:**
```bash
./scripts/set-owner-tag.sh your.email@example.com
```

**Benefits:**
- Clear cost attribution
- Easy resource discovery
- Automated lifecycle management
- Compliance and audit readiness

---

**Last Updated:** January 28, 2026
**Maintained By:** GCHP Benchmarking Team
