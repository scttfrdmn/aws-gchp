"""Provenance tagging — the honesty core of the calculator.

Every numeric answer the calculator produces is an `Estimate`: a value plus a
confidence level plus (where applicable) the source it came from. This is what
lets the tool ship despite thin data — it never presents a guess as a fact.

Confidence levels (ordered weakest->strongest for display):
  UNKNOWN      — no basis; value is None; the tool refuses to rank/recommend on it.
  EXTRAPOLATED — computed outside the range of any measured point (e.g. fullchem
                 throughput via the TT ratio; fullchem memory at an unmeasured
                 resolution). Directional only.
  INTERPOLATED — between two measured points (or a small multi-point fit).
  MEASURED     — a value read directly from a benchmark run.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional, Any, Dict

MEASURED = "MEASURED"
INTERPOLATED = "INTERPOLATED"
EXTRAPOLATED = "EXTRAPOLATED"
UNKNOWN = "UNKNOWN"

# strongest -> weakest, for picking the overall confidence of a derived value
_RANK = {MEASURED: 3, INTERPOLATED: 2, EXTRAPOLATED: 1, UNKNOWN: 0}


@dataclass
class Estimate:
    """A number with its provenance. value is None iff confidence == UNKNOWN."""
    value: Optional[float]
    confidence: str
    source: Optional[Dict[str, Any]] = None   # {"file":..., "line":..., "date":...}
    note: str = ""
    unit: str = ""

    def __post_init__(self):
        if self.confidence not in _RANK:
            raise ValueError(f"bad confidence {self.confidence!r}")
        if self.confidence == UNKNOWN:
            self.value = None
        elif self.value is None:
            raise ValueError("non-UNKNOWN Estimate must have a value")

    @property
    def known(self) -> bool:
        return self.confidence != UNKNOWN

    def source_str(self) -> str:
        if not self.source:
            return ""
        f = self.source.get("file", "")
        ln = self.source.get("line")
        d = self.source.get("date", "")
        loc = f"{f}:{ln}" if ln else f
        return f"{loc}" + (f" ({d})" if d else "")

    def render(self, fmt: str = "{:.1f}") -> str:
        """Human string: '556.0 GB [MEASURED gchp-run-results:581 (2026-06-28)]'."""
        if not self.known:
            base = "UNKNOWN"
        else:
            base = fmt.format(self.value) + (f" {self.unit}" if self.unit else "")
        tag = f"[{self.confidence}"
        s = self.source_str()
        if s:
            tag += f"  {s}"
        tag += "]"
        extra = f"  ({self.note})" if self.note else ""
        return f"{base} {tag}{extra}"

    def to_dict(self, fmt: str = "{:.3f}") -> Dict[str, Any]:
        """Machine-readable form for --json output. Always carries provenance."""
        d: Dict[str, Any] = {
            "value": (round(self.value, 6) if self.value is not None else None),
            "confidence": self.confidence,
        }
        if self.unit:
            d["unit"] = self.unit
        if self.source:
            d["source"] = self.source
        if self.note:
            d["note"] = self.note
        return d


def unknown(note: str = "", unit: str = "") -> Estimate:
    return Estimate(value=None, confidence=UNKNOWN, note=note, unit=unit)


def weakest(*confidences: str) -> str:
    """The overall confidence of a value derived from several inputs = the weakest."""
    if not confidences:
        return UNKNOWN
    return min(confidences, key=lambda c: _RANK[c])
