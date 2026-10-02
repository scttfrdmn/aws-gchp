# Decoupled Chemistry Execution for GCHP — Implementation Design

**Date:** 2026-07-10
**Status:** Design (no code). Implementation is a separately-scoped effort; the phased build path is
described here but not executed.
**Companion:** `gchp-run-results-2026-06-28.md` (the measurements this design rests on),
`gchp-advection-split-2026-06-28.md` (the FV3 kill test), `gchp-instrumentation-2026-06-28.md` (the
default-off patch discipline this design follows).
**Source verified against:** local clone `/Users/scttfrdmn/src/GCHP-instrument/GCHP`, GCHP 14.7.1.

---

## 0. TL;DR

Move GCHP's chemistry tier — the ~80%-of-cost, ~45%-of-memory, halo-free, column-local part — off the
homogeneous RDMA monolith onto an independently-scaled, fault-tolerant worker pool (spot / GPU /
serverless), **without forking GCHP**. The mechanism: add a *transport backend* to a gather→solve→
scatter seam **the GEOS-Chem community has already built** (the default-off `MPI_LOAD_BALANCE` path in
`fullchem_mod.F90`), reuse the *state contract* the community has already defined (`KppSa_Write_Samples`),
and put the pool/orchestrator entirely outside the GCHP repo. Every claim below is grounded in a
measurement from the run-results report or a verified line of source.

---

## 1. Why not fork

GCHP is three live, community-developed codebases stitched together — GCHP, MAPL, and GEOS-Chem — each
shipping frequent updates (new chemical mechanisms, met sources, bug fixes, performance work). A fork
turns every one of those upstream updates into a merge conflict; within a year the fork is stale, and
the science community — the entire beneficiary of the throughput win — can't adopt it. **A fork defeats
the purpose.**

The approach must therefore be: **upstreamable, default-off, flag-gated, numerics-identical when
disabled.** This is not aspirational — this session already demonstrated exactly that discipline on this
same tree: default-off KPP timing gated on `Input_Opt%useTimers`, and a MAPL per-rank state probe gated
on the `GCHP_INSTR_SHARD` environment variable, both delivered as clean patches (`instr/mapl.patch`,
`instr/geos-chem.patch`) that apply to stock GCHP with zero divergence. The decoupled-chemistry shim
follows the identical pattern.

---

## 2. The evidence base (why this is worth building)

From `gchp-run-results-2026-06-28.md`, all measured this cycle, not assumed:

- **The seam is real.** FV3 kill test: tracer advection runs *outside* the acoustic loop. Dynamics,
  transport, and chemistry are genuinely separable stages.
- **Chemistry is the prize tier.** C180 fullchem on m9g (768 GB): chemistry steps run **4.3 d/d vs
  18.4 d/d** for transport-only steps (**~80% of per-step cost**), and memory jumps **306 GB → 556 GB**
  when KPP allocates (**~45% of footprint**). Chemistry is **column/cell-local — no halo** — i.e.
  embarrassingly parallel.
- **The state boundary is complete.** Bitwise continuation test: stop→checkpoint→restart reproduces a
  straight run to roundoff (299/318 fields bit-identical; the 19 that differ are prognostic species at
  ≤1e-6 relative). A superstep-boundary state snapshot loses nothing.
- **The handoff medium is characterized** (same 27 GB / 120 ranks, only the medium changes):

  | Medium | Handoff (fullchem 230 MB/rank) | Note |
  |--------|-------------------------------|------|
  | DISK (shared Lustre) | **168 s** | shared-lock contention — catastrophic |
  | SHM (on-node tmpfs) | **0.33 s** | on-node only |
  | RDMA (MPI one-sided/EFA) | **2.07 s** | fast, but co-scheduled + both endpoints alive |
  | **S3 really-wide** | **~32 s** (19.5 PUT + 12.2 GET) | durable, temporally decoupled, N≠M |

  Serialization itself is ~free (0.33 s to marshal 230 MB). The lesson: the handoff must be
  memory/network, **never shared-FS disk**; and **S3-wide is the only durable, temporally-decoupled
  medium** — the one that actually unlocks spot/elastic/GPU chemistry, at ~one-compute-step latency.

---

## 3. The seam already exists — `MPI_LOAD_BALANCE`

**This is the linchpin.** We do not need to *create* a place to intercept chemistry. The community has
already restructured the per-cell KPP solve into exactly the three phases a remote solve requires,
behind the default-off CPP macro **`MPI_LOAD_BALANCE`** in
`geos-chem/GeosCore/fullchem_mod.F90` (originally to load-balance stiff/non-stiff cells across ranks via
one-sided MPI). Verified structure:

- **Flatten buffers** (declared ~lines 91–131): `C_1D(:,:)`, `RCONST_1D(:,:)`, `ICNTRL_1D`, `RCNTRL_1D`,
  `ISTATUS_1D`, `RSTATE_1D` — rank-wide, sized `NSPEC × NCELL_total` (C), `NREACT × NCELL_total`
  (RCONST). Buffers are initialized at ~548–562.
- **GATHER** (loop 1): the per-cell body runs everything *up to but not including* `Integrate`, then
  instead of solving, flattens the cell into the 1D buffers — `fullchem_mod.F90:1659–1667`:
  ```
  NCELL_local = NCELL_local + 1
  C_1D(:,NCELL_local)      = C(:)
  RCONST_1D(:,NCELL_local) = RCONST(:)
  ICNTRL_1D(:,NCELL_local) = ICNTRL(:)
  RCNTRL_1D(:,NCELL_local) = RCNTRL(:)
  IJL_to_Idx(I,J,L)        = NCELL_local      ! the flatten map
  ```
- **SOLVE** (loop 2, `~1675–1947`): a work-queue (`MPI_Win_lock_all` at 1686; `MPI_Fetch_and_op` ticket)
  pulls a cell index, loads `C/RCONST/ICNTRL/RCNTRL` from the 1D buffers, calls `Integrate`, retries on
  failure, and writes results back into `C_1D`/`RSTATE_1D`/`ISTATUS_1D`.
- **SCATTER** (loop 3, `~1954+`): re-walks the 3D grid, uses `N = IJL_to_Idx(I,J,L)` (line 1959) to pull
  each solved cell out of the 1D buffers, and does the writeback
  `State_Chm%Species(SpcID)%Conc(I,J,L) = REAL(C(N),kind=fp)` (line 2114).
- The **stock in-process baseline** (macro undefined) is the plain per-cell `CALL Integrate(0.0_dp, DT,
  ICNTRL, RCNTRL, ISTATUS, RSTATE, IERR)` at `fullchem_mod.F90:1122`, with the relaxed-tolerance retry at
  `:1257` and writeback at `:1443`.

**Takeaway:** gather (loop 1) and scatter (loop 3) are reusable *as-is*. Only the **solve phase** needs
to change — today its transport is MPI shared-memory windows; our contribution is an *alternative
transport backend* selectable at that same seam. We are extending a pattern GCHP maintainers already
accepted, not fighting `Do_FullChem`.

---

## 4. Recommended architecture — "seam backend abstraction"

Keep gather and scatter exactly as `MPI_LOAD_BALANCE` writes them. Replace only the solve phase with a
single dispatch:

```
CALL Chem_Remote_Solve( C_1D, RCONST_1D, ICNTRL_1D, RCNTRL_1D,   &  ! in
                        RSTATE_1D, ISTATUS_1D,                   &  ! out
                        DT, ATOL, RTOL, NCELL_total, backend, RC )
   backend ∈ { inproc, shm, rdma, s3 }
```

- `inproc` = a local `DO i=1,NCELL_total; CALL Integrate(...); END DO` over the flatten buffers. This is
  the **bitwise-identical fallback** and the phase-0 baseline — same integrator, same code.
- `shm` / `rdma` / `s3` ship the buffers to an external worker pool and receive solved concentrations.

The remote worker is a **pure KPP `Integrate`** — the smallest possible kernel: it reads `C` + `RCONST`
+ controls, solves, returns `C`. It needs **nothing** from GEOS-Chem (no State_Met, no photolysis, no
species database), because `RCONST` was already computed by `Update_RCONST()` (`fullchem_mod.F90:1034`)
*before* the gather and folds photolysis in. This is precisely the KPP-Standalone executable
(`geos-chem/KPP/standalone/`, built with `-DKPPSA=y`) — tiny, dependency-free, and GPU-portable.

**Mode B (rejected as primary).** A coarser intercept at the gridcomp level (`chemistry_mod.F90:427`
`CALL Do_FullChem`, shipping met+species and running the *full* chemistry step remotely) was considered
and rejected: it forces the remote worker to carry the entire GEOS-Chem chemistry machinery
(`Set_Kpp_GridBox_Values`, `Set_Sulfur_Chem_Rates`, het-chem, photolysis tables, `Update_RCONST`) — a
second GEOS-Chem, not a GPU kernel — and it reopens the het-chem contract gap (§5) because recomputing
`RCONST` remotely *does* need aerosol surface state. Its only advantage (a single het-free contract) is
already delivered by Mode A, which ships precomputed `RCONST`. **Keep Mode B named only** as a
correctness oracle (a full remote step is easy to bit-compare) and a future fallback if a mechanism ever
makes `RCONST` cell-coupled.

---

## 5. The state contract — reuse, don't invent

GEOS-Chem already serializes a complete per-cell KPP input: **`KppSa_Write_Samples`**
(`geos-chem/GeosCore/kppsa_interface_mod.F90:569–843`), which writes `initC` (species), `localRCONST`
(rate constants — **including photolysis**), TEMP / PRESS / NUMDEN / H2O / SUNCOS, `ICNTRL(20)` /
`RCNTRL(20)`, `DT`, and per-species `ATOL`, as a plain-text CSV. Its purpose is single-cell debugging,
but it **is** the column-state contract a remote solve needs — community-owned and kept current with the
mechanism.

Two representations of the same contract:
- **Text CSV** (`KppSa_Write_Samples`): the canonical, human-auditable *validation/golden* format. Reuse
  as-is for cross-checking in-proc vs remote at any phase (a single active cell is already selectable via
  `run/shared/kpp_standalone_interface.yml`, `settings%activate`, default off).
- **Binary fast path**: the `_1D` buffer layout with a versioned header — `NSPEC`, `NREACT`, `NCELL`,
  **mechanism hash**, `DT`, `ATOL`/`RTOL`, kind/endian tag. This is what moves over the wire.

Because `RCONST` is shipped, the worker **never recomputes rates**, so the one known gap in the
serialized state — heterogeneous-chemistry aerosol surface fields (aClArea, xRadi, xVol, State_Het) — is
a **non-issue** in Mode A. The **mechanism hash is mandatory**: a worker built from a different KPP
mechanism must trigger a hard abort, never a silent wrong answer.

---

## 6. Three layers: in-repo (upstreamable) vs external (this repo)

**Layer 1 — in-repo shim (ships to the community, default-off).**
- Gather/scatter reuse of the existing `_1D` buffers in `fullchem_mod.F90` + the `Chem_Remote_Solve`
  dispatch + the `inproc` and `shm` backends + contract pack/unpack.
- New file `geos-chem/GeosCore/chem_remote_mod.F90` (public `Chem_Remote_Init` / `Chem_Remote_Solve` /
  `Chem_Remote_Final`); minimal edits in `fullchem_mod.F90`; a `remote_chemistry:` config block plumbed
  through `Input_Opt`.
- The `rdma` / `s3` backends are compiled only under `-DDECOUPLED_CHEM_S3=ON`, so **stock GCHP gains
  zero new link-time dependencies** (no aws-sdk/libcurl in the default build). This is the discipline
  that keeps it mergeable upstream.

**Layer 2 — transport backends.** `shm` is fully in-repo (POSIX shm, the measured 0.33 s path). `rdma`/
`s3` are thin in-repo stubs behind an abstract `chem_remote_backend` interface, calling a small client
lib (or a sidecar over a Unix socket) that carries the heavy dependency outside the GCHP link.

**Layer 3 — orchestrator + worker service (EXTERNAL — NOT in the GCHP repo; lives in `aws-gchp`).**
- **Worker:** the KppSa standalone wrapped in a service loop (pull rank-batch → per-cell `Integrate` →
  push results). GPU variant swaps the per-cell loop for a batched Rosenbrock kernel; **contract bytes
  are identical**.
- **Orchestrator:** spot/GPU pool manager + autoscaler, the S3-wide sharding (the measured 19.5 s PUT /
  12.2 s GET wide pattern), retry / dead-letter, and the superstep barrier that releases step N+1 once
  every rank-batch for N is solved.
- This layer speaks *only* the versioned contract and never touches GCHP source. That separation is the
  whole point: GCHP stays stock; "chemistry-as-a-service" lives in the infra repo and evolves
  independently (new solver, GPU, scheduler — no GCHP recompile).

---

## 7. Default-off and numerics-identical

- **Compile gate** `DECOUPLED_CHEM` (default OFF in CMake): undefined ⇒ `fullchem_mod.F90` is
  byte-for-byte the stock in-process solve at line 1122. The stock build is provably untouched.
- **Runtime gate** `Input_Opt%DecoupledChem` (default `.FALSE.`, read from the `remote_chemistry:` block
  in `geoschem_config.yml`, parsed in `input_mod.F90` near the existing timers block): even compiled in,
  default falls through to the stock solve.
- **Fallback = the same code.** `inproc` is literally `CALL Integrate` over the flatten buffers.
- **Determinism tiers (state honestly, don't over-promise):**
  - `inproc`, `shm`, and CPU remote workers built from the *identical* mechanism with identical
    `ICNTRL/RCNTRL/ATOL/RTOL` (all in the contract) and matching compiler/FMA flags ⇒ **bitwise-identical**.
  - **GPU workers are NOT bitwise-identical** (different reduction/FMA order) — validated *statistically*
    (species-wise relative error, drift over N steps), not by bit-diff.

---

## 8. Batching and pipelining

- **Granularity is already correct:** one flatten buffer per rank per step (`C_1D` = NSPEC×NCELL,
  `RCONST_1D` = NREACT×NCELL) — the ~230 MB/rank we measured. The "can't ship 14M cell-files" problem
  never arises because **gather (loop 1) coalesces** the rank's cells into one contiguous block; we ship
  one object per rank per step.
- **Pipeline depth 1 hides the ~1-step handoff.** The ship is a single non-blocking PUT issued from the
  master thread *after* `!$OMP END PARALLEL DO` (so the OMP loops are untouched); the host proceeds into
  the next substep's work; the scatter (loop 3) becomes the join point, waiting on the GET just before
  the next chemistry gather. Double-buffer the `_1D` arrays (ping/pong) so gather(N+1) fills buffer B
  while remote-solve(N) drains buffer A. Cost: ~2×230 MB/rank — acceptable given chemistry already adds
  250 GB globally. Deeper pipelines buy nothing except absorbing spot/elastic jitter (configurable).

---

## 9. Phased build path

Each phase changes exactly **one** thing, so a regression localizes cleanly.

| Phase | Change | Backend | Gate to pass |
|-------|--------|---------|--------------|
| **0** | In-process refactor: solve loop over flatten buffers instead of 3D loop | `inproc` | **Bitwise-identical restart** vs stock (reuse the existing continuation harness). Isolates "did the gather/scatter refactor preserve numerics." |
| **1** | Separate worker process, same node, over POSIX shm | `shm` | Bitwise-identical + measured handoff < chemistry step. Proves the process boundary + contract packer, no network. |
| **2** | Remote pool on separate nodes | `s3` / `rdma` | Bitwise-identical (CPU worker, same mechanism); pipelined superstep wall ≤ synchronous in-process wall (overlap actually hides handoff); straggler distribution characterized. |
| **3** | Spot fleet and/or GPU batched solver | `s3` + pool | Cost/sim-day target; **statistical** validation (GPU); spot-reclaim recovery < step budget. |

Phase 0 needs no cluster beyond a normal fullchem run; phases 1–3 reuse the m9g/hpc7g + S3-wide
infrastructure already exercised this session.

### Phase 0 — IMPLEMENTED & VERIFIED (2026-07-11)

Built and proven. The `DECOUPLED_CHEM` in-process backend was added to `GeosCore/fullchem_mod.F90`
(widen the generic `MPI_LOAD_BALANCE` gather-init/gather/scatter regions to
`#if defined(MPI_LOAD_BALANCE) || defined(DECOUPLED_CHEM)`; a serial `DO I_CELL=1,NCELL_TOTAL` solve
loop-open under `#if defined(DECOUPLED_CHEM)`; plain `ALLOCATE`/`DEALLOCATE` branches in
`Init_/Cleanup_FullChem`) plus a `DECOUPLED_CHEM` CMake option (mutually exclusive with
`MPI_LOAD_BALANCE`). Delivered as patches — `patches/decoupled-geos-chem.patch`,
`patches/decoupled-cmake.patch` (also staged to `s3://…/instr/`); no fork. The stock build is
byte-for-byte unchanged when the flag is off.

**Verification (the strong, three-way form):** on cluster `bench-decoupled` (hpc7g), three binaries were
built — `inline` (both macros OFF = stock per-cell solve), `mpi` (default `MPI_LOAD_BALANCE`), and
`decoupled` — and each ran **C24 fullchem, MERRA-2, 1 node, 2 h, o-server OFF** from an identical run
dir / restart. Result:

> **All three `gcchem_internal_checkpoint` files are MD5-identical** (`3e755be9…`). `h5diff -c` exits 0
> for `decoupled`-vs-`inline` and `decoupled`-vs-`mpi`; all 405 datasets show 0 differences.

This **exceeds** the gate: not merely bitwise-identical-to-roundoff, but the *exact same bytes* as both
the original per-cell algorithm and the community MPI path. The gather→solve→scatter refactor is
numerically transparent. Phase 0 is the foundation confirmed; Phases 1–3 are transport swaps behind the
same seam. **Cost:** ~2 h build (3 variants) + 3 short C24 runs on one hpc7g cluster.

---

## 10. Risks (design-changing)

1. **Straggler / MPI coupling (TOP risk).** The superstep barrier means the slowest rank's remote batch
   gates *all* ranks' dynamics(N+1). Spot reclaim or S3 tail latency (the 19.5 s PUT is a mean; p99 wide
   could be worse) can stall the whole model. **Mitigation, designed-in:** a per-batch deadline with
   **fallback to the local `inproc` solve on timeout** — the flatten buffers are still resident on the
   rank, so the in-process solver (always compiled in) is a zero-cost safety valve that makes the
   external service non-fatal to the MPI job. Plus pipeline depth to absorb jitter.
2. **KPP double-failure handling is not fully ported even in the existing `MPI_LOAD_BALANCE` scaffold.**
   Retry is naturally worker-local (the worker holds `RCONST` + `C_before` + controls, so it does the
   relaxed-tolerance retry itself — no round-trip). But the `Failed2x` hard-stop and the negative-
   concentration reflag path are not fully expressed in the batched solve/scatter even in the community
   code; the design must define what the worker returns on double-failure (IERR<0 in `ISTATUS_1D`) and
   have the scatter phase honor it. This is an inherited gap, not a new one.
3. **Het-chem contract gap (LOW).** Only bites if a worker recomputes `RCONST`. Mode A ships it, so it
   doesn't. If a future worker recomputes rates to shrink payload (`RCONST` is NREACT×NCELL, often larger
   than C), the aerosol surface fields must be added under a *new* contract version.
4. **Determinism (MEDIUM).** CPU = bitwise; GPU = statistical. Declare the tier per backend; validate
   accordingly. Do not promise bitwise for GPU.
5. **Per-cell load imbalance (MEDIUM).** Per-cell KPP cost varies wildly (sunrise/sunset, autoreduce) —
   which is *why* the stock code uses `SCHEDULE(DYNAMIC,24)` and the `MPI_Fetch_and_op` work-queue. The
   remote pool must replicate this with dynamic cell-level work-stealing, not static rank→worker binding,
   or one hot batch stalls the barrier.
6. **Contract / version skew (MEDIUM).** A worker built from a different mechanism = silent wrong
   chemistry. The mechanism hash in the header (hard-abort on mismatch) is mandatory.

---

## 11. What this buys (the prize, tied to measured numbers)

- **Memory stops being the cost driver.** Chemistry's ~250 GB working set (the 306→556 GB jump) — which
  needs *no fabric* — moves onto cheap memory-optimized / spot nodes, off the 768 GB EFA monolith.
- **Independent scaling.** Chemistry is column-parallel with no halo → scale it 10× without touching the
  dynamics decomposition (today, adding ranks over-decomposes the cube and *raises* halo cost).
- **Spot + fault tolerance for the 80% tier.** A stateless map over column batches with a proven-complete
  boundary → a dead worker just re-runs its batch (today one rank dying kills the job).
- **GPU / accelerator chemistry.** KPP can emit accelerator code; behind the contract boundary, chemistry
  runs on GPUs while dynamics stays on CPU.
- **Pipelined latency hiding.** The 4:1 chemistry tax becomes *overlappable* with the next step's
  dynamics rather than serial.

**Bottom line:** every link in the chain is measured, not assumed — the seam is real, the state boundary
is complete, chemistry is the dominant separable tier, the handoff is cheap over the right medium, and
**the intercept seam already exists in the community codebase**. Implementation is engineering, not a
feasibility question — and it never requires forking GCHP.
