# AWS Instance Selection Guide for GCHP (May 2026 Update)

## Quick Reference - Gen 8/9 Recommendations

| Use Case | Best Choice | Gen | Memory:Core | EFA | Price | Notes |
|----------|-------------|-----|-------------|-----|-------|-------|
| **Benchmarking** | c8a.48xlarge | 8 | 2 GB/core | No | $4.40/hr | 10% cheaper than c7a |
| **Production Single-Node** | m8a.48xlarge | 8 | 4 GB/core | No | $7.40/hr | Best value, no EFA |
| **Production Single-Node + EFA** | m8g.48xlarge | 8 | 4 GB/core | Yes | $7.80/hr | Graviton4, 200 Gbps |
| **Production Multi-Node** | hpc8a.96xlarge | 8 | 4 GB/core | Yes | $8.20/hr | 400 Gbps EFA |
| **Future: Multi-Node** | hpc9a.96xlarge | 9 | 4 GB/core | Yes | $7.80/hr | 800 Gbps, Preview |

## What Changed in Gen 8/9

### Generation 8 (Mature, GA in 2025)
- **~10% cost reduction** vs Gen 7
- **AMD EPYC Zen 5** (c8a, m8a, r8a) - still **NO EFA**
- **Graviton4** (c8g, m8g, r8g) - **HAS EFA** + better price/performance
- **Intel Emerald Rapids** (c8i, m8i, r8i) - has EFA on large sizes
- **hpc8a.96xlarge**: 400 Gbps (33% faster than hpc7a's 300 Gbps)

### Generation 9 (Early Availability)
- **Graviton5** (c9g, m9g) - GA, **HAS EFA**, up to 400 Gbps
- **AMD Zen 6** (c9a, hpc9a) - Preview, **hpc9a HAS EFA** (800 Gbps!)
- **15-20% cost reduction** vs Gen 7
- Most cost-effective options yet

## Comprehensive Comparison by Use Case

### Benchmarking (Minimal HISTORY, 2-3 collections)

**Requirements:** 0.6 GB/core memory, maximize compute efficiency

| Instance | Gen | Cores | Memory | $/hr | $/core-hr | EFA | Recommendation |
|----------|-----|-------|--------|------|-----------|-----|----------------|
| **c9a.48xlarge** | 9 | 192 | 384 GB | $4.10 | $0.021 | ❌ | 🏆 Best value (Preview) |
| **c8a.48xlarge** | 8 | 192 | 384 GB | $4.40 | $0.023 | ❌ | ✅ Best GA option |
| c8g.48xlarge | 8 | 192 | 384 GB | $4.50 | $0.023 | ✅ | If need EFA |
| c9g.48xlarge | 9 | 192 | 384 GB | $4.20 | $0.022 | ✅ | Future best w/ EFA |
| c7a.48xlarge | 7 | 192 | 384 GB | $4.90 | $0.026 | ❌ | Old Gen 7 |

**Winner:** c8a.48xlarge (10% cheaper than Gen 7, mature)

### Production Single-Node (Full HISTORY, ≤192 cores)

**Requirements:** 4 GB/core memory, full diagnostics

#### Without EFA (Pure Single-Node)
| Instance | Gen | Cores | Memory | $/hr | $/core-hr | Architecture |
|----------|-----|-------|--------|------|-----------|--------------|
| **m8a.48xlarge** | 8 | 192 | 768 GB | $7.40 | $0.039 | 🏆 AMD Zen 5 |
| m7a.48xlarge | 7 | 192 | 768 GB | $8.26 | $0.043 | AMD EPYC 4 |

**Savings:** 10% cheaper than Gen 7

#### With EFA (Future Multi-Node Compatible)
| Instance | Gen | Cores | Memory | $/hr | $/core-hr | Network | Architecture |
|----------|-----|-------|--------|------|-----------|---------|--------------|
| **m9g.48xlarge** | 9 | 192 | 768 GB | $7.40 | $0.039 | 400 Gbps | 🏆 Graviton5 |
| **m8g.48xlarge** | 8 | 192 | 768 GB | $7.80 | $0.041 | 200 Gbps | Graviton4 |
| m8i.48xlarge | 8 | 192 | 768 GB | $9.50 | $0.049 | 50 Gbps | Intel |
| m7i.48xlarge | 7 | 192 | 768 GB | $10.08 | $0.053 | 50 Gbps | Intel |

**Winners:**
- **Same price as m8a but WITH EFA:** m9g.48xlarge (Graviton5)
- **Mature option:** m8g.48xlarge (Graviton4, only $0.40/hr more than m8a)

### Production Multi-Node (Full HISTORY, >192 cores)

**Requirements:** EFA required, 4 GB/core memory

| Instance | Gen | Cores/Node | Memory | $/hr | Network | Status |
|----------|-----|-----------|--------|------|---------|--------|
| **hpc9a.96xlarge** | 9 | 192 | 768 GB | $7.80 | 800 Gbps | 🏆 Preview |
| **hpc8a.96xlarge** | 8 | 192 | 768 GB | $8.20 | 400 Gbps | ✅ GA |
| hpc7a.96xlarge | 7 | 192 | 768 GB | $8.81 | 300 Gbps | Gen 7 |

**For 384 cores (2 nodes), 7-day run:**
- Gen 9: $7.80 × 2 × 168 hrs = **$2,620** (800 Gbps)
- Gen 8: $8.20 × 2 × 168 hrs = **$2,755** (400 Gbps)
- Gen 7: $8.81 × 2 × 168 hrs = **$2,960** (300 Gbps)

**Savings:** Gen 9 is 11% cheaper than Gen 7 with 2.7× network bandwidth!

## ARM vs x86 Considerations

### Graviton Advantages (Gen 8/9)
- ✅ **Better price/performance:** 5-15% cheaper than equivalent Intel
- ✅ **EFA on all sizes:** Unlike AMD "a" series
- ✅ **Higher network bandwidth:** 200-400 Gbps
- ✅ **Lower power consumption:** Better for long runs

### Graviton Requirements
- ⚠️ **ARM64 architecture:** Need to compile GCHP for ARM
- ⚠️ **Compiler:** GCC 12+ or LLVM 15+ for best performance
- ⚠️ **Libraries:** All dependencies must support ARM64

**For GCHP:** If your software stack supports ARM64 (modern GCC/gfortran does), Graviton is the best value!

## EFA Support Summary (Gen 7-9)

### ❌ NO EFA (All Generations)
**AMD "a" series:** c7a, c8a, c9a(?), m7a, m8a, r7a, r8a
- Pattern continues: AMD EPYC cost-optimized instances lack EFA
- Exception: **hpc8a, hpc9a HAVE EFA** (HPC-specific)

### ✅ HAS EFA
- **All HPC instances:** hpc7a, hpc8a, hpc9a
- **All Graviton (large):** c8g, c9g, m8g, m9g, r8g (16xlarge+)
- **All Intel (large):** c8i, m8i, r8i (32xlarge+)
- **Network "n" variants:** All generations

## Updated Cost Analysis (192 cores, 7-day simulation)

### Minimal HISTORY (Benchmarking)
| Instance | Gen | Cost | vs Gen 7 |
|----------|-----|------|----------|
| c9a.48xlarge | 9 | $689 | -16% |
| c8a.48xlarge | 8 | $739 | -10% |
| c7a.48xlarge | 7 | $823 | baseline |

### Full HISTORY (Single-Node Production)
| Instance | Gen | EFA | Cost | vs Gen 7 |
|----------|-----|-----|------|----------|
| m9g.48xlarge | 9 | ✅ | $1,243 | -10% |
| m8a.48xlarge | 8 | ❌ | $1,243 | -10% |
| m8g.48xlarge | 8 | ✅ | $1,310 | -6% |
| m7a.48xlarge | 7 | ❌ | $1,387 | baseline |

### Full HISTORY (384 cores, 2-node)
| Instance | Gen | Network | Cost | vs Gen 7 |
|----------|-----|---------|------|----------|
| hpc9a.96xlarge | 9 | 800 Gbps | $2,620 | -11% |
| hpc8a.96xlarge | 8 | 400 Gbps | $2,755 | -7% |
| hpc7a.96xlarge | 7 | 300 Gbps | $2,960 | baseline |

## Definitive Recommendations (May 2026)

### Tier 1: Best Value (Mature, GA)

**For Benchmarking:**
```
Instance: c8a.48xlarge
Cost: $4.40/hr ($739/week)
Savings: 10% vs Gen 7
```

**For Single-Node Production (no future multi-node):**
```
Instance: m8a.48xlarge  
Cost: $7.40/hr ($1,243/week)
Savings: 10% vs Gen 7
EFA: No (but don't need it)
```

**For Single-Node Production (might scale to multi-node):**
```
Instance: m8g.48xlarge (Graviton4)
Cost: $7.80/hr ($1,310/week)
Savings: 6% vs Gen 7
EFA: Yes (200 Gbps)
Bonus: Same price as m9g if ARM-compatible!
```

**For Multi-Node Production:**
```
Instance: hpc8a.96xlarge
Cost: $8.20/hr ($2,755/week for 2 nodes)
Savings: 7% vs Gen 7
Network: 400 Gbps EFA (33% faster)
```

### Tier 2: Best Future Value (Early Availability)

**For Single-Node + EFA:**
```
Instance: m9g.48xlarge (Graviton5)
Cost: $7.40/hr ($1,243/week)
Savings: 10% vs Gen 7, SAME as m8a but WITH EFA!
Network: 400 Gbps
Status: GA
```

**For Multi-Node (if available):**
```
Instance: hpc9a.96xlarge (AMD Zen 6)
Cost: $7.80/hr ($2,620/week for 2 nodes)
Savings: 11% vs Gen 7
Network: 800 Gbps (!) - 2.7× Gen 7
Status: Preview (check regional availability)
```

## ParallelCluster Configuration (May 2026)

```yaml
Scheduling:
  Scheduler: slurm
  SlurmQueues:
    # Benchmark queue - minimal HISTORY, Gen 8
    - Name: benchmark
      ComputeResources:
        - Name: c8a
          InstanceType: c8a.48xlarge
          MinCount: 0
          MaxCount: 4
    
    # Production single-node - full HISTORY, Gen 8 AMD (no EFA)
    - Name: prod-single-amd
      ComputeResources:
        - Name: m8a
          InstanceType: m8a.48xlarge
          MinCount: 0
          MaxCount: 4
    
    # Production single-node - full HISTORY, Gen 8/9 Graviton (with EFA)
    - Name: prod-single-arm
      ComputeResources:
        - Name: m9g
          InstanceType: m9g.48xlarge  # or m8g.48xlarge
          MinCount: 0
          MaxCount: 4
      Networking:
        PlacementGroup:
          Enabled: false
    
    # Production multi-node - full HISTORY, Gen 8 HPC
    - Name: prod-multi
      ComputeResources:
        - Name: hpc8a
          InstanceType: hpc8a.96xlarge
          MinCount: 0
          MaxCount: 8
          Efa:
            Enabled: true
      Networking:
        PlacementGroup:
          Enabled: true
    
    # Production multi-node - Gen 9 (if available)
    - Name: prod-multi-gen9
      ComputeResources:
        - Name: hpc9a
          InstanceType: hpc9a.96xlarge
          MinCount: 0
          MaxCount: 8
          Efa:
            Enabled: true
      Networking:
        PlacementGroup:
          Enabled: true
```

## Migration Path

**Current (Gen 7) → Gen 8:**
- c7a.48xlarge → c8a.48xlarge (10% savings)
- m7a.48xlarge → m8a.48xlarge (10% savings, no code changes)
- hpc7a.96xlarge → hpc8a.96xlarge (7% savings, 33% faster network)

**Current (Gen 7) → Gen 9 (if ARM-compatible):**
- m7a.48xlarge → m9g.48xlarge (10% savings + EFA + 400 Gbps)
- hpc7a.96xlarge → hpc9a.96xlarge (11% savings, 2.7× network bandwidth)

**Gotcha:** If using Gen 9 Graviton, must compile GCHP for ARM64!

## Key Takeaways

1. **Gen 8 is mature and ~10% cheaper** than Gen 7
2. **Gen 9 Graviton is GA** and offers best value IF ARM-compatible
3. **AMD "a" series still NO EFA** (except HPC variants)
4. **Graviton + EFA = best price/performance** for multi-node
5. **hpc9a.96xlarge is game-changer:** 800 Gbps at lower cost
6. **Network bandwidth tripled** Gen 7→8→9: 300 → 400 → 800 Gbps

## Bottom Line

**For most users in May 2026:**
- Benchmarking: c8a.48xlarge ($4.40/hr)
- Single-node: m8a.48xlarge ($7.40/hr) or m9g.48xlarge (same price + EFA!)
- Multi-node: hpc8a.96xlarge ($8.20/hr) or hpc9a.96xlarge if available ($7.80/hr)

**Graviton is now the best value** if your software supports ARM64!
