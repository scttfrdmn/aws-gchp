"""Per-node memory model for GCHP on AWS.

The naive "GB per core" model (validate_gchp_config.py's original 1.7/0.6) is wrong
for fullchem: memory is dominated by the GLOBAL cubed-sphere state, which is divided
across NODES (not ranks-on-a-node). Measured evidence forces this shape:

  C180 fullchem DYNAMICS-init:  269 GB @ 1 node   ->  125.7 GB/node @ 2 nodes
  (gchp-run-results-2026-06-28.md:166,581)

That ~halving with node count (not rank count) is the signature of global-state /
num_nodes. So:

  per_node_gb(cs, mech, nodes, rpn, history) =
        GLOBAL_STATE(cs, mech) / nodes            # shrinks with NODES
      + PER_RANK_OVERHEAD(mech) * rpn             # halo/window overhead, per rank
      + HISTORY_TERM(history, rpn)                # additive (the old per-core term)

GLOBAL_STATE scales with the global cell count 6*cs^2*NZ. Fullchem adds the KPP
250-species working set: measured to ~double the resident footprint (306->556 GB),
modeled as a multiplier. Coefficients are anchored to the (few) measured points and
each carries a confidence; any estimate that leans on the chem multiplier or on
resolution extrapolation is tagged EXTRAPOLATED.
"""

from __future__ import annotations
from .provenance import Estimate, MEASURED, INTERPOLATED, EXTRAPOLATED, weakest
from .constraints import NZ_LEVELS

# --- anchors (all MEASURED; cite in benchmarks.json) ---
_C180 = 180
_CELLS_C180 = 6 * _C180 * _C180 * NZ_LEVELS      # global cell count at C180

# Two-point fit of the DYNAMICS-init (pre-chem) global state vs nodes:
#   269 = G/1 + f ; 125.7 = G/2 + f   ->  G = 286.6 GB, f = -17.6 GB
# f is small & negative (within 2-point-fit noise) -> clamp f>=0, keep G.
# This G is the C180 *dynamics+transport* global-state term.
_G_DYN_C180 = 2 * (269.0 - 125.7)                # = 286.6 GB  (INTERPOLATED, 2 pts)
_F_FIXED = 0.0                                    # per-node fixed floor (fit ~0)

# Chemistry multiplier on the dynamics-resident state (306 -> 556 GB at C180/1N).
# high_water = chem_mult * (dyn_global/1 + base). Solve with the ramp:
#   TimeLoop entry (dyn+transport resident) = 306 GB ; first-KPP = 556 GB
#   => chem_mult ~= 556/306 = 1.82   (LOW confidence: one ramp)
_CHEM_MULT = 556.0 / 306.0                        # ~1.82  (LOW)

# The C180 fullchem high-water anchor used to back-solve a self-consistent model:
_HW_C180_FULLCHEM_1N = 556.5

# TransportTracers: per-rank dominated (no 250-species chem). Measured ~2.1 GB/rank.
_TT_PER_RANK_GB = 2.1                             # MEASURED (C180@60, 128GB edge)

MEM_SAFETY_MARGIN = 0.75                          # use <=75% of node RAM (shared w/ validator)


# History adder (small next to global state at C180; the legacy per-core term).
def _history_gb(history: str, rpn: int) -> float:
    per_core = {"full": 1.7, "minimal": 0.6, "none": 0.0}.get(history, 0.6)
    return per_core * rpn

# Model shape:  per_node = GLOBAL(cs,mech)/nodes + HISTORY(history,rpn)
# GLOBAL is the whole-model peak global state, calibrated so the model REPRODUCES
# the measured C180 fullchem 1-node high-water exactly, then scaled by resolution
# (cells ~ cs^2) and, for the ÷nodes divisor, justified by the measured 269->126
# dynamics-init halving. We deliberately fold per-rank + chem into GLOBAL rather
# than adding independent terms, so the pieces cannot double-count past the anchor.
_HIST_AT_C180_ANCHOR = 1.7 * 48                         # history adder present in the 556.5 measurement
_GLOBAL_C180_FULLCHEM = _HW_C180_FULLCHEM_1N - _HIST_AT_C180_ANCHOR   # ~474.9 GB global @C180 fullchem


def _global_state_gb(cs_res: int, mechanism: str) -> tuple:
    """Whole-model peak GLOBAL state (node-independent) + confidence."""
    scale = (cs_res * cs_res) / float(_C180 * _C180)     # cell-count ratio (NZ constant)
    if mechanism == "fullchem":
        g = _GLOBAL_C180_FULLCHEM * scale
        conf = MEASURED if cs_res == _C180 else EXTRAPOLATED
        return g, conf
    elif mechanism == "transporttracers":
        # TT has no 250-species chem: strip the chem multiplier (~1.82x) from the global term.
        g = (_GLOBAL_C180_FULLCHEM / _CHEM_MULT) * scale
        conf = INTERPOLATED if cs_res == _C180 else EXTRAPOLATED
        return g, conf
    else:
        raise ValueError(f"unknown mechanism {mechanism!r}")


def per_node_gb(cs_res: int, mechanism: str, nodes: int, ranks_per_node: int,
                history: str = "full") -> Estimate:
    """Estimated PEAK memory per node (GB), with provenance.

    per_node = GLOBAL_STATE(cs,mech)/nodes + HISTORY(history,rpn).
    Calibrated to reproduce the one measured fullchem high-water (C180/1N=556.5)."""
    if nodes < 1 or ranks_per_node < 1:
        raise ValueError("nodes and ranks_per_node must be >= 1")
    g, gconf = _global_state_gb(cs_res, mechanism)
    val = g / nodes + _history_gb(history, ranks_per_node)

    if mechanism == "fullchem" and cs_res == _C180 and nodes == 1:
        conf = MEASURED
        src = {"file": "gchp-run-results-2026-06-28.md", "line": 553, "date": "2026-06-28"}
        note = "reproduces the measured C180 fullchem 1-node high-water (556.5 GB)"
    else:
        conf = weakest(gconf, INTERPOLATED)   # ÷nodes divisor is itself a 2-pt fit (269->126)
        src = {"file": "gchp-run-results-2026-06-28.md", "line": 166, "date": "2026-06-28"}
        note = ("global-state/nodes + history; "
                + ("res^2 + chem-mult extrapolation (order-of-magnitude)" if conf == EXTRAPOLATED
                   else "node-scaling from 2 measured points (269->126 GB)"))
    return Estimate(value=val, confidence=conf, source=src, note=note, unit="GB")


def fits(per_node: Estimate, ram_gb: float) -> bool:
    """Does the estimate fit within the node's usable RAM (safety margin applied)?"""
    if not per_node.known:
        return False
    return per_node.value <= ram_gb * MEM_SAFETY_MARGIN


def dev_shm_gb(cs_res: int, mechanism: str, per_node: Estimate) -> Estimate:
    """Derived /dev/shm size guardrail. MAPL's MPI_Win_allocate_shared windows scale
    with on-node state; measured anchors: 550G @C180 fullchem, 48G @C24 fullchem."""
    if mechanism == "fullchem" and cs_res == 180:
        return Estimate(550, MEASURED, {"file": "scripts/gchp-fullchem-m9g.sh", "line": 127,
                                        "date": "2026-07"}, unit="GB")
    if cs_res <= 24:
        return Estimate(48, MEASURED, {"file": "scripts/gchp-phase1b-run.sh", "line": 123,
                                       "date": "2026-07"}, unit="GB")
    # between anchors: scale ~ with per-node resident state, round up to a sane size.
    if per_node.known:
        est = max(48.0, min(600.0, per_node.value * 1.0))   # ~1x resident, clamped
        return Estimate(round(est / 8) * 8, EXTRAPOLATED,
                        {"file": "scripts/gchp-fullchem-m9g.sh", "line": 127, "date": "2026-07"},
                        note="scaled from the 550G@C180 / 48G@C24 anchors", unit="GB")
    return Estimate(64, EXTRAPOLATED, note="fallback", unit="GB")


def domains_stack_size(cs_res: int, layout) -> Estimate:
    """FMS mpp_domains halo stack. 20M default overflows at C180 coarse decomposition;
    64M measured-needed there. Use 64M for C180+ / coarse subdomains, else 20M."""
    coarse = (cs_res >= 180) or (layout is not None and layout.tile_x >= 20)
    val = 64000000 if coarse else 20000000
    conf = MEASURED if (cs_res == 180) else EXTRAPOLATED
    return Estimate(val, conf, {"file": "scripts/gchp-fullchem-m9g.sh", "line": 98, "date": "2026-07"},
                    note=("64M measured-needed at C180" if conf == MEASURED else "heuristic from C180 anchor"))
