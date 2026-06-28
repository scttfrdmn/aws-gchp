# GCHP Multi-Node Scaling Benchmark — C180 Strong Scaling (June 2026)

Strong scaling (fixed C180 problem, more nodes) across HPC instance types in us-east-2b.
Follows the single-node arc (`data/benchmark-c90-2026-06.md`) and the EFA de-risk (PASSED,
2026-06-27: GCHP 14.7.1 OpenMPI uses EFA RDMA cross-node — `mtl:ofi:provider` = efa).

## Design (locked)
- **Grid:** C180 TransportTracers (largest restart in gcgrid; GC_14.0.0, 1GB). 1 sim-day.
- **Scaling:** strong, **1 → 2 → 4 nodes**; 8-node gated on 4-node parallel efficiency >~60%.
- **Ranks/node:** **60** across all instances (matched per-rank comparison; 60 ≤ every part's core count).
- **Instance set (us-east-2b):**
  | instance | arch | cores | RAM GB | net Gb | role | $/hr (us-east-2) |
  |----------|------|-------|--------|--------|------|------|
  | hpc8a.96xl  | AMD Turin (gen8) | 192 | 768  | 300 | headline AMD HPC | 7.92 |
  | hpc6id.32xl | Intel SPR        | 64  | 1024 | 200 | Intel HPC reference | 5.70 |
  | c8a.48xl    | AMD8 compute     | 192 | 384  | **75** | **thin-network control** | **10.35** |
  | hpc7g.16xl  | Graviton3E       | 64  | 128  | 200 | Graviton HPC (us-east-1 companion) | — |
- **The headline test:** does hpc8a (300Gb) hold parallel efficiency at 4 nodes while c8a
  (same AMD8 cores, only 75Gb AND pricier at $10.35/hr) collapses? Isolates network as the
  multi-node differentiator.

## Reproduction & infra (for re-running)
- **Configs:** `parallelcluster/configs/bench-matrix-use2.template.yaml` (us-east-2 x86, sub
  @INSTANCE_TYPE@/@MAXCOUNT@ via `scripts/launch-matrix-cluster.sh`), `bench-hpc7g-use1.yaml`
  (us-east-1 ARM). Run driver: `scripts/gchp-matrix-run.sh` (sim-completion-detect + internal
  throughput + O-server fix baked in). Sweep: `/tmp/full-sweep.sh` (1/2/4-node).
- **Standing infra to recreate:** input FSx (Lustre **2.15**, gcgrid ImportPath, ~33min import,
  reference by FileSystemId); us-east-1 VPC endpoints **ssm+ssmmessages+ec2messages+ec2 (interface)
  + s3 + dynamodb (gateway)** — KEPT (~$30/mo). The 3 gcgrid input FSx were DELETED post-run
  (~$420/mo saved); re-import when next needed. EBS `/sw` stack synced from
  s3://gchp-shared-storage-us-east-{1,2}/bootstrap/sync-stack{,-arm}.sh.
- **Cluster build gotchas (all in memory):** PC 3.15 = 1 new FSx/cluster; regional keypairs;
  ElasticIp boolean-only + us-east-2 EIP quota; same-AZ head↔FSx; multi-NIC EFA needs the full
  VPC-endpoint set (DynamoDB miss = "retrieve compute node info" Chef loop).

## Storage architecture (three tiers by access pattern)
| tier | mount | access | backing | notes |
|------|-------|--------|---------|-------|
| software | `/sw` | r | EBS (S3-synced on head, NFS to compute) | 3.3GB, no collective I/O — EBS fine |
| input | `/input` | r | FSx Lustre (by-ID, **shared** fs-0530cb89869306328) | gcgrid, reused across whole matrix |
| scratch | `/scratch` | **r/w** | FSx Lustre (new per-cluster, SCRATCH_2) | run dir + HISTORY + pnc4 checkpoints |

**FINDING — parallel-NetCDF checkpoints REQUIRE Lustre scratch, not ext4.** Early matrix runs
put the GCHP run dir on the EBS `/fsx` (ext4). GCHP writes its internal checkpoint with
**parallel NetCDF (pnc4 / collective MPI-IO)**; on ext4 this **intermittently FAILS** at
`NetCDF4_FileFormatter.F90 line 189 (status=-35)` AFTER the simulation completes (run reached
2019/01/02, all Finalize OK, then the collective checkpoint write died). One run succeeded, the
next (identical) failed — classic collective-I/O-on-non-parallel-FS nondeterminism. Fix: a
writable **FSx Lustre `/scratch`** (what Lustre is built for). This is exactly why the validated
three-FSx design has scratch as r/w Lustre. (Deviating from it to dodge PC's 1-new-FSx limit
caused the failure; the matrix template now uses the 1-FSx slot for scratch + input by-ID.)

## Methodology notes
- **Warm cache:** the shared input FSx (fs-0530cb89869306328) persists; C180 met for
  2019-01-01 pages in ONCE (first run), then all later runs (any node count / instance) read
  warm. The first cold run is discarded as a warmup — efficiency uses the WARM 1-node baseline.
  (Observed: at C180/60-ranks the run is COMPUTE-bound ~165 sdays/day integration rate; cold vs
  warm differ little — but keep the discipline for the lower-rank/higher-I/O ratio cases.)
- **Timing:** `ELAPSED_SECONDS` = mpirun wall (epoch delta), NOT slurm job time (which includes
  ~150s benign-finalization teardown reap). Throughput = sim-days / (elapsed/86400).
- **Success:** cap_restart advances + checkpoint written; benign GCHP 14.7.1 exit-134 ignored.
- **$/sim-day** = $/hr × 24 / throughput(sim-days/day).

## HEADLINE — C180 strong scaling, GCHP-internal Avg throughput (days/day), 60 ranks/node

| instance | arch | net Gb | $/hr | 1N | 2N | 4N | eff@2N | eff@4N | best $/sim-day |
|----------|------|--------|------|----|----|----|--------|--------|----------------|
| **hpc7g** | Graviton3E | 200 | (us-e1) | OOM | 229.5 | **439.7** | — | **96%**¹ | — |
| **hpc8a** | AMD Turin g8 | 300 | 7.92 | 157.1 | 268.3 | 411.4 | 85% | 65% | **$1.21** (1N) |
| hpc6id | Intel SPR | 200 | 5.70 | 86.3 | 145.1 | 210.8 | 84% | 61% | $1.59 (1N) |
| c8a | AMD compute | 75 | 10.35 | 107.5 | 178.9 | — ² | 83% | — | $2.31 (1N) |

¹ hpc7g eff@4N is vs its 2-node baseline (1-node OOM-infeasible — 128GB too small for single-node C180).
² c8a 4-node capacity-blocked in us-east-2c (placement-group thrash); 1N/2N obtained.

**FINDINGS:**
1. **Graviton3E (hpc7g) is the multi-node throughput champion** — 439.7 d/d at 4 nodes, the highest
   of ANY instance, and scales **near-linearly (96%) 2→4 nodes**. The 200Gb fat network + only 64
   cores/node keep halo-exchange from starving the cores, where the 192-core parts knee harder.
   Caveat: hpc7g's 128GB RAM makes single-node C180 infeasible (OOM) — it NEEDS ≥2 nodes for C180.
2. **AMD Turin (hpc8a) wins single-node + cost**: 1.82× faster per node than Intel SPR (157 vs 86)
   AND cheaper per sim-day ($1.21 vs $1.59) despite higher $/hr. Best $/sim-day overall (1-node).
   Consistent with the single-node C90 arc (AMD > Intel on speed AND cost).
3. **Network is NOT the differentiator among the fat-network parts** — hpc8a (300Gb) and hpc6id
   (200Gb) scale almost identically (85/84% @2N, 65/61% @4N). Per-core compute speed separates them.
4. **The thin-network control (c8a, 75Gb) held 83% @2N** — same as the fat parts. So at C180/120-rank
   the 75Gb pipe is NOT yet the bottleneck; the 4-node point (240 ranks) that would stress it was
   capacity-blocked. Provisional read: network only bites past 2 nodes for this grid.
5. **The scaling knee is between 2 and 4 nodes for C180** on the 192-core parts (~20pt efficiency
   drop). Graviton3E is the exception — it stays near-linear to 4 nodes.
6. **$/sim-day rises with node count** everywhere (sub-linear scaling): multi-node buys turnaround
   time at a cost premium. Cheapest absolute = hpc8a 1-node $1.21/sim-day.

**One-line takeaway (original 4-instance round):** *For GCHP C180 multi-node, Graviton3E (hpc7g)
delivers the best throughput and scaling (needs ≥2 nodes for memory); for single-node or
cost-per-sim-day, AMD Turin (hpc8a) wins; Intel SPR trails; the compute-die c8a is worst value.*

## UPDATED takeaway after the expansion round (Graviton4/5 + Intel Emerald)
The expansion **changes the headline** — newer Graviton parts dominate decisively:
- **Graviton5 (m9g.48xl) is the overall winner**: highest per-node (281.8) AND 2-node (582.3 d/d)
  throughput of EVERY instance tested, **cheapest $/sim-day ($0.80)**, and 768GB RAM so no
  single-node OOM. If you run GCHP C180 on AWS, this is the part.
- **Graviton4 (c8g compute / c8gn net-opt) is close behind** and even cheaper to acquire; c8g hits
  $0.84/sim-day. Graviton4 net-opt (c8gn) out-scales Graviton3E (hpc7g) at 4 nodes (469.6 vs 439.7).
- **Graviton sweep (gen3E→4→5) shows clear gen-over-gen gains.** x86 (AMD Turin best at $1.21,
  Intel Emerald $1.65) and the older Graviton3E now sit below the Graviton4/5 parts.
- **Network rarely the bottleneck for C180 ≤2 nodes** — even 50Gb (c8g) held super-linear 2N
  scaling. The fat-network advantage only matters at higher node counts (4N+, which were
  capacity-blocked for the 192-core parts this round).
- **Caveat:** 4-node points for c8g/c8i/m9g/c8a were capacity-blocked (4× placement-group scarce
  in us-east-2b); 2-node efficiency + per-node throughput are the solid comparison. Compiler tuning
  (-mcpu=neoverse-v2 for Graviton4, -v3 for Graviton5) was NOT applied — Graviton lead could widen.

## Raw results

### hpc8a.96xl (AMD Turin gen8, 300Gb EFA) — $7.92/hr — COMPLETE (GCHP-internal Avg, new method)
| nodes | ranks | internal Avg (d/d) | parallel eff | $/sim-day |
|-------|-------|--------------------|--------------|-----------|
| 1 | 60  | 157.1 | (baseline) | 1.21 |
| 2 | 120 | 268.3 | **85.4%** | 1.42 |
| 4 | 240 | 411.4 | **65.5%** | 1.85 |

- **Scaling:** 85.4% (2N) → 65.5% (4N). 4-node still >60% gate, but the per-node return is
  dropping fast (knee between 2 and 4 nodes). 8-node not pursued (C180 over-decomposes; the
  single-node arc already showed C180 knees past ~240 ranks).
- **Fastest absolute throughput** of the HPC set (157 d/d/node, AMD Turin).
- **$/sim-day rises with node count** (efficiency <100%): scaling out buys wall-clock speed at a
  cost premium — for throughput-insensitive batch work, 1 node is cheapest.
- (Old mpirun-wall method gave 141/214/310 & lower apparent efficiency 76%/55% — that method
  charged per-run init/IO to "scaling loss". Internal Avg is the correct, cleaner metric.)

### hpc6id.32xl (Intel SPR, 200Gb EFA) — $5.70/hr — internal-throughput (checkpoint hung; metric from GCHP log)
| nodes | ranks | internal Avg (d/d) | parallel eff | $/sim-day |
|-------|-------|--------------------|--------------|-----------|
| 1 | 60  | 86.3  | (baseline) | 1.58 |
| 2 | 120 | 145.1 | 84.1% | 1.89 |
| 4 | 240 | 210.8 | 61.1% | 2.60 |

- Intel SPR ≈ **0.6×** hpc8a's per-node throughput (86 vs 141 at 1-node) — AMD Turin clearly faster per-core.
- **Better scaling efficiency than hpc8a** (84% vs 76% @2N; 61% vs 55% @4N) — fewer cores/node
  (64 vs 192) means less intra-node contention + the 200Gb net feeds 60 ranks comfortably.
- $/sim-day computed on internal-Avg throughput (hpc6id $5.70/hr).
- (1-node mpirun-wall cross-check: 1107s/78 d/d — internal Avg 86 is slightly higher as it
  excludes init overhead, as expected.)

### c8a.48xl (AMD8 compute, **75Gb**, thin-network control, us-east-2c) — $10.35/hr — internal Avg
| nodes | ranks | internal Avg (d/d) | parallel eff | $/sim-day |
|-------|-------|--------------------|--------------|-----------|
| 1 | 60  | 107.5 | (baseline) | 2.31 |
| 2 | 120 | 178.9 | 83.2% | 2.78 |
| 4 | 240 | **capacity-blocked** | — | — |

- 4-node NOT obtained: 4× c8a.48xl in a placement group thrashed CONFIGURING↔PENDING in us-east-2c
  (intermittent capacity for 4 co-located; 1N/2N launched fine). Honest gap, not a run failure.

- c8a (AMD Turin/Genoa compute die, 75Gb net) per-node throughput **107.5** — slower than hpc8a's
  157 despite same-gen AMD cores. Likely the lower clock/cache of the compute-optimized SKU.
- **2-node efficiency 83.2%** — NOT collapsing yet at 75Gb (C180/120-rank halo still fits the pipe);
  the 4-node point (240 ranks, more comms) is the real network-stress test vs hpc8a's 300Gb.
- Pricey ($10.35/hr) → worst $/sim-day of the set ($2.31 1N). Ran in us-east-2c (no 2b capacity).

### EXPANSION (2026-06-27 round 2): Graviton4/5 + Intel Emerald + thin-net Graviton
GCHP-internal Avg (d/d). All us-east-2b, 60 ranks/node, O-server, sim-completion-detect method.

| instance | arch | net Gb | $/hr | 1N | 2N | 4N | notes |
|----------|------|--------|------|----|----|----|-------|
| c8gn.16xl | Graviton4 net-opt | 200 | 3.79 | OOM | 305.3 | **469.6** | 4N beats hpc7g! 128GB→1N OOM. eff4(v2N)=77% |
| c8g.48xl | Graviton4 cmpt 192c | 50 | 7.63 | 219.0 | 459.6 | cap-blocked | **eff2=105%** (super-linear); **$0.84/simday** |
| c8i.48xl | Intel Emerald g8 | 75 | 9.00 | 131.0 | 220.4 | cap-blocked | eff2=84%; 1.5× older SPR (hpc6id 86) |
| c8a.48xl | AMD compute | 75 | 10.35 | cap-flaky | | | never got capacity even at 1N this round |
| **m9g.48xl** | **Graviton5** 192c | 100 | 9.39 | 281.8 | **582.3** | cap-blocked | **highest 2N of ALL**; eff2=103%; **$0.80/simday** |

(internal Avg d/d. 4-node capacity-blocked for c8g/c8i/m9g: 4× placement-group in us-east-2b wouldn't
satisfy — persistent, not transient. c8gn got its full curve in round 1.)

**FINDINGS (expansion round):**
- **Graviton5 (m9g) is the per-node + 2-node throughput KING** — 1N=281.8, 2N=582.3 (highest
  2-node of ANY instance, beating even c8gn). 768GB RAM → no 1-node OOM (unlike the 128GB Graviton
  net-opt parts). And **cheapest $/sim-day at $0.80** (1N). Newest Graviton core = biggest per-core punch.
- **Graviton4 compute (c8g) nearly matches** — 2N=459.6, $0.84/simday — despite a THIN 50Gb network.
  At C180/120-rank the 50Gb pipe isn't the bottleneck; fast cores dominate. (4N/240-rank would test it.)
- **Super-linear 2-node scaling (105% c8g, 103% m9g)**: at 1-node, 192 ranks contend for memory
  bandwidth/cache; splitting across 2 nodes relieves it → >2× speedup. Real effect, not noise.
- **Intel Emerald (c8i) = 1.5× the older SPR** (hpc6id) per node (131 vs 86) — newest Intel closes
  some gap but still trails Graviton/AMD badly and is the priciest-per-sim-day x86 ($1.65).
- **Graviton4 net-opt (c8gn) 4N=469.6 beats hpc7g (Graviton3E) 439.7** — gen-over-gen Graviton win.
- **c8a never obtained** even 1-node this round (c8a.48xl capacity genuinely scarce in us-east-2b).

### hpc7g.16xl (Graviton3E, 200Gb, us-east-1) — $TBD/hr — internal Avg
| nodes | ranks | internal Avg (d/d) | parallel eff | notes |
|-------|-------|--------------------|--------------|-------|
| 1 | 60  | **OOM — infeasible** | — | 128GB too small for single-node C180 (killed sig-9 during init at ~34GB climbing) |
| 2 | 120 | 229.5 | (baseline) | |
| 4 | 240 | 439.7 | 95.7% (vs 2N) | near-linear 2→4! |

- **hpc7g 1-node C180 is INFEASIBLE** — only 128GB RAM; OOM-killed during initialization (all 6
  cubed-sphere faces' fields on one node exceed 128GB). 2/4-node succeed because the global domain
  is partitioned across nodes (less memory/node). A real hardware limit, not a config bug.
- **Graviton3E scales beautifully 2→4: 95.7% efficiency** (229.5→439.7) — the 200Gb fat network +
  fewer cores/node (64) keep it near-linear where the 192-core parts knee harder.
- Bootstrap required adding the us-east-1 **DynamoDB gateway endpoint** (+ the 4 SSM/EC2 interface
  endpoints) — the missing DynamoDB endpoint was the classic "retrieve compute node info" hang.

## Key methodology evolution (2026-06-27)

**1. Multi-node pnc4 checkpoint HANGS — and `WRITE_RESTART_BY_OSERVER: YES` is NOT a reliable fix.**
1-node checkpoints write fine; 2+ node runs HANG at the collective pnc4 checkpoint write
(`NetCDF4_FileFormatter line 189`) AFTER the sim completes — regardless of filesystem (hangs on
Lustre too; ext4 was a red herring). O-server YES fixed it on hpc8a (192c) but NOT on hpc6id
(64c) — there the checkpoint still hung until the job's time limit (~2hr wasted on a 4-node run!).

**2. THE REAL FIX — measure throughput from GCHP's INTERNAL timer, kill mpirun at sim-completion.**
The benchmark only needs throughput, which GCHP prints every timestep:
`Throughput(days/day)[Avg Tot Run]`. The run script now WATCHES the log; the instant the final
timestep prints it records time + GCHP-internal Avg throughput, then KILLS mpirun — so a hung
checkpoint costs seconds, not hours. **No reliance on any timeout** (a tight 40min `--time`
remains only as a last-resort backstop for a truly-wedged job). The checkpoint is irrelevant to
the measurement, so we stopped waiting on it.

**3. Primary metric = GCHP-internal "Avg" throughput (cumulative days/day over the integration).**
Immune to the I/O hang, identical extraction across instances, more precise than mpirun-wall.
The earlier hpc8a numbers used mpirun-wall (the old method); hpc8a will be RE-RUN with the new
method for apples-to-apples comparison. hpc6id numbers below are GCHP-internal.
