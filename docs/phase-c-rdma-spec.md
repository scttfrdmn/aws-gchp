# Phase C1 — RDMA transport backend: build-ready spec (deferred, not yet coded)

**Why deferred:** the kpp_worker is currently a NON-MPI standalone executable (talks to GCHP only via
POSIX shm — deliberate on-node decoupling). RDMA requires the worker to share an MPI communicator with
the GCHP ranks, which is ~1-2 days of code AND untestable without a co-scheduled multi-node EFA cluster
(the atomic-multi-node/placement-group launch that was capacity-blocked all campaign — the exact
constraint S3/C2 exists to avoid). So C1 is specified here and built after C2 proves the off-node
mechanism (or when a multi-node harness is reliably available). This spec is complete enough to build from.

## Launch model — MPMD single mpirun
Replace the two-step (mpirun gchp + srun --overlap workers) with ONE MPMD launch so ranks + workers
share `MPI_COMM_WORLD`:
```
mpirun -n N ./gchp : -n M ./kpp_worker --service-mpi
```
- First N ranks = GCHP transport (unchanged). Next M = chem workers. `MPI_COMM_WORLD` rank r: if r<N it's
  GCHP (which never calls the worker path); if r>=N it's worker index (r-N).
- Mapping worker→owning-rank + subrank: reuse the static slice math. With K workers/rank, worker global
  index w (0..M-1) serves rank (w / K), subrank (w % K) — identical to the shm SLURM_PROCID mapping,
  just over MPI rank instead of SLURM_PROCID. Split a `worker_comm` via `MPI_Comm_split(color=is_worker)`.
- GCHP must tolerate extra COMM_WORLD ranks it doesn't use. Safer alt: `MPI_Comm_spawn` M workers from
  the GCHP ranks after init (dynamic), avoiding changes to GCHP's own communicator setup. Spawn is the
  recommended path (no GCHP-internal comm assumptions); MPMD is the fallback if spawn is flaky on EFA.

## Data movement — one-sided MPI windows (RDMA over EFA)
Per (rank, worker) pair, two windows (or one window with in/out regions):
- **IN window** (rank-owned, worker reads): for the worker's slice [lo,hi), the flat buffers
  C(NSPEC,·) RCONST(NREACT,·) ICNTRL(20,·) RCNTRL(20,·). Rank `MPI_Win_lock`+writes its slice or just
  exposes its buffers; worker `MPI_Get`s them (13 GB/s measured on EFA → 2.1s/27GB).
- **OUT window** (worker-owned or rank-owned): solved C(NSPEC,·) RSTATE(20,·) ISTATUS(20,·). Worker
  `MPI_Put`s results back to the rank's buffer at [lo,hi).
- Const arrays (ATOL/RTOL/MW) + ctl scalars: broadcast once (small); or a small always-exposed window.

## Handshake — counting barrier over RDMA flags (replaces POSIX sems)
Cross-node has no named sems. Replace with window flag words + `MPI_Win_flush`:
- Rank publishes slice descriptors + dt/ar/ss + a per-worker `ready_gen` counter (monotonic superstep #)
  into a control window, `MPI_Win_flush` (ensures visibility), i.e. the "post K ready" equivalent.
- Each worker polls its `ready_gen` (via `MPI_Get`/passive-target or `MPI_Win_flush_local` on a shared
  window) until it advances, MPI_Gets inputs, solves (Solve_Batch [lo,hi] — UNCHANGED numerics), MPI_Puts
  outputs, then writes its own `done_gen`. Rank polls the K `done_gen` words until all == current gen =
  the counting barrier. Bounded by a wall deadline (same fallback-to-inprocess safety valve).
- Memory ordering: `MPI_Win_flush` after the data Put, THEN the flag Put, so the rank never sees done
  before the results land (the RDMA analog of the sem being a full barrier).

## What stays identical (byte-identity preserved by construction)
- Slice partition (static contiguous [lo,hi), remainder to front slices) — same code path.
- `Solve_Batch(lo,hi,...)` numerics, retry, envelope, per-slice Failed2x — untouched.
- The buffer *contents* shipped are the same bytes shm exposed; only the medium changes.
- GATE C1 = C24 checkpoint MD5 == Phase-4 baseline `dd532a95539327633dddc98ba0a76897`.

## Backend hookup
`Chem_Remote_Transport==GCR_TRANSPORT_RDMA` selects: Init exposes windows instead of shm segs; Solve
does publish-flush-pollK instead of post-K/waitK; worker Attach joins worker_comm + exposes/maps windows.
The `publish_slice/release/collect` op-seam in the design doc is where rdma vs shm diverge; Solve_Batch
is below the seam and shared.

## Test/validate (when a multi-node cluster exists)
2 nodes: N=24 GCHP ranks on node A, M=24 workers on node B (K=1) → C24 gate MD5. Then N ranks node A,
M>N workers node B (K=2) → speedup + byte-identity. Chase-AZ or ODCR for the co-scheduled 2-node m9g.
Measured handoff budget (2.1s/27GB) predicts speedup ≈ on-node minus ~2s/superstep overhead.
