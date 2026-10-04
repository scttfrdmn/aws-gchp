#!/usr/bin/env python3
"""Derive the fullchem input working set from an official GCHP run directory.

WHY. The lith /input analysis is complete except for one gap: every number in it is
C24 TransportTracers, and fullchem reads far more of gcgrid. To measure whether
lith's cold advantage grows, holds or inverts at that scale, I first need to know
WHAT fullchem reads -- and the only non-guessing source is a run directory built by
GCHP's own createRunDir.sh (see mk-fullchem-rundir.expect).

WHAT THIS IS AND IS NOT. This parses ExtData.rc and HEMCO_Config.rc, so it is an
INFERRED manifest, not a MEASURED one. A MEASURED list would come from HEMCO.log /
the ExtData "Opening file" lines of a real run, which costs a compute node. Two
consequences stated up front rather than buried:

  * It is an UPPER BOUND on files. HEMCO decides at runtime which entries to read
    (species enabled, hierarchy overrides, date coverage). Entries under an "off"
    extension are excluded here, but an "on" extension can still skip individual
    fields.
  * Year resolution for $YYYY paths is a RULE, not HEMCO's logic: try the sim year,
    else fall back to the closest year present on disk. HEMCO clamps to its
    declared time range, which usually agrees, but not always.

Neither caveat weakens the layer comparison this feeds, because the SAME manifest
is read through both lith and FSx. Manifest error is common-mode.

Sizes come from stat() on the FSx /input mount, which mirrors s3://gcgrid
(ImportPath verified s3://gcgrid on fs-0804c4d8e01897d21). FSx Lustre carries S3
object metadata without hydrating content, so this costs zero bytes and zero GETs.
"""
import os
import re
import sys
import json
from collections import defaultdict

RUNDIR = sys.argv[1] if len(sys.argv) > 1 else "/scratch/gchp_lith_fullchem"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/scratch/lith-gates/fullchem-manifest.tsv"

# Simulation window. cap_restart holds the start date the run directory was built
# for; fullchem defaults to 20190701. One simulated day, but met is read a day
# ahead (I3 fields at 00Z of day+1), so the window spans two dates.
def read_start_date(rundir):
    p = os.path.join(rundir, "cap_restart")
    with open(p) as fh:
        tok = fh.read().split()
    return tok[0]  # YYYYMMDD

START = read_start_date(RUNDIR)
YEAR, MON, DAY = START[:4], START[4:6], START[6:8]
# day+1 without pulling in datetime edge cases for month ends: 0701 -> 0702 is safe
# for the default start, and the fallback keeps the same day if arithmetic would
# cross a month boundary (a one-file difference, flagged rather than hidden).
try:
    import datetime
    d0 = datetime.date(int(YEAR), int(MON), int(DAY))
    d1 = d0 + datetime.timedelta(days=1)
    DATES = [(f"{d.year:04d}", f"{d.month:02d}", f"{d.day:02d}") for d in (d0, d1)]
except Exception:
    DATES = [(YEAR, MON, DAY)]

INPUT_ROOT = "/input"


def expand(tpl):
    """Expand a path template into every concrete path in the sim window."""
    out = set()
    for (y, m, d) in DATES:
        s = tpl
        # ExtData (MAPL) tokens
        s = s.replace("%y4", y).replace("%m2", m).replace("%d2", d)
        s = s.replace("%h2", "00").replace("%n2", "00")
        # HEMCO tokens
        s = s.replace("$YYYY", y).replace("$MM", m).replace("$DD", d)
        s = s.replace("$HH", "00").replace("$MN", "00")
        out.add(s)
    return out


def to_fs(path):
    """Map a run-directory-relative or $ROOT path onto the /input mount."""
    p = path.strip()
    p = p.replace("$ROOT", f"{INPUT_ROOT}/HEMCO")
    p = p.replace("$METDIR", f"{INPUT_ROOT}/GEOS_0.5x0.625/MERRA2")
    p = p.replace("$CHEMDIR", f"{INPUT_ROOT}/CHEM_INPUTS")
    if p.startswith("./"):
        p = os.path.join(RUNDIR, p[2:])
    # Resolve the run directory's own symlinks (MetDir/ChemDir/HcoDir -> /input/...)
    return os.path.realpath(p)


def parse_extdata(rundir):
    """ExtData.rc: the file template is the LAST whitespace field of a data line."""
    tpls = set()
    p = os.path.join(rundir, "ExtData.rc")
    with open(p) as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#") or s.endswith("%%") or ":" in s.split()[0]:
                continue
            last = s.split()[-1]
            if "/" not in last or last == "/dev/null":
                continue
            tpls.add(last)
    return tpls


def parse_hemco(rundir):
    """HEMCO_Config.rc, honouring the extension switches.

    Two line shapes carry paths:
      data lines   `<extnum> <name> <path> <var> <time> ...`
      sub-options  `    --> Some option : <path>`
    A path of `-` means "reuse the previous entry's file", so it contributes no new
    object. Extensions switched off are dropped: `1xx ExtName : off ...`.
    """
    tpls = set()
    off_ext = set()
    p = os.path.join(rundir, "HEMCO_Config.rc")
    lines = open(p).read().splitlines()

    # Pass 1: extension switches. Shape: `<num> <Name>  : on|off  <species>`
    sw = re.compile(r"^\s*(\d+)\s+(\S+)\s*:\s*(on|off)\b", re.IGNORECASE)
    for line in lines:
        if line.lstrip().startswith("#"):
            continue
        m = sw.match(line)
        if m and m.group(3).lower() == "off":
            off_ext.add(m.group(1))

    # Pass 2: data lines and sub-options
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("-->"):
            # sub-option: path is after the colon, if it looks like one
            if ":" in s:
                val = s.split(":", 1)[1].strip()
                if "/" in val and not val.lower() in ("on", "off"):
                    tpls.add(val.split()[0])
            continue
        f = s.split()
        if len(f) < 3 or not f[0].isdigit():
            continue
        if sw.match(line):          # this is a switch line, not a data line
            continue
        if f[0] in off_ext:         # extension is off -> not read
            continue
        path = f[2]
        if path == "-" or "/" not in path:
            continue
        # A "/" is not enough to mean "path": the SCALE FACTORS section puts values
        # in this column, e.g. `MATH:78.12/(6.0*12.0)` and month-factor lists like
        # `0.79/0.72/...`. Those produced 65 of the first run's 74 "unresolved"
        # entries -- noise that would have made the real misses hard to see.
        if not (path.startswith("$") or path.startswith("./") or path.startswith("/")):
            continue
        tpls.add(path)
    return tpls, off_ext


def resolve_year_fallback(fs_path):
    """If the sim-year path is absent, fall back to the closest year present.

    This is MY rule, not HEMCO's. HEMCO clamps to the time range declared in the
    config; the two usually agree, and where they don't the difference is which
    year's copy of the same-sized file gets read -- immaterial to a byte/latency
    measurement, but stated because it is an assumption.
    """
    if os.path.exists(fs_path):
        return fs_path, "exact"
    # Year can live in the FILENAME as well as in a directory component
    # (CMIP6_GHG_surface_VMR_2019.2x25.nc, MODIS.CHLRv...2019.nc). The first run
    # counted those as missing when they exist under a different year, which
    # overstated the gap. Try filename-year substitution against the real directory.
    d, base = os.path.split(fs_path)
    ym = re.search(r"(19|20)\d{2}", base)
    if ym and os.path.isdir(d):
        want = int(ym.group(0))
        pat = re.escape(base[: ym.start()]) + r"((?:19|20)\d{2})" + re.escape(base[ym.end():])
        cands = []
        for name in os.listdir(d):
            mm = re.fullmatch(pat, name)
            if mm:
                cands.append((abs(int(mm.group(1)) - want), int(mm.group(1)), name))
        if cands:
            cands.sort()
            return os.path.join(d, cands[0][2]), f"fileyear->{cands[0][1]}"
    m = re.search(r"/(\d{4})/", fs_path)
    if not m:
        return None, "missing"
    parent = fs_path[: m.start()]
    try:
        years = sorted(int(x) for x in os.listdir(parent) if re.fullmatch(r"\d{4}", x))
    except OSError:
        return None, "missing"
    if not years:
        return None, "missing"
    want = int(m.group(1))
    best = min(years, key=lambda y: (abs(y - want), y))
    cand = fs_path[: m.start()] + f"/{best:04d}/" + fs_path[m.end():]
    if os.path.exists(cand):
        return cand, f"year->{best}"
    return None, "missing"


def main():
    ext_tpls = parse_extdata(RUNDIR)
    hco_tpls, off_ext = parse_hemco(RUNDIR)

    rows = []
    seen = set()
    missing = []
    for src, tpls in (("extdata", ext_tpls), ("hemco", hco_tpls)):
        for tpl in tpls:
            for concrete in expand(tpl):
                fs = to_fs(concrete)
                real, how = resolve_year_fallback(fs)
                if real is None:
                    missing.append((src, concrete))
                    continue
                if real in seen:
                    continue
                seen.add(real)
                try:
                    sz = os.stat(real).st_size
                except OSError:
                    missing.append((src, concrete))
                    continue
                rows.append((src, how, sz, real))

    rows.sort(key=lambda r: -r[2])
    with open(OUT, "w") as fh:
        fh.write("#src\thow\tbytes\tpath\n")
        for r in rows:
            fh.write(f"{r[0]}\t{r[1]}\t{r[2]}\t{r[3]}\n")

    total = sum(r[2] for r in rows)
    # "Family" = the top-level gcgrid directory under /input, which is the unit the
    # input audit and the pre-hydration scripts both use.
    fams = defaultdict(lambda: [0, 0])
    for r in rows:
        rel = r[3][len(INPUT_ROOT) + 1:] if r[3].startswith(INPUT_ROOT) else r[3]
        parts = rel.split("/")
        fam = "/".join(parts[:2]) if parts[0] == "HEMCO" else parts[0]
        fams[fam][0] += 1
        fams[fam][1] += r[2]

    print(f"run dir      : {RUNDIR}")
    print(f"start date   : {START}  (window {DATES[0][0]}{DATES[0][1]}{DATES[0][2]}"
          f"..{DATES[-1][0]}{DATES[-1][1]}{DATES[-1][2]})")
    print(f"ExtData tpls : {len(ext_tpls)}")
    print(f"HEMCO   tpls : {len(hco_tpls)}   (extensions off: {sorted(off_ext) or 'none'})")
    print(f"objects      : {len(rows)}")
    print(f"total bytes  : {total} ({total/2**30:.1f} GiB)")
    print(f"missing      : {len(missing)}")
    print(f"families     : {len(fams)}")
    print()
    print("top 15 objects by size:")
    for r in rows[:15]:
        print(f"  {r[2]/2**20:10.1f} MiB  {r[3]}")
    print()
    print("top 15 families by bytes:")
    for fam, (n, b) in sorted(fams.items(), key=lambda kv: -kv[1][1])[:15]:
        print(f"  {b/2**20:10.1f} MiB  {n:4d} obj  {fam}")
    if missing:
        print()
        print(f"unresolved ({len(missing)}), first 15:")
        for src, c in missing[:15]:
            print(f"  [{src}] {c}")

    with open(OUT + ".summary.json", "w") as fh:
        json.dump({
            "rundir": RUNDIR, "start": START, "objects": len(rows),
            "total_bytes": total, "families": len(fams), "missing": len(missing),
            "extdata_templates": len(ext_tpls), "hemco_templates": len(hco_tpls),
            "family_bytes": {k: v[1] for k, v in fams.items()},
        }, fh, indent=2)


if __name__ == "__main__":
    main()
