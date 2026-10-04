# Decoupling-speedup Amdahl ceiling — GATE 0 (Phase 0, desk work, $0)

**Question:** is building the M-workers>N-ranks decoupled work-queue worth it — i.e. is there enough
speedup headroom to justify the medium code change + C180 bring-up?

**Data** (all measured, C180 fullchem / m9g.48xl / 48 ranks / 1 node,
`gchp-run-results-2026-06-28.md:588`):
- transport-only step: **18.4 sim-days/day**
- step where KPP chemistry runs (chem dt 600 s, ~every other 5-min step): **4.3 d/d**
- whole-run cumulative: **7.4 d/d**
- corroborated: chemistry is "~80% of per-step cost, ~45% of memory, no halo (columns independent)"
  (`:49-50`).

**Analysis** (time = 1/throughput):
| quantity | value |
|---|---|
| chemistry share of a **chem-step** | **77%** |
| chemistry share of **total wall** | **60%** |
| asymptotic ceiling (chemistry → 0, transport-bound) | **2.49×** |
| realistic whole-run speedup, chem on 2× cores | 1.43× (10.6 d/d) |
| realistic whole-run speedup, chem on 3× cores | 1.66× (12.3 d/d) |
| realistic whole-run speedup, chem on **4× cores** (48 ranks → 192 chem cores) | **1.81× (13.4 d/d)** |

**Why this is the lever:** 1:1 decoupling gives zero single-node speedup by construction (rank blocks on
a semaphore while its one co-located worker runs — they alternate, never both hot). The only way to win
is to run chemistry on cores transport isn't using. C180 fullchem uses only **48 of 192 cores** (memory-
limited: each *rank* holds the full model state). A chemistry *worker* is light and attaches the *same*
shm buffers (extra workers cost cores, not RAM), so up to ~144 idle cores can do chemistry in parallel
with the 48 transport ranks — that's the M>N work-queue.

**GATE 0 verdict: GO.** Chemistry is 60% of wall (≫ the 15% skip threshold) and the ceiling is 2.49×
(≫ the 1.3× threshold). A realistic ~1.8× whole-run speedup is on the table. Build the M>N extension
(Phase 4).

**Caveat:** these fractions are from the C180/m9g cadence. The Phase-4 demo runs at C90 (memory-feasible
for the decoupled binary) and will report C90's own measured chemistry fraction from its MAPL timers, so
the demonstrated speedup is judged against the *demo config's* ceiling, not C180's.
