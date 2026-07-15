#!/usr/bin/env python3
"""Append a measured benchmark result to data/benchmarks.json, with provenance.

Kills the hand-copy step: parse a matrix-run SLURM log (its RESULT_* lines), compute
$/sim-day from the instance catalog, and append one confidence:"measured" row citing
the log as source. Idempotent (skips an existing (res,mech,instance,nodes,rpn) row
unless --force). Re-loads the JSON after writing (integrity gate) so a malformed
write fails loudly instead of corrupting the canonical table.

Usage:
  append_benchmark.py --log slurm-c180_n2x60-1234.log --instance c8g.48xlarge \
      --mechanism transporttracers [--date 2026-07-15] [--force] [--dry-run]

The SLURM log must contain the lines gchp-matrix-run.sh emits:
  RESULT_NODES=<n> RESULT_RANKS=<total> RESULT_CS=<cs> RESULT_DAYS=<d>
  INTERNAL_THROUGHPUT_AVG=<dd>
"""

from __future__ import annotations
import argparse
import json
import re
import sys
from pathlib import Path

_DATA = Path(__file__).parent / "data" / "benchmarks.json"
_INST = Path(__file__).parent / "data" / "instances.json"


def _parse_log(text: str) -> dict:
    def grab(pat, cast=str, required=True):
        m = re.search(pat, text)
        if not m:
            if required:
                raise ValueError(f"log missing pattern {pat!r}")
            return None
        return cast(m.group(1))
    nodes = grab(r"RESULT_NODES=(\d+)", int)
    total = grab(r"RESULT_RANKS=(\d+)", int)
    cs = grab(r"RESULT_CS=(\d+)", int)
    avg = grab(r"INTERNAL_THROUGHPUT_AVG=([0-9.]+)", float)
    status_ok = "RUN_STATUS=SUCCEEDED" in text
    return {"nodes": nodes, "total_ranks": total, "cs_res": cs,
            "sim_days_per_day": avg, "ranks_per_node": total // nodes,
            "succeeded": status_ok}


def _usd_per_hr(instance: str) -> float | None:
    for i in json.loads(_INST.read_text())["instances"]:
        if i["name"] == instance:
            return i.get("usd_per_hr")
    raise ValueError(f"instance {instance!r} not in instances.json")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True, type=Path)
    ap.add_argument("--instance", required=True)
    ap.add_argument("--mechanism", required=True, choices=["transporttracers", "fullchem"])
    ap.add_argument("--date", default="")
    ap.add_argument("--force", action="store_true", help="overwrite an existing matching row")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    parsed = _parse_log(args.log.read_text())
    if not parsed["succeeded"]:
        print(f"REFUSING: {args.log} is not RUN_STATUS=SUCCEEDED — not recording a failed run", file=sys.stderr)
        return 2

    dd = parsed["sim_days_per_day"]
    uhr = _usd_per_hr(args.instance)
    usd_per_sim_day = round(uhr * 24.0 * parsed["nodes"] / dd, 4) if (uhr and dd) else None

    row = {
        "cs_res": parsed["cs_res"], "mechanism": args.mechanism, "instance": args.instance,
        "nodes": parsed["nodes"], "ranks_per_node": parsed["ranks_per_node"],
        "total_ranks": parsed["total_ranks"], "sim_days_per_day": dd,
        "confidence": "measured",
        "source": {"file": f"scripts/logs/{args.log.name}", "line": 1, "date": args.date},
    }
    if usd_per_sim_day is not None:
        row["usd_per_sim_day"] = usd_per_sim_day

    db = json.loads(_DATA.read_text())
    key = lambda r: (r.get("cs_res"), r.get("mechanism"), r.get("instance"),
                     r.get("nodes"), r.get("ranks_per_node"))
    tp = db["throughput_points"]
    existing = [i for i, r in enumerate(tp) if isinstance(r, dict) and key(r) == key(row)]
    action = "append"
    if existing:
        if not args.force:
            print(f"SKIP: row for {key(row)} already exists (use --force to overwrite)")
            return 0
        tp[existing[0]] = row; action = "overwrite"
    else:
        tp.append(row)

    if args.dry_run:
        print(f"DRY-RUN would {action}: {json.dumps(row)}")
        return 0

    _DATA.write_text(json.dumps(db, indent=2) + "\n")
    # integrity gate: re-load + assert every throughput row is a dict
    check = json.loads(_DATA.read_text())["throughput_points"]
    assert all(isinstance(r, dict) for r in check), "non-dict row after write!"
    print(f"{action.upper()}: {args.instance} C{row['cs_res']} {args.mechanism} "
          f"{row['nodes']}N/{row['ranks_per_node']}r -> {dd} d/d, "
          f"${usd_per_sim_day}/sim-day  ({len(check)} rows total)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
