#!/usr/bin/env python3
"""GCHP -> AWS provisioning calculator (forward tool).

Given a simulation intent, estimate the AWS provisioning answer: per-node memory,
valid grid layouts, which instances fit, throughput + $/sim-day, and the derived
config guardrails. Every number is tagged MEASURED/INTERPOLATED/EXTRAPOLATED/UNKNOWN
with a source. Where there's no basis it prints UNKNOWN and refuses to rank.

Usage:
  gchp-aws-calc --cs-res 180 --mechanism fullchem --sim-days 1 --history full --mode cheapest
  gchp-aws-calc --cs-res 24  --mechanism fullchem --mode fastest --json
"""

from __future__ import annotations
import argparse
import json
import sys
from typing import List, Optional, Dict, Any

from . import memory as M
from . import throughput as T
from . import instances as I
from . import constraints as C
from .provenance import Estimate


def _candidate_node_counts(mode: str, fixed_nodes: Optional[int]) -> List[int]:
    if fixed_nodes:
        return [fixed_nodes]
    return [1, 2, 4]   # the node counts we have any data for


def _rpn_for(instance: I.Instance, mechanism: str) -> int:
    """Ranks per node to model. Fullchem is memory-heavy -> the measured 48;
    TT -> the measured 60; capped at physical cores."""
    base = 48 if mechanism == "fullchem" else 60
    return min(base, instance.cores)


def evaluate(cs_res: int, mechanism: str, history: str, sim_days: float,
             mode: str, fixed_nodes: Optional[int], massflux: bool) -> Dict[str, Any]:
    """Build the full evaluation across the instance catalog. Pure data (no I/O)."""
    catalog = I.load_catalog()
    rows: List[Dict[str, Any]] = []

    for inst in catalog:
        for nodes in _candidate_node_counts(mode, fixed_nodes):
            rpn = _rpn_for(inst, mechanism)
            total_cores = rpn * nodes
            mem = M.per_node_gb(cs_res, mechanism, nodes, rpn, history)
            fits = M.fits(mem, inst.ram_gb)
            if not fits:
                continue
            layout = C.recommended_layout(cs_res, total_cores, massflux=massflux)
            tput = T.throughput(cs_res, mechanism, inst.name, nodes)
            # prefer a directly-tabulated $/sim-day if present, else compute
            tab = T.measured_usd_per_sim_day(cs_res, mechanism, inst.name, nodes)
            if tab is not None:
                cost = Estimate(tab, tput.confidence, tput.source, unit="USD/sim-day")
            else:
                cost = T.usd_per_sim_day(tput, inst.usd_per_hr, nodes)
            rows.append({
                "instance": inst, "nodes": nodes, "rpn": rpn, "total_cores": total_cores,
                "mem": mem, "layout": layout, "tput": tput, "cost": cost,
            })
    return {"cs_res": cs_res, "mechanism": mechanism, "history": history,
            "sim_days": sim_days, "mode": mode, "massflux": massflux, "rows": rows}


from .provenance import MEASURED as _MEAS


def _rank(rows: List[Dict[str, Any]], mode: str):
    """Return (ranked_rows, refused_reason). Refuses (empty rank) when the mode's
    key metric is UNKNOWN for every candidate.

    Confidence-aware: a MEASURED result is never out-ranked by a merely-EXTRAPOLATED
    one unless the extrapolated is >20% better on the key metric — so a directional
    guess can't unseat a hard measurement on a rounding-level difference."""
    def keymetric(r, mode):
        return r["cost"] if mode != "fastest" else r["tput"]

    if mode == "cheapest":
        known = [r for r in rows if r["cost"].known]
        if not known:
            return [], "no candidate has a known $/sim-day (throughput UNKNOWN)"
        ranked = sorted(known, key=lambda r: (r["cost"].value, 0 if r["cost"].confidence == _MEAS else 1))
    elif mode == "fastest":
        known = [r for r in rows if r["tput"].known]
        if not known:
            return [], "no candidate has a known throughput (cannot rank 'fastest')"
        ranked = sorted(known, key=lambda r: (-r["tput"].value, 0 if r["tput"].confidence == _MEAS else 1))
    else:  # fits-in-nodes
        return sorted(rows, key=lambda r: (r["cost"].value if r["cost"].known else 1e18,
                                           r["mem"].value)), None

    # Confidence guard: if the #1 is EXTRAPOLATED but a MEASURED option exists within
    # 20% on the key metric, promote the measured one (don't trust a guess over a fact).
    if ranked and keymetric(ranked[0], mode).confidence != _MEAS:
        measured = [r for r in ranked if keymetric(r, mode).confidence == _MEAS]
        if measured:
            top_v = keymetric(ranked[0], mode).value
            best_meas = measured[0]
            mv = keymetric(best_meas, mode).value
            better = (mv <= top_v * 1.2) if mode != "fastest" else (mv >= top_v * 0.8)
            if better:
                ranked.remove(best_meas)
                ranked.insert(0, best_meas)
    return ranked, None


def _guardrails(cs_res: int, mechanism: str, inst: I.Instance, layout, mem: Estimate) -> Dict[str, Any]:
    return {
        "stack": inst.stack, "s3_stack": I.s3_stack_path(inst.stack),
        "nx": layout.nx if layout else None, "ny": layout.ny if layout else None,
        "domains_stack_size": M.domains_stack_size(cs_res, layout),
        "dev_shm": M.dev_shm_gb(cs_res, mechanism, mem),
    }


# ----------------------------- rendering -----------------------------------

def render_text(ev: Dict[str, Any]) -> str:
    L = []
    L.append("=" * 74)
    L.append("GCHP -> AWS PROVISIONING PLAN")
    L.append("=" * 74)
    L.append(f"Intent: C{ev['cs_res']} {ev['mechanism']}, {ev['sim_days']} sim-day(s), "
             f"{ev['history']} HISTORY, mode={ev['mode']}"
             + (", mass-flux met" if ev['massflux'] else ""))
    L.append("")

    ranked, refused = _rank(ev["rows"], ev["mode"])

    if not ev["rows"]:
        L.append("NO instance in the catalog fits this configuration's memory.")
        L.append("  -> scale to more nodes (memory is global-state/nodes), or reduce resolution.")
        L.append("=" * 74)
        return "\n".join(L)

    if refused:
        L.append(f"*** REFUSING TO RANK '{ev['mode']}': {refused}. ***")
        L.append("    Honesty guard: no measured basis -> not guessing. What IS measured:")
        for r in ev["rows"]:
            if r["tput"].known:
                L.append(f"      {r['instance'].name} {r['nodes']}N: {r['tput'].render('{:.1f}')}")
        L.append("    -> run the benchmark for this config, or use --mechanism transporttracers "
                 "(more measured points).")
        L.append("")
        L.append("Configurations that at least FIT in memory (unranked):")
        ranked = sorted(ev["rows"], key=lambda r: (r["nodes"], r["instance"].name))

    n_show = len(ranked) if refused else min(len(ranked), 4)
    for i, r in enumerate(ranked[:n_show], 1):
        inst, nodes = r["instance"], r["nodes"]
        tag = f"#{i} " if not refused else "   "
        L.append(f"{tag}{inst.name}  {nodes}N x {r['rpn']}r = {r['total_cores']} cores  "
                 f"{inst.ram_gb}GB {inst.arch} {'EFA' if inst.efa else 'ENA'}  ${inst.usd_per_hr}/hr")
        L.append(f"     memory/node : {r['mem'].render('{:.0f}')}")
        lay = r["layout"]
        if lay:
            warn = "" if lay.is_square_ish else f"  [side-ratio {lay.side_ratio:.1f} >= 2.5 WARNING]"
            mf = "" if (not ev["massflux"] or lay.massflux_ok()) else "  [mass-flux: NOT evenly divisible]"
            L.append(f"     layout      : NX={lay.nx} NY={lay.ny} (tile {lay.tile_x:.0f}x{lay.tile_y:.0f}){warn}{mf}")
        else:
            L.append(f"     layout      : none valid at {r['total_cores']} cores")
        L.append(f"     throughput  : {r['tput'].render('{:.1f}')}")
        L.append(f"     $/sim-day   : {r['cost'].render('{:.2f}')}")
        if not inst.offered_use1:
            L.append(f"     WARNING: {inst.name} NOT offered in us-east-1")
        if "scarce" in inst.notes or "capacity" in inst.notes:
            L.append(f"     WARNING: capacity note — {inst.notes}")
        # config guardrails for the top pick
        if i == 1 and not refused and lay:
            g = _guardrails(ev["cs_res"], ev["mechanism"], inst, lay, r["mem"])
            L.append(f"     CONFIG GUARDRAILS:")
            L.append(f"       stack               : {g['stack']}  {g['s3_stack']}")
            L.append(f"       NX,NY               : {g['nx']},{g['ny']}")
            L.append(f"       domains_stack_size  : {g['domains_stack_size'].render('{:.0f}')}")
            L.append(f"       /dev/shm            : {g['dev_shm'].render('{:.0f}')}")
        L.append("")

    L.append("=" * 74)
    L.append("Legend: [MEASURED]=from a benchmark run  [INTERPOLATED]=between measured points")
    L.append("        [EXTRAPOLATED]=outside measured range (directional)  [UNKNOWN]=no basis")
    L.append("=" * 74)
    return "\n".join(L)


def render_json(ev: Dict[str, Any]) -> str:
    ranked, refused = _rank(ev["rows"], ev["mode"])
    out = {
        "intent": {k: ev[k] for k in ("cs_res", "mechanism", "history", "sim_days", "mode", "massflux")},
        "refused_to_rank": refused,
        "candidates": [],
    }
    src = ranked if not refused else ev["rows"]
    for r in src:
        inst, lay = r["instance"], r["layout"]
        g = _guardrails(ev["cs_res"], ev["mechanism"], inst, lay, r["mem"]) if lay else {}
        out["candidates"].append({
            "instance": inst.name, "arch": inst.arch, "nodes": r["nodes"], "rpn": r["rpn"],
            "total_cores": r["total_cores"], "usd_per_hr": inst.usd_per_hr,
            "offered_use1": inst.offered_use1,
            "memory_per_node_gb": r["mem"].to_dict(),
            "layout": ({"nx": lay.nx, "ny": lay.ny, "square_ish": lay.is_square_ish,
                        "side_ratio": round(lay.side_ratio, 2),
                        "massflux_ok": lay.massflux_ok()} if lay else None),
            "throughput_sim_days_per_day": r["tput"].to_dict(),
            "usd_per_sim_day": r["cost"].to_dict(),
            "guardrails": ({"stack": g["stack"], "s3_stack": g["s3_stack"], "nx": g["nx"], "ny": g["ny"],
                            "domains_stack_size": g["domains_stack_size"].to_dict("{:.0f}"),
                            "dev_shm_gb": g["dev_shm"].to_dict("{:.0f}")} if g else None),
        })
    return json.dumps(out, indent=2)


def main(argv=None):
    ap = argparse.ArgumentParser(description="GCHP -> AWS provisioning calculator")
    ap.add_argument("--cs-res", type=int, required=True, help="cubed-sphere resolution, e.g. 24/48/90/180/360")
    ap.add_argument("--mechanism", choices=["fullchem", "transporttracers"], required=True)
    ap.add_argument("--sim-days", type=float, default=1.0, help="simulation length in days")
    ap.add_argument("--history", choices=["full", "minimal", "none"], default="full")
    ap.add_argument("--mode", choices=["cheapest", "fastest", "fits-in-nodes"], default="cheapest")
    ap.add_argument("--nodes", type=int, default=None, help="fixed node count (required for fits-in-nodes)")
    ap.add_argument("--met", choices=["standard", "massflux"], default="standard")
    ap.add_argument("--json", action="store_true", help="machine-readable output (blog table)")
    args = ap.parse_args(argv)

    if args.mode == "fits-in-nodes" and not args.nodes:
        ap.error("--mode fits-in-nodes requires --nodes N")

    ev = evaluate(args.cs_res, args.mechanism, args.history, args.sim_days,
                  args.mode, args.nodes, massflux=(args.met == "massflux"))
    print(render_json(ev) if args.json else render_text(ev))
    return 0


if __name__ == "__main__":
    sys.exit(main())
