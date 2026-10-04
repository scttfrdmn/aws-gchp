"""GCHP cubed-sphere grid-layout constraints — the shared core.

This is the single source of truth for GCHP's domain-decomposition rules, used by
BOTH the forward calculator (gchp_aws.calculator) and the backward validator
(scripts/validate_gchp_config.py). Extracted from the latter's original checks so
the two can never drift.

The rules (authoritative, from GCHP setCommonRunSettings.sh / createRunDir):
  TOTAL_CORES = NX * NY          (the 6 cubed-sphere faces are folded into NY)
  NY % 6 == 0
  CS_RES / NX  >= 4              (>=4 grid points per tile in X;  IM = CS_RES)
  CS_RES*6 / NY >= 4             (>=4 in Y;  JM = CS_RES*6, so equivalently CS_RES/(NY/6) >= 4)
  square-ish preferred: per-face tile aspect NX : (NY/6) should be < 2.5 or a
    "side ratio" WARNING fires (not fatal).
  mass-flux met inputs ONLY: additionally CS_RES % NX == 0 and CS_RES % (NY/6) == 0.
"""

from __future__ import annotations
from dataclasses import dataclass
from typing import List, Optional

NZ_LEVELS = 72
SIDE_RATIO_WARN = 2.5


@dataclass
class Layout:
    cs_res: int
    nx: int
    ny: int
    @property
    def total_cores(self) -> int:
        return self.nx * self.ny
    @property
    def tile_x(self) -> float:          # grid points per tile in X
        return self.cs_res / self.nx
    @property
    def tile_y(self) -> float:          # grid points per tile in Y (per face)
        return (self.cs_res * 6) / self.ny
    @property
    def faces_per_ny(self) -> int:
        return self.ny // 6
    @property
    def side_ratio(self) -> float:
        """Per-face tile aspect ratio NX : (NY/6), always >= 1."""
        a, b = self.nx, max(self.faces_per_ny, 1)
        return max(a, b) / min(a, b)
    @property
    def is_square_ish(self) -> bool:
        return self.side_ratio < SIDE_RATIO_WARN
    def massflux_ok(self) -> bool:
        """Even-divisibility rule that applies ONLY to mass-flux met inputs."""
        return (self.cs_res % self.nx == 0) and (self.cs_res % max(self.faces_per_ny, 1) == 0)

    def hard_valid(self) -> bool:
        return (self.ny % 6 == 0 and self.tile_x >= 4 and self.tile_y >= 4
                and self.nx >= 1 and self.ny >= 6)

    def reasons_invalid(self) -> List[str]:
        r = []
        if self.ny % 6 != 0:
            r.append(f"NY={self.ny} not divisible by 6")
        if self.tile_x < 4:
            r.append(f"CS/NX = {self.cs_res}/{self.nx} = {self.tile_x:.2f} < 4")
        if self.tile_y < 4:
            r.append(f"CS*6/NY = {self.cs_res*6}/{self.ny} = {self.tile_y:.2f} < 4")
        return r


def check_layout(cs_res: int, nx: int, ny: int, massflux: bool = False) -> Layout:
    """Build a Layout (inspect .hard_valid(), .reasons_invalid(), .massflux_ok())."""
    return Layout(cs_res=cs_res, nx=nx, ny=ny)


def enumerate_layouts(cs_res: int, total_cores: int,
                      massflux: bool = False) -> List[Layout]:
    """All hard-valid (NX,NY) with NX*NY == total_cores, best (most square) first.

    massflux only affects sorting/annotation via .massflux_ok(); a layout that is
    hard-valid is still returned (callers decide whether to require massflux_ok).
    """
    out: List[Layout] = []
    for nx in range(1, total_cores + 1):
        if total_cores % nx:
            continue
        ny = total_cores // nx
        lay = Layout(cs_res=cs_res, nx=nx, ny=ny)
        if lay.hard_valid():
            out.append(lay)
    # most-square first; tie-break prefer massflux-ok when requested
    out.sort(key=lambda L: (L.side_ratio, 0 if (not massflux or L.massflux_ok()) else 1))
    return out


def _gchp_auto_nxny(total_cores: int) -> Optional[tuple]:
    """Reproduce GCHP's AutoUpdate_NXNY algorithm: Z = TOTAL/6, take the integer
    sqrt, walk DOWN to the nearest divisor of Z -> NX, then NY = (Z/NX)*6. This is
    what GCHP itself picks when AutoUpdate_NXNY=ON, so the calculator's default
    layout matches the model's own choice (e.g. C180/192 -> NX=4, NY=48)."""
    if total_cores % 6:
        return None
    z = total_cores // 6
    n = int(z ** 0.5)
    while n > 1 and z % n:
        n -= 1
    nx = n
    ny = (z // nx) * 6
    return (nx, ny)


def recommended_layout(cs_res: int, total_cores: int,
                       massflux: bool = False) -> Optional[Layout]:
    """The recommended layout. Default = GCHP's own AutoUpdate_NXNY choice, if that
    is hard-valid (and massflux-ok when required); otherwise the most-square valid
    layout from the full enumeration."""
    auto = _gchp_auto_nxny(total_cores)
    if auto:
        lay = Layout(cs_res=cs_res, nx=auto[0], ny=auto[1])
        if lay.hard_valid() and (not massflux or lay.massflux_ok()):
            return lay
    lays = enumerate_layouts(cs_res, total_cores, massflux=massflux)
    if massflux:
        ok = [L for L in lays if L.massflux_ok()]
        if ok:
            return ok[0]
    return lays[0] if lays else None


def valid_core_counts(cs_res: int, lo: int, hi: int) -> List[int]:
    """Core counts in [lo,hi] that admit at least one hard-valid layout."""
    return [c for c in range(lo, hi + 1) if enumerate_layouts(cs_res, c)]
