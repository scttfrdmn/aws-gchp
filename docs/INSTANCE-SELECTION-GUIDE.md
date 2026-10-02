# AWS Instance Selection Guide for GCHP

## Quick Reference

| Use Case | Instance Family | Memory:Core | EFA | Best Choice |
|----------|----------------|-------------|-----|-------------|
| **Benchmarking** (minimal HISTORY) | c7a | 2 GB/core | No | c7a.48xlarge |
| **Production Single-Node** (full HISTORY) | m7a | 4 GB/core | No | m7a.48xlarge |
| **Production Multi-Node** (full HISTORY) | hpc7a | 4 GB/core | Yes | hpc7a.96xlarge |

## Memory Requirements (from empirical testing)

- **Minimal HISTORY (2-3 collections):** 0.6 GB/core → c7a works (2 GB/core)
- **Full HISTORY (12-13 collections):** 1.7 GB/core → need 4 GB/core instances

## EFA Support by Instance Family

### ❌ NO EFA
All AMD EPYC "a" series lack EFA:
- c6a, **c7a**, m6a, **m7a**, r6a, **r7a**
- Use ENA (up to 100 Gbps) instead
- Trade-off: Lower price, no RDMA support

### ✅ HAS EFA
- **All HPC instances:** hpc6a, hpc6id, **hpc7a**, hpc7g
- **Intel "i" series (large):** c6i, c7i, m6i, **m7i**, r6i, **r7i** (32xlarge+)
- **Graviton "g" series (large):** c7g, **m7g**, **r7g** (16xlarge+)
- **Network "n" variants:** c5n, c6in, c7gn, m5n, m6in, r5n, r6in, r7iz

## Detailed Instance Comparison

### Tier 1: HPC-Optimized (Best for Multi-Node)

| Instance | Cores | Memory | GB/Core | Network | EFA | $/hr |
|----------|-------|--------|---------|---------|-----|------|
| **hpc7a.96xlarge** | 192 | 768 GB | 4.0 | 300 Gbps | ✅ | $8.813 |
| hpc7a.48xlarge | 96 | 384 GB | 4.0 | 300 Gbps | ✅ | $4.406 |
| hpc7a.24xlarge | 48 | 192 GB | 4.0 | 300 Gbps | ✅ | $2.203 |
| hpc7a.12xlarge | 24 | 96 GB | 4.0 | 300 Gbps | ✅ | $1.102 |

**Use:** Multi-node simulations (>192 cores), full HISTORY diagnostics  
**Pros:** Perfect memory:core ratio, highest network bandwidth, purpose-built for HPC  
**Cons:** Slightly more expensive than non-EFA alternatives for single-node

### Tier 2: General Purpose (Best for Single-Node)

#### With EFA (m7i - Intel Xeon 4th Gen)
| Instance | Cores | Memory | GB/Core | Network | EFA | $/hr |
|----------|-------|--------|---------|---------|-----|------|
| **m7i.48xlarge** | 192 | 768 GB | 4.0 | 50 Gbps | ✅ | $10.08 |
| m7i.24xlarge | 96 | 384 GB | 4.0 | 50 Gbps | ✅ | $5.04 |

**Use:** Single-node with future multi-node compatibility  
**Pros:** EFA-ready, Intel architecture if needed  
**Cons:** 18% more expensive than m7a, lower network bandwidth than hpc7a

#### Without EFA (m7a - AMD EPYC 4th Gen)
| Instance | Cores | Memory | GB/Core | Network | EFA | $/hr |
|----------|-------|--------|---------|---------|-----|------|
| **m7a.48xlarge** | 192 | 768 GB | 4.0 | 50 Gbps | ❌ | $8.256 |
| m7a.24xlarge | 96 | 384 GB | 4.0 | 50 Gbps | ❌ | $4.128 |

**Use:** Pure single-node production runs  
**Pros:** Cheapest 4 GB/core option, latest AMD architecture  
**Cons:** No EFA (can't scale to multi-node later)

### Tier 3: Compute-Optimized (Best for Benchmarking)

| Instance | Cores | Memory | GB/Core | Network | EFA | $/hr |
|----------|-------|--------|---------|---------|-----|------|
| **c7a.48xlarge** | 192 | 384 GB | 2.0 | 50 Gbps | ❌ | $4.896 |
| c7a.24xlarge | 96 | 192 GB | 2.0 | 50 Gbps | ❌ | $2.448 |

**Use:** Benchmarking with minimal HISTORY (2-3 collections)  
**Pros:** 40% cheaper than m7a, validated at 40-45% memory usage  
**Cons:** Only 2 GB/core (risks OOM with full HISTORY)

### Tier 4: Memory-Optimized (Overkill for GCHP)

| Instance | Cores | Memory | GB/Core | Network | EFA | $/hr |
|----------|-------|--------|---------|---------|-----|------|
| r7i.48xlarge | 192 | 1536 GB | 8.0 | 50 Gbps | ✅ | $14.515 |
| r7a.48xlarge | 192 | 1536 GB | 8.0 | 50 Gbps | ❌ | $14.515 |

**Use:** Only if you need >4 GB/core (not typical for GCHP)  
**Pros:** 8 GB/core (4.7× more than needed)  
**Cons:** 76% more expensive, wastes 80% of memory

## Cost Comparison (192 cores, 7-day simulation)

### Minimal HISTORY (Benchmarking)
| Instance | Nodes | Memory Usage | Total Cost | $/core-hr |
|----------|-------|--------------|-----------|-----------|
| **c7a.48xlarge** | 1 | 40-45% ✅ | $823 | $0.026 |

### Full HISTORY (Production)
| Instance | Nodes | EFA | Memory Usage | Total Cost | $/core-hr |
|----------|-------|-----|--------------|-----------|-----------|
| **m7a.48xlarge** | 1 | No | 42% ✅ | $1,387 | $0.043 |
| m7i.48xlarge | 1 | Yes | 42% ✅ | $1,693 | $0.053 |
| 2× hpc7a.96xlarge | 2 | Yes | 42% ✅ | $2,962 | $0.046 |

## Decision Tree

```
Need to run GCHP with full HISTORY diagnostics?
├─ No (benchmarking only)
│  └─ Use: c7a.48xlarge ($4.90/hr)
│     Memory: 2 GB/core, validated at 40-45% usage
│
└─ Yes (production science)
   │
   ├─ Single node (≤192 cores)?
   │  ├─ Might scale to multi-node later?
   │  │  └─ Use: m7i.48xlarge ($10.08/hr)
   │  │     EFA-ready, 4 GB/core
   │  │
   │  └─ Pure single-node, won't scale?
   │     └─ Use: m7a.48xlarge ($8.26/hr) ← BEST VALUE
   │        No EFA, 4 GB/core, cheapest
   │
   └─ Multi-node (>192 cores)?
      └─ Use: hpc7a.96xlarge ($8.81/hr per node)
         300 Gbps EFA, 4 GB/core, purpose-built for HPC
```

## ParallelCluster Configuration Example

```yaml
Scheduling:
  Scheduler: slurm
  SlurmQueues:
    # Queue 1: Benchmarking (minimal HISTORY)
    - Name: benchmark
      ComputeResources:
        - Name: c7a-benchmark
          InstanceType: c7a.48xlarge
          MinCount: 0
          MaxCount: 4
      Networking:
        PlacementGroup:
          Enabled: false
    
    # Queue 2: Production single-node (full HISTORY)
    - Name: prod-single
      ComputeResources:
        - Name: m7a-production
          InstanceType: m7a.48xlarge
          MinCount: 0
          MaxCount: 4
      Networking:
        PlacementGroup:
          Enabled: false
    
    # Queue 3: Production multi-node (full HISTORY, >192 cores)
    - Name: prod-multi
      ComputeResources:
        - Name: hpc7a-multinode
          InstanceType: hpc7a.96xlarge
          MinCount: 0
          MaxCount: 8
          Efa:
            Enabled: true
      Networking:
        PlacementGroup:
          Enabled: true
```

## Key Recommendations

1. **For benchmarking:** Use c7a (2 GB/core, no EFA needed)
2. **For single-node production:** Use m7a (4 GB/core, cheapest, no EFA)
3. **For multi-node production:** Use hpc7a (4 GB/core, EFA required)
4. **Avoid:** Using multi-node with idle cores just to get more memory (wasteful)
5. **Avoid:** r7a/r7i family for GCHP (8 GB/core is overkill, wastes money)

## Important Notes

- **All AMD "a" series (c7a, m7a, r7a) lack EFA** - cannot do multi-node
- **EFA is only needed for multi-node** (>1 instance) with tight MPI coupling
- **Single-node doesn't need EFA** - ENA is sufficient
- **4 GB/core is the sweet spot** for full HISTORY diagnostics (42% memory usage)
- **Pre-flight validator** (`scripts/validate_gchp_config.py`) checks memory requirements

## Related Documentation

- [GCHP Memory Investigation](GCHP-MEMORY-INVESTIGATION-MAY2026.md) - Root cause analysis
- [Pre-flight Validator](../scripts/validate_gchp_config.py) - Configuration checker
- Memory requirements saved to: `~/.claude/projects/.../memory/gchp_memory_requirements.md`
