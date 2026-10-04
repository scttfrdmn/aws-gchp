#!/bin/bash
# build-instrumented-gchp.sh — on the HEAD NODE: clone GCHP 14.7.1, apply the default-off
# instrumentation patches (KPP timer + MAPL shard probe), and build against the validated
# aarch64 stack already synced to /sw. Mirrors the stack-builder's exact GCHP cmake recipe.
# Output binary: /scratch/gchp-instr/gchp-14.7.1/bin/gchp  (built on Lustre scratch, fast + roomy).
set -euo pipefail

STACK=/sw                       # validated aarch64 stack (gcc12.2/ompi4.1.7/esmf8.6.1/netcdf/...)
NCPUS=$(nproc)
GCHP_VERSION=14.7.1
# CHEM_BACKEND (mpi|inline|decoupled) selects the fullchem solve backend for the Phase-0 bitwise A/B.
# Each variant gets its OWN clone + build + install so patches/builds never collide and the
# inline/mpi clones never receive the decoupled patch.
CHEM_BACKEND="${CHEM_BACKEND:-mpi}"
SRC=/scratch/gchp-instr/GCHP-${CHEM_BACKEND}       # per-variant build tree on Lustre
PREFIX=/scratch/gchp-instr/install-${CHEM_BACKEND}

echo "=== [build] sourcing stack env from $STACK/gchp-env.sh ==="
source "$STACK/gchp-env.sh"     # sets PATH/LD_LIBRARY_PATH/ESMF_ROOT/OPAL_PREFIX/etc, relocatable
command -v mpifort >/dev/null || { echo "FAIL: mpifort not on PATH after sourcing stack env"; exit 1; }

# RELOCATION FIX (see memory: openmpi_pmix_relocation): the OpenMPI wrapper compilers have the
# ORIGINAL build prefix (/fsx/stacks/...) baked in and look for gfortran/gcc/g++ there. gchp-env.sh
# sets OPAL_PREFIX (runtime) but NOT the wrapper's underlying-compiler override needed at BUILD time.
# Point the wrappers at the actual /sw GCC so cmake's compiler test passes.
export OMPI_FC="$STACK/gcc-12.2.0/bin/gfortran"
export OMPI_CC="$STACK/gcc-12.2.0/bin/gcc"
export OMPI_CXX="$STACK/gcc-12.2.0/bin/g++"
echo "[build] OMPI_FC=$OMPI_FC ($([ -x "$OMPI_FC" ] && echo exists || echo MISSING))"

# Dependency roots for CMake FindXXX (the stack has no h5cc/nc-config wrappers synced, so
# point find_package at the roots explicitly via env too — belt & suspenders with the -D flags).
export HDF5_ROOT="$STACK/hdf5-1.14.0"
export NetCDF_ROOT="$STACK/netcdf-c-4.9.2"
# Safety net for any other relocated GCC libexec exec-bit drops from the S3 sync.
chmod -R +x "$STACK/gcc-12.2.0/libexec" 2>/dev/null || true

# RELOCATION FIX for ESMF: esmf.mk is a GENERATED makefile fragment with the original build
# prefix (/fsx/stacks/gchp14.7.1-validated-arm64) baked into ~41 absolute paths (ESMF_LIBSDIR,
# link/rpath/include dirs). GCHP's FindESMF.cmake reads ESMF_LIBSDIR from it and find_library()
# fails because that path doesn't exist here. Rewrite it in place to the deploy prefix ($STACK).
# Idempotent (sed is a no-op once rewritten). Touches only the generated .mk, not source/numerics.
ESMF_MK="$(find "$STACK/esmf-8.6.1/lib" -name esmf.mk 2>/dev/null | head -1)"
if [ -n "$ESMF_MK" ] && grep -q "/fsx/stacks/gchp14.7.1-validated-arm64" "$ESMF_MK" 2>/dev/null; then
  sudo sed -i "s#/fsx/stacks/gchp14.7.1-validated-arm64#$STACK#g" "$ESMF_MK"
  echo "[build] rewrote stale /fsx paths in $ESMF_MK -> $STACK"
fi
"$STACK"/esmf-8.6.1/bin/ESMF_Info >/dev/null 2>&1 && echo "[build] ESMF_Info OK" || echo "[build] WARN: ESMF_Info check skipped"

# OS build-dep: ESMF/MAPL link against expat; the validated builder had expat-devel from the OS
# but the runtime AMI ships only libexpat.so.1 (no header). Install the dev header (cheap OS pkg).
command -v expat_config >/dev/null 2>&1 || [ -f /usr/include/expat.h ] || sudo dnf install -y expat-devel 2>&1 | tail -1

echo "=== [build] clone GCHP $GCHP_VERSION + submodules (recursive) ==="
mkdir -p "$(dirname "$SRC")"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$GCHP_VERSION" https://github.com/geoschem/GCHP.git "$SRC"
  git -C "$SRC" submodule update --init --recursive --depth 1
fi

echo "=== [build] apply instrumentation patches (default-off) ==="
aws s3 cp s3://gchp-shared-storage-us-east-1/instr/mapl.patch      /tmp/mapl.patch      --region us-east-1 --only-show-errors
aws s3 cp s3://gchp-shared-storage-us-east-1/instr/geos-chem.patch /tmp/geos-chem.patch --region us-east-1 --only-show-errors
# apply inside each submodule; --3way tolerant, idempotent check first
( cd "$SRC/src/MAPL" && git apply --check /tmp/mapl.patch 2>/dev/null && git apply /tmp/mapl.patch && echo "[build] MAPL patch applied" \
    || echo "[build] MAPL patch already applied or check failed (continuing — verify markers below)" )
( cd "$SRC/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem" && git apply --check /tmp/geos-chem.patch 2>/dev/null && git apply /tmp/geos-chem.patch && echo "[build] geos-chem patch applied" \
    || echo "[build] geos-chem patch already applied or check failed (continuing — verify markers below)" )
echo "[build] marker check (must be >0 each):"
echo "  ShardWriter: $(ls $SRC/src/MAPL/base/MAPL_ShardWriter.F90 2>/dev/null && echo present || echo MISSING)"
echo "  KPP timer:   $(grep -c 'KPP Integrate' $SRC/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/GeosCore/fullchem_mod.F90)"
echo "  shard call:  $(grep -c 'ShardProbe_Record' $SRC/src/MAPL/generic/MAPL_Generic.F90)"

# CHEM_BACKEND (set at top) selects the fullchem solve backend for the Phase-0 bitwise A/B:
#   mpi       (default) : MPI_LOAD_BALANCE=ON  -- the community default gather/solve/scatter path
#   inline              : both macros OFF      -- true-stock per-cell inline Integrate
#   decoupled           : DECOUPLED_CHEM=ON    -- the new in-process gather/solve/scatter backend
# All three apply the same instrumentation patches above (in this variant's own clone); 'decoupled'
# additionally applies the two decoupled patches. SRC/PREFIX are already variant-tagged (see top).
CMAKE_CHEM_FLAGS="-DMPI_LOAD_BALANCE=ON"   # default (mpi)
case "$CHEM_BACKEND" in
  inline)
    CMAKE_CHEM_FLAGS="-DMPI_LOAD_BALANCE=OFF"
    echo "=== [build] CHEM_BACKEND=inline -> true-stock per-cell solve (both macros OFF) ==="
    ;;
  decoupled)
    echo "=== [build] CHEM_BACKEND=decoupled -> apply decoupled patches + -DDECOUPLED_CHEM=ON ==="
    aws s3 cp s3://gchp-shared-storage-us-east-1/instr/decoupled-geos-chem.patch /tmp/decoupled-geos-chem.patch --region us-east-1 --only-show-errors
    aws s3 cp s3://gchp-shared-storage-us-east-1/instr/decoupled-cmake.patch     /tmp/decoupled-cmake.patch     --region us-east-1 --only-show-errors
    ( cd "$SRC/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem" && git apply --check /tmp/decoupled-geos-chem.patch 2>/dev/null && git apply /tmp/decoupled-geos-chem.patch && echo "[build] decoupled geos-chem patch applied" \
        || echo "[build] decoupled geos-chem patch already applied or check failed (verify markers)" )
    ( cd "$SRC" && git apply --check /tmp/decoupled-cmake.patch 2>/dev/null && git apply /tmp/decoupled-cmake.patch && echo "[build] decoupled cmake patch applied" \
        || echo "[build] decoupled cmake patch already applied or check failed (verify markers)" )
    echo "  DECOUPLED_CHEM markers (must be >0 each):"
    echo "    fullchem:  $(grep -c 'DECOUPLED_CHEM' $SRC/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/GeosCore/fullchem_mod.F90)"
    echo "    cmakelist: $(grep -c 'DECOUPLED_CHEM' $SRC/src/GCHP_GridComp/GEOSChem_GridComp/CMakeLists.txt)"
    echo "    kpp_worker.F90 present: $([ -f $SRC/src/GCHP_GridComp/GEOSChem_GridComp/geos-chem/GeosCore/kpp_worker.F90 ] && echo yes || echo NO)"
    # DECOUPLED_CHEM CMake forces MPI_LOAD_BALANCE OFF; pass both so intent is explicit.
    CMAKE_CHEM_FLAGS="-DMPI_LOAD_BALANCE=OFF -DDECOUPLED_CHEM=ON"
    # Phase 1a: also build the offline kpp_worker executable (env BUILD_WORKER=1).
    if [ "${BUILD_WORKER:-0}" = "1" ]; then
      CMAKE_CHEM_FLAGS="$CMAKE_CHEM_FLAGS -DDECOUPLED_CHEM_WORKER=ON"
      echo "  [build] BUILD_WORKER=1 -> will also build kpp_worker (Phase 1a)"
    fi
    ;;
  mpi)
    echo "=== [build] CHEM_BACKEND=mpi -> community default MPI_LOAD_BALANCE=ON ==="
    ;;
  *) echo "FAIL: unknown CHEM_BACKEND=$CHEM_BACKEND (want inline|mpi|decoupled)"; exit 1 ;;
esac

# --- aarch64 mcmodel strip (gotcha): several GC subcomponent CMakeLists hardcode -mcmodel=medium,
# which is an x86-only flag -> gfortran-aarch64 rejects it ("unrecognized argument in option").
# Strip it from every source CMakeLists/.cmake before configure so it never reaches flags.make.
# (HETP, HEMCO, Cloud-J, GEOSChem_GridComp all carry it.) x86 builds keep the flag.
if [ "$(uname -m)" = "aarch64" ]; then
  n=0
  for f in $(grep -rlnE 'mcmodel=medium' "$SRC/src" "$SRC/CMakeLists.txt" 2>/dev/null); do
    sed -i 's/-mcmodel=medium//g' "$f"; n=$((n+1))
  done
  echo "[build] aarch64: stripped -mcmodel=medium from $n CMakeLists/.cmake file(s)"
fi

echo "=== [build] cmake (validated recipe; RPATH to /sw stack libs) ==="
SR="$STACK"
# Derive the ESMF lib dir dynamically (this stack is the .32. layout, not .64.) — match gchp-env.sh.
ESMF_LIBDIR="$(dirname "$(find "$SR/esmf-8.6.1/lib" -name libesmf.so -type f 2>/dev/null | head -1)")"
[ -n "$ESMF_LIBDIR" ] || { echo "FAIL: libesmf.so not found under $SR/esmf-8.6.1/lib"; exit 1; }
echo "[build] ESMF lib dir = $ESMF_LIBDIR"
RP="$ESMF_LIBDIR"
for d in openmpi-4.1.7 netcdf-c-4.9.2 netcdf-fortran-4.6.0 hdf5-1.14.0 udunits-2.2.28 gcc-12.2.0/lib64 \
         libfabric-1.22.0 hwloc-2.11.1 pmix-5.0.3 libevent-2.1.12 zlib-1.3.1 gmp-6.3.0 mpfr-4.2.1 mpc-1.3.1; do
  RP="$RP:$SR/$d/lib"; done
RP="${RP/gcc-12.2.0\/lib64\/lib/gcc-12.2.0\/lib64}"   # fix the lib64 entry

mkdir -p "$SRC/build" && cd "$SRC/build"
cmake .. \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_C_COMPILER=mpicc -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_Fortran_COMPILER=mpifort \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_RPATH="$RP" -DCMAKE_BUILD_RPATH="$RP" -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=TRUE \
  ${CMAKE_CHEM_FLAGS} \
  -DHDF5_ROOT="$SR/hdf5-1.14.0" \
  -DHDF5_NO_FIND_PACKAGE_CONFIG_FILE=TRUE \
  -DHDF5_C_LIBRARY_hdf5="$SR/hdf5-1.14.0/lib/libhdf5.so" \
  -DHDF5_hdf5_LIBRARY_RELEASE="$SR/hdf5-1.14.0/lib/libhdf5.so" \
  -DHDF5_INCLUDE_DIRS="$SR/hdf5-1.14.0/include" \
  -DNETCDF_C_LIBRARY="$SR/netcdf-c-4.9.2/lib/libnetcdf.so" \
  -DNETCDF_C_INCLUDE_DIR="$SR/netcdf-c-4.9.2/include" \
  -DNETCDF_F_LIBRARY="$SR/netcdf-fortran-4.6.0/lib/libnetcdff.so" \
  -DNETCDF_F90_INCLUDE_DIR="$SR/netcdf-fortran-4.6.0/include" \
  -DNETCDF_F77_INCLUDE_DIR="$SR/netcdf-fortran-4.6.0/include" \
  -Dudunits_LIBRARY="$SR/udunits-2.2.28/lib/libudunits2.so" \
  -Dudunits_INCLUDE_DIR="$SR/udunits-2.2.28/include" \
  -Dudunits_XML_PATH="$SR/udunits-2.2.28/share/udunits/udunits2.xml" 2>&1 | tail -20

echo "=== [build] make -j$NCPUS (this is the long pole) ==="
make -j"$NCPUS" 2>&1 | tail -25
# Phase 1a: explicitly build the worker target too (add_executable is in ALL, but be explicit).
if [ "${BUILD_WORKER:-0}" = "1" ] && [ "$CHEM_BACKEND" = "decoupled" ]; then
  echo "=== [build] make kpp_worker ==="
  make -j"$NCPUS" kpp_worker 2>&1 | tail -12
fi
make install 2>&1 | tail -5

echo "=== [build] RESULT (CHEM_BACKEND=$CHEM_BACKEND) ==="
# The build-tree binary is what we run (make install can fail cosmetically on install-prefix perms).
BUILT_BIN="$SRC/build/bin/gchp"
if [ -x "$BUILT_BIN" ]; then
  ls -la "$BUILT_BIN"
  echo "BUILD_OK $BUILT_BIN (backend=$CHEM_BACKEND)"
else
  echo "BUILD_FAILED (backend=$CHEM_BACKEND)"
fi
if [ "${BUILD_WORKER:-0}" = "1" ] && [ "$CHEM_BACKEND" = "decoupled" ]; then
  WBIN="$SRC/build/bin/kpp_worker"
  if [ -x "$WBIN" ]; then ls -la "$WBIN"; echo "WORKER_OK $WBIN"; else echo "WORKER_FAILED"; fi
fi
