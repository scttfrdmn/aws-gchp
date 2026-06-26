# GCHP C90 Single-Node Benchmark — June 2026

**Workload:** GCHP 14.7.1, TransportTracers, MERRA-2, C90, 1 day, single node, full
physical cores per instance. Validated stacks (GCC 12.2 / OpenMPI 4.1.7 / ESMF 8.6.1).

**Metric that matters:** $ per simulated day = ($/hr) / (throughput days/day). Raw
throughput is NOT comparable across instances (different core counts).

## Instance matrix

| instance | arch / gen | phys cores (GCHP) | RAM GiB | $/hr (OD, us-east-1) | $/core-hr |
|----------|-----------|-------------------|---------|----------------------|-----------|
| c7a.48xlarge | AMD EPYC Genoa (gen7) | 192 | 384 | 9.853 | 0.051 |
| c8a.48xlarge | AMD EPYC Turin (gen8)  | 192 | 384 | 10.346 | 0.054 |
| c7i.48xlarge | Intel SPR (gen7)       | 96  | 384 | 8.568 | 0.089 |
| c8i.48xlarge | Intel EMR/GNR (gen8)   | 96  | 384 | 8.996 | 0.094 |
| c7g.16xlarge | Graviton3              | 60  | 128 | 2.320 | 0.039 |
| c8g.16xlarge | Graviton4              | 60  | 128 | 2.552 | 0.043 |

Notes: Intel uses 96 PHYSICAL cores (SMT disabled). Graviton uses 60 of 64 (÷6 rule).
Pricing snapshot 2026-06-25 on-demand; verify before publishing.

## Method
- One cluster per instance type, C90 1-day run via gchp-setup-rundir.sh (--cs-res 90).
- Throughput read from GCHP log `Throughput(days/day)[Avg Tot Run]` (Avg column) at
  run end; success = cap_restart advance + checkpoint (benign teardown abort ignored).
- Phased rollout: validate c7i (first-ever Intel run) before fanning out to the rest.

## Results (RAW — full physical cores; see CRITICAL CAVEAT below)

All 6 completed successfully (cap_restart→20190102, checkpoint written). Throughput
is the GCHP `Avg` column. $/sim-day = $/hr × 24 / throughput.

| instance | arch/gen | cores | throughput (days/day) | $/sim-day | tput/core |
|----------|----------|-------|----------------------|-----------|-----------|
| c7a.48xlarge | AMD7   | 192 | 184.8  | 1.280 | 0.96 |
| c8a.48xlarge | AMD8   | 192 | 203.4  | 1.221 | 1.06 |
| c7i.48xlarge | Intel7 | 96  | 352.7  | 0.583 | 3.67 |
| c8i.48xlarge | Intel8 | 96  | 567.3  | 0.381 | 5.91 |
| c7g.16xlarge | Grav3  | 60  | 847.2  | 0.066 | 14.12 |
| c8g.16xlarge | Grav4  | 60  | 1067.1 | 0.057 | 17.79 |

### ⚠️ CRITICAL CAVEAT — this table is NOT a valid architecture comparison

Two confounds make the raw numbers misleading; do not publish as "arch X beats Y":

1. **Core count is confounded with architecture.** "Full physical cores" meant AMD
   ran at 192, Intel at 96, Graviton at 60 — so differences reflect core count as much
   as architecture. We measured three different *configurations*, not three CPUs.
2. **The 192-core AMD runs are anomalously slow** (tput/core ≈ 1.0 vs Graviton 14-18,
   Intel 3.7-5.9). C90 over 192 MPI ranks is almost certainly **over-decomposed** —
   tiny per-rank subdomains (C90 = 90×90/face; at 32 ranks/face the tiles are small),
   so halo-exchange/MPI overhead dominates and throughput collapses. This is a
   workload/scale artifact at 192 ranks, not "AMD is slow."

**Conclusion: invalid as run.** A correct comparison must hold core count constant
across architectures (and pick a core count that's well-matched to C90). See redo plan.

Pricing snapshot 2026-06-25 on-demand, us-east-1.

---

# REDO — Matched 96 cores (the valid comparison)

Intel is the core-count ceiling (c7i/c8i max = 96 PHYSICAL cores), so **96 is the
matched value** every vendor can hit. Larger Graviton (c8g.24xl, m9g.24xl) used to reach
96 rather than capping at 64. Graviton3 (c7g) can't exceed 60, so it's a labeled bonus.

Matrix (all C90, 1 day, single node, **96 cores** except c7g=60):

| cluster | instance | arch / gen | cores | $/hr | RAM-class |
|---------|----------|-----------|-------|------|-----------|
| bench-c7a   | c7a.48xlarge | AMD gen7      | 96 (of 192) | 9.853 | compute (2GB/vCPU) |
| bench-c8a   | c8a.48xlarge | AMD gen8      | 96 (of 192) | 10.346 | compute |
| bench-c7i   | c7i.48xlarge | Intel gen7    | 96 (full phys, SMT off) | 8.568 | compute |
| bench-c8i   | c8i.48xlarge | Intel gen8    | 96 (full phys, SMT off) | 8.996 | compute |
| bench-c8g24 | c8g.24xlarge | Graviton4     | 96 | (tbd) | compute |
| bench-m9g24 | m9g.24xlarge | Graviton5     | 96 | (tbd) | general (4GB/vCPU) |
| bench-c7g   | c7g.16xlarge | Graviton3     | 60 (max) | 2.320 | compute *(bonus, diff cores)* |

Note: m9g is general-purpose (no compute-optimized c9g exists yet); valid CPU comparison
but different memory tier. c7a/c8a run 96 of their 192 cores for matching.

## Results (matched 96 cores — VALID comparison) — 2026-06-26

All C90, 1 day, single node, 96 cores (c7g = 60, bonus). Sorted by $/sim-day (best first).

| instance | arch / gen | cores | $/hr | days/day | **$/sim-day** | tput/core |
|----------|-----------|-------|------|----------|--------------|-----------|
| c7g.16xlarge | Graviton3 | 60 | 2.320 | 842.4  | **0.066** | 14.04 |
| c8g.24xlarge | Graviton4 | 96 | 3.828 | 1156.4 | **0.079** | 12.05 |
| m9g.24xlarge | Graviton5 | 96 | 4.696 | 1381.2 | **0.082** | 14.39 |
| c8i.48xlarge | Intel gen8 | 96 | 8.996 | 556.4 | **0.388** | 5.80 |
| c7i.48xlarge | Intel gen7 | 96 | 8.568 | 362.8 | **0.567** | 3.78 |
| c8a.48xlarge | AMD gen8 | 96 | 10.346 | 408.1 | **0.608** | 4.25 |
| c7a.48xlarge | AMD gen7 | 96 | 9.853 | 360.2 | **0.657** | 3.75 |

### Findings (matched 96 cores)
- **Graviton wins decisively on cost-efficiency**: ~5-10× lower $/sim-day than Intel/AMD.
  Driven by both lower $/hr (~$2-5 vs ~$9-10) AND higher throughput per core.
- **Per-core throughput (architecture speed):** Graviton 12-14 >> Intel gen8 5.8 >
  Intel gen7 3.8 ≈ AMD 3.8-4.3. Graviton ~2-3× faster per core here, AND cheaper.
- **Gen-on-gen:** Graviton5 (m9g) > Graviton4 (c8g) on raw tput (1381 vs 1156) but
  ~same $/sim-day (m9g costs more, is general-purpose 4GB/vCPU). Intel gen8 ≫ gen7
  (556 vs 363 — a big jump). AMD gen8 > gen7 modestly (408 vs 360).
- **Intel vs AMD at matched 96 cores:** Intel gen8 is the best of the x86 field here;
  AMD trails on both throughput and (because it's priced for 192 cores) $/sim-day.

### Caveats / honesty
- **96 cores is matched, but AMD/Intel are NOT at their best deployment point.** AMD
  c7a/c8a have 192 physical cores; running only 96 means you pay for 192 and use half —
  so their $/sim-day here is pessimistic for "best instance value." A separate
  full-instance run (AMD at 192, with a healthy decomposition) is needed to answer
  "best $/sim-day per instance" — distinct from this per-core architecture comparison.
- C90 single-node only; init overhead is smaller than C24 but still nonzero. Multi-node
  scaling not measured. Throughput is the GCHP `Avg` column from one run each (no repeats
  for variance yet).
- m9g is general-purpose (4GB/vCPU); no compute-optimized Graviton5 (c9g) exists yet.
- Run history: a first attempt at "full cores" was invalid (192-core AMD over-decomposed);
  a collector race then destroyed the first matched-96 x86 runs mid-flight — both
  documented above / in memory. THIS table is the clean redo (x86 re-run with a safe
  collector; Graviton survived the incident).

---

# 192-core run (full-instance) + scaling knee — 2026-06-26

Instances with 192 physical cores: c7a/c8a (AMD), c8g.48xl (Graviton4). Intel included
at 192 *vCPU* = 96 cores + SMT (c7i/c8i.48xl, labeled HT). m9g.48xl (Graviton5 192c)
could NOT run — AWS `InsufficientInstanceCapacity` in us-east-1a (newest silicon, scarce).

## SCALING KNEE — C90 throughput, 96 vs 192 cores (days/day)
| instance | C90 @96 | C90 @192 | change |
|----------|---------|----------|--------|
| c8g (Graviton4) | 1156.4 | 1477.6 | **+28%** (still scales) |
| c7a (AMD7)  | 360.2 | 184.3 | **-49%** |
| c8a (AMD8)  | 408.1 | 200.7 | **-51%** |
| c7i-HT (Intel7) | 362.8 | 100.0 | **-72%** |
| c8i-HT (Intel8) | 556.4 | 121.4 | **-78%** |

**Finding (confirms the predicted knee):** C90 is too small to feed 192 MPI ranks. The
x86 instances LOSE ~50% (AMD) to ~75% (Intel) throughput going 96→192 — comms/halo
overhead dominates the tiny ~11x22-cell subdomains. This vindicates the earlier
"192-core C90 disaster" as a REAL scaling effect, not just the harness bug.
- **Graviton4 still gained +28%** at 192 — far more tolerant of fine decomposition
  (memory bandwidth / interconnect), a real architectural advantage.
- **Intel-HT was worst** (-72/-78%): enabling SMT (192 vCPU on 96 cores) actively HURTS
  GCHP — oversubscription thrash. Direct evidence SMT should stay OFF for GCHP.

**Practical takeaway:** for C90, run ~96 cores, not 192 (except Graviton, which still
benefits). Match core count to grid size; bigger grids (C180+) justify more cores.

## C180 @192 (days/day)
| instance | C90@192 | C180@192 |
|----------|---------|----------|
| c8g (Graviton4) | 1477.6 | 320.1 |
| c8a (AMD8) | 200.7 | 81.3 |
| c7a (AMD7) | 184.3 | 71.8 |
| c8i-HT (Intel8) | 121.4 | 50.2 |
| c7i-HT (Intel7) | 100.0 | 39.4 |

C180 days/day is lower (4x the grid cells/timestep = more work per sim-day). Graviton4
leads every category. A C180@96 baseline (not run) would be needed to judge C180 scaling
efficiency. m9g (Graviton5) 192-core data pending capacity.

---

# Gap-fill — Graviton5 @192 + C180@96 baseline — 2026-06-26

m9g capacity came through on retry (earlier InsufficientCapacity was transient).

## Graviton5 (m9g.48xl) full-instance — now complete
| res | 96c | 192c | scaling |
|-----|-----|------|---------|
| C90  | 1381.2 | 1737.9 | +26% |
| C180 | (n/a) | 411.9 | — |
m9g C90@192 = 1737.9 is the highest single-instance C90 throughput measured.

## C180 scaling 96->192 (Graviton4, the knee question for the bigger grid)
| grid | c8g C180 @96 | c8g C180 @192 | scaling |
|------|--------------|---------------|---------|
| C180 | 205.6 | 320.1 | **+56%** |
(vs c8g C90: 1156.4 -> 1477.6 = +28%)

**FINDING — the knee moves out with resolution.** C180 scales 96->192 markedly better
than C90 (+56% vs +28% on Graviton4). The bigger grid keeps 192 ranks fed (larger
subdomains), so the over-decomposition that crushed C90@192 on x86 is much milder at
C180. Practical rule: pick core count to match grid — ~96 for C90, scale higher for
C180+. Graviton scales well at both; x86 only at the grid-matched core count.

## Complete C90 96->192 scaling efficiency (all arches)
| arch | C90@96 | C90@192 | change |
|------|--------|---------|--------|
| Graviton5 (m9g) | 1381.2 | 1737.9 | +26% |
| Graviton4 (c8g) | 1156.4 | 1477.6 | +28% |
| AMD8 (c8a) | 408.1 | 200.7 | -51% |
| AMD7 (c7a) | 360.2 | 184.3 | -49% |
| Intel8-HT (c8i) | 556.4 | 121.4 | -78% |
| Intel7-HT (c7i) | 362.8 | 100.0 | -72% |

Only Graviton scales past 96 on C90. x86 instances lose 49-78% (Intel-HT worst — SMT
oversubscription). This is the central single-node result.

---

# Graviton3 (c7g) + Graviton3E (hpc7g) single-node — 2026-06-26

Both cap at 64 cores (60 for GCHP) — no 96-core single-node point exists for Graviton3.
Running C90@60 + C180@60 on each for a clean Graviton3 vs Graviton3E comparison (only
variable = the chip variant; 3E has ~2x memory bandwidth + EFA). The multi-node
scaling study (where 3E's interconnect should shine) remains a SEPARATE future effort.
- hpc7g (Graviton3E): us-east-1a only, 64 cores, 128GB, EFA.

## Graviton3 family single-node results (60 cores)
| instance | chip | C90@60 | C180@60 |
|----------|------|--------|---------|
| c7g.16xlarge   | Graviton3  | _rerunning_ (prior: 842.4) | _pending_ |
| hpc7g.16xlarge | Graviton3E | _pending_ | _pending_ |

---

# ════ FINAL SINGLE-NODE SUMMARY (C90, medians, right-sized pricing) ════
Generated 2026-06-26. $/sim-day = $/hr × 24 / throughput. Variance: medians of 3 reps
where measured (c8g/c8a/c8i); c8i had one outlier (341 vs ~574) → median used.

| instance | arch/gen | cores | $/hr | C90 days/day | $/sim-day | rank |
|----------|----------|-------|------|--------------|-----------|------|
| c7g.16xl  | Graviton3  | 60 | 2.320 | 842.4  | 0.066 | best $/sim-day |
| c8g.24xl  | Graviton4  | 96 | 3.828 | 1259.7 | 0.073 | |
| m9g.24xl  | Graviton5  | 96 | 4.696 | 1381.2 | 0.082 | fastest |
| c8a.24xl  | AMD8       | 96 | 5.173 | 397.1  | 0.313 | best x86 |
| c7a.24xl  | AMD7       | 96 | 4.927 | 360.2  | 0.328 | |
| c8i.48xl  | Intel8     | 96 | 8.996 | 573.1  | 0.377 | |
| c7i.48xl  | Intel7     | 96 | 8.568 | 362.8  | 0.567 | worst $/sim-day |
| hpc7g     | Graviton3E | 60 | tbd   | 839.2  | (pending price) | |

## Headline conclusions (single-node, validated)
1. **Graviton is cheapest AND fastest.** Best $/sim-day (Graviton ~$0.07 vs Intel
   $0.38-0.57, AMD $0.31-0.33) AND highest throughput. Wins both axes.
2. **AMD beats Intel** once right-sized (24xl): AMD8 $0.313 < Intel8 $0.377 < Intel7
   $0.567. (The earlier "Intel wins x86" was an artifact of wrong 48xl pricing.)
3. **Per-core: Graviton ≈ 2-3× Intel/AMD.** Graviton4/5 ~13-14 days/day/core vs x86 ~3.8-6.
4. **SMT hurts GCHP** — Intel at 192 vCPU (HT) was the worst scaler (-72/-78% vs 96-phys).
5. **Scaling knee depends on grid:** C90 over-decomposes past ~96 ranks on x86 (-49 to
   -78% at 192); only Graviton keeps scaling (+26-28%). C180 scales 96→192 far better
   (+56% on Graviton4) — bigger grids justify more cores.
6. **Graviton3 vs Graviton3E single-node: identical** (842 vs 839) — 3E's bandwidth/EFA
   edge only matters multi-node (→ the multi-node study).

## Gen-on-gen (matched 96, C90)
- Graviton: G4 1260 → G5 1381 (+10%)
- AMD: gen7 360 → gen8 397 (+10%)
- Intel: gen7 363 → gen8 573 (+58%, biggest generational jump)

---

# Graviton3 family single-node — final (2026-06-26)

| instance | chip | C90@60 | C180@60 |
|----------|------|--------|---------|
| c7g.16xl   | Graviton3  | 842.4 | 839.1 |
| hpc7g.16xl | Graviton3E | 839.2 | **OOM** (rank killed, sig 9, during init) |

**Findings:**
- **Graviton3 ≈ Graviton3E single-node** (C90: 842 vs 839 — within noise). Confirms 3E's
  memory-bandwidth/EFA advantage is a MULTI-NODE story, not single-node.
- **C180@60 is at the 128GB memory edge for the Graviton3 family.** Same 64c/128GB
  hardware: c7g completed C180@60 (839.1), hpc7g OOM'd at init (~2.1GB/rank vs the
  ~1.7GB/core HISTORY driver + model state). Marginal/run-to-run sensitive at 128GB.
  IMPLICATION for multi-node: hpc7g (128GB) needs watching for OOM at C180; the AMD/Intel
  HPC parts (384-1024GB) have ample headroom. Could also reduce ranks/node or HISTORY
  collections to fit C180 on hpc7g.

C180@60 throughput for the Graviton3 family is therefore only cleanly measured on c7g
(839.1); hpc7g's is OOM-limited (not a throughput result).

---

# Future consideration: per-architecture compiler tuning (NOT done — flagged 2026-06-26)

All results above use ONE build per ISA: x86_64 = generic `-O2 -g` (no -march, for
portability across AMD+Intel); aarch64 = `-O2 -g -mcpu=neoverse-v1`. So the cross-arch
numbers reflect GENERIC builds, not per-chip-optimized ones.

Implications / open avenue:
- Graviton3E (hpc7g) is Neoverse V1 like Graviton3, so -mcpu=neoverse-v1 is appropriate,
  BUT Graviton4/5 (Neoverse V2/V3) may gain from -mcpu=neoverse-v2 / native, and 3E's
  wider memory subsystem might reward different tuning. Our single binary leaves that on
  the table.
- x86 generic -O2 (no -march=znver4 / sapphirerapids) likely UNDERSELLS both AMD and
  Intel vs a tuned build — the portability tradeoff. A -march-tuned build per chip could
  shift the x86 numbers up (how much is unknown — could narrow the Graviton gap or not).
- So the benchmark answers "generic-portable-build performance," which is the realistic
  default for a shared FSx stack. A separate "tuned-build" study would be a distinct arc.
This does NOT change the headline (Graviton cheapest+fastest on the as-shipped stack),
but it's an honest scope boundary.
