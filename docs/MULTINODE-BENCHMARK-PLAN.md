# GCHP Multi-Node Scaling Benchmark — Plan

Draft 2026-06-26, grounded in API-verified constraints. Follows the single-node arc
(see data/benchmark-c90-2026-06.md). Goal: measure **strong scaling** (fixed problem,
more nodes) and the role of **network** across architectures.

## What single-node taught us (carry-over)
- Per-core architecture speed: Graviton ≫ Intel ≈ AMD; SMT hurts GCHP (keep off).
- The scaling knee depends on grid: C90 over-decomposes past ~96 ranks; C180 scales
  further. **So multi-node should use C180** (big enough to feed many ranks; restart exists).
- Cost-efficiency: Graviton ~5-8× better $/sim-day single-node.

## The key multi-node insight (new, from EFA/bandwidth data)
Network bandwidth per core matters more than raw cores once you cross nodes:

| instance | cores | net Gb | Gb/core | role |
|----------|-------|--------|---------|------|
| hpc7g.16xlarge  | 64 | 200 | 3.1 | HPC Graviton3E |
| c7gn.16xlarge   | 64 | 200 | 3.1 | net-opt Graviton3 |
| c8gn.16xlarge   | 64 | 200 | 3.1 | net-opt Graviton4 |
| c8a.48xlarge    | 192 | 75 | 0.39 | compute AMD8 |
| c7a.48xlarge    | 192 | 50 | 0.26 | compute AMD7 |
| c8g.48xlarge    | 192 | 50 | 0.26 | compute Graviton4 |
| c8i.48xlarge    | 96 | 75 | 0.78 | compute Intel8 |

Hypothesis: the **64-core network-optimized parts (hpc7g/c7gn/c8gn, 200 Gb)** will
**out-scale** the 192-core compute parts multi-node, because GCHP halo exchange is
comms-bound — the 192-core parts starve their cores on a 50-75 Gb link. This is the
opposite of the single-node "more cores win" intuition, and is the headline question.

## Constraints (verified)
- **Grid ≤ C180** — only C180 (and smaller) TransportTracers restarts exist in s3://gcgrid.
  No C360/C720 restart, so C180 is the ceiling for a clean run.
- **All candidate instances are EFA-capable and in us-east-1a** (our input-FSx AZ).
- **EFA requires:** Efa.Enabled in the compute resource + a PlacementGroup (cluster) +
  the stack's OpenMPI built with libfabric/EFA (it is). Multi-node is where the EFA
  build finally gets exercised — single-node never used it.
- Decomposition stays valid for C180 to 8 nodes; tiles shrink to ~11×11 at the top
  (1536 cores) — that's near the expected scaling limit, which is what we want to find.

## Proposed design

**Primary: strong-scaling curve, C180, 1/2/4/8 nodes**, on a focused instance set.
Report throughput vs nodes, **parallel efficiency** (vs 1-node baseline), and $/sim-day.

Instance set (keep it tight — this is expensive):
1. **hpc7g.16xlarge** (Graviton3E, 200 Gb) — the HPC-purpose part; expected scaling champ.
2. **c8gn.16xlarge** (Graviton4 net-opt, 200 Gb) — newest net-optimized Graviton.
3. **c8a.48xlarge** (AMD8, 75 Gb, 192c) — best compute x86; tests "big cores, thin pipe".
4. **c8i.48xlarge** (Intel8, 75 Gb) — Intel multi-node reference.

Cores/node: 60 for the 64-core Graviton parts; for AMD/Intel use a MATCHED ranks/node
so the comparison isn't reconfounded — recommend **60 ranks/node across all** (apples-to-
apples on total ranks), with an optional "full-node" variant for the value question.

Node sweep: **1, 2, 4** first; add **8** only if 4-node efficiency is still healthy
(>~60%) — no point paying for 8 nodes past the knee.

### Matrix (primary)
4 instances × {1,2,4} nodes × C180 = 12 runs (+ up to 4 more if 8-node warranted).
60 ranks/node → 60/120/240 total ranks (all valid C180 layouts).

## Metrics
- Throughput (days/day) per node count.
- **Parallel efficiency** = (tput_N / (N × tput_1)) — the real scaling answer.
- $/sim-day at each scale (does scaling out stay cost-effective?).
- EFA validation: confirm `fi_info`/ompi uses EFA provider (first multi-node EFA exercise).

## Cost / risk
- Peak: 8-node × c8a.48xl ≈ 8 × $10/hr during overlap — the 8-node points are the
  expensive part; gate them on 4-node efficiency.
- Capacity risk: 8× same instance in one AZ + PlacementGroup can hit InsufficientCapacity
  (we already saw m9g scarcity). Launch high-node-count clusters first / be ready to retry.
- Use the SAFE collector (affirmative-success-only deletes — never the empty-queue race).

## REVISION (2026-06-26): use the purpose-built HPC instances

The hpc* family is the *right* tool for multi-node GCHP (built for tightly-coupled MPI,
fat EFA networks, no SMT, big RAM). Verified availability:

| instance | vendor | AZ | cores | RAM GB | net Gb | Gb/core | region |
|----------|--------|-----|-------|--------|--------|---------|--------|
| hpc7g.16xl  | Graviton3E | us-east-1a | 64 | 128 | 200 | 3.12 | us-east-1 |
| hpc8a.96xl  | AMD Turin (gen8) | us-east-2b | 192 | 768 | 300 | 1.56 | us-east-2 |
| hpc7a.96xl  | AMD Genoa (gen7) | us-east-2b | 192 | 768 | 300 | 1.56 | us-east-2 |
| hpc7a.48xl  | AMD Genoa  | us-east-2b | 96 | 768 | 300 | 3.12 | us-east-2 |
| hpc6a.48xl  | AMD Milan (gen6) | us-east-2b | 96 | 384 | 100 | 1.04 | us-east-2 |
| hpc6id.32xl | Intel SPR  | us-east-2b | 64 | 1024 | 200 | 3.12 | us-east-2 |

**hpc8a.96xl (AMD Turin, gen8) confirmed** — 192c/768GB/300Gb, us-east-2b. Newest AMD HPC
part; use this over hpc7a for the headline AMD multi-node contender (gen8 > gen7, same net).
AMD HPC generational sweep available: hpc6a (Milan) → hpc7a (Genoa) → hpc8a (Turin).

**Why this changes the headline:** hpc7a pairs 192 cores WITH 300 Gb — vs the c7a/c8a
compute parts' 192 cores on only 50-75 Gb. So the multi-node question becomes a clean
**HPC-vs-HPC** fight: Graviton3E (hpc7g) vs AMD Genoa (hpc7a) vs Intel SPR (hpc6id),
all on fat networks — far more meaningful than scaling the network-starved compute parts.

### REGION SPLIT — operational reality
- **hpc7g is us-east-1 only; hpc7a/hpc6a/hpc6id are us-east-2 (AZ us-east-2b) only.**
- s3://gcgrid (GEOS-Chem RODA) IS readable from us-east-2 (public) — input data works
  there via an FSx ImportPath (small cross-region transfer, one-time).
- Validated stacks are NOT yet in us-east-2 S3 — must sync
  gchp-shared-storage-us-east-1/stacks/ -> us-east-2 first (~250MB×2, one-time).
- us-east-2 clusters must use a **us-east-2b** subnet (only AZ with the HPC parts);
  existing us-east-2 resources: gchp-shared-storage-us-east-2 + gchp-input-data-us-east-2
  buckets (empty), an FSx fem-cluster-fsx (1.2TB, unknown contents).

### Revised instance set for the scaling sweep (C180, 1/2/4 nodes)
- **hpc7g.16xl** (Graviton3E, us-east-1) — 60 ranks/node
- **hpc7a.96xl** (AMD Genoa, us-east-2) — could run 192/node OR 60/node matched
- **hpc6id.32xl** (Intel SPR, us-east-2) — 60 ranks/node
- (optional) hpc6a.48xl (AMD Milan gen6) for an AMD generational point
- Keep ONE compute part (c8a.48xl) as a "thin-network 192-core" contrast — to *prove*
  the network matters by showing it scales worse than hpc7a despite same vendor/cores.

## Prereqs before launch
1. Sync validated stacks to us-east-2 S3 (x86_64 + aarch64). (aarch64 not needed if no
   Graviton runs in us-east-2 — hpc7g is us-east-1; so us-east-2 only needs x86_64.)
2. Stand up input data in us-east-2b (FSx ImportPath s3://gcgrid) OR check whether
   fem-cluster-fsx already holds GEOS-Chem data (mount + inspect).
3. Find/confirm a us-east-2b subnet + security group for ParallelCluster.

## RECOMMENDED DESIGN (decision-ready — pending your sign-off)

After the single-node arc, here's the proposed multi-node study, with my recommended
answers to the earlier open questions baked in:

**Region:** Run the whole HPC study in **us-east-2b** (where hpc8a/hpc7a/hpc6a/hpc6id
live). Treat hpc7g (Graviton3E, us-east-1) as a SEPARATE small companion run — don't
split one matrix across regions (operational complexity, cross-region confounds).

**Instance set (us-east-2b), C180, strong scaling 1→2→4 nodes:**
| instance | arch | role |
|----------|------|------|
| hpc8a.96xl | AMD Turin gen8 | headline AMD HPC (newest) |
| hpc6id.32xl | Intel SPR | Intel HPC reference |
| c8a.48xl | AMD8 compute | **thin-network control** (192c, 75Gb vs hpc8a 300Gb) — isolates the network effect |
Plus **hpc7g.16xl** in us-east-1 as the Graviton HPC point (companion run).

**Ranks/node:** matched **60 ranks/node** across all for the scaling sweep (clean
per-rank comparison; 60 is hpc7g/hpc6id's max anyway). Add a **full-node** variant
(hpc8a @192/node) only for the 1-node value point, clearly labeled.

**Node counts:** 1 → 2 → 4. **Gate 8 nodes** on 4-node parallel efficiency >~60%
(C180 at 4×60=240 ranks is still healthy per decomposition; 8×60=480 approaches the limit).

**Primary metric:** parallel efficiency = tput_N / (N × tput_1), plus $/sim-day at scale.

**The headline test:** does hpc8a (300Gb) hold efficiency at 4 nodes while c8a (75Gb,
same AMD cores) collapses? That isolates the network as the multi-node differentiator.

### Run count & rough cost
us-east-2: 3 instances × 3 node-counts (1/2/4) = 9 cluster-runs (+ up to 3 for 8-node).
us-east-1: hpc7g × 3 = 3 runs. ~12-15 runs total. Peak spend bounded by gating 8-node.

### Prereqs (do these before launch, cheap)
1. Sync x86_64 validated stack → gchp-shared-storage-us-east-2 (aarch64 too, for nothing
   in us-east-2 — skip; us-east-2 set is all x86). hpc7g (aarch64) uses us-east-1 stack.
2. Provision input FSx in us-east-2b: ImportPath s3://gcgrid (reads cross-region, fine).
3. Identify a us-east-2b subnet + SG for ParallelCluster (the HPC AZ).
4. Build EFA-enabled run configs (Efa.Enabled + PlacementGroup; multi-node finally
   exercises the stack's EFA OpenMPI build).

### Still genuinely open for you
- Include the full AMD HPC generational sweep (hpc6a Milan + hpc7a Genoa + hpc8a Turin)
  for a "generations of AMD HPC" story, or just hpc8a (newest) to keep cost down?
- C180 is the grid ceiling (no larger restart). OK, or generate a C360 restart first
  (separate task) for a study that better justifies 8 nodes?
