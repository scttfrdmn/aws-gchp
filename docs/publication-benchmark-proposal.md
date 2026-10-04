# Proposal: Publication-Quality GCHP-on-AWS Decoupled-Chemistry Benchmark Study

**Status: PROPOSAL — no spend until approved.** Requested scope (2026-07-18): statistically-meaningful
(5-rep, mean±stddev) results across all GCHP-usable us-east-1 instances, comparing three operating
modes — **stock**, **on-node M>N plugin**, **S3/horizontal decoupling** — driven to the Amdahl limit,
plus a STREAM mechanism probe. Publication quality.

## Thesis / paper claim
> Decoupling GEOS-Chem chemistry from the transport monolith is **bit-identical** and converts
> otherwise-stranded cores into throughput: **~2.2× on-node** (core-count-limited) and **up to the
> ~3.8× Amdahl ceiling off-node** via an elastic S3/RDMA chemistry fleet — at production resolution
> (C180) where chemistry is ~74% of the wall. Graviton's advantage on this memory-bound workload is
> ~1.7× (bandwidth-driven, STREAM-confirmed), not the 7–9× naive small-grid numbers suggest.

## Instance matrix (10 GCHP-usable in us-east-1)
hpc7g, c7g, c8gn.16xl (128 GB) · c8g, c8gn.48xl, c7a, c8a, c7i, c8i (384 GB) · m9g (768 GB).
Memory feasibility (fullchem): C24 all 10 · C48/C90 the 7 ≥384 GB boxes · **C180 m9g-only**.

## Statistical design
- **5 replicates per cell**, report **mean ± stddev** (+ min/max). Quantifies the ~7% FSx-contention
  spread we saw at 1-rep. Warm-cache (first rep of each resolution is a discarded warmup, not counted).
- **Held-constant cores** for cross-arch comparison (96 ranks = the common denominator); layout + NX/NY
  documented per cell. Full-core points reported separately, never mixed into arch comparisons.
- Throughput = GCHP-internal `Avg` d/d (END_MARK method, checkpoint-hang-immune). Each row keeps
  `source{file,line,date}`; every figure reproducible via the calculator.

## Phases, cells, and cost (honest — includes cluster-lifecycle overhead)

Compute-node minutes are short (TT ~3, fullchem C24/C48/C90/C180 ≈ 2/3/7/18 min), so **cost is
dominated by cluster lifecycle** — head node + FSx bill for the whole batch (create+poll+teardown ≈
20–40 min/cluster beyond compute), plus capacity retries and reruns. Estimates below pad for that.

| phase | what | cells×reps | run-cost | notes |
|---|---|--:|--:|---|
| **D. STREAM** | per-arch mem-BW (5 instances) | 5 | ~$5 | finish now; explains Graviton |
| **A. Stock matrix** | TT+fullchem, all instances, held-cores | ~38 TT + 25 FC, ×5 | **$250–400** | backbone; TT cheap, FC the cost |
| **B. On-node M>N** | fullchem K-sweep to core wall | ~18 cells ×5 | **$200–350** | m9g-heavy 2h runs; byte-identity each |
| **C. S3/horizontal** | BUILD + multi-node fleet-sweep | ~16 configs ×5 | **$500–900** | + build (dev time); multi-node m9g |
| | | | **≈ $1,000–1,700 total** | vs my initial $1.5–3k guess |

### Phase C is the long pole — it needs a BUILD first
The S3/RDMA backends are **designed but not written** (only on-node shm exists). Phase C requires:
1. **RDMA transport backend** — swap shm↔EFA one-sided in the ChemRemote layer (mechanism/slices/barrier
   unchanged). ~1–2 days. Enables a co-scheduled remote chem fleet (2.1 s/27 GB handoff, measured).
2. **S3-wide backend + fleet orchestrator** — transport ranks PUT column state to own-keys, an elastic
   pool GETs/solves/PUTs back (~32 s round-trip, measured). N≠M, spot-tolerant. ~2–3 days.
3. Multi-node cluster configs (transport node + chem-fleet nodes) + fleet-size sweep to the Amdahl limit.

Risk: this is the novel, capacity-sensitive, multi-node part (m9g 4N historically capacity-blocked).
Recommend **building + smoke-testing C before committing its full 5-rep matrix.**

## Deliverables
- `benchmarks.json` grows to a full replicated matrix (mean±stddev per cell) — the paper's data table.
- Figures: (1) throughput vs cores/instance/res; (2) $/sim-day frontier; (3) speedup vs Amdahl for
  M>N and S3-horizontal; (4) STREAM-BW vs fullchem-throughput correlation (the Graviton mechanism).
- The RDMA + S3 backends (default-off, flag-gated, upstreamable patches — no fork).
- A methods section reproducible from the calculator + committed scripts/configs.

## Recommended execution order (each gated on the prior)
**D (now, ~$5) → A (backbone) → B (on-node, already-built code) → build-C → C-smoke → C-full.**
This front-loads cheap/certain value (STREAM + stock stats), banks the already-built M>N statistics,
and defers the expensive/risky S3 build+multi-node until the paper's spine is measured. Per your
"plan + approve first," I proceed only on your go — and I'll report cost+results after each phase.

## What I need from you to start
Approve (a) the total envelope (~$1–1.7k), or a cap; (b) whether to build Phase C now or after A+B
confirm the paper's core; (c) any venue-specific rigor (e.g. a specific stats test, or CO2/energy
figures some HPC venues want). Default if you just say "go": run D+A+B, then pause before the Phase-C build.
