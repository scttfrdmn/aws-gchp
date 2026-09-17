#!/bin/bash
# Prefix-scoped indexes, one per data family (per docs/lith-input-layer-analysis.md:
# scope per family, not over all of gcgrid).
set -u
IDX=/scratch/lith-gates/idx
build() {
  name=$1; prefix=$2
  s=$(date +%s)
  out=$(lith index build "s3://gcgrid/${prefix}" --no-sign-request \
        --index-file "${IDX}/${name}.lithidx" 2>&1 | tail -1)
  echo "[$name] $(( $(date +%s) - s ))s :: $out"
}
build met      GEOS_0.25x0.3125/GEOS_FP/2019/07
build hemco    HEMCO
build cheminp  CHEM_INPUTS
build restarts GEOSCHEM_RESTARTS
echo "ALL DONE"
