# GCHP FV3 Advection Split — Separability Analysis

**Date:** 2026-06-28
**Source:** GCHP 14.7.1, FV3 dycore = `GFDL_atmos_cubed_sphere` @ 643f3c44 (nested submodule
`src/GCHP_GridComp/FVdycoreCubed_GridComp/fvdycore`), cloned locally at
`/Users/scttfrdmn/src/GCHP-instrument/GCHP`.
**Scope:** static source analysis (Parts A, B, D) + a default-off timer design (Part C, build-gated).
Numerics unchanged. Every structural claim carries a file:line; inferences marked `[INFERRED]`.

Paths below are relative to the dycore model dir:
`.../FVdycoreCubed_GridComp/fvdycore/model/`

---

## PART A — THE KILL TEST: is tracer advection inside or outside the acoustic loop?

### VERDICT: **CONFIRMED — tracer advection is OUTSIDE the acoustic loop.** The separation is real.

Tracers are transported **once per outer (`k_split`) step** using mass fluxes and Courant numbers
**accumulated over the acoustic (`n_split`) substeps**. Tracers do **not** participate in the
acoustic substeps. The design's load-bearing claim holds, in source, not by inference.

### The loop structure (the proof)

**Outer driver — `fv_dynamics.F90`, `subroutine fv_dynamics`:**

```
579   do n_map=1, k_split            ! outer (vertical-remap) time split
...
613                                   call timing_on('DYN_CORE')
614     call dyn_core(... nq, mdt, n_split, ... u,v,w,delz,pt,q,delp, ...   ! ACOUSTIC core
620                   mfxL, mfyL, cxL, cyL, ...)                             ! flux capacitors out
625                                   call timing_off('DYN_CORE')
...
667     if( .not. flagstruct%inline_q .and. nq /= 0 ) then
668 !   Perform large-time-step scalar transport using the accumulated CFL and
669 !   mass fluxes                                  ← the design intent, verbatim
671                                   call timing_on('tracer_2d')
684       call tracer_2d(q, dp1, mfxL, mfyL, cxL, cyL, ... q_split, mdt, ...)   ! TRACERS, once
688     endif
```

- The **tracer call (`fv_dynamics.F90:684`) is lexically OUTSIDE and sequentially AFTER** the
  `dyn_core` call (`:614`). It is *not* nested inside the acoustic loop — that loop lives one level
  down, inside `dyn_core`.
- `tracer_2d` is handed `mfxL, mfyL, cxL, cyL` — the accumulated fluxes — plus `q_split` (its own
  sub-cycling count) and `mdt` (the large time step). `fv_dynamics.F90:684-686`.
- The in-tree comment `fv_dynamics.F90:668-670` states the mechanism outright: *"Perform
  large-time-step scalar transport using the accumulated CFL and mass fluxes."*

**Acoustic core — `dyn_core.F90`, `subroutine dyn_core`:**

```
221 ! The Flux capacitors: accumulated Mass flux arrays
222   real(kind=8), intent(inout):: mfx(...)        ! accumulated, returned to caller
223   real(kind=8), intent(inout):: mfy(...)
225   real(kind=8), intent(inout)::  cx(...)
226   real(kind=8), intent(inout)::  cy(...)
288   dt = bdt / real(n_split)                       ! acoustic substep = outer dt / n_split
363   mfx(:,:,:) = 0.0  ;  mfy = 0  ;  cx = 0  ;  cy = 0    ! (lines 363-366) zero ONCE, pre-loop
390   do it=1,n_split                                ! THE ACOUSTIC LOOP
...
510      call c_sw(...)                              ! C-grid fast-wave solver (winds/pressure)
749      call d_sw(... mfx(is,js,k), mfy(is,js,k), cx(is,jsd,k), cy(isd,js,k) ...)  ! D-grid; ACCUMULATES fluxes
...
      enddo                                          ! end acoustic loop
```

- The acoustic loop `do it=1,n_split` (`dyn_core.F90:390`) sub-steps the **fast-wave dynamics**
  (`c_sw` at :510, `d_sw` at :749) at `dt = bdt/n_split` (:288).
- Fluxes are zeroed once **before** the loop (`:363-366`) and **accumulated** inside it: `d_sw`
  receives `mfx,mfy,cx,cy` and adds each substep's contribution (`:749-752`). These are the
  "flux capacitors" (the source's own term, `:221`).
- **Tracers `q` are passed into `dyn_core` (:614) but are NOT arguments to `c_sw`/`d_sw`** — they
  ride along for diagnostics/remap, not acoustic advection. The acoustic substeps move only the
  dynamical state (winds, delp, pt), accumulating the fluxes that the *single* downstream
  `tracer_2d` call then consumes.

### Grain ratio (config)

- `n_split` (acoustic substeps per outer step) and `q_split` (tracer sub-cycles) are passed into
  `fv_dynamics` as arguments (`fv_dynamics.F90:163-164,183-184`); `k_split` from
  `flagstruct%k_split` (`:297`).
- Actual GCHP C180/C720 values are set in the FV3 namelist (`fvcore_layout.rc` / `input.nml`),
  **not in the source tree** — `[INFERRED]` from FV3 conventions: typical `n_split` ≈ 6–14
  (resolution-dependent; rises with resolution), `q_split` often 0 (auto) or a small int,
  `k_split` ≈ 1–4. **To confirm:** dump the resolved `fvcore_layout.rc` from a live C180 run dir.
  The point for the design holds regardless of exact values: tracer transport runs `n_split`×
  *less often* than the acoustic solver.

### Why this is the gate
Because the tracer call sits outside the acoustic loop and consumes only accumulated flux fields,
tracer transport (a) runs at the coarse advective grain and (b) depends on the acoustic solver
**only through `{mfx,mfy,cx,cy}` (+ `delp`/`dp1`)** — a small, well-defined interface. That is
exactly the seam Part D measures. **Had the tracer call been inside `do it=1,n_split`, the seam
would not exist and the decoupled design would be moot. It is not. Proceed.**

---

## PART B — STATE BREAKDOWN BY TIER

Byte model: global field = `6 · C² · npz · 8` bytes (cubed-sphere 6 faces, double precision).
At **C720, npz=72**: one 3-D field = 6·720²·72·8 = **1.79 GB**. (At C180: 6·180²·72·8 = 112 MB.)
Halo cells (`isd:ied` adds ~3-4 ghost rings) inflate per-rank arrays ~5-10% but not the global
science state; ignored for the tier ratio.

### B1 — Flow-solver (dynamical) tier — fields resident, all from `fv_arrays.F90`
Distinct 3-D dynamical fields the acoustic solver carries (citations from `fv_arrays.F90`):

| field | role | dims | line |
|-------|------|------|------|
| u, v | D-grid winds | (isd:ied,jsd:jed+1,npz)/(… ) | 1434,1435 |
| uc, vc | C-grid winds | (…,npz) | 1466,1467 |
| pt | potential temp | (isd:ied,jsd:jed,npz) | 1437 |
| delp | pressure thickness | (isd:ied,jsd:jed,npz) | 1438 |
| w, delz | NH vert vel / thickness | (…,npz) | 1486,1487 |
| mfx,mfy,cx,cy | accumulated flux capacitors | (is:ie+1,…)/… | 1469-1472 |
| pe,pk,peln,pkz | edge/log pressures | (…,npz+1 / npz) | 1444-1447 |

≈ **18 distinct 3-D dynamical fields** (a handful are npz+1 or 2-D; treat as ~18 full fields).
**Flow-solver state ≈ 18 × 1.79 GB ≈ 32 GB global at C720** (≈ 2.0 GB at C180).

### B2 — Tracer tier — the LARGE state
- Tracer array: `q(bd%isd:bd%ied, bd%jsd:bd%jed, npz, ncnst)` — `fv_dynamics.F90:196`;
  allocated `Atm%q(isd:ied,jsd:jed,npz,nq)` — `fv_arrays.F90:1439`.
- `ncnst`/`nq` = advected-species count, sourced from `State_Chm%nAdvect`
  (`state_chm_mod.F90:72,828`), passed FV3-ward via `AdvCore_GridCompMod.F90` (`offline_tracer_advection`, :64).
- GCHP **fullchem advects ≈ 228 species** `[INFERRED — exact count is runtime from the species
  database; confirm with a live nAdvect dump]`. Order-200 is the right magnitude regardless.
- **Tracer state ≈ 228 × 1.79 GB ≈ 408 GB global at C720** (≈ 25.6 GB at C180).

### B3 — The ratio (the anti-correlation, confirmed)
| tier | global bytes @C720 | share |
|------|--------------------|-------|
| flow solver (~18 dyn fields) | ~32 GB | **~7.3%** |
| tracers (~228 species) | ~408 GB | **~92.7%** |

The design predicted ~3% : ~97%. **Direction confirmed, magnitude corrected to ~7% : ~93%.** The
gap from 3% is because FV3 carries ~18 dynamical 3-D fields (not ~5) — C-grid winds, NH fields,
and the pressure-diagnostic set inflate the small tier. Still: **tracer state outweighs flow-solver
state by ~13×**, the qualitative claim (small flow solver, fat tracers) holds decisively. The ratio
also *grows* toward tracers as species count rises (fullchem ≫ TransportTracers); for a 700-species
chemistry it would approach 97%+.

## PART C — TIMER: flow solver vs tracer transport (Amdahl number)

### KEY FINDING: the split timers ALREADY EXIST — minimal/no new code needed.
FV3 is already instrumented with the FMS `timing_on/timing_off` API at exactly the three regions
the spec asks for, in `fv_dynamics.F90`:

| region (spec) | existing bracket | file:line |
|---------------|------------------|-----------|
| (i) acoustic flow solver | `timing_on('DYN_CORE')` … `timing_off('DYN_CORE')` | `fv_dynamics.F90:613,625` (wraps `dyn_core`, which runs the `do it=1,n_split` acoustic loop) |
| (ii) tracer transport | `timing_on('tracer_2d')` … `timing_off('tracer_2d')` | `fv_dynamics.F90:671,690` (wraps `tracer_2d`) |
| (iii) halo within (i) | `timing_on('COMM_TOTAL')` … `timing_off('COMM_TOTAL')` | `fv_dynamics.F90:580/592` and inside `dyn_core.F90` around each `start/complete_group_halo_update` |

So the **flow-solver-vs-tracer split is recoverable from FV3's own FMS timer report with ZERO
source edits** — it only needs the FMS timing report enabled (FV3 `print_timing`/`fv_timing`
nml flag) `[INFERRED — confirm the GCHP nml exposes it; the `timing_on` calls are unconditional,
the *report* is flag-gated]`. This is the lightest possible Part C and avoids touching numerics.

### Optional refinement (default-off, only if FMS granularity insufficient)
If `DYN_CORE` lumps acoustic-solver compute with its internal halos and we need (iii) cleanly
separated from (i)-compute, add **two** default-off `MAPL_TimerOn/Off` brackets — but note
`dyn_core.F90` has **no MAPL_MetaComp in scope** (it's pure FV3), so use the **same FMS
`timing_on('ACOUSTIC_COMM')` idiom already in the file**, gated behind a module logical
`instr_enabled` (read once from an env var, default `.false.`). Candidate insertions
(NOT YET APPLIED — staged for the build):
- `dyn_core.F90:390` (just inside `do it=1,n_split`) / matching `enddo` — bracket
  `'ACOUSTIC_STEP'` to isolate per-substep solver cost.
- around the `start_group_halo_update`/`complete_group_halo_update` pairs inside that loop —
  bracket `'ACOUSTIC_HALO'`.
Each is one `if(instr_enabled) call timing_on(...)` line; zero numeric effect.

### Reported numbers (per node count) — REQUIRES THE BUILD+RUN (Part C is the only build-gated part)
`[PENDING RUN]` — to be filled from the FMS timer report on the instrumented C180 run at 1→2→4
nodes (hpc7g, us-east-1; node counts as capacity allows per the prior capacity study):
- X = wall fraction of (i) DYN_CORE (acoustic flow solver) — **the Amdahl ceiling: max single-fat-
  node speedup ≈ 1/X** if tracers are offloaded and only the flow solver stays coupled.
- (ii) tracer_2d fraction.
- (iii) COMM_TOTAL (halo) as a fraction of (i).
- Whether X grows with node count (acoustic halo cost rising as the cubed-sphere faces subdivide).

## PART D — SEPARABILITY & THE INTER-TIER INTERFACE

### D1 — The interface: exactly what tracer transport needs from the flow solver
`tracer_2d` signature (`fv_tracer2d.F90:336`):
```
subroutine tracer_2d(q, dp1, mfx, mfy, cx, cy, gridstruct, bd, domain, npx,npy,npz, &
                     nq, hord, q_split, dt, id_divg, q_pack, nord_tr, trdm, lim_fac, dpA)
```
Flow-solver-produced inputs consumed: **`{mfx, mfy, cx, cy}` (the accumulated flux capacitors) +
`dp1` (the pre-advection layer pressure thickness)** — plus static `gridstruct`/`bd`/`domain`
(grid geometry & decomposition, not per-step state). **It reads NONE of u, v, pt, w, delz, uc, vc.**
The design hoped the interface was `{mfx,mfy,cx,cy}` (+delp). **Confirmed, with one addition: `dp1`
(=delp snapshot).** So the coarse→fine handoff per outer step is **5 fields, not 4.**

**Interface size per outer step @C720:** `mfx,mfy,cx,cy` are single-layer-staggered ~1.79 GB each,
`dp1` 1.79 GB → **~9 GB global per outer step** (≈0.56 GB at C180). This crosses the tier boundary
**once per `k_split` outer step**, i.e. at the advective grain — *not* per acoustic substep. That's
the quantity an S3/independent-write handoff would materialize; at C180 ~0.56 GB/step is modest,
at C720 ~9 GB/step is the real number to weigh against heartbeat wall-time (the grain ratio).

### D2 — Cross-species coupling: tracers are (almost) per-species fungible
The tracer loop advects each species **independently**:
```
do iq=1,nq                      ! fv_tracer2d.F90:532
   call fv_tp_2d(q(isd,jsd,k,iq), cx(...), cy(...), ... )   ! :534 — independent per species
   q(i,j,k,iq) = (q*dp1 + flux_div)/dp2                     ! :545-548 — independent update
enddo
```
- **Per-species advection** (`fv_tp_2d` per `iq`, `:534`); each species sees the *same* shared
  `{mfx,mfy,cx,cy,dp1}` but no other species. → **fungible across species.**
- **The ONLY cross-species coupling is the shared mass field** `dp1→dp2` (one layer-thickness all
  species divide by) — and `fillz` mass-filling is **also per-species** (`fv_tracer2d.F90:1031`,
  called inside the `iq` loop), not a cross-species borrow. No global pressure-fixer or
  inter-species mass borrowing in the transport step.
- **Verdict:** tracer transport is a **per-species fungible fleet** — you can advect any subset of
  species on any worker, provided each worker has `{mfx,mfy,cx,cy,dp1}`. The shared mass field is a
  *broadcast input*, not a coupling that forces co-residence. (Caveat: GEOS-Chem's *chemistry* and
  any global mass-conservation/pressure-fixer steps OUTSIDE this transport routine may re-couple
  species; this finding is scoped to FV3 tracer *transport* only.)

### D3 — Halo cadence: tracer comms are n_split× looser than acoustic
- **Acoustic halos:** inside `do it=1,n_split` (`dyn_core.F90:390`), multiple per-field
  `start/complete_group_halo_update` per substep (u/v at :393, w at :426, etc.) → **~n_split ×
  (several fields)** halo rounds per outer step.
- **Tracer halos:** inside `do it=1,nsplt` (`fv_tracer2d.F90:501`), **one batched**
  `complete_group_halo_update(q_pack,…)` (:504) + one `start_group_halo_update(q_pack,q,…)` (:570)
  per sub-cycle, **all nq species in a single grouped update**.
- **Ratio:** tracer transport communicates **once per outer step** (× `q_split` sub-cycles, batched
  across all species) vs acoustic **n_split× per outer step, per field**. Tracer halo frequency is
  ~`n_split`× lower and its messages are big-and-batched (latency-tolerant) rather than
  small-and-frequent (latency-bound).
- **Interconnect implication:** the acoustic solver is the EFA-latency-bound part (frequent small
  halos — and recall the *separate* finding that GCHP's MAPL one-sided RMA can't even run over TCP);
  **tracer transport's batched, infrequent, bandwidth-shaped halos are plausibly satisfiable on a
  looser interconnect** `[INFERRED — needs the Part C halo-time measurement + a tracer-only
  non-EFA run to confirm; the structure supports it but the latency sensitivity of `fv_tp_2d`'s
  stencil halos at the advective grain is unmeasured]`.

---

## PART E — SYNTHESIS

**(1) The gate — is the separation real?** **YES, confirmed in source (not inferred).** FV3
sub-steps fast-wave dynamics on the acoustic `do it=1,n_split` loop *inside* `dyn_core`
(`dyn_core.F90:390`), accumulating mass-flux "capacitors" `mfx,mfy,cx,cy` (`:221,363-366,749`);
tracers are advected **once per outer `k_split` step, OUTSIDE that loop**, by a single `tracer_2d`
call (`fv_dynamics.F90:684`) consuming those accumulated fluxes — the source comment says so
verbatim (`:668-670`). Had tracers been inside the acoustic loop the design would be dead; they are
not. **The wall cracks.**

**(2) State split + Amdahl.** Flow-solver state ≈ **7%** (~32 GB @C720, ~18 dyn 3-D fields);
tracers ≈ **93%** (~408 GB @C720, ~228 species) — a ~13× anti-correlation, growing toward tracers
with richer chemistry. So the *fat* tier (tracers) is the loosely-coupled one — exactly the tier
you want to offload to a cheap/elastic fleet, leaving the *small* flow-solver tier on a tight
EFA group. Whether a **single fat node** keeps up depends on the flow-solver wall-fraction **X**
(Part C, `[PENDING RUN]`): max speedup from offloading tracers ≈ **1/X**. If X is small (chemistry/
tracers dominate wall time, as the companion instrumentation study expects), the prize is large
and a single/small EFA flow-solver group suffices; if X is large, a small-EFA-group is still
needed for the acoustic part but the tracer offload still removes the 93%-state from the tight tier.

**(3) The inter-tier interface — S3-friendly at the advective grain?** What crosses: **5 fields
`{mfx,mfy,cx,cy,dp1}`**, **once per outer step** (~0.56 GB @C180, ~9 GB @C720). This is a *small,
fixed, well-defined* payload at the *coarse* grain — far more handoff-friendly than the per-acoustic
-substep state. At C180 it's trivially materializable; at C720 ~9 GB/step must be weighed against
heartbeat wall-time (the grain ratio from the companion study). **Plausibly S3-friendly at C180,
marginal at C720 — confirm against measured heartbeat seconds.**

**(4) Is tracer transport per-species fungible?** **Yes** — each species advects independently via
`fv_tp_2d` (`fv_tracer2d.F90:532-548`); the only shared input is the broadcast mass field
`{dp1}`, and even `fillz` is per-species (`:1031`). No pressure-fixer / mass-borrow couples species
*in the transport step*. So tracer transport is a **fungible per-species fleet**, communicating
~`n_split`× less often than the acoustic solver and in big batched (bandwidth-shaped, not
latency-bound) halos — the profile that *might* tolerate a non-EFA interconnect.

### Top 3 things that would change the verdict
1. **Part C wall-fractions (X) at 1→2→4 nodes** — if the acoustic flow solver `DYN_CORE` is a large
   and *growing* share as nodes increase, the single-fat-node design's Amdahl ceiling bites and you
   need a real EFA flow-solver group, not one node. (Build-gated; the one unmeasured number.)
2. **A tracer-only non-EFA run** — D3 claims tracer halos are latency-tolerant; if `fv_tp_2d`'s
   advective-stencil halos are actually latency-bound at scale, tracer transport still needs EFA and
   the "cheap fleet" economics weaken.
3. **Species re-coupling OUTSIDE transport** — the per-species fungibility is scoped to FV3
   `tracer_2d`. If GEOS-Chem's global mass-conservation / pressure-fixer / chemistry re-couples
   species each heartbeat, the fungible-fleet boundary must sit at the transport step only, and the
   superstep accounting must include a re-coupling cost. (Cross-check in the companion completeness
   study.)

### Diffs applied so far
**NONE.** Part A (kill test), B (state bytes), D (interface/coupling/halo) are pure static source
reading — zero files modified. Part C found the needed timers **already present** (FMS
`timing_on('DYN_CORE'/'tracer_2d'/'COMM_TOTAL')`); only the FMS report-enable flag (config, not
code) and an optional default-off `ACOUSTIC_HALO` bracket remain, staged for the build, not yet
applied. Every change, when made, will be listed with file:line on the instrumentation branch.
