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

**Findings:**
- **Graviton dominates decisively** — c8g (Graviton4) and m9g (Graviton5) beat the fastest x86 (Intel
  Emerald c8i) by **3–6×** at equal core count across the ladder. AMD (c7a/c8a) and Intel trail closely
  behind each other and well behind Graviton.
- **Graviton4 vs Graviton5 swaps with resolution.** c8g (G4) wins C24 (clock-bound, tiny per-rank work);
  m9g (G5) wins C48/C90 (once there's real work per rank). m9g's *unique* advantage is **memory
  capacity** (768 GB) — it is the only in-region box that fits C180 fullchem at all.
- At C24 the workload is init/comms-bound (m9g's internal integrate-rate was 15000 d/d but wall was
  overhead-dominated), so small-resolution rankings are **not** predictive of production (C180) behavior.

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

---

## 5. What this means for a GCHP-on-AWS user

- **Pick by memory first, then throughput.** C180 fullchem → m9g (only ≥768 GB in-region). C90/C48
  fullchem → any 384 GB box (c8g best value). TT at any resolution → hpc7g (cheapest $/sim-day).
- **Prefer Graviton.** 3–6× the x86 throughput at equal cores, and the cheapest $/sim-day at every cell.
- **Don't over-decompose fullchem.** Adding ranks past the memory-optimal point slows it or OOMs it
  (C180: 48r is faster than 96r and 192r OOMs). Match ranks to the memory-feasible layout.
- **Decoupling is a real lever at production resolution**, where chemistry is 60–74% of the wall and the
  idle cores are otherwise stranded — up to ~2.2× today, more with more cores.

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
