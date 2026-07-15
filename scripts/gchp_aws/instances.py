"""Instance catalog + fit logic."""

from __future__ import annotations
import json
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Dict, Any

_DATA = Path(__file__).parent / "data" / "instances.json"


@dataclass
class Instance:
    name: str
    arch: str
    gen: str
    cores: int
    ram_gb: int
    net_gbps: int
    efa: bool
    stack: str
    usd_per_hr: Optional[float]
    price_confidence: str
    price_date: str
    offered_use1: bool
    notes: str = ""

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "Instance":
        return cls(
            name=d["name"], arch=d["arch"], gen=d.get("gen", ""), cores=d["cores"],
            ram_gb=d["ram_gb"], net_gbps=d.get("net_gbps", 0), efa=d.get("efa", False),
            stack=d["stack"], usd_per_hr=d.get("usd_per_hr"),
            price_confidence=d.get("price_confidence", "unknown"),
            price_date=d.get("price_date", ""), offered_use1=d.get("offered_use1", True),
            notes=d.get("notes", ""))


def load_catalog(path: Path = _DATA) -> List[Instance]:
    raw = json.loads(path.read_text())
    return [Instance.from_dict(x) for x in raw["instances"]]


def s3_stack_path(stack: str) -> str:
    return f"s3://gchp-shared-storage-us-east-1/stacks/{stack}/gchp14.7.1-validated/"
