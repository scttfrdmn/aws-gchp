#!/usr/bin/env python3
"""
GCHP Configuration Pre-Flight Validator

Validates GCHP run directory configuration before job submission.
Checks domain decomposition constraints and estimates memory requirements.

Usage:
    python validate_gchp_config.py /path/to/run/directory
"""

import sys
import re
from pathlib import Path
from typing import Tuple, Dict, List

# Shared grid-constraint + memory core (same source of truth as the forward
# calculator gchp_aws.calculator). Kept optional so this validator still runs
# standalone if the package is missing.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from gchp_aws import constraints as _gc_constraints
    from gchp_aws import memory as _gc_memory
    _HAVE_SHARED = True
except Exception:
    _HAVE_SHARED = False


class ValidationResult:
    """Result of a validation check"""
    def __init__(self, passed: bool, message: str, severity: str = "error"):
        self.passed = passed
        self.message = message
        self.severity = severity  # "error", "warning", "info"


class GCHPValidator:
    """Validates GCHP configuration files"""

    # Memory estimates based on empirical data (May 2026)
    MEMORY_PER_CORE_FULL_HISTORY = 1.7  # GB per core with full HISTORY
    MEMORY_PER_CORE_MINIMAL = 0.6  # GB per core with minimal HISTORY
    MEMORY_SAFETY_MARGIN = 0.75  # Use only 75% of available memory

    def __init__(self, run_dir: Path):
        self.run_dir = run_dir
        self.gchp_rc = run_dir / "GCHP.rc"
        self.history_rc = run_dir / "HISTORY.rc"
        self.cap_rc = run_dir / "CAP.rc"

    def validate_all(self, node_memory_gb: float = 373) -> List[ValidationResult]:
        """Run all validation checks"""
        results = []

        # Check files exist
        if not self.gchp_rc.exists():
            results.append(ValidationResult(False, f"GCHP.rc not found in {self.run_dir}"))
            return results

        # Parse configuration
        try:
            config = self._parse_gchp_rc()
            history_config = self._parse_history_rc() if self.history_rc.exists() else {}
            cap_config = self._parse_cap_rc() if self.cap_rc.exists() else {}
        except Exception as e:
            results.append(ValidationResult(False, f"Failed to parse config: {e}"))
            return results

        # Domain decomposition checks
        results.extend(self._validate_domain_decomposition(config))

        # Memory estimation
        results.extend(self._validate_memory(config, history_config, cap_config, node_memory_gb))

        return results

    def _parse_gchp_rc(self) -> Dict:
        """Parse GCHP.rc for critical parameters"""
        config = {}
        with open(self.gchp_rc) as f:
            for line in f:
                line = line.strip()
                if ':' in line and not line.startswith('#'):
                    key, value = line.split(':', 1)
                    key = key.strip()
                    value = value.strip()
                    if key in ['NX', 'NY', 'IM', 'JM']:
                        try:
                            config[key] = int(value)
                        except ValueError:
                            pass
        return config

    def _parse_history_rc(self) -> Dict:
        """Parse HISTORY.rc to count collections"""
        collections = []
        try:
            with open(self.history_rc) as f:
                content = f.read()
                # Find COLLECTIONS block (multi-line format)
                in_collections = False
                for line in content.split('\n'):
                    if 'COLLECTIONS:' in line:
                        in_collections = True
                        # Get first collection from COLLECTIONS: line
                        match = re.search(r"'([^']+)'", line)
                        if match:
                            col = match.group(1).strip()
                            if col:
                                collections.append(col)
                        continue

                    if in_collections:
                        # Stop at :: or blank line followed by non-indented content
                        if line.strip() == '::' or (line and not line[0].isspace() and line.strip()):
                            break

                        # Skip commented lines
                        if line.strip().startswith('#'):
                            continue

                        # Extract collection name from indented lines with 'name',
                        match = re.search(r"'([^']+)'", line)
                        if match and line.startswith((' ', '\t')):
                            col = match.group(1).strip()
                            if col:
                                collections.append(col)
        except Exception:
            pass

        return {'collections': collections, 'count': len(collections)}

    def _parse_cap_rc(self) -> Dict:
        """Parse CAP.rc for simulation duration"""
        config = {}
        try:
            with open(self.cap_rc) as f:
                for line in f:
                    if 'BEG_DATE:' in line or 'End_Time:' in line:
                        parts = line.split(':', 1)
                        if len(parts) == 2:
                            key = parts[0].strip()
                            value = parts[1].strip().strip('"')
                            config[key] = value
        except Exception:
            pass
        return config

    def _validate_domain_decomposition(self, config: Dict) -> List[ValidationResult]:
        """Validate domain decomposition constraints"""
        results = []

        # Check we have required values
        required = ['NX', 'NY', 'IM', 'JM']
        missing = [k for k in required if k not in config]
        if missing:
            results.append(ValidationResult(
                False,
                f"Missing required parameters in GCHP.rc: {', '.join(missing)}"
            ))
            return results

        nx = config['NX']
        ny = config['NY']
        im = config['IM']
        jm = config['JM']

        # When the shared core is available, use it as the single source of truth
        # for the tile-size math (cs_res == IM; the Layout computes tile_x/tile_y
        # identically to the inline checks below, which are kept for standalone use).
        _lay = _gc_constraints.Layout(cs_res=im, nx=nx, ny=ny) if _HAVE_SHARED else None

        # Constraint 1: NY must be divisible by 6
        if ny % 6 != 0:
            results.append(ValidationResult(
                False,
                f"NY={ny} must be divisible by 6 (cubed-sphere requirement). "
                f"Nearest valid: {(ny//6)*6} or {((ny//6)+1)*6}"
            ))
        else:
            results.append(ValidationResult(
                True,
                f"✓ NY={ny} is divisible by 6",
                "info"
            ))

        # Constraint 2: Tile size X must be >= 4
        tile_x = _lay.tile_x if _lay else im / nx
        if tile_x < 4:
            results.append(ValidationResult(
                False,
                f"Tile X size = IM/NX = {im}/{nx} = {tile_x:.1f} < 4 (minimum). "
                f"Reduce NX to ≤ {im//4}"
            ))
        else:
            results.append(ValidationResult(
                True,
                f"✓ Tile X size = {tile_x:.1f} >= 4",
                "info"
            ))

        # Constraint 3: Tile size Y must be >= 4
        tile_y = _lay.tile_y if _lay else jm / ny
        if tile_y < 4:
            results.append(ValidationResult(
                False,
                f"Tile Y size = JM/NY = {jm}/{ny} = {tile_y:.1f} < 4 (minimum). "
                f"Reduce NY to ≤ {(jm//4)//6*6}"  # Must be multiple of 6
            ))
        else:
            results.append(ValidationResult(
                True,
                f"✓ Tile Y size = {tile_y:.1f} >= 4",
                "info"
            ))

        # Info: Total cores
        total_cores = nx * ny
        results.append(ValidationResult(
            True,
            f"Configuration: C{im} @ {total_cores} cores (NX={nx} × NY={ny}, tile {tile_x:.1f}×{tile_y:.1f})",
            "info"
        ))

        return results

    def _validate_memory(
        self,
        config: Dict,
        history_config: Dict,
        cap_config: Dict,
        node_memory_gb: float
    ) -> List[ValidationResult]:
        """Estimate memory requirements and validate against node capacity"""
        results = []

        if 'NX' not in config or 'NY' not in config:
            return results

        total_cores = config['NX'] * config['NY']
        num_collections = history_config.get('count', 0)

        # Estimate memory based on HISTORY configuration
        if num_collections == 0:
            # No HISTORY.rc or no collections
            memory_per_core = self.MEMORY_PER_CORE_MINIMAL
            history_desc = "no HISTORY output"
        elif num_collections <= 3:
            memory_per_core = self.MEMORY_PER_CORE_MINIMAL
            history_desc = f"{num_collections} HISTORY collections (minimal)"
        else:
            # Scale between minimal and full based on collection count
            # Full HISTORY typically has 13+ collections
            scale_factor = min(num_collections / 13.0, 1.0)
            memory_per_core = (
                self.MEMORY_PER_CORE_MINIMAL +
                (self.MEMORY_PER_CORE_FULL_HISTORY - self.MEMORY_PER_CORE_MINIMAL) * scale_factor
            )
            history_desc = f"{num_collections} HISTORY collections"

        estimated_memory_gb = total_cores * memory_per_core
        safe_limit_gb = node_memory_gb * self.MEMORY_SAFETY_MARGIN
        memory_percent = (estimated_memory_gb / node_memory_gb) * 100

        # Add simulation duration context if available
        duration_warning = ""
        if 'End_Time' in cap_config and 'BEG_DATE' in cap_config:
            # Could parse dates and calculate duration, but for now just note it
            duration_warning = " (Note: longer simulations accumulate more memory)"

        results.append(ValidationResult(
            True,
            f"Memory estimate: {estimated_memory_gb:.1f} GB ({history_desc})",
            "info"
        ))

        if estimated_memory_gb > node_memory_gb:
            results.append(ValidationResult(
                False,
                f"Estimated memory ({estimated_memory_gb:.1f} GB) exceeds node capacity "
                f"({node_memory_gb:.1f} GB). Configuration will likely crash with OOM."
            ))
        elif estimated_memory_gb > safe_limit_gb:
            results.append(ValidationResult(
                False,
                f"Estimated memory ({estimated_memory_gb:.1f} GB = {memory_percent:.1f}%) exceeds "
                f"safe limit ({safe_limit_gb:.1f} GB = 75%). High risk of OOM crash.{duration_warning}",
                "warning"
            ))
            results.append(ValidationResult(
                False,
                f"Recommendation: Reduce HISTORY collections from {num_collections} to "
                f"≤ {int(num_collections * safe_limit_gb / estimated_memory_gb)} collections"
            ))
        else:
            results.append(ValidationResult(
                True,
                f"✓ Memory usage ({memory_percent:.1f}%) is within safe limits (<75%)",
                "info"
            ))

        return results


def print_results(results: List[ValidationResult]) -> bool:
    """Print validation results and return overall pass/fail"""

    errors = [r for r in results if not r.passed and r.severity == "error"]
    warnings = [r for r in results if not r.passed and r.severity == "warning"]
    info = [r for r in results if r.passed and r.severity == "info"]

    print("\n" + "="*70)
    print("GCHP CONFIGURATION PRE-FLIGHT CHECK")
    print("="*70 + "\n")

    if info:
        print("Configuration Details:")
        for result in info:
            print(f"  {result.message}")
        print()

    if errors:
        print("❌ ERRORS - Configuration will fail:")
        for result in errors:
            print(f"  • {result.message}")
        print()

    if warnings:
        print("⚠️  WARNINGS - Configuration may fail:")
        for result in warnings:
            print(f"  • {result.message}")
        print()

    print("="*70)
    if errors:
        print("RESULT: ❌ FAIL - Do not submit this configuration")
        print("="*70 + "\n")
        return False
    elif warnings:
        print("RESULT: ⚠️  CAUTION - High risk, proceed with care")
        print("="*70 + "\n")
        return False
    else:
        print("RESULT: ✅ PASS - Configuration is valid")
        print("="*70 + "\n")
        return True


def main():
    if len(sys.argv) < 2:
        print("Usage: validate_gchp_config.py <run_directory> [node_memory_gb]")
        print()
        print("Examples:")
        print("  python validate_gchp_config.py /scratch/benchmarks/c48_192_v2")
        print("  python validate_gchp_config.py /scratch/benchmarks/c90_192_v2 373")
        sys.exit(1)

    run_dir = Path(sys.argv[1])
    node_memory_gb = float(sys.argv[2]) if len(sys.argv) > 2 else 373.0

    if not run_dir.exists():
        print(f"Error: Directory not found: {run_dir}")
        sys.exit(1)

    validator = GCHPValidator(run_dir)
    results = validator.validate_all(node_memory_gb)
    passed = print_results(results)

    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
