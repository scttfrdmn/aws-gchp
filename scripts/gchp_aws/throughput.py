"""Throughput (sim-days/day) + $/sim-day lookup, provenance-tagged.

Lookup order, weakest-fallback:
  1. exact (cs_res, mechanism, instance, nodes) in benchmarks.json      -> MEASURED
  2. same instance, TT measured but FULLCHEM asked                      -> EXTRAPOLATED
     via fullchem ~= TT / tt_to_fullchem_ratio (single-grid; loud flag)
  3. nothing                                                            -> UNKNOWN (refuse)

$/sim-day = usd_per_hr * 24 * nodes / (sim_days_per_day).
"""

from __future__ import annotations
import json
from pathlib import Path
from typing import Optional, List, Dict, Any
from .provenance import Estimate, MEASURED, EXTRAPOLATED, unknown

_DATA = Path(__file__).parent / "data" / "benchmarks.json"


def _load() -> Dict[str, Any]:
    return json.loads(_DATA.read_text())


_DB = _load()
_TP: List[Dict[str, Any]] = _DB["throughput_points"]
_TT_RATIO = _DB["derived_constants"]["tt_to_fullchem_throughput_ratio"]


def _find(cs_res: int, mechanism: str, instance: str, nodes: int) -> Optional[Dict[str, Any]]:
    for p in _TP:
        if (p["cs_res"] == cs_res and p["mechanism"] == mechanism
                and p["instance"] == instance and p["nodes"] == nodes):
            return p
    return None


def throughput(cs_res: int, mechanism: str, instance: str, nodes: int) -> Estimate:
    """sim-days/day for (cs_res, mechanism, instance, nodes)."""
    p = _find(cs_res, mechanism, instance, nodes)
    if p:
        return Estimate(p["sim_days_per_day"], MEASURED, p["source"], unit="sim-d/day")
    # fullchem via TT ratio (only if we have the TT point at the same instance/scale)
    if mechanism == "fullchem":
        tt = _find(cs_res, "transporttracers", instance, nodes)
        if tt:
            val = tt["sim_days_per_day"] / _TT_RATIO["value"]
            return Estimate(val, EXTRAPOLATED, _TT_RATIO["source"], unit="sim-d/day",
                            note=(f"fullchem = TT({tt['sim_days_per_day']:.0f}) / {_TT_RATIO['value']} "
                                  "[single-grid ratio; the ONLY measured fullchem point is "
                                  "C180/m9g/48r/1N = 7.4 d/d]"))
    return unknown(note="no measured throughput for this (resolution, mechanism, instance, nodes)",
                   unit="sim-d/day")


def usd_per_sim_day(tput: Estimate, usd_per_hr: Optional[float], nodes: int) -> Estimate:
    """$/sim-day = $/hr * 24 * nodes / throughput. UNKNOWN if either input is."""
    if not tput.known or tput.value <= 0:
        return unknown(note="throughput unknown", unit="USD/sim-day")
    if usd_per_hr is None:
        return unknown(note="instance $/hr unknown", unit="USD/sim-day")
    val = usd_per_hr * 24.0 * nodes / tput.value
    # cost confidence inherits the throughput's (a measured $/sim-day may also be tabulated)
    return Estimate(val, tput.confidence, tput.source, unit="USD/sim-day",
                    note="$/hr*24*nodes / throughput" + (f"; {tput.note}" if tput.note else ""))


def measured_usd_per_sim_day(cs_res: int, mechanism: str, instance: str, nodes: int) -> Optional[float]:
    """If the benchmark row tabulated $/sim-day directly, return it (else None)."""
    p = _find(cs_res, mechanism, instance, nodes)
    return p.get("usd_per_sim_day") if p else None
