# GCHP Decoupled-Execution Instrumentation — Plan + Findings

**Date:** 2026-06-28
**Source clone:** `/Users/scttfrdmn/src/GCHP-instrument/GCHP` (GCHP 14.7.1), branch
`instrument/decoupled-metrics`. Submodules inited: MAPL, geos-chem, FVdycoreCubed (+ fvdycore
nested), HEMCO.
**Run target (when built):** hpc7g (Graviton3E) us-east-1, C180, 60 ranks/node, 1→2→4 nodes as
capacity allows (per the capacity study — 4-node on in-demand SKUs is not guaranteed).
**Guardrails honored:** numerics unchanged; ALL instrumentation behind a default-off flag; timing
read from internal timers (never wall-clock around the brittle checkpoint); a hung pnc4 checkpoint
cannot contaminate Part-A/B numbers (timers + the independent side-channel write are separate paths).

> **Companion report:** `gchp-advection-split-2026-06-28.md` (the FV3 tracer/flow-solver kill test
> — PASSED: tracer advection is outside the acoustic loop). That study shares this build+run.

---

## KEY DISCOVERY governing the whole plan: two timer systems, only one live in GCHP

GCHP has **two** independent timing systems, and this dictates every Part-A choice:

1. **MAPL timer tree (LIVE in GCHP).** Enabled by resource knob **`MAPL_ENABLE_TIMERS: YES`**
   (`MAPL/gridcomps/Cap/MAPL_CapGridComp.F90:384`; default `'NO'`) + `MAPL_TIMER_MODE: MINMAX`
   (`:396`). Prints per-component "Times for component …" at finalize via `report_generic_profile()`
   (`MAPL/generic/MAPL_Generic.F90:2463`). GCHP **already brackets** a rich component tree with
   `MAPL_TimerOn(STATE,name)`: `GC_CHEM, GC_CONV, GC_DRYDEP, GC_EMIS, GC_FLUXES, GC_TURB`
   (`Interfaces/GCHP/gchp_chunk_mod.F90:1164–1337`), plus `DYN_CORE`/`-DYN_CORE`/`--FV_DYNAMICS`
   in the dynamics (`FVdycoreCubed_GridComp/DynCore_GridCompMod.F90:4140`, `FV_StateMod.F90:1708`).
   ⇒ **Part A's component split (CHEM vs ADV vs ECTM vs I/O) is FREE — enable the knob, zero code.**

2. **GEOS-Chem `Timers_Mod` (DORMANT in GCHP).** `Timer_Setup`/`Timer_Add`/`Timer_PrintAll`/
   `Use_Timers` are called ONLY in the GCClassic main (`Interfaces/GCClassic/main.F90:323–342,2185`),
   **never in `Interfaces/GCHP/`**. The InLoop accumulating-timer machinery exists
   (`GeosUtil/timers_mod.F90:78,233` — per-thread `START_TIME_LOOP`) but is never initialized in a
   GCHP run. ⇒ **The KPP-Integrate sub-fraction requires BOOTSTRAPPING Timers_Mod inside the GCHP
   interface.** (Decision: do it — see Part A diffs. Most faithful to "Integrate fraction"; most
   invasive; default-off.)

---

## PART A — component split + KPP Integrate fraction

### A0 (no code): enable the MAPL report
Set in the run dir's `GCHP.rc` (or `CAP.rc`): `MAPL_ENABLE_TIMERS: YES`, `MAPL_TIMER_MODE: MINMAX`.
Yields ECTM / DYNAMICS(ADV, incl. DYN_CORE/FV_DYNAMICS) / GC_CHEM / GC_* / I-O component wall split
at finalize, per rank, min/mean/max across ranks. **This alone answers "does chemistry dominate."**

### A1 (DIFFS — bootstrap GEOS-Chem Timers_Mod in GCHP for the KPP InLoop timer)
All gated behind a new default-off logical (env var `GCHP_INSTR_KPP`, read once at init). Planned
insertions (file:line are the TARGET sites in the clone; exact post-edit lines listed after apply):

- **D-A1a** `Interfaces/GCHP/gchp_chunk_mod.F90` — in `GCHP_Chunk_Init` (subroutine at :59), after
  Input_Opt is populated (~:206): `USE Timers_Mod`; if `instr_kpp` then `CALL Timer_Setup(1)` +
  `CALL Timer_Add("KPP Integrate", RC)`. (Mirror of GCClassic/main.F90:323–326.)
- **D-A1b** `GeosCore/fullchem_mod.F90` — `USE Timers_Mod, ONLY : Timer_Start, Timer_End` (with the
  existing `USE` block ~:187 which already imports `Timers_Mod`). Around the per-cell Integrate
  call (`:1115`): `if(instr_kpp) CALL Timer_Start("KPP Integrate", RC, InLoop=.TRUE., ThreadNum=Thread)`
  before, matching `Timer_End(...,InLoop=.TRUE.,ThreadNum=Thread)` after (`Thread` is already an
  OMP-PRIVATE var in this loop — verified at the `!$OMP PRIVATE(... Thread ...)` directive).
- **D-A1c** report at finalize: `CALL Timer_PrintAll(Input_Opt, RC)` on the GCHP finalize path
  (Chem_GridCompMod finalize / MAPL finalize), gated. (Mirror of GCClassic/main.F90:2185.)

Overhead: one SYSTEM_CLOCK pair per grid cell when enabled; **inert (untouched code path) when
`GCHP_INSTR_KPP` unset** — default-off, numerics unaffected.

### A1 (no new code needed): ADV + halo
Dynamics already bracketed (`DYN_CORE` etc.). Halo inside dynamics already timed via FMS
`timing_on('COMM_TOTAL')` (`fvdycore/model/fv_dynamics.F90:580,592` and inside dyn_core). Report
via the FMS timing report (enable in FV3 nml) — surfaced, not re-added.

### A3 — reported numbers `[PENDING RUN]`
Per node count: wall-% for CHEM (GC_CHEM) vs ADV (DYN_CORE+FV_DYNAMICS) vs ECTM vs I/O; and
Integrate fraction = "KPP Integrate" / GC_CHEM. Decision number: is chem dominant, by how much, and
does ADV's share grow with node count (acoustic halo cost rising as faces subdivide)?

---

## PART B — per-rank state size + independent S3 side-channel writer

### B1 — per-rank INTERNAL-state bytes `[method fixed; numbers PENDING RUN]`
Sum registered `MAPL_AddInternalSpec` field bytes owned per rank at the superstep boundary. Probe:
at the RecordAlarm site, iterate the INTERNAL ESMF_State fields, sum `product(localCount)*kind`.
Cross-check vs on-disk restart (~1 GB global @C180). Hook = `MAPL_GenericRecord` (alarm tested
`MAPL/generic/MAPL_Generic.F90:2622`); state write `MAPL_StateRecord` (`:2761`,
`MAPL_ESMFStateWriteToFile` for INTERNAL).

### B2 (DIFF — flag-gated independent per-rank writer)
- **D-B2** at the RecordAlarm site (`MAPL_Generic.F90` `MAPL_StateRecord`, alongside — NOT replacing
  — the collective INTERNAL write at `:2761`): if env `GCHP_INSTR_SHARD` set, each rank serializes
  ITS OWN internal-state fields to a single local file (sequential NetCDF / raw; NO collective, NO
  barrier) and, if `GCHP_INSTR_S3` set, `aws s3 cp` to `s3://<bucket>/<run>/<step>/rank-<id>`.
  Per-rank epoch timers around serialize / local-write / S3-PUT, logged per rank. Default-off.

### B3/B4 — `[PENDING RUN]`
Per-rank p50/p95 serialize/local/PUT times; all-ranks-finish wall (the real boundary cost);
compare to pnc4 collective time where pnc4 completes, and show the per-rank path succeeding where
pnc4 hangs. Grain ratio = heartbeat wall (Part A) / all-ranks-independent-write.

---

## PART C — restart completeness

### C1 — state-location table `[built from source; PENDING the live AddInternalSpec dump to finalize]`
Table: quantity | where persisted (MAPL INTERNAL / HEMCO restart / module SAVE) | in MAPL restart? |
in per-rank shard? | risk-if-missed. Built by enumerating `MAPL_AddInternalSpec` registrations vs
`HCO_RestartWrite` (HEMCO) vs module-level SAVE/ALLOCATABLE in GeosCore (carbon, mercury, POPs,
planeflight, tpcore — NOTE: the spec's "comm-analysis §5 list" doc does NOT exist in this repo;
table will be built from the actual source registrations, not a referenced doc).

### C2 — bitwise continuation test `[PENDING RUN; uses EXISTING binary — no rebuild needed for this part]`
(run N → checkpoint → restart → run M) vs (run N+M straight); diff final restart. Bit-matching
fields validate the snapshot; drifting fields localize state a per-shard boundary must additionally
capture. Can run on the CURRENT prebuilt stack (no instrumentation needed) — cheapest part, can go
first / independently.

---

## PART D — synthesis `[PENDING the run numbers]`
Chem wall-share + scaling trend → Design-2 prize real?; per-rank write throughput + grain ratio →
which design at C180; completeness gaps → what a faithful boundary captures beyond MAPL restart;
top-3 measurements that would still change the conclusion. Printed to console on completion.

---

## DIFF LEDGER — APPLIED (branch `instrument/decoupled-metrics` in MAPL + geos-chem submodules)
All default-off; numerics unchanged. Post-edit file:line:

| id | file:line (post-edit) | change | gate |
|----|----------------------|--------|------|
| D-A1a | geos-chem `Interfaces/GCHP/gchp_chunk_mod.F90:83` | `USE Timers_Mod, ONLY: Timer_Setup, Timer_Add` | — |
| D-A1a | geos-chem `Interfaces/GCHP/gchp_chunk_mod.F90:227` | `Timer_Setup(2)` + `Timer_Add(...)` incl. `"KPP Integrate"`, after Read_Input_File | `Input_Opt%useTimers` |
| D-A1b | geos-chem `GeosCore/fullchem_mod.F90:1120` | InLoop `Timer_Start/End("KPP Integrate", InLoop=.TRUE., ThreadNum=Thread)` around per-cell `Integrate` (:1115→now ~1126) | `Input_Opt%useTimers` |
| D-A1c | geos-chem `Interfaces/GCHP/Chem_GridCompMod.F90:3390` (USE) + `:3564` (call) | `Timer_PrintAll(Input_Opt,RC)` in `Finalize_` before HCOI_GC_FINAL | `Input_Opt%useTimers` |
| D-B2-new | MAPL `base/MAPL_ShardWriter.F90` (NEW, 180 lines) | independent per-rank size+write+S3 probe module; no collective/barrier | `GCHP_INSTR_SHARD` env |
| D-B2 | MAPL `base/CMakeLists.txt:4` | register `MAPL_ShardWriter.F90` in MAPL.base srcs | — |
| D-B2 | MAPL `generic/MAPL_Generic.F90:110` (USE) + `:2775` (call) | gated `ShardProbe_Record(internal_state, rank, INT_FNAME)` in `MAPL_StateRecord`, before the collective INTERNAL write (unchanged) | `GCHP_INSTR_SHARD` env |

Submodule commits: geos-chem + MAPL each have one commit on `instrument/decoupled-metrics`.

### Runtime enablement (config/env, NOT code — keeps everything default-off)
- **Part A timers:** set `useTimers: true` under the `timers` section of `geoschem_config.yml` in
  the run dir (read at `GeosCore/input_mod.F90:863`). Yields the GEOS-Chem timer report incl.
  the `KPP Integrate` line at finalize. (Also enable MAPL component report via
  `MAPL_ENABLE_TIMERS: YES` in `GCHP.rc` for the ECTM/DYNAMICS/GC_* component split.)
- **Part B shard probe:** `export GCHP_INSTR_SHARD=1` (+ optional `GCHP_INSTR_S3=s3://bucket/run`,
  `GCHP_INSTR_LOCAL=/scratch/shardprobe`) in the SLURM script. Emits `SHARDPROBE tag=… rank=…
  bytes=… write_s=… put_s=… total_s=…` per rank at each record alarm.

### Build recipe (for the run phase) `[to verify on cluster]`
GCHP builds via CMake against the installed ESMF/MAPL stack; the instrumented MAPL is a
**submodule of GCHP**, so `cmake --build` of GCHP rebuilds MAPL.base + MAPL.generic +
GEOSChem_GridComp with these diffs — **no full dependency-stack rebuild** (GCC/OpenMPI/ESMF/NetCDF
from the validated stack are reused). Expected: a GCHP-tree recompile (~20-40 min on the build
node), not the multi-hour from-scratch stack build. CONFIRM on first cluster build before scaling.
