#!/bin/bash
# build-gchp-mapl46.sh — on the HEAD NODE: build stock GCHP 14.7.1 against the /sw stack, keep that
# binary as the control, then apply geoschem/MAPL PR #46 (finalization fix for GCHP#556) to
# src/MAPL and rebuild incrementally. Both binaries come from one tree with one cmake configure,
# so the only difference between them is MAPL_Cap.F90.
# Same cmake recipe as build-instrumented-gchp.sh, with no instrumentation patches.
#   out: $W/gchp-stock  $W/gchp-pr46  (+ build logs)
set -eo pipefail

STACK=/sw
NCPUS=$(nproc)
GCHP_VERSION=14.7.1
W=${W:-/scratch/gchp-mapl46}
SRC=$W/GCHP
PATCH=${PATCH:-$W/mapl46.patch}       # gridcomps/Cap/MAPL_Cap.F90 hunks of PR #46 (head b6de899c1c)

source "$STACK/gchp-env.sh"
export OMPI_FC="$STACK/gcc-12.2.0/bin/gfortran" OMPI_CC="$STACK/gcc-12.2.0/bin/gcc" OMPI_CXX="$STACK/gcc-12.2.0/bin/g++"
export HDF5_ROOT="$STACK/hdf5-1.14.0" NetCDF_ROOT="$STACK/netcdf-c-4.9.2"
chmod -R +x "$STACK/gcc-12.2.0/libexec" 2>/dev/null || true
ESMF_MK="$(find "$STACK/esmf-8.6.1/lib" -name esmf.mk 2>/dev/null | head -1)"
if [ -n "$ESMF_MK" ] && grep -q "/fsx/stacks/gchp14.7.1-validated-arm64" "$ESMF_MK" 2>/dev/null; then
  sudo sed -i "s#/fsx/stacks/gchp14.7.1-validated-arm64#$STACK#g" "$ESMF_MK"
fi
[ -f /usr/include/expat.h ] || sudo dnf install -y expat-devel 2>&1 | tail -1

mkdir -p "$W"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$GCHP_VERSION" https://github.com/geoschem/GCHP.git "$SRC"
  git -C "$SRC" submodule update --init --recursive --depth 1
fi
echo "[build] GCHP $(git -C "$SRC" describe --tags) MAPL $(git -C "$SRC/src/MAPL" rev-parse --short HEAD)"
git -C "$SRC/src/MAPL" apply --check "$PATCH" || { echo "FAIL: PR #46 does not apply to 14.7.1 MAPL"; exit 1; }
echo "[build] PR #46 applies cleanly to 14.7.1 MAPL (checked, not yet applied)"

if [ "$(uname -m)" = "aarch64" ]; then
  for f in $(grep -rlnE 'mcmodel=medium' "$SRC/src" "$SRC/CMakeLists.txt" 2>/dev/null); do sed -i 's/-mcmodel=medium//g' "$f"; done
fi

SR="$STACK"
ESMF_LIBDIR="$(dirname "$(find "$SR/esmf-8.6.1/lib" -name libesmf.so -type f | head -1)")"
RP="$ESMF_LIBDIR"
for d in openmpi-4.1.7 netcdf-c-4.9.2 netcdf-fortran-4.6.0 hdf5-1.14.0 udunits-2.2.28 gcc-12.2.0/lib64 \
         libfabric-1.22.0 hwloc-2.11.1 pmix-5.0.3 libevent-2.1.12 zlib-1.3.1 gmp-6.3.0 mpfr-4.2.1 mpc-1.3.1; do
  RP="$RP:$SR/$d/lib"; done
RP="${RP/gcc-12.2.0\/lib64\/lib/gcc-12.2.0\/lib64}"

mkdir -p "$SRC/build" && cd "$SRC/build"
cmake .. \
  -DCMAKE_C_COMPILER=mpicc -DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_Fortran_COMPILER=mpifort \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_RPATH="$RP" -DCMAKE_BUILD_RPATH="$RP" -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=TRUE \
  -DHDF5_ROOT="$SR/hdf5-1.14.0" -DHDF5_NO_FIND_PACKAGE_CONFIG_FILE=TRUE \
  -DHDF5_C_LIBRARY_hdf5="$SR/hdf5-1.14.0/lib/libhdf5.so" -DHDF5_hdf5_LIBRARY_RELEASE="$SR/hdf5-1.14.0/lib/libhdf5.so" \
  -DHDF5_INCLUDE_DIRS="$SR/hdf5-1.14.0/include" \
  -DNETCDF_C_LIBRARY="$SR/netcdf-c-4.9.2/lib/libnetcdf.so" -DNETCDF_C_INCLUDE_DIR="$SR/netcdf-c-4.9.2/include" \
  -DNETCDF_F_LIBRARY="$SR/netcdf-fortran-4.6.0/lib/libnetcdff.so" \
  -DNETCDF_F90_INCLUDE_DIR="$SR/netcdf-fortran-4.6.0/include" -DNETCDF_F77_INCLUDE_DIR="$SR/netcdf-fortran-4.6.0/include" \
  -Dudunits_LIBRARY="$SR/udunits-2.2.28/lib/libudunits2.so" -Dudunits_INCLUDE_DIR="$SR/udunits-2.2.28/include" \
  -Dudunits_XML_PATH="$SR/udunits-2.2.28/share/udunits/udunits2.xml" > "$W/cmake.log" 2>&1 || { tail -20 "$W/cmake.log"; exit 1; }

echo "=== [build] stock make -j$NCPUS  $(date -u +%T)"
make -j"$NCPUS" > "$W/make-stock.log" 2>&1 || { tail -30 "$W/make-stock.log"; exit 1; }
cp -p bin/gchp "$W/gchp-stock"
echo "[build] stock OK $(md5sum "$W/gchp-stock" | cut -c1-12)  $(date -u +%T)"

git -C "$SRC/src/MAPL" apply "$PATCH"
echo "[build] PR #46 applied: $(git -C "$SRC/src/MAPL" diff --stat | tail -1)"
make -j"$NCPUS" > "$W/make-pr46.log" 2>&1 || { tail -30 "$W/make-pr46.log"; exit 1; }
cp -p bin/gchp "$W/gchp-pr46"
echo "[build] pr46 OK $(md5sum "$W/gchp-pr46" | cut -c1-12)  $(date -u +%T)"
echo BUILD_DONE
