# Phase C: off-node chemistry transport backends (RDMA + S3)

## The invariant that makes this tractable
The **numerical contract is already proven** (Phase 1a/1b/4): given a cell's flat KPP input buffers
(C, RCONST, ICNTRL, RCNTRL) + shipped constants (ATOL/RTOL/MW/ss/ar/dt), `Solve_Batch` produces
bit-identical C/RSTATE/ISTATUS. That is transport-agnostic. Phase C only changes **how the bytes get
to/from the worker** — not the solve, not the slice partition, not the counting-barrier semantics.

## What changes off-node
On-node shm was **zero-copy**: worker mmaps the same buffers, solves in place. Off-node the worker is on
a different host, so the transport must **move bytes both ways**:

```
rank slice k:  serialize [C,RCONST,ICNTRL,RCNTRL] for cells [lo_k,hi_k)  -->  SHIP
remote worker: solve slice  -->  SHIP BACK [C,RSTATE,ISTATUS] for those cells
rank:          deserialize into its buffers at [lo_k,hi_k)
```

Payload per cell = (NSPEC + NREACT + 20 + 20) doubles in, (NSPEC + 20 + 20) out. At C180 ~230 MB/rank
total (measured). This is the same buffer layout the shm path already packs — so serialization reuses
the existing flat-buffer strides; no new packing logic.

## Backend abstraction (runtime-selected: GCHP_CHEM_TRANSPORT=shm|rdma|s3)
A thin dispatch over 4 ops the mechanism already calls. shm keeps zero-copy (ops are no-ops after
attach); rdma/s3 implement real movement.

| op | shm (built) | rdma (Phase C1) | s3 (Phase C2) |
|---|---|---|---|
| `publish_slice(k, lo, hi)` | write slice table (no data move) | one-sided PUT of in-buffers to worker k's window | PUT own-key `<job>/<rank>/<step>/in` |
| `release(k)` | sem_post(ready) | RDMA flag write / small am | (implicit: key existence) |
| `collect(k)` | sem_timedwait(done) | poll RDMA done-flag | poll/GET `<...>/out` (bounded) |
| `worker recv/send` | in-place (shm) | RDMA read in / write out | GET in-key / PUT out-key |

## C1 — RDMA (co-scheduled, fastest; correctness proof)
- Transport = EFA one-sided (MPI-3 `MPI_Put`/`MPI_Get` windows, or libfabric). Workers are extra MPI
  ranks in the SAME job on separate nodes (co-scheduled). Reuses the OpenMPI+EFA stack already built.
- Handshake stays the counting-barrier, but over RDMA flags instead of POSIX sems (cross-node sems
  don't exist). Rank exposes an MPI window per worker; worker RDMA-reads inputs, solves, RDMA-writes
  outputs + a done flag; rank polls the flags (its own counting barrier).
- Measured budget: 2.1 s / 27 GB (13 GB/s) ≪ chem compute → speedup preserved.
- GATE C1: C24 checkpoint MD5 == the Phase-4 baseline `dd532a95…` (byte-identity across the wire).

## C2 — S3-wide (elastic; the paper headline)
**The point of S3 is NOT the data movement — it is eliminating co-scheduling.** RDMA (C1) requires
every node in ONE EFA job / placement group, launched atomically — which is *exactly* the capacity
constraint that blocked 4N all campaign (192-core parts under a PG). S3 removes that entirely: the
transport cluster and the chemistry fleet are **separately launched, independent lifecycles** — they
can be different instance types, spot, different AZs, different architectures, even GPUs; no EFA, no
placement group, no atomic-cohort launch, no "all nodes up together." You launch transport when you
have capacity for it, and grow/shrink the chem fleet independently as capacity appears. That
operational decoupling — not the ~32 s handoff — is the headline.

- Transport = S3 own-key PUT/GET (the measured ~32 s/27 GB round-trip). Rank PUTs each slice's inputs
  to `s3://<bucket>/chemq/<jobid>/<rank>/<step>/in.bin`; an **elastic worker pool** (separate cluster /
  autoscaling group / spot fleet, launched on its OWN schedule) long-polls for `in` keys, GETs, solves,
  PUTs `out.bin`; rank polls for `out`. Producers (N ranks) and consumers (M workers) are **fully
  decoupled** — different counts, different hardware, needn't be co-alive or co-launched. Spot-tolerant:
  a killed worker's claim lease expires and the slice is re-claimed by another.
- This is the operational answer to the capacity walls the campaign hit repeatedly (m9g AZ-specific
  scarcity, 4N placement-group blocks): chemistry no longer has to fit in the same atomically-scheduled
  allocation as transport.
- Orchestrator (external, in aws-gchp): the elastic chem pool + a claim protocol (S3 conditional
  writes or a tiny SQS/DynamoDB lease) so two workers never solve the same slice.
- GATE C2: same byte-identity MD5, AND demonstrate N≠M (e.g. 48 ranks, elastic 12–192 workers) +
  survive a worker kill mid-run (spot-eviction sim) with the run still completing byte-identical.

## Amdahl-limit demo (both)
Sweep worker-fleet size until throughput plateaus at the chem-fraction ceiling (measured 73.5% →
3.78× at C90). On-node capped at 192 cores (2.23×); off-node should climb past it toward 3.78× as the
fleet grows beyond one node's cores — that plateau IS the paper's money figure.

## Build order
C1 (RDMA backend + cross-node counting-barrier + GATE C1) → C2 (S3 backend + elastic orchestrator +
GATE C2 + kill-test) → fleet-size sweep to Amdahl (5-rep) on both. Default-off, flag-gated
(`GCHP_CHEM_TRANSPORT`), upstreamable. K=1 shm path unchanged (regression-protected by the existing gate).
