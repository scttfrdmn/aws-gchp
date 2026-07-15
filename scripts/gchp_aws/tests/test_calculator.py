"""Tests for the GCHP->AWS calculator. Run: pytest scripts/gchp_aws/tests/ -q
(from repo root, or `cd scripts && python3 -m pytest gchp_aws/tests -q`)."""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))   # repo/scripts on path

from gchp_aws import constraints as C
from gchp_aws import memory as M
from gchp_aws import throughput as T
from gchp_aws import instances as I
from gchp_aws import calculator as CALC
from gchp_aws.provenance import MEASURED, EXTRAPOLATED, UNKNOWN


# ---------------- constraints ----------------

def test_c180_known_valid_layouts():
    # GCHP auto-layout choices, all hard-valid
    for cores, (nx, ny) in [(96, (4, 24)), (192, (4, 48)), (384, (8, 48))]:
        rec = C.recommended_layout(180, cores)
        assert rec is not None and rec.hard_valid()
        assert (rec.nx, rec.ny) == (nx, ny), (cores, rec.nx, rec.ny)

def test_c180_1rank_is_invalid():
    # the mistake made earlier: 1 core can't host C180
    assert C.enumerate_layouts(180, 1) == []

def test_ny_must_be_mult_of_6():
    # 100 cores: NX*NY=100 with NY%6==0 has no hard-valid solution at C180
    assert all(L.ny % 6 == 0 for L in C.enumerate_layouts(180, 100))

def test_tile_min_4():
    # C24 with NX=8 -> tile_x = 24/8 = 3 < 4 -> invalid
    lay = C.Layout(cs_res=24, nx=8, ny=6)
    assert not lay.hard_valid()
    assert any("< 4" in r for r in lay.reasons_invalid())

def test_massflux_caveat():
    # C180 NX=8 -> 180/8=22.5 not integer -> massflux NOT ok, but hard-valid
    lay = C.Layout(cs_res=180, nx=8, ny=24)
    assert lay.hard_valid()
    assert not lay.massflux_ok()
    # C180 NX=6 -> 180/6=30 integer, 180/(24/6=4)=45 integer -> massflux ok
    assert C.Layout(cs_res=180, nx=6, ny=24).massflux_ok()

def test_side_ratio_warning():
    assert C.Layout(cs_res=180, nx=4, ny=24).is_square_ish       # 4:4 ratio 1.0
    assert not C.Layout(cs_res=180, nx=8, ny=12).is_square_ish   # 8:2 ratio 4.0


# ---------------- memory ----------------

def test_memory_anchor_c180_fullchem_1node():
    e = M.per_node_gb(180, "fullchem", 1, 48, "full")
    assert e.confidence == MEASURED
    assert abs(e.value - 556.5) < 1.0        # reproduces the measured high-water

def test_memory_scales_down_with_nodes():
    one = M.per_node_gb(180, "fullchem", 1, 48, "full").value
    two = M.per_node_gb(180, "fullchem", 2, 48, "full").value
    four = M.per_node_gb(180, "fullchem", 4, 48, "full").value
    assert two < one and four < two          # global-state/nodes

def test_memory_fit():
    e1 = M.per_node_gb(180, "fullchem", 1, 48, "full")
    assert M.fits(e1, 768) and not M.fits(e1, 384) and not M.fits(e1, 128)

def test_c24_fullchem_is_extrapolated():
    e = M.per_node_gb(24, "fullchem", 1, 48, "full")
    assert e.confidence == EXTRAPOLATED       # res^2 off the one measured point


# ---------------- throughput + cost ----------------

def test_throughput_measured():
    e = T.throughput(180, "fullchem", "m9g.48xlarge", 1)
    assert e.confidence == MEASURED and abs(e.value - 7.4) < 1e-6

def test_throughput_extrapolated_via_tt_ratio():
    e = T.throughput(180, "fullchem", "c8g.48xlarge", 1)   # TT known, fullchem not
    assert e.confidence == EXTRAPOLATED and e.value > 0

def test_throughput_unknown_refuses():
    e = T.throughput(24, "fullchem", "m9g.48xlarge", 1)
    assert e.confidence == UNKNOWN and e.value is None

def test_cost_formula():
    tp = T.throughput(180, "fullchem", "m9g.48xlarge", 1)   # 7.4 d/d
    cost = T.usd_per_sim_day(tp, 9.39, 1)                    # 9.39*24/7.4
    assert abs(cost.value - (9.39 * 24 / 7.4)) < 1e-6

def test_cost_unknown_when_throughput_unknown():
    tp = T.throughput(24, "fullchem", "m9g.48xlarge", 1)
    assert not T.usd_per_sim_day(tp, 9.39, 1).known


# ---------------- end-to-end (the two acceptance examples) ----------------

def test_exampleA_c180_fullchem_cheapest_top_is_measured_m9g():
    ev = CALC.evaluate(180, "fullchem", "full", 1.0, "cheapest", None, False)
    ranked, refused = CALC._rank(ev["rows"], "cheapest")
    assert refused is None and ranked
    top = ranked[0]
    # confidence guard: the #1 pick must be the MEASURED m9g 1-node, not an extrapolation
    assert top["instance"].name == "m9g.48xlarge" and top["nodes"] == 1
    assert top["cost"].confidence == MEASURED

def test_exampleB_c24_fullchem_fastest_refuses():
    ev = CALC.evaluate(24, "fullchem", "full", 1.0, "fastest", None, False)
    ranked, refused = CALC._rank(ev["rows"], "fastest")
    assert ranked == [] and refused    # refuses to rank on no measured throughput

def test_json_has_provenance_on_every_number():
    ev = CALC.evaluate(180, "fullchem", "full", 1.0, "cheapest", None, False)
    import json
    out = json.loads(CALC.render_json(ev))
    for c in out["candidates"]:
        for key in ("memory_per_node_gb", "throughput_sim_days_per_day", "usd_per_sim_day"):
            cell = c[key]
            assert "confidence" in cell               # never a bare number
            if cell["confidence"] != UNKNOWN:
                assert cell["value"] is not None
