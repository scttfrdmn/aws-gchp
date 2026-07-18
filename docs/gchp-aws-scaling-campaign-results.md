# GCHP on AWS: Scaling, Cost, and Chemistry Decoupling — Campaign Results

**What this is.** A defensible, measured account of running GEOS-Chem High Performance (GCHP 14.7.1)
on AWS across the cubed-sphere resolution ladder C24→C180, on Graviton/Intel/AMD instances, for both
TransportTracers (TT) and full chemistry (fullchem). It answers four questions with data, not
estimates: (1) how GCHP **scales** across instances and resolutions, (2) **timing/throughput**,
(3) **cost** ($/sim-day frontier), and (4) whether **decoupling chemistry** to otherwise-idle cores
delivers real speedup. Every number traces to a run in `scripts/gchp_aws/data/benchmarks.json` with
`source{file,line,date}` provenance; the companion calculator (`scripts/gchp_aws/`) reproduces them
and refuses to rank where it has no basis.

**Dataset:** 65 measured rows (55 TT, 10 fullchem), 14 instance types, resolutions C24/C48/C90/C180,
1N/2N/4N. Region us-east-1 (GEOS-Chem RODA `s3://gcgrid` native). Method: END_MARK + GCHP-internal
`Avg` throughput + kill-at-sim-completion (immune to the pnc4 checkpoint hang). Total spend ≈ $210.

---

## 1. Scaling across instances (held constant at 96 ranks, 1 node)

Comparing **at equal core count** (96 ranks) — not full-cores, which confounds architecture with core
count. Throughput in sim-days/day:

| resolution | best → worst (sim-days/day) |
|---|---|
| C24 TT  | c8g 4206 · m9g 1675 · c8i 834 · c8a 529 · c7i 498 · c7a 447 |
| C48 TT  | **m9g 4444** · c8g 3252 · c8i 734 · c8a 508 · c7i 460 · c7a 430 |
| C90 TT  | **m9g 1381** · c8g 1156 · c8i 556 · c8a 408 · c7a 360 · c7i 353 |

**Findings (with an important regime distinction):**
- **The raw TT gap is large but MOSTLY an overhead artifact, not compute.** Graviton (c8g) beats AMD
  (c7a) by **9.4× at C24 TT, 7.6× at C48 TT** — but that gap **collapses to 1.6–1.9× on compute-bound
  fullchem** (c8g/c7a = 1.9× at C48, 1.6× at C90). The shrink is the tell: at small resolution GCHP is
  dominated by *fixed per-timestep overhead* (MPI collective latency, halo exchange, per-step setup)
  because cells/rank is tiny (~2,600 at C24/96r) and timesteps are short — so throughput measures
  *how fast you can dispatch timesteps* (latency), not FLOPs. Graviton's on-package memory-controller +
  interconnect integration wins that latency game hugely. **Don't quote the 9×; it's not the compute
  advantage.**
- **The defensible production-workload advantage is ~1.6–1.9×** (compute-bound fullchem), and it is
  very plausibly **memory bandwidth** — GEOS-Chem's KPP Rosenbrock solver is a sparse gather/scatter
  workload (memory-bound, not FLOP-bound), and Graviton4's DDR5 + on-die controllers deliver more
  effective BW/core than the AMD Genoa part here. (STREAM Triad per-arch confirms the mechanism — see
  §5a.) **Caveat:** only 2 cross-arch fullchem points measured (both c8g-vs-c7a); no Intel fullchem,
  no matched-core m9g-vs-c8g fullchem. So "~1.7×, likely bandwidth" is what the data supports — not more.
- **Graviton4 vs Graviton5 swaps with resolution.** c8g (G4) wins C24 TT (clock/latency); m9g (G5) wins
  C48/C90 (real work per rank). m9g's *unique, unambiguous* advantage is **memory capacity** (768 GB) —
  it is the only in-region box that fits C180 fullchem at all, independent of any bandwidth argument.

**Multi-node:** super-linear-ish 2N on Graviton for C90 TT (c8g 1478→2525 d/d = 1.7×); 4N reliably
achievable only PlacementGroup-OFF (192-core parts are capacity-blocked under a PG). C180 TT 2N
scaled 1.6–2.0× across the board.

---

## 2. Timing / throughput — the fullchem resolution curve (m9g, 1N, 2 sim-hr window)

| resolution | fullchem d/d | TT/fullchem ratio |
|---|--:|--:|
| C24  | 895.0 | 4.7× |
| C48  | 231.1 | 19× |
| C90  | 60.9  | 26× |
| C180 | 7.4 (48r) | 113× |

- **Chemistry's share of the wall explodes with resolution.** The TT/fullchem throughput ratio grows
  from 4.7× (C24) to **113× (C180)** — at production resolution, chemistry is the overwhelming cost.
  (A prior single-grid "flat 34×" was a mid-resolution artifact; the calculator now uses the measured
  per-resolution ratio.)
- **C180 1N/48r = 7.3–7.4 d/d reproduced independently to <2%**, validating the whole methodology.
- **C180 fullchem does NOT scale by adding ranks on one node** (the key result feeding §4): 48r → 7.4,
  96r → 6.1 (*slower*), 192r → **OOM** (715 GB high-water > 768 GB box; kernel OOM-killer at t=00:15).
  More ranks = more per-rank memory + worse decomposition. The 144 spare cores are unreachable by the
  monolith.

---

## 3. Cost — the $/sim-day frontier

Cheapest instance per cell (`$/hr × 24 × nodes / throughput`):

| resolution | TT cheapest | fullchem cheapest |
|---|---|---|
| C24  | hpc7g **$0.014** | m9g $0.25 |
| C48  | hpc7g **$0.021** | c8g $0.77 |
| C90  | c8g $0.057 | c8g $2.72 |
| C180 | c7g $0.066 | m9g **$30.46** |

- **For TT, cheapest-$/hr wins** — hpc7g (Graviton3E, $1.68/hr, 128 GB) is the $/sim-day floor; the box
  is fast enough and its low hourly rate dominates.
- **For fullchem, the memory wall reshapes the frontier.** C90 fullchem's cheapest is c8g (384 GB,
  $2.72) — hpc7g's 128 GB can't hold it. C180 fullchem is **m9g-only in us-east-1** ($30/sim-day) because
  no other in-region box has ≥768 GB (us-east-1 lacks hpc8a/hpc6id).
- C180 fullchem at $30/sim-day is **the number that makes decoupling worth building** — halving it is
  real money on any multi-month campaign.

---

## 4. Chemistry decoupling — the headline result

**Thesis:** move the KPP chemistry solve out of the GCHP rank into co-located worker processes over
POSIX shared memory (zero-copy), so M workers > N transport ranks can run chemistry on the idle cores
that §2 proved the monolith can't use. Extra workers attach the *same* per-rank shm → they cost **cores,
not RAM** — which is exactly why this is memory-feasible where adding ranks OOMs.

**Correctness (GATE 3, C24 fullchem, 6 ranks):** the decoupled checkpoint is **bit-for-bit identical**
to the stock inline monolith at every worker count:

| config | checkpoint MD5 |
|---|---|
| baseline (inline) · K=1 · K=2 · K=4 | `dd532a95…a76897` — all identical ✅ |

**Speedup (C90 fullchem, m9g, N=48 transport ranks):** byte-identical at every K
(`3a03bda9…065821`), throughput scales with chem workers:

| config | processes | throughput | speedup |
|---|--:|--:|--:|
| baseline (48 inline) | 48 | 31.9 d/d | 1.00× |
| K=2 | 96 | 55.6 d/d | **1.74×** |
| K=4 | 192 (all cores) | 71.1 d/d | **2.23×** |

- **2.23× measured speedup, byte-identical, using cores the monolith wasted.** Monotonic in K;
  transport Run-rate held steady (~151 d/d) — only the chemistry tier accelerated, exactly as designed.
- The measured chemistry fraction is **73.5%** → Amdahl ceiling ≈ **3.78×**. The 2.23× at K=4 is
  **core-count-limited** (192 = all cores on the box), not algorithm-saturated — a bigger box or
  multi-node worker pool would go further.
- Mechanism: static contiguous `[lo,hi)` cell slices + a counting-barrier handshake (rank posts
  `ready` K times, waits `done` K times). K=1 reduces exactly to the proven 1:1 path. Default-off,
  flag-gated (`GCHP_USE_REMOTE_CHEM`, `GCHP_CHEM_NWORKERS`), upstreamable as patches (no fork).

**Beyond on-node: horizontal (off-node) chemistry.** On one node, M>N is capped at the box's core
count (the 2.23× at K=4 IS that wall — 192 = all cores). The next step is a **remote chemistry fleet**:
the transport ranks ship column state off-node and a separate pool solves it. The transport cost is
already measured (per-superstep state ≈ 230 MB/rank, ~27 GB/domain at C180):

| transport | 27 GB handoff | spans nodes | durable / time-decoupled |
|---|--:|:--:|:--:|
| POSIX shm (what's built) | 0.33 s | no (on-node) | no |
| RDMA / EFA one-sided | 2.1 s (13 GB/s) | yes | no (both ends co-scheduled) |
| S3-wide (own-key/rank) | ~32 s round-trip | yes | **yes (N≠M, spot-tolerant)** |
| shared Lustre | 168 s | yes | no (lock contention — fatal) |

The chemistry compute this offloads is tens of seconds to minutes per superstep, so **the handoff is
1–2 orders of magnitude cheaper than the physics it moves** — off-node scaling is *not* transport-gated,
only orchestration-gated. Two regimes: **RDMA** (2.1 s, essentially free) for a co-scheduled remote
chem fleet — my slice/counting-barrier mechanism ports with only a shm→RDMA backend swap; and
**S3-wide** (~32 s) for the operational prize — an **elastic/spot/GPU chemistry tier** that decouples in
*time*, not just space (producers and consumers needn't be the same count or alive simultaneously).
Per-cell chemistry is embarrassingly parallel, so off-node has **no core-count cap** — it runs to the
Amdahl ceiling (3.78× here) and rises further as resolution pushes the chem fraction toward 80%+.

---

## 5. What this means for a GCHP-on-AWS user

- **Pick by memory first, then throughput.** C180 fullchem → m9g (only ≥768 GB in-region). C90/C48
  fullchem → any 384 GB box (c8g best value). TT at any resolution → hpc7g (cheapest $/sim-day).
- **Prefer Graviton** — but for the *right* reason. On production fullchem the advantage over AMD is
  **~1.6–1.9×** (not the 7–9× the tiny-resolution TT numbers suggest; that gap is per-timestep overhead,
  not compute). It's very likely memory-bandwidth-driven (see §5a) and it comes at a *lower* $/hr, so
  Graviton also holds the cheapest $/sim-day at every measured cell — the value case is strong even at
  the honest 1.7×.
- **Don't over-decompose fullchem.** Adding ranks past the memory-optimal point slows it or OOMs it
  (C180: 48r is faster than 96r and 192r OOMs). Match ranks to the memory-feasible layout.
- **Decoupling is a real lever at production resolution**, where chemistry is 60–74% of the wall and the
  idle cores are otherwise stranded — up to ~2.2× today, more with more cores.

## 5a. Why Graviton wins fullchem — memory bandwidth (STREAM Triad, per arch)

To test whether the ~1.7× compute-bound advantage is bandwidth (not clock/FLOPs), STREAM Triad
(sustained DRAM bandwidth, OpenMP over all cores, 1.6 GB arrays to defeat cache) on each bare instance:

@@STREAM_TABLE@@

**Reading it:** if the STREAM bandwidth ratio (Graviton4/AMD) tracks the fullchem throughput ratio
(~1.7×), memory bandwidth is confirmed as the mechanism — GCHP's KPP solver is bandwidth-bound, so the
box that feeds its cores more bytes/sec wins, and it's not about clock speed or peak FLOPs. (This
isolates the *compute-bound* advantage; the 7–9× TT gap in §1 is separate — that's per-timestep
dispatch latency, which STREAM does not measure.)

## 6. Appendix — C360 (characterized, not run)

No C360 restart exists in `s3://gcgrid` (the ladder tops out at C180), so C360 needs a one-time offline
regrid of the C180 restart → C360 (ESMF / `regrid_restart_file.py`), then a multi-node run. From the
measured memory law (∝ cs²/nodes) and throughput law: C360 fullchem global state ≈ **~1.9 TB** →
**≥3–4 m9g nodes for memory alone**; checkpoint ≈ ~170 GB; throughput extrapolates to ~1–2 d/d on 4
nodes (the calculator EXTRAPOLATES to C360 with a loud flag). Out of committed scope; characterized so
the frontier is bounded without the multi-node spend. This is exactly where decoupling matters most —
C360's chemistry fraction would exceed C180's 74%.

---
*All figures measured on GCHP 14.7.1, us-east-1, GCC 12.2.0 + OpenMPI 4.1.7 + EFA, 2026-06 → 2026-07.
Reproduce via `scripts/gchp_aws/` (the calculator) against `scripts/gchp_aws/data/benchmarks.json`.*
