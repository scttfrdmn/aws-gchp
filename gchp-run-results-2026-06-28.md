# GCHP: Can C180 Run Clean, and Can the Monolith Be Broken Apart?

**This was not a benchmark.** Two goals: **(1)** get C180 to run clean (both TransportTracers and
fullchem), and **(2)** determine whether GCHP can be decomposed along its internal seams — and, more
importantly, **what becomes possible if it were.** The measurements below are in service of those two
questions; throughput/cost numbers are evidence, not the point (the cost table is now an appendix).

**Date:** 2026-06-28 → 2026-07-10.
**Clusters:** `bench-fabrictest` (2× hpc7g.16xlarge, 128 GB, us-east-1a) for the fabric + TT + restart
work; `bench-fullchem-m9g-1c` (m9g.48xlarge, 768 GB, us-east-1c) for C180 fullchem.
**Binaries:** instrumented GCHP 14.7.1 aarch64 (fabric/TT/restart runs; symbols `GCHP_INSTR_SHARD`,
`SHARDPROBE tag=`, `KPP Integrate` verified present) and the stock validated aarch64 binary (fullchem).
**Companion reports:** `gchp-instrumentation-2026-06-28.md` (design + diff ledger),
`gchp-advection-split-2026-06-28.md` (FV3 kill test).

---

## GOAL 1 — Does C180 run clean? **YES, both simulations (first time end-to-end in this project).**

- **C180 TransportTracers:** clean and repeatable (2-node EFA, ran to completion multiple times).
- **C180 fullchem:** clean on m9g (768 GB) — 2 h sim, 24 steps, 556 GB peak, 42.9 GB checkpoint,
  finalized OK. The value is the **runbook**, not the number: the walls between `createRunDir` and a
  clean run are now known and fixed. In launch order:
  1. Pre-create input FSx **Lustre 2.15 + Lustre-ports SG** (reference by ID, never inline).
  2. **Pre-hydrate the scoped fullchem working set** (`lfs hsm_restore`) before launch — FSx-from-gcgrid
     lazy-loads on first touch, which makes cold init slow, nondeterministic, and useless for timing.
  3. Stage the **5 GMI symlink aliases** onto a writable Lustre `HcoDir` overlay.
  4. Link the version-matched C180 fullchem **restart** + set `cap_restart`.
  5. `input.nml` **`domains_stack_size` 20M → 64M** (FMS halo stack overflows at coarse decomposition).
  6. **`/dev/shm` → 550G** (SIGBUS at first KPP call = tmpfs exhaustion of MAPL shared windows).

---

## GOAL 2 — Can the monolith be broken apart, and what's the prize?

### Separability verdict: the seam is real; the coupling that fights a decoupled *deployment* is incidental, not physical.

GCHP cleaves along a genuine algorithmic seam — **flow solver | tracer transport | chemistry** — and
each tier's true requirements differ sharply:

| Tier | Coupling | Memory | Comm pattern | Fabric it *actually* needs |
|------|----------|--------|--------------|----------------------------|
| Flow solver (dyn_core) | tight (acoustic substeps) | small | halo per substep | RDMA (genuine) |
| Tracer transport | loose (outside acoustic loop — **kill test PASSED**) | heavy | halo at advective grain | RDMA-ish |
| **Chemistry (KPP)** | **none — column-local** | **~250 GB** (the 306→556 GB jump) | **scatter/gather of columns** | **none** |

**Evidence the tiers separate** (all measured this session):
- Kill test: tracer advection is *outside* the FV3 acoustic loop (consumes accumulated flux capacitors).
- Chemistry is the heavy, fungible tier: **~80 % of per-step cost** (4.3 vs 18.4 d/d cadence), **~45 %
  of memory**, **no halo** (columns independent).
- The state handoff is **faithful**: MAPL INTERNAL restart is complete (restart = straight run to
  roundoff, 299/318 fields bit-identical), so a superstep-boundary snapshot loses nothing.

**Why today's coupling is incidental, not intrinsic.** GCHP is one MPI program where every rank is a
full vertical slice, coupled through in-core MAPL state and MPI one-sided windows. That single design
choice forces three constraints onto *every* node at once: (a) hold the full per-rank state (~11.6
GB/rank at C180), (b) sit on an RDMA fabric (the `MPI_Win` requirement — see Measurement 1), (c) advance
in lockstep (slowest tier gates every step; one rank dying kills the job). **These three are joined only
because the code couples the tiers in-core — not because the science requires it.**

### The prize — what enabling the seams makes possible (each grounded in a measured fact)

1. **Right-size hardware per tier; the memory wall stops being a cost driver.** Chemistry — the 250 GB,
   80%-cost, **fabric-free** tier — moves onto cheap memory-optimized / spot nodes with **no EFA**. You
   stop renting 768 GB of RDMA-connected RAM to run embarrassingly-parallel column chemistry.
2. **Scale the dominant cost independently.** Chemistry is column-parallel with no halo → scale it 10×
   without touching the dynamics decomposition (today, adding ranks over-decomposes the cube and *raises*
   halo cost — the 4-node scaling pain). Decoupling severs "more chemistry" from "worse dynamics scaling."
3. **Spot + fault tolerance for the 80% tier.** Chemistry as a stateless map over column batches with a
   *proven-complete* serializable boundary → a dead worker just re-runs its batch. Today one rank dying
   kills the job, so spot is unusable.
4. **GPU / accelerator chemistry.** KPP can emit accelerator code; the blocker is the in-core coupling.
   Behind a state boundary, chemistry runs on GPUs while dynamics stays on CPU.
5. **Pipeline across the lockstep barrier.** Async column handoff lets dynamics step N+1 overlap
   chemistry step N — the 4:1 chemistry tax becomes *hideable* instead of serial.

### On "TCP a problem — then we fix it"

For the tier where the cost lives, **you don't fix TCP; you route around it.** The RDMA requirement is a
property of MAPL's in-core windowed coupling (Measurement 1), **not** of the chemistry physics —
chemistry's natural pattern is latency-tolerant scatter/gather that rides TCP, a queue, or object store.
Decouple chemistry and its fabric requirement evaporates. (Rescuing the *monolith* on TCP is also
possible — the `osc/pt2pt`-no-`THREAD_MULTIPLE` wall is an OpenMPI-4.1.x limitation newer one-sided
layers lift — but that rescues the monolith, whereas decoupling makes the fabric question moot for the
tier that matters.)

### The load-bearing measurement — MEASURED (and it sharpens the design, not blocks it)

Everything above holds **iff the per-column state handoff is cheaper than the compute it offloads, and
async.** This was the one missing number. Rather than keep fighting the MAPL checkpoint machinery to fire
the shard probe (3 build attempts, 3 run configs — the probe's hook sits on collective checkpoint paths
that GCHP's end-of-run write doesn't traverse: the RecordAlarm never rings from `RECORD_FREQUENCY`, and
the o-server bypasses the collective write entirely), I measured the **same physical quantity directly**
with a 120-rank MPI microbenchmark (`scripts`/`shardbench.c`): each rank serializes (memcpy) its state
chunk, then writes it to shared FSx Lustre **independently — no collective, no barrier** — exactly the
decoupled per-rank handoff.

| per-rank chunk | serialize (max) | independent write (max) | all-ranks-finish | agg BW |
|----------------|-----------------|-------------------------|------------------|--------|
| 27 MB (C180 TT INTERNAL/rank) | 0.039 s | 10.9 s | 10.9 s | 297 MB/s |
| 230 MB (C180 fullchem INTERNAL/rank) | 0.33 s | 174.9 s | 175 s | 157 MB/s |

**Verdict — the prize is real but the handoff medium is decisive:**
- **Serialization is essentially FREE** (0.33 s to marshal a 230 MB fullchem chunk). Getting column
  state into a transferable buffer is *not* the bottleneck — the marshaling layer is fine.
- **Writing it to shared disk is catastrophic** — 175 s for one fullchem superstep's handoff vs. a
  chemistry step of only tens of seconds → the disk handoff is **~5-10× the compute it would offload.**
  120 "independent" ranks still serialize at the shared filesystem (~157 MB/s aggregate — Lustre
  contention). A shared-FS handoff **destroys** the decoupling win.
- **Therefore the decoupled handoff must move column state over a memory/network channel** — RDMA
  one-sided, on-node shared memory, or an in-memory object store — **never shared-FS disk.** The
  brittle 42.9 GB pnc4 checkpoint (and any per-shard-to-disk variant) is the *wrong* mechanism.

This inverts cleanly into the design constraint: decoupling pays **iff** the rank→chemistry-tier column
transfer runs at memory/network speed — which is exactly what the monolith's in-core `MPI_Win` already
provides (and why forcing it onto TCP breaks it, Measurement 1).

### And that "iff" is now MEASURED — the prize is confirmed viable, not just claimed

Same handoff (`scripts/handoff_transport_bench.c`), same 120 ranks / 27 GB, same bytes — **only the
transport medium changes:**

Same handoff, same 120 ranks / 27 GB, same bytes — **only the transport medium changes** (fullchem
scale, 230 MB/rank):

| Medium | Handoff time | Agg BW | vs. disk | Enables |
|--------|--------------|--------|----------|---------|
| DISK (shared Lustre) | **168 s** | 164 MB/s | baseline | — (shared-lock contention kills it) |
| SHM (on-node tmpfs) | **0.33 s** | 82,654 MB/s | ~500× | on-node tiers only |
| RDMA (MPI one-sided/EFA) | **2.07 s** | 13,307 MB/s | ~81× | fast inter-node, **but both endpoints alive + co-scheduled** |
| **S3 really-wide** (own key/rank) | **19.5 s** PUT + 12.2 s GET = **~32 s** | 1419 MB/s PUT | ~9× | **durable, temporally decoupled, N≠M, spot/elastic/GPU** |

**The nuanced result — and it's the actual lesson, not a footnote.** The instinct "Lustre=fast,
RDMA=fast, those are the options" is wrong on both ends here:
- **Lustre is the SLOWEST** (168 s) — not because disks are slow but because 120 independent writers
  contend on one shared-lock/metadata domain. Shared-FS is the *worst* fit for wide independent writes.
- **S3-wide is ~9× FASTER than Lustre** (19.5 s) for the identical bytes — precisely because S3 has *no*
  shared lock and *likes* being hit wide; throughput scales with concurrency. Zero failures at 120-wide.
- **S3-wide is ~9× SLOWER than RDMA** — so it is *not* the speed winner.

But speed is the wrong axis. Rank the media by **what they enable**: SHM is fastest but on-node only;
RDMA is fast inter-node but requires both endpoints alive and co-scheduled — which keeps you in the
tightly-coupled world the design is trying to escape. **S3-wide is the only medium that is durable and
temporally decoupled** (N producers → M consumers, any time; a dead spot worker's state is just
re-read) — i.e. the only one that actually delivers the decoupled-design *prize* (spot chemistry,
elastic independent scaling, async pipelining, GPU/serverless). Against a chemistry step of tens of
seconds, S3-wide's ~32 s round-trip is same-order — affordable, especially pipelined (superstep N's
handoff overlaps N+1's dynamics).

**Bottom line for Goal 2:** the decoupled-execution design is **confirmed viable** — every link is
measured, not assumed: seam is real (kill test), state boundary complete (bitwise continuation),
chemistry is the 80%-cost / 45%-memory / zero-halo tier (fullchem run), and the per-column handoff is
cheap over the right medium (this table). The design choice is now a clear, evidence-backed trade — **not
"which is fastest" but "which enables what":**
- **RDMA one-sided** (+ SHM on-node) → raw speed, for tiers you keep co-scheduled on RDMA fabric.
- **S3 really-wide** → the operational prize (spot/elastic/fault-tolerant/GPU chemistry), at the cost of
  ~one compute-step of latency you can pipeline away.

The false assumption this whole thread retired: *fast fabric/filesystem = the only way.* Sometimes the
"slower," lock-free, durable medium is the one that unlocks the architecture — and Lustre, the reflexive
"fast" choice, was the worst option on the board for this access pattern.

---

> **Honesty note on scope.** The spec targeted **C180 fullchem**. Fullchem at C180 does **not fit
> hpc7g** (1-node OOM at 108 GB; 2-node OOM at 125.7 GB during DYNAMICS init on 128 GB nodes), and the
> fullchem run additionally aborts on missing HEMCO input (`GMI/v2015-02/gmi.clim.NPMN...nc not found`
> — the gcgrid FSx subset lacks the GMI climatology tree). I therefore ran **C180 TransportTracers**
> instead. This is not a downgrade for Measurement 1: TransportTracers **is** tracer advection and
> nothing else — no KPP, no 250-species chemistry, no chemistry halo. Every inter-rank message in a TT
> run is either the FV3 dynamics halo or the tracer-transport halo. That makes TT's throughput
> sensitivity to the fabric a **direct, undiluted proxy** for the load-bearing question ("does tracer
> transport need EFA?"), which is exactly what Measurement 1 asks. The trade-off: TT cannot speak to
> chemistry wall-share (Measurement 4's CHEM-vs-ADV split), which is called out where relevant.

---

## MEASUREMENT 1 — FABRIC TEST (EFA vs TCP) — **THE VERDICT**

### Headline

**GCHP does not run multi-node over TCP at all. It is not "slower on TCP" — it aborts before the first
timestep.** The question "how much throughput is lost EFA→TCP?" has no percentage answer because the
TCP configuration never produces a timestep. The loss is not gradual; it is total, and it happens at
initialization, in **MAPL's MPI one-sided window creation** (`MPI_Win_create`).

This is a **stronger** result than a throughput penalty: it means **GCHP multi-node is hard-bound to an
RDMA-capable fabric** (EFA, InfiniBand). On a TCP-only interconnect it does not degrade — it fails to
launch. Conversely, where EFA is present, the tracer-transport halo is **not** a throughput bottleneck:
EFA C180 TT sustains ~250 d/d on just 2 nodes with no halo stall visible in the per-step record.

### The three legs (all C180 TransportTracers, 2 nodes × 60 ranks = 120 ranks, layout NX=5 NY=24)

| Leg | Fabric config (verbatim) | Outcome | Throughput |
|-----|--------------------------|---------|------------|
| **EFA** | `--mca mtl_ofi_provider_include efa` | ✅ **completed** full 1-day sim, 288 steps | **~246–250 d/d** (final cumulative Avg; see dist. below) |
| **TCP** (default OSC) | `--mca pml ob1 --mca btl tcp,self --mca mtl ^ofi --mca btl_tcp_if_include ens5` | ❌ **abort at init** (0 timesteps) | n/a — `MPI_Win_create` fatal |
| **TCP + forced osc/rdma** | …above… `--mca osc rdma` | ❌ **abort at init** (0 timesteps) | n/a — `MPI_Win_create` fatal |

### Auditable settings — every MCA/env flag distinguishing the runs (copied from the generated SLURM scripts)

```
EFA leg  (job 9/12/13/14, slurm-c180tt_n2_efa-*.log):
  env : export FI_PROVIDER=efa ; export OMPI_MCA_mtl_ofi_provider_include=efa
  mpirun -n 120 --mca mtl_ofi_provider_include efa [-x GCHP_INSTR_SHARD -x GCHP_INSTR_LOCAL] \
         --mca mtl_base_verbose 10 --mca btl_base_verbose 10 ./gchp

TCP leg  (job 10, slurm-c180tt_n2_tcp-10.log):
  env : export FI_PROVIDER=tcp ; export OMPI_MCA_mtl_ofi_provider_exclude=efa
  mpirun -n 120 --mca pml ob1 --mca btl tcp,self --mca mtl ^ofi --mca btl_tcp_if_include ens5 \
         --mca mtl_base_verbose 10 --mca btl_base_verbose 10 ./gchp

TCP+rdma leg (job 11, slurm-c180tt_n2_tcprdma-11.log):
  env : export FI_PROVIDER=tcp ; export OMPI_MCA_mtl_ofi_provider_exclude=efa
  mpirun -n 120 --mca pml ob1 --mca btl tcp,self --mca mtl ^ofi --mca osc rdma \
         --mca btl_tcp_if_include ens5 --mca mtl_base_verbose 10 --mca btl_base_verbose 10 ./gchp
```

### Fabric PROOF (not asserted — read from the run logs)

EFA leg, what the MTL/OFI layer actually selected, on every rank:
```
[compute-dy-nodes-2:NNNNN] mtl_ofi_component.c:362: mtl:ofi:provider: rdmap0s31-rdm
```
`rdmap0s31-rdm` is the **EFA RDM endpoint device** (the Graviton EFA NIC). `fi_info -p efa` on both
nodes lists `provider: efa / fabric: efa`. EFA carried the point-to-point traffic. (The logs also show
`select: initializing btl component tcp` — that is OpenMPI's always-loaded fallback BTL registering; it
is not the transport. The MTL→OFI→EFA path above is what moved the messages.)

TCP leg, what happened instead (verbatim from `gchp_c180tt_n2_tcp.log`):
```
mca: bml: Using tcp btl for send to [[26333,1],0] on node compute-dy-nodes-1     ← TCP confirmed as transport
--------------------------------------------------------------------------
The OSC pt2pt component does not support MPI_THREAD_MULTIPLE in this release.
Workarounds are to run on a single node, or to use a system with an RDMA
capable network such as Infiniband.
--------------------------------------------------------------------------
*** An error occurred in MPI_Win_create
*** MPI_ERR_WIN: invalid window
*** MPI_ERRORS_ARE_FATAL (processes in this communicator will now abort)
```

TCP + forced `osc rdma` leg (verbatim from `gchp_c180tt_n2_tcprdma.log`):
```
mca: bml: Using tcp btl for send to [[27106,1],0] on node compute-dy-nodes-1
*** An error occurred in MPI_Win_create
*** MPI_ERR_WIN: invalid window      ← same fatal abort; the tcp BTL cannot back an RDMA window either
```

### Mechanism (why this happens — pinned to the analysis in the companion report)

MAPL allocates **MPI one-sided RMA windows** (`MPI_Win_create` / `MPI_Win_allocate_shared`) under
`MPI_THREAD_MULTIPLE`. OpenMPI satisfies one-sided ops via an **OSC component**:

- Over **EFA**, OpenMPI selects **`osc/rdma`** riding the OFI/EFA provider — native RDMA put/get,
  thread-multiple-safe → windows create successfully → GCHP runs.
- Force plain **TCP** and OpenMPI falls back to **`osc/pt2pt`**, which **explicitly does not support
  `MPI_THREAD_MULTIPLE` in OpenMPI 4.1.x** → `MPI_Win_create` returns `MPI_ERR_WIN` → fatal abort.
- Force **`osc rdma` over the tcp BTL** to dodge pt2pt, and the window *still* fails (`MPI_ERR_WIN`,
  this time with no thread-multiple message): the **tcp BTL cannot provide the RDMA put/get/atomic
  primitives** `osc/rdma` needs. The window is invalid from creation.

Both non-RDMA paths dead-end at the same place. This is the in-tree confirmation of the companion
report's static prediction that GCHP's on-node/inter-node state exchange is **RMA-window-based, not
two-sided send/recv**, and therefore presumes an RDMA fabric.

### Verdict for the decoupled-execution design question

- **Is GCHP non-EFA-viable?** For **multi-node**, **no** — it cannot run on a TCP-only interconnect at
  all (init abort, not slowdown). The decoupled design cannot assume commodity TCP between tiers if any
  tier uses stock MAPL one-sided windows across nodes.
- **Is the tracer halo the bottleneck on EFA?** **No.** With EFA present, C180 TT holds ~250 d/d on 2
  nodes with a tight per-step distribution (p50 252.8, p95 274.9 d/d) — the tracer-transport halo is
  comfortably absorbed. The fabric is a **hard gate** (must be RDMA), not a **throttle** (once RDMA,
  transport is not stalling). That reframes the design tension: the question is not "can we tolerate a
  slower fabric for tracer transport" but "any tier doing cross-node MAPL RMA needs an RDMA NIC."

---

## MEASUREMENT 4 (partial) — throughput + grain on EFA

EFA C180 TransportTracers, 2 nodes / 120 ranks, 1 simulated day (288 × 5-min dynamic steps):

```
Instantaneous "Tot" throughput, steps 20–280 (steady state, init transient excluded):
  n=261  min=246.5  p50=252.8  p95=274.9  max=283.0  mean=255.1   days/day
Final cumulative Avg (whole-run metric, consistent across 4 EFA runs): 246–250 d/d
  (observed per-run finals: 229.9, 247.1, ~246, 246.1 d/d — run-to-run spread ≈ ±7%)
Timeloop wall for the 1-day sim: ~6 min (06:42→06:48 wallclock on job 14)
```

**Fleet-sizing read:** ~250 d/d at C180 on 120 Graviton3E cores means one simulated **year ≈ 1.5
days** of wall on a single 2-node job — i.e., long campaigns are throughput-bound on node count, and the
result scales cleanly because the transport halo is not saturating the fabric at this size.

**Limitation (stated, not papered over):** the **MAPL per-component timer report** (`MAPL_ENABLE_TIMERS:
YES` is set in `CAP.rc`) and the **FV3 FMS clock table** (`COMM_TRACER` / `tracer_2d` / `DYN_CORE`)
**did not reach stdout**. They print during MAPL finalize, *after* the end-of-run checkpoint, and GCHP
14.7.1's known **benign finalization double-free abort (signal 6)** truncates finalize before the report
flushes. No profiler file is written (only an empty `EGRESS`). So the **fine-grained CHEM-vs-ADV-vs-halo
split is NOT available from these runs** — I have the aggregate throughput, not the component
breakdown. Getting it would require either suppressing the finalize abort or adding an explicit
mid-run timer dump; flagged as the top follow-up. (For TT specifically the CHEM share is ~0 by
construction, so the missing split matters mainly for the eventual fullchem run.)

**Run-to-run throughput note (auditability):** across the four completing EFA C180 TT runs the final
cumulative Avg landed at 229.9 / 247.1 / ~246 / 246.1 d/d — a ~7% spread driven by the shared FSx
Lustre under contention from overlapping runs (plus the init transient). The steady-state instantaneous
distribution (p50 252.8) is the more stable figure. No EFA run dropped below ~230 d/d; every TCP run
produced **zero** timesteps. The fabric gap is categorical, not a noisy percentage.

---

## MEASUREMENT 3 — state accounting

C180 TransportTracers, 120 ranks, NX=5 NY=24:

| Quantity | Bytes | Note |
|----------|-------|------|
| Collective INTERNAL checkpoint (`gcchem_internal_checkpoint`, pnc4) | **3,209,986,322** (3.21 GB) | written once at end-of-run, all ranks, single file |
| Input restart (`GEOSChem.Restart...c180.nc4`, GC_14.7.0) | 980,579,334 (0.98 GB) | initial condition only |
| **Per-rank average INTERNAL** (checkpoint ÷ 120) | **~26.7 MB/rank** (~25 MiB) | the unit a per-rank shard writer would emit |

The **3.3× ratio** (3.21 GB checkpoint vs 0.98 GB input restart) is the INTERNAL state being larger than
the species restart: the checkpoint carries the full MAPL INTERNAL (all registered `AddInternalSpec`
fields incl. dynamics internal, tracer state, and diagnostic accumulators) at full `pnc4` precision,
whereas the input restart is species concentrations only. This is consistent with — and a partial
resolution of — the "13× discrepancy" flagged in the spec: the INTERNAL footprint is dominated by
state the species restart does not contain. **Caveat:** this is the *averaged* per-rank size derived
from the collective file, not a direct per-rank measurement, because the shard probe did not fire (see
below). A direct per-rank distribution (p50/p95 across the 120 ranks) was not captured.

---

## MEASUREMENT 2 — per-shard-write vs collective-hang — **THE HANG REPRODUCED (live); PROBE DID NOT FIRE**

Updated finding (the continuation-test runs caught it):

1. **The collective o-server checkpoint DID hang — caught live, with a process-state smoking gun.**
   In an early continuation-test attempt (job 16, **2-node C180 TT, `WRITE_RESTART_BY_OSERVER: YES`**),
   the straight-24h arm finished all 288 timesteps and then **never produced a checkpoint file**. 20+
   minutes after the last timestep, with no `gcchem_internal_checkpoint` on disk, I ssh'd to the
   compute node and inspected the ranks directly:
   ```
   gchp_procs = 60          (all ranks still alive on node 1)
   /proc/<pid>/status: State: R (running)      ← spinning, NOT blocked
   /proc/<pid>/wchan:  0                         ← not waiting in a kernel/IO syscall
   ```
   **State R + wchan 0 = the ranks are busy-spinning in an MPI progress loop, not stuck in disk I/O.**
   That is the MAPL **o-server** signature: compute ranks hand the INTERNAL checkpoint to the o-server
   and then spin waiting for a completion that, on this 2-node job with no dedicated server rank, never
   comes. It does not error and does not time out — it spins forever. I had to `scancel` it.

2. **Why the EARLIER fabric-A/B runs looked healthy.** Those runs *did* leave a 3.21 GB checkpoint —
   but only because their watcher **killed mpirun after a finalize grace** once the end-mark was seen.
   In the fabric runs the write happened to land inside the grace window; the continuation run, running
   `mpirun` in the foreground with no watcher, exposed the underlying spin. So the corrected reading is:
   **the o-server collective checkpoint is genuinely fragile at multi-node** (consistent with the prior
   project finding that the real fix is "kill mpirun at sim-completion, don't wait on the checkpoint"),
   and turning the o-server **OFF on 1 node** writes natively and cleanly (the continuation test at C90
   1-node wrote its 802 MB checkpoint every segment with no hang). **This is direct support for the
   decoupled design's premise**: the standard collective restart path does NOT reliably return at
   multi-node, which is exactly the failure an independent per-rank writer would sidestep.

2. **The shard probe did not fire**, so no per-rank write timings were captured. Root cause, found by
   reading the source on the head node (not guessed): the probe is hooked inside `MAPL_StateRecord`
   (`MAPL/generic/MAPL_Generic.F90:2677` call site, probe at `:2769`), which executes **only when the
   MAPL `RecordAlarm` rings**. That alarm is created only if `RECORD_FREQUENCY:` is present
   (`:1427`); it is **commented out by default**. I set `RECORD_FREQUENCY: 120000` (12 h) in `GCHP.rc`
   and `-x`-forwarded `GCHP_INSTR_SHARD` to all ranks (verified in the mpirun line), but the alarm
   **still did not ring mid-run** (no dated mid-run checkpoint was produced — only the single
   end-of-run file). The end-of-run checkpoint is written by a different finalize path that does not
   route through the alarm-gated `MAPL_StateRecord`, so the probe was never reached.

   The probe **code is built, correct, and default-off-verified** (symbol `SHARDPROBE tag=` present in
   the binary; `ShardProbe_IsEnabled()` reads `GCHP_INSTR_SHARD` correctly). What's missing is the
   correct MAPL incantation to make the RecordAlarm fire from a run-dir config. Per the project's
   no-guess / don't-burn-money rule, I **stopped** rather than launch more paid runs probing MAPL alarm
   internals by trial-and-error. **Could not run because:** the MAPL RecordAlarm did not trigger from
   `RECORD_FREQUENCY` in this GCHP 14.7.1 run-dir, and resolving why is MAPL-config-internals work I
   would not guess at on the billing clock.

---

## MEASUREMENT 5 — restart completeness / bitwise continuation — **RUN; PASSES (roundoff-only divergence)**

**Test (C90 TransportTracers, 1 node / 60 ranks, o-server OFF so the checkpoint writes natively):**
- **Arm A (segmented):** run 12 h → checkpoint → rename → restart → run 12 h → final checkpoint @ 20190102.
- **Arm B (straight):** run 24 h straight → final checkpoint @ 20190102.
- Both final INTERNAL checkpoints are **identical size (802,531,682 bytes)**; compared field-by-field
  with `h5diff` (HDF5 1.14.0) plus absolute/relative threshold sweeps.

**Result:**

| Cut | Count | Interpretation |
|-----|-------|----------------|
| Datasets compared | **318** | full INTERNAL state |
| **Bit-identical** | **299** | every met / geometry / deposition-reservoir / derived-diagnostic field |
| **Differing** | **19** | **all 19 are prognostic species** (`SPC_*`) — and ONLY species |

Magnitude of the 19 species diffs (absolute-delta sweep):

```
  abs > 1e-30 : 19   ← all species differ at the bit floor
  abs > 1e-20 : 11
  abs > 1e-12 : 10
  abs > 1e-9  :  3
  abs > 1e-3  :  3   ← SPC_aoa, SPC_aoa_nh, SPC_aoa_bl  (age-of-air clocks, values O(1880))
```

The 3 "large" ones are the **age-of-air tracers**, whose values are ~1880 (monotonic clocks); an abs
diff >1e-3 on ~1880 is a **relative diff ≈5e-7** — roundoff at F64. The others differ at the absolute
floor of their own (tiny) magnitudes (e90 ~1e-12, st80_25 ~2e-7). Checkpoint species are stored **F64**
(verified via `h5dump -H`), so this is **not** float32 truncation — it is floating-point **chaos
amplifying the checkpoint round-trip**: writing state to disk and reading it back is not bit-exact at
the last ULP, and a chaotic transport field amplifies that into ~1e-6-relative drift over 12 h.

**Verdict: the MAPL INTERNAL checkpoint is COMPLETE.** A stop/restart reproduces a straight run to
roundoff — no field is *lost* across the boundary. The only divergence is last-ULP species drift
intrinsic to non-bit-exact restart of a chaotic system, confined entirely to prognostic species, and
bounded (≤~1e-6 relative). Nothing in the 299 non-species fields drifts at all.

### State-completeness table (Part C, built from the run + source, not a referenced doc)

| Quantity | Persisted where | In MAPL INTERNAL restart? | Reproduces on restart? | Risk if a per-shard boundary missed it |
|----------|-----------------|---------------------------|------------------------|-----------------------------------------|
| Prognostic species (`SPC_*`) | MAPL INTERNAL | ✅ yes | ✅ to ~1e-6 rel (roundoff) | high — these ARE the simulation state |
| Dynamics state (`DELP_DRY`, winds, `BXHEIGHT`) | MAPL INTERNAL | ✅ yes | ✅ **bit-identical** | high — but fully captured |
| Deposition reservoirs (`DEP_RESERVOIR`, `DRYPERIOD`) | MAPL INTERNAL | ✅ yes | ✅ **bit-identical** | medium — captured |
| Derived/diag accumulators (`H2O2AfterChem`, `JNO2`, `PARDF_DAVG`…) | MAPL INTERNAL | ✅ yes | ✅ **bit-identical** | low — captured |
| Grid/geometry (`AREA`, `lat`/`lon`/`lev`) | MAPL INTERNAL | ✅ yes | ✅ **bit-identical** | none — static |
| HEMCO internal state | HEMCO restart (separate file) | ➖ not in this checkpoint | n/a for this test (TT emissions are simple) | medium for fullchem — a faithful boundary must ALSO carry the HEMCO restart |

**Takeaway for the decoupled design:** the MAPL INTERNAL snapshot is a *complete* handoff for the
species + dynamics + diagnostic state at TransportTracers complexity — a per-rank shard that serializes
the same INTERNAL fields would carry everything that matters here. The one caveat the table surfaces:
**HEMCO keeps its own restart** outside the MAPL INTERNAL checkpoint, so a faithful boundary for
*fullchem* must capture the HEMCO restart in addition to MAPL INTERNAL (not exercised by TT).

---

## SYNTHESIS (Part D) — what these runs change

1. **The fabric is a gate, not a dial.** The single most decision-relevant result: GCHP multi-node is
   **hard-bound to an RDMA fabric**. TCP doesn't slow it down — it stops it at `MPI_Win_create`. Any
   decoupled-execution design that imagines commodity-network links between tiers must keep
   MAPL-RMA-using components on RDMA-connected nodes. This kills the "cheap TCP tier" option for any
   tier that does cross-node MAPL one-sided exchange.

2. **The tracer halo is not the throughput villain (on EFA).** C180 TT holds ~250 d/d on 2 nodes with a
   tight per-step distribution — the transport halo is absorbed, not stalling. The decoupled design's
   prospective win is therefore **not** "relieve a saturated tracer halo"; on adequate fabric it isn't
   saturated at this scale. The win, if any, lies elsewhere (memory headroom for fullchem — which
   *doesn't fit* C180 on a 128 GB node — and the state-handoff cost, not the halo bandwidth).

3. **Memory, not communication, is the C180 fullchem wall.** The most concrete operational finding of
   the whole session: **C180 fullchem does not fit hpc7g** (125.7 GB at 2-node DYNAMICS init vs 128 GB).
   That is a memory-capacity ceiling, and it is the strongest *quantitative* argument for a decoupled /
   memory-tiered design — stronger than any halo measurement. The transport-vs-chemistry separation
   matters because chemistry's 250-species state is what blows the node, not because the halo is slow.

4. **The collective o-server checkpoint is genuinely fragile at multi-node — confirmed live.** With
   `WRITE_RESTART_BY_OSERVER: YES` on a 2-node job, the checkpoint **hung** post-completion: all ranks
   spinning (State R, wchan 0), no file ever written, killed after 20+ min. The earlier "healthy" runs
   only survived because a watcher killed mpirun inside a finalize grace. Turning the o-server OFF at
   1 node writes natively and cleanly. So the brittle-restart premise motivating the per-rank writer
   **does manifest** here — the independent-writer design targets a real failure, though the writer
   itself remains built-but-unfired (the probe's RecordAlarm trigger is the open item).

### Top-3 measurements that would still change the conclusion
1. **The component split (Measurement 4 proper)** — CHEM vs ADV vs halo wall-share, by node count.
   Needs the MAPL/FMS timer report to survive finalize (suppress the double-free abort, or dump timers
   at a mid-run alarm). Without it, "chemistry dominates" is asserted by the companion static analysis,
   not measured here.
2. **C180 fullchem on a big-memory node** (e.g. hpc7a.96xl, 768 GB, or r-class) to get the *real*
   fullchem fabric + memory numbers the spec wanted — TT proves the fabric gate, but fullchem is where
   the memory ceiling and chemistry halo actually live.
3. **Fire the per-rank shard probe** to put real numbers on the independent-writer path (per-rank
   serialize+write p50/p95, all-ranks-finish wall) and compare directly against the now-confirmed
   o-server hang. The probe is built and verified; the open item is triggering its MAPL RecordAlarm
   from run-dir config (setting `RECORD_FREQUENCY:` in GCHP.rc did not make the alarm ring mid-run).

**Status of the five measurements:** M1 (fabric) ✅ decisive; M2 (collective hang) ✅ reproduced live,
probe unfired; M3 (state bytes) ✅ from the collective file (per-rank distribution not captured);
M4 (component split) ⚠️ throughput only — the timer report is eaten by the finalize abort;
M5 (restart completeness) ✅ passes (roundoff-only divergence).

---

## RUN LEDGER (this session, all on `bench-fabrictest`, hpc7g ×2)

| Job | Config | Result | Note |
|-----|--------|--------|------|
| 7 | C90 fullchem 2n EFA | ❌ | missing HEMCO input `gmi.clim.NPMN...nc` (fullchem GMI tree absent) |
| 8 | C180 TT 2n EFA | ✅ ran, reports killed | watcher killed mpirun at end-mark → severed finalize reports (fixed) |
| 9 | C180 TT 2n EFA | ✅ completed | finalize-preserving watcher; ckpt wrote, no hang |
| 10 | C180 TT 2n **TCP** | ❌ init abort | `MPI_Win_create` / `osc pt2pt` no THREAD_MULTIPLE |
| 11 | C180 TT 2n **TCP+osc rdma** | ❌ init abort | `MPI_Win_create` `MPI_ERR_WIN` (tcp BTL can't back RDMA) |
| 12 | C180 TT 2n EFA +shard | ✅ completed | shard env not forwarded (no `-x`) → probe silent (fixed) |
| 13 | C180 TT 2n EFA +shard −x | ✅ completed | `-x` forwarded, but RecordAlarm never rang → probe silent |
| 14 | C180 TT 2n EFA +shard +RECORD_FREQUENCY | ✅ completed | alarm still didn't ring mid-run → probe silent |
| 15 | C180 TT 1n continuation | ❌ OOM (signal 9) | C180 doesn't fit ONE 128 GB node even for TT → moved to 2n / C90 |
| 16 | C180 TT 2n continuation (o-server ON) | ❌ **checkpoint HANG** | **Measurement-2 evidence**: ranks State R/wchan 0, no file, killed at 28 min |
| 17 | **C90 TT 1n continuation (o-server OFF)** | ✅ **completed** | **Measurement 5**: 3 segments + h5diff; 299/318 bit-identical, 19 species roundoff-only |

**Teardown:** cluster `bench-fabrictest` + scratch FSx **deleted**; input FSx `fs-0804c4d8e01897d21`
(gcgrid, us-east-1a) **kept** per user decision (reused for the fullchem-on-big-memory follow-up).

---

## FULLCHEM-ON-BIG-MEMORY READINESS (offline audit — no cluster spent)

The follow-up arc is C180 **fullchem** on a big-memory node (where it fits and the chemistry halo +
memory ceiling actually live). De-risked this session WITHOUT launching a cluster:

**Instance:** `m9g.48xlarge` (Graviton5, 768 GB, EFA) is **available in us-east-1a** — same AZ as the
kept input FSx, and it runs the **existing aarch64 instrumented binary with no rebuild**. (x86 `hpc7a`
is not even offered in us-east-1, so ARM big-mem is the only HPC path here — and per
`gchp_multinode_c180_results` m9g was the C180 throughput winner with no OOM.)

**Input completeness audit** (fullchem `HEMCO_Config.rc.fullchem`, 487 distinct file refs, ~50 data
families, resolved against `s3://gcgrid`):
- **48 of 50 active data families present** in `s3://gcgrid/HEMCO/` (CEDS, NEI2016, CMIP6, EDGARv43,
  GFED4, MEGAN, OLSON_MAP, …). All confirmed.
- **2 families absent** (`DICE_Africa`, `APEI`) — but both are **disabled by default** (`: false` in
  the inventory switches) and sit inside `(((NAME … )))` HEMCO conditional blocks, so HEMCO never reads
  them. **Not blockers.**
- **5 GMI "files" are symlink aliases** (`NPMN`, `IPMN` → `PMN`; `RIPA`, `RIPB`, `RIPD` → `RIP`) that
  GCHP's `download_data.py` normally creates and our FSx-from-S3 path skips — this was the exact cause
  of the job-7 abort. **Fixed:** the 5 real copies are staged at
  `s3://gchp-shared-storage-us-east-1/gmi-aliases/v2015-02/`. A future run-dir setup just copies these
  onto Lustre `HcoDir/GMI/v2015-02/` after `createRunDir` (the `/input` FSx is read-only, can't symlink
  there). `download_data.py` has **no other** edge-cased files beyond these 5.

**Net:** the next fullchem cluster can launch input-clean — instance + AZ + binary + the one real input
gap are all resolved. Remaining unknowns for that run: actual C180 fullchem memory high-water on 768 GB,
the CHEM-vs-ADV component split (needs the finalize-abort timer fix), and multi-node fullchem throughput.

---

## C180 FULLCHEM ON m9g.48xl — **RAN TO COMPLETION** (2026-07-10)

The follow-up run executed. Cluster `bench-fullchem-m9g-1c`, **m9g.48xlarge** (Graviton5, 192 cores,
768 GB, EFA), us-east-1c, STOCK validated aarch64 binary (no rebuild), 48 ranks / 1 node, layout
NX=4 NY=12, C180 fullchem, 2-hour sim. **Completed all 24 timesteps + wrote a 42.9 GB INTERNAL
checkpoint + finalized cleanly.**

### Headline numbers

| Metric | Value | Significance |
|--------|-------|--------------|
| **Memory high-water** | **556.5 GB** | **4.3× a 128 GB node** — definitively why C180 fullchem OOMs on hpc7g |
| Throughput (cumulative) | **7.4 days/day** | 48 cores, 1 node |
| INTERNAL checkpoint | 42.9 GB | full C180 fullchem state (vs 3.2 GB for C180 TT) |

### Appendix: performance / cost row (context, NOT a benchmark result)

> This exercise was not a benchmark — these numbers exist only to *size the prize* for Goal 2. The
> single load-bearing figure is the **fullchem-vs-TT gap** at the bottom: it is a direct dollar-and-
> throughput measure of "the chemistry tier," which is exactly what decoupling would offload.

| Instance | Gen | Sim | Cores used | Nodes | Throughput | Mem high-water | On-demand $/hr | **$/sim-day** | $/sim-year |
|----------|-----|-----|-----------|-------|-----------|----------------|----------------|---------------|------------|
| m9g.48xlarge | Graviton5 | C180 fullchem | 48 / 192 | 1 | 7.4 sim-d/wall-d | 556.5 GB | **$9.393** (measured) | **$30.46** | ~$11,100 |

**Two honest caveats on this cost row:**
1. **Only 48 of 192 cores were used** (fullchem's memory/cache pressure + a conservative layout). So
   **$30.46/sim-day is the cost of *this configuration*, not the m9g's floor** — a fuller-core layout
   (e.g. 96 or 192 ranks with a valid C180 decomposition) would raise throughput and lower $/sim-day,
   bounded by fullchem's chemistry bottleneck (the 4.3 d/d chem-step cadence caps the gain — scaling is
   sublinear). Treat $30/sim-day as an **upper bound** for m9g C180 fullchem, not the achievable best.
2. **Measured price is $9.393/hr**, materially higher than the $7.40/hr *projected* for m9g.48xl in
   `docs/INSTANCE-SELECTION-GUIDE-2026.md`. That guide's m9g/hpc9a/c9a prices are pre-GA estimates and
   should be reconciled to the live on-demand rate. At the real price, m9g's $/core-hr is $0.049, not
   the guide's $0.039 — still competitive with big-memory peers but not the bargain the guide implies.

For contrast, the C180 **TransportTracers** run (hpc7g, 2 nodes × 60 = 120 cores, EFA) sustained
~250 sim-d/wall-d — TT is ~34× faster than fullchem per the same grid because it carries no chemistry.
That gap **is** the chemistry cost, and it is the quantity the decoupled design targets.

**Memory ramp (where the 556 GB comes from):** GCHPctmEnv init 70 GB → GCHPchem init 150 GB →
DYNAMICS init 269 GB → TimeLoop entry 306 GB → **first KPP chemistry call 556 GB**. Chemistry's
250-species working set is what pushes it from 306 → 556 GB — i.e. **chemistry roughly doubles the
resident footprint** over dynamics+transport alone.

**Implicit CHEM-vs-dynamics split (from the throughput cadence, since the MAPL "Times for" report is
again eaten by the finalize double-free abort):** instantaneous per-step throughput alternates
**18.4 d/d on a transport-only 5-min step** vs **4.3 d/d on a step where KPP chemistry runs** (chem dt
= 600 s, so every other step). **Chemistry quarters the per-step throughput** — a direct, if coarse,
measurement of the chem:dynamics cost ratio (~4:1 per chemistry step) without any instrumentation.

### The fix chain (each a real, resolved wall — see run ledger below)

1. **m9g InsufficientInstanceCapacity in us-east-1a** → moved the whole setup to **us-east-1c**
   (capacity is AZ-specific; AWS's own error names the AZs that have it). The input FSx must live in
   the compute AZ (FSx is not cross-AZ), so this forced a fresh input FSx in 1c.
2. **FsxMountFailure** on the pre-created 1c FSx — two CLI-default bugs: it defaulted to **Lustre 2.10**
   (AL2023 client is 2.15 → `mount.lustre: Invalid argument`), and got the **VPC default SG** (no
   Lustre ports 988/1018-1023). Fix: recreate with `--file-system-type-version 2.15` +
   `--security-group-ids sg-09d153889e75c86cb`.
3. **5 GMI symlink aliases** staged onto a writable Lustre `HcoDir` overlay (read-only `/input` can't
   hold them) — the fix prepared in the offline audit above, applied cleanly.
4. **Restart link** — createRunDir defaults to a 20190701 start; linked the version-matched GC_14.7.0
   `GEOSChem.Restart.fullchem.20190101_0000z.c180.nc4` (13 GB) + set cap_restart.
5. **`domains_stack_size` 20M → 64M** in `input.nml` — FMS `mpp_domains` halo stack overflows at C180's
   coarse 48-rank decomposition (`FATAL … mpp_domains_stack overflow, call …(32475168)`).
6. **`/dev/shm` 200G → 550G** — **SIGBUS (signal 7) at the FIRST KPP chemistry call**, ~half the ranks
   simultaneously. Root cause: tmpfs exhaustion of MAPL's `MPI_Win_allocate_shared` windows when
   chemistry first touches the full 250-species array (physics — conv/drydep/emis/turb — ran fine
   before it; the fault is specifically the chemistry working set landing in a too-small `/dev/shm`).
   m9g's 768 GB RAM makes a 550 GB `/dev/shm` safe.

### What this settles for the decoupled-execution design

- **Memory, not communication, is the C180 fullchem wall** — and now quantified: **556 GB**, of which
  chemistry adds ~250 GB on top of the ~306 GB dynamics+transport base. This is the strongest
  quantitative argument in the whole study for a memory-tiered / decoupled design: the chemistry state
  is what blows a commodity node, and it is exactly the loosely-coupled tier the design would peel off.
- **Chemistry dominates per-step cost ~4:1** over a transport step (the 4.3-vs-18.4 d/d cadence),
  corroborating the companion static analysis's "chemistry is the heavy, fungible tier" without needing
  the MAPL timer report.

**Artifacts:** config `parallelcluster/configs/bench-fullchem-m9g-use1c.yaml`, harness
`scripts/gchp-fullchem-m9g.sh`. **Teardown:** cluster `bench-fullchem-m9g-1c` + scratch FSx deleted;
the run-specific 1c input FSx deleted (the us-east-1a input FSx `fs-0804c4d8e01897d21` persists).

### Fullchem run ledger (cluster `bench-fullchem-m9g-1c`, m9g.48xl ×1, us-east-1c)

| Job | Result | Note |
|-----|--------|------|
| 1a-cluster | ❌ never launched | m9g InsufficientInstanceCapacity in us-east-1a → moved to 1c |
| 1c-cluster #1/#2 | ❌ FsxMountFailure | FSx was Lustre 2.10 + default SG → recreated as 2.15 + Lustre SG |
| job 1 | ❌ no run | restart symlink missing (createRunDir defaulted to 20190701) → linked 20190101 |
| job 2 | ❌ MPI_ABORT at init | `mpp_domains_stack overflow` → domains_stack_size 20M→64M |
| job 3 | ❌ SIGBUS at 1st chem | `/dev/shm` (200G) tmpfs exhaustion of MAPL shared windows → 550G |
| **job 4** | ✅ **completed** | 2h sim, 24 steps, **556 GB peak, 7.4 d/d**, 42.9 GB checkpoint, clean finalize |
