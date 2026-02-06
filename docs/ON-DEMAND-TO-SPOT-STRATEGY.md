# Testing Strategy: ON-DEMAND → SPOT

**Date:** January 28, 2026
**Rationale:** Validate configurations without Spot interruption risk, then optimize costs

---

## Strategy Overview

### Phase 1: Validation (ON-DEMAND)
**Goal:** Prove configurations work correctly
- ✅ No Spot interruptions during testing
- ✅ Predictable testing timeline
- ✅ Isolate configuration issues from capacity issues
- ⚠️ Higher cost (~3x Spot pricing)

### Phase 2: Production (SPOT)
**Goal:** Optimize costs for long-running workloads
- ✅ 70% cost savings vs ON-DEMAND
- ✅ Checkpointing handles interruptions
- ✅ Validated configurations reduce debugging time
- ⚠️ Interruptions possible (but recoverable)

---

## Cost Comparison

| Configuration | ON-DEMAND | SPOT (70% off) | Savings |
|--------------|-----------|----------------|---------|
| **Test minimal** (30 min) | $0.29 | $0.09 | $0.20 |
| **Test multi-node** (45 min) | $2.53 | $0.85 | $1.68 |
| **Production single-node** (1 hr) | $0.82 | $0.24 | $0.58 |
| **Production campaign** (96 hrs) | $322 | $96 | $226 |

**Testing Cost Premium:** ~$2 extra for ON-DEMAND validation
**Campaign Savings:** $226 per 4-day campaign with Spot

**ROI:** First campaign recoups testing premium 100x over!

---

## Testing Timeline

### ✅ Test with ON-DEMAND (Today)

**Step 1: Minimal Test**
```bash
# Config already set to ONDEMAND
AWS_PROFILE=aws AWS_REGION=us-east-1 uv run pcluster create-cluster \
  --cluster-name gchp-test-minimal \
  --cluster-configuration parallelcluster/configs/gchp-test-minimal.yaml \
  --region us-east-1

# Test environment, validate SLURM, FSx, basic functionality
# Cost: ~$0.29 (30 minutes)
# Delete when done
```

**Step 2: Multi-Node Test**
```bash
# Config already set to ONDEMAND
AWS_PROFILE=aws AWS_REGION=us-east-1 uv run pcluster create-cluster \
  --cluster-name gchp-test-multinode \
  --cluster-configuration parallelcluster/configs/gchp-test-multinode.yaml \
  --region us-east-1

# Test 4-node EFA, validate MPI, measure scaling
# Cost: ~$2.53 (45 minutes)
# Delete when done
```

**Total Testing Cost:** ~$2.82

### ✅ Switch to SPOT (After Validation)

**Step 3: Update Production Config**

```bash
# Edit gchp-production.yaml
# Change all queues from ONDEMAND to SPOT:

  CapacityType: SPOT  # Was: ONDEMAND
  AllocationStrategy: capacity-optimized
```

**Step 4: Deploy Production with Spot**

```bash
AWS_PROFILE=aws AWS_REGION=us-east-1 uv run pcluster create-cluster \
  --cluster-name gchp-production \
  --cluster-configuration parallelcluster/configs/gchp-production.yaml \
  --region us-east-1

# Run production campaigns with 70% cost savings
```

---

## When to Use Each

### Use ON-DEMAND When:
- ✅ Initial testing and validation
- ✅ Debugging configuration issues
- ✅ Critical deadline, cannot tolerate interruptions
- ✅ Very short runs (<30 minutes) where Spot overhead isn't worth it
- ✅ Presentations/demos (need guaranteed availability)

### Use SPOT When:
- ✅ Long-running campaigns (>2 hours)
- ✅ Production workloads with checkpointing
- ✅ Batch processing (interruptions are acceptable)
- ✅ Cost-sensitive research
- ✅ After configurations are validated

---

## Spot Interruption Handling

### GCHP Checkpointing Strategy

**Automatic Restart:**
1. Spot interruption warning (2 minutes)
2. SLURM catches signal, saves checkpoint
3. Job auto-requeues in SLURM
4. When capacity returns, job resumes from checkpoint

**Configuration:**
```yaml
# In gchp config (already set up)
checkpointing:
  enabled: true
  frequency: 3600  # Save every hour
  directory: /fsx/scratch/checkpoints
```

**SLURM Script:**
```bash
#!/bin/bash
#SBATCH --signal=B:SIGTERM@120  # 2-minute warning before kill
#SBATCH --requeue               # Auto-requeue on failure

# Job handles SIGTERM to save state
trap 'save_checkpoint_and_exit' SIGTERM
```

### Spot Best Practices

1. **Diverse instance types** - increases capacity availability
2. **Capacity-optimized allocation** - AWS picks least-likely-to-be-interrupted
3. **Checkpoint frequently** - minimize lost work (every 1-2 hours)
4. **Test interruption** - manually trigger to validate recovery
5. **Monitor interruption rate** - adjust strategy if too high

---

## Production Config Changes

### Current (Test Phase)
```yaml
# parallelcluster/configs/gchp-test-*.yaml
CapacityType: ONDEMAND  # For validation
```

### After Validation (Production Phase)
```yaml
# parallelcluster/configs/gchp-production.yaml
CapacityType: SPOT
AllocationStrategy: capacity-optimized

# Optionally add instance flexibility
InstancesDistribution:
  - InstanceType: hpc7a.48xlarge
  - InstanceType: hpc7a.96xlarge  # Fallback if hpc7a.48xlarge scarce
```

---

## Validation Checklist

### ✅ Before Switching to SPOT

- [ ] Minimal test cluster works (SLURM, FSx, SSH)
- [ ] Multi-node test works (EFA, 4 nodes, MPI)
- [ ] C24 benchmark completes successfully
- [ ] GCHP checkpointing tested (manually save/restore)
- [ ] Understand interruption rates in us-east-1 for hpc7a

### ✅ After Switching to SPOT

- [ ] Monitor first Spot run closely
- [ ] Verify auto-requeue works if interrupted
- [ ] Measure actual interruption frequency
- [ ] Document any issues for community
- [ ] Update cost estimates based on real usage

---

## Expected Interruption Rates

### hpc7a in us-east-1 (Typical)

**Historical Data:**
- HPC instances generally have **low** interruption rates (<5% per hour)
- Capacity-optimized allocation reduces rate further
- us-east-1 (Ohio) has good HPC capacity

**For 4-day campaign:**
- 96 hours × 10 nodes = 960 node-hours
- Expected interruptions: ~5-10 (5-10% of node-hours)
- With checkpointing: ~5-10 hours lost work (if checkpoints every hour)
- **Overhead: <10% time, but save 70% cost**

**ROI:** Even with interruptions, Spot is dramatically cheaper.

---

## Migration Commands

### Quick Config Update (for future)

```bash
# After testing, update all configs to SPOT
cd parallelcluster/configs

# macOS
sed -i '' 's/CapacityType: ONDEMAND/CapacityType: SPOT/' gchp-production.yaml

# Linux
sed -i 's/CapacityType: ONDEMAND/CapacityType: SPOT/' gchp-production.yaml

# Verify changes
git diff gchp-production.yaml
```

### Or: Keep Both Configs

```bash
# Keep ON-DEMAND version for critical work
cp gchp-production.yaml gchp-production-ondemand.yaml

# Update main version to SPOT
vim gchp-production.yaml  # Change to SPOT

# Use as needed:
# pcluster create-cluster ... --cluster-configuration gchp-production.yaml          # SPOT
# pcluster create-cluster ... --cluster-configuration gchp-production-ondemand.yaml # ON-DEMAND
```

---

## Summary

### Testing Strategy (Today)
1. ✅ **ON-DEMAND** for test-minimal (~$0.29)
2. ✅ **ON-DEMAND** for test-multinode (~$2.53)
3. ✅ Validate everything works
4. ✅ **Total cost: ~$2.82**

### Production Strategy (After Validation)
1. ✅ Switch production config to **SPOT**
2. ✅ Deploy with 70% cost savings
3. ✅ Monitor interruption rates
4. ✅ Run campaigns confidently

### Cost Benefit
- **Testing premium:** $2 (ON-DEMAND vs Spot for testing)
- **Campaign savings:** $226 per 4-day run
- **Break-even:** First campaign pays for itself 100x over

---

**Smart testing strategy: validate first, optimize costs after!** 💰✅
