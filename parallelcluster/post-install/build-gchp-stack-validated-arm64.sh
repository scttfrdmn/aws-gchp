#!/bin/bash
#
# GCHP Software Stack Builder - Validated Self-Contained Build (ARM64/Graviton)
# Builds: gcc12.2-ompi4.1.7-esmf8.6.1-gchp14.7.1-arm64
#
# Run on: ARM64 Linux system (Graviton 2/3/4)
# Duration: ~6-8 hours for full build
# Output: /fsx/stacks/gchp14.7.1-validated-arm64/
# S3 Export: Automatic via FSx Lustre ExportPath
#
# This script builds a completely self-contained GCHP stack with:
# - ALL dependencies from source (no OS package dependencies)
# - Validated versions from GCHP 14.7.1 Spack scope
# - EFA support built from source (libfabric)
# - ARM64/AArch64 optimizations for AWS Graviton
#

set -e  # Exit on error
set -u  # Error on undefined variables

# Configuration
STACK_NAME="gchp14.7.1-validated-arm64"
STACK_ROOT="/fsx/stacks/${STACK_NAME}"
BUILD_DIR="/tmp/gchp-build-validated-arm64"
LOG_FILE="/fsx/build-${STACK_NAME}.log"
NCPUS=$(nproc)

# Software versions - FROM GCHP 14.7.1 VALIDATED SPACK SCOPE
GCC_VERSION="12.2.0"           # GCHP Spack pin
OPENMPI_VERSION="4.1.7"        # Latest 4.1.x
HDF5_VERSION="1.14.0"          # GCHP Spack pin
NETCDF_C_VERSION="4.9.2"       # GCHP Spack pin
NETCDF_FORTRAN_VERSION="4.6.0" # GCHP Spack pin
ESMF_VERSION="8.6.1"           # GCHP VALIDATED VERSION (not 8.9.1!)
GCHP_VERSION="14.7.1"
CMAKE_VERSION="3.27.9"         # Avoids curl build issues

# GCC dependencies
GMP_VERSION="6.3.0"
MPFR_VERSION="4.2.1"
MPC_VERSION="1.3.1"

# OpenMPI dependencies (build libfabric for EFA)
LIBFABRIC_VERSION="1.22.0"
HWLOC_VERSION="2.11.1"
LIBEVENT_VERSION="2.1.12"
PMIX_VERSION="5.0.3"

# Other dependencies
UDUNITS_VERSION="2.2.28"
ZLIB_VERSION="1.3.1"
LIBAEC_VERSION="1.1.3"

# ARM64/Graviton optimization flags (Neoverse V1 for Graviton 3/4, works on Graviton 2)
OPTFLAGS="-O2 -g -mcpu=neoverse-v1"

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=========================================="
log "GCHP Validated Stack Build"
log "=========================================="
log "Stack: ${STACK_NAME}"
log "Root: ${STACK_ROOT}"
log "Build: ${BUILD_DIR}"
log "CPUs: ${NCPUS}"
log "Optimization: ${OPTFLAGS}"
log ""
log "Key versions:"
log "  GCC: ${GCC_VERSION}"
log "  ESMF: ${ESMF_VERSION} (VALIDATED)"
log "  OpenMPI: ${OPENMPI_VERSION}"
log "  GCHP: ${GCHP_VERSION}"

# Minimal system prerequisites (bootstrap compiler only)
log "Installing minimal bootstrap tools..."
if command -v dnf &> /dev/null; then
    sudo dnf install -y gcc gcc-c++ gcc-gfortran make wget git bzip2 patch perl m4 openssl-devel rdma-core-devel expat-devel libxml2-devel libcurl-devel patchelf
elif command -v apt-get &> /dev/null; then
    sudo apt-get update && sudo apt-get install -y gcc g++ gfortran make wget git bzip2 patch perl m4 patchelf
elif command -v yum &> /dev/null; then
    sudo yum install -y gcc gcc-c++ gcc-gfortran make wget git bzip2 patch perl m4 patchelf
else
    log "ERROR: Unknown package manager"
    exit 1
fi

# Create directories
sudo mkdir -p "$STACK_ROOT"
sudo chown -R $(whoami):$(whoami) "$STACK_ROOT"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# ============================================================================
# 1. GCC 12.2.0 Prerequisites
# ============================================================================

log "Building GMP ${GMP_VERSION}..."
if [ ! -f "${STACK_ROOT}/gmp-${GMP_VERSION}/lib/libgmp.so" ]; then
    cd "$BUILD_DIR"
    wget -q https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz
    tar -xf gmp-${GMP_VERSION}.tar.xz
    cd gmp-${GMP_VERSION}
    ./configure --prefix="${STACK_ROOT}/gmp-${GMP_VERSION}" --enable-cxx
    make -j${NCPUS}
    make install
    log "GMP ${GMP_VERSION} installed"
else
    log "GMP ${GMP_VERSION} exists, skipping"
fi

log "Building MPFR ${MPFR_VERSION}..."
if [ ! -f "${STACK_ROOT}/mpfr-${MPFR_VERSION}/lib/libmpfr.so" ]; then
    cd "$BUILD_DIR"
    wget -q https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VERSION}.tar.xz
    tar -xf mpfr-${MPFR_VERSION}.tar.xz
    cd mpfr-${MPFR_VERSION}
    ./configure --prefix="${STACK_ROOT}/mpfr-${MPFR_VERSION}" \
        --with-gmp="${STACK_ROOT}/gmp-${GMP_VERSION}"
    make -j${NCPUS}
    make install
    log "MPFR ${MPFR_VERSION} installed"
else
    log "MPFR ${MPFR_VERSION} exists, skipping"
fi

log "Building MPC ${MPC_VERSION}..."
if [ ! -f "${STACK_ROOT}/mpc-${MPC_VERSION}/lib/libmpc.so" ]; then
    cd "$BUILD_DIR"
    wget -q https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VERSION}.tar.gz
    tar -xf mpc-${MPC_VERSION}.tar.gz
    cd mpc-${MPC_VERSION}
    ./configure --prefix="${STACK_ROOT}/mpc-${MPC_VERSION}" \
        --with-gmp="${STACK_ROOT}/gmp-${GMP_VERSION}" \
        --with-mpfr="${STACK_ROOT}/mpfr-${MPFR_VERSION}"
    make -j${NCPUS}
    make install
    log "MPC ${MPC_VERSION} installed"
else
    log "MPC ${MPC_VERSION} exists, skipping"
fi

# ============================================================================
# 2. GCC 12.2.0
# ============================================================================
log "Building GCC ${GCC_VERSION}..."
if [ ! -f "${STACK_ROOT}/gcc-${GCC_VERSION}/bin/gcc" ]; then
    cd "$BUILD_DIR"
    wget -q https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
    tar -xf gcc-${GCC_VERSION}.tar.xz
    cd gcc-${GCC_VERSION}

    mkdir -p build && cd build
    ../configure \
        --prefix="${STACK_ROOT}/gcc-${GCC_VERSION}" \
        --enable-languages=c,c++,fortran \
        --disable-multilib \
        --disable-bootstrap \
        --with-gmp="${STACK_ROOT}/gmp-${GMP_VERSION}" \
        --with-mpfr="${STACK_ROOT}/mpfr-${MPFR_VERSION}" \
        --with-mpc="${STACK_ROOT}/mpc-${MPC_VERSION}"

    make -j${NCPUS}
    make install

    log "GCC ${GCC_VERSION} installed"
else
    log "GCC ${GCC_VERSION} exists, skipping"
fi

# Set up GCC environment
export PATH="${STACK_ROOT}/gcc-${GCC_VERSION}/bin:${PATH:-}"
export LD_LIBRARY_PATH="${STACK_ROOT}/gcc-${GCC_VERSION}/lib64:${STACK_ROOT}/gmp-${GMP_VERSION}/lib:${STACK_ROOT}/mpfr-${MPFR_VERSION}/lib:${STACK_ROOT}/mpc-${MPC_VERSION}/lib:${LD_LIBRARY_PATH:-}"
export CC="${STACK_ROOT}/gcc-${GCC_VERSION}/bin/gcc"
export CXX="${STACK_ROOT}/gcc-${GCC_VERSION}/bin/g++"
export FC="${STACK_ROOT}/gcc-${GCC_VERSION}/bin/gfortran"
export F77="${STACK_ROOT}/gcc-${GCC_VERSION}/bin/gfortran"

log "Using GCC $(gcc --version | head -1)"

# ============================================================================
# 3. CMake 3.27.9
# ============================================================================
log "Building CMake ${CMAKE_VERSION}..."
if [ ! -f "${STACK_ROOT}/cmake-${CMAKE_VERSION}/bin/cmake" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}.tar.gz
    tar -xf cmake-${CMAKE_VERSION}.tar.gz
    cd cmake-${CMAKE_VERSION}

    ./bootstrap --prefix="${STACK_ROOT}/cmake-${CMAKE_VERSION}" --parallel=${NCPUS}
    make -j${NCPUS}
    make install

    log "CMake ${CMAKE_VERSION} installed"
else
    log "CMake ${CMAKE_VERSION} exists, skipping"
fi

export PATH="${STACK_ROOT}/cmake-${CMAKE_VERSION}/bin:$PATH"

# ============================================================================
# 4. OpenMPI Dependencies
# ============================================================================

log "Building zlib ${ZLIB_VERSION}..."
if [ ! -f "${STACK_ROOT}/zlib-${ZLIB_VERSION}/lib/libz.so" ]; then
    cd "$BUILD_DIR"
    wget -q -O zlib-${ZLIB_VERSION}.tar.gz https://github.com/madler/zlib/archive/refs/tags/v${ZLIB_VERSION}.tar.gz
    tar -xf zlib-${ZLIB_VERSION}.tar.gz
    cd zlib-${ZLIB_VERSION}
    ./configure --prefix="${STACK_ROOT}/zlib-${ZLIB_VERSION}"
    make -j${NCPUS}
    make install
    log "zlib ${ZLIB_VERSION} installed"
else
    log "zlib ${ZLIB_VERSION} exists, skipping"
fi

export LD_LIBRARY_PATH="${STACK_ROOT}/zlib-${ZLIB_VERSION}/lib:$LD_LIBRARY_PATH"

log "Building hwloc ${HWLOC_VERSION}..."
if [ ! -f "${STACK_ROOT}/hwloc-${HWLOC_VERSION}/bin/hwloc-info" ]; then
    cd "$BUILD_DIR"
    wget -q https://download.open-mpi.org/release/hwloc/v2.11/hwloc-${HWLOC_VERSION}.tar.gz
    tar -xf hwloc-${HWLOC_VERSION}.tar.gz
    cd hwloc-${HWLOC_VERSION}
    ./configure --prefix="${STACK_ROOT}/hwloc-${HWLOC_VERSION}"
    make -j${NCPUS}
    make install
    log "hwloc ${HWLOC_VERSION} installed"
else
    log "hwloc ${HWLOC_VERSION} exists, skipping"
fi

log "Building libevent ${LIBEVENT_VERSION}..."
if [ ! -f "${STACK_ROOT}/libevent-${LIBEVENT_VERSION}/lib/libevent.so" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}-stable/libevent-${LIBEVENT_VERSION}-stable.tar.gz
    tar -xf libevent-${LIBEVENT_VERSION}-stable.tar.gz
    cd libevent-${LIBEVENT_VERSION}-stable
    ./configure --prefix="${STACK_ROOT}/libevent-${LIBEVENT_VERSION}"
    make -j${NCPUS}
    make install
    log "libevent ${LIBEVENT_VERSION} installed"
else
    log "libevent ${LIBEVENT_VERSION} exists, skipping"
fi

log "Building PMIx ${PMIX_VERSION}..."
if [ ! -f "${STACK_ROOT}/pmix-${PMIX_VERSION}/lib/libpmix.so" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/openpmix/openpmix/releases/download/v${PMIX_VERSION}/pmix-${PMIX_VERSION}.tar.gz
    tar -xf pmix-${PMIX_VERSION}.tar.gz
    cd pmix-${PMIX_VERSION}
    ./configure --prefix="${STACK_ROOT}/pmix-${PMIX_VERSION}" \
        --with-libevent="${STACK_ROOT}/libevent-${LIBEVENT_VERSION}" \
        --with-hwloc="${STACK_ROOT}/hwloc-${HWLOC_VERSION}"
    make -j${NCPUS}
    make install
    log "PMIx ${PMIX_VERSION} installed"
else
    log "PMIx ${PMIX_VERSION} exists, skipping"
fi

log "Building libfabric ${LIBFABRIC_VERSION} (EFA support)..."
if [ ! -f "${STACK_ROOT}/libfabric-${LIBFABRIC_VERSION}/lib/libfabric.so" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/ofiwg/libfabric/releases/download/v${LIBFABRIC_VERSION}/libfabric-${LIBFABRIC_VERSION}.tar.bz2
    tar -xf libfabric-${LIBFABRIC_VERSION}.tar.bz2
    cd libfabric-${LIBFABRIC_VERSION}
    ./configure --prefix="${STACK_ROOT}/libfabric-${LIBFABRIC_VERSION}" \
        --enable-efa \
        --enable-tcp \
        --enable-udp \
        --enable-sockets
    make -j${NCPUS}
    make install
    log "libfabric ${LIBFABRIC_VERSION} installed"
else
    log "libfabric ${LIBFABRIC_VERSION} exists, skipping"
fi

# ============================================================================
# 5. OpenMPI 4.1.7
# ============================================================================
log "Building OpenMPI ${OPENMPI_VERSION}..."
if [ ! -f "${STACK_ROOT}/openmpi-${OPENMPI_VERSION}/bin/mpirun" ]; then
    cd "$BUILD_DIR"
    wget -q https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-${OPENMPI_VERSION}.tar.gz
    tar -xf openmpi-${OPENMPI_VERSION}.tar.gz
    cd openmpi-${OPENMPI_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/openmpi-${OPENMPI_VERSION}" \
        --with-libfabric="${STACK_ROOT}/libfabric-${LIBFABRIC_VERSION}" \
        --with-hwloc="${STACK_ROOT}/hwloc-${HWLOC_VERSION}" \
        --with-libevent="${STACK_ROOT}/libevent-${LIBEVENT_VERSION}" \
        --with-pmix="${STACK_ROOT}/pmix-${PMIX_VERSION}" \
        --enable-mpi1-compatibility \
        --enable-mpirun-prefix-by-default \
        --without-verbs \
        CC="$CC" CXX="$CXX" FC="$FC"

    make -j${NCPUS}
    make install

    log "OpenMPI ${OPENMPI_VERSION} installed"
else
    log "OpenMPI ${OPENMPI_VERSION} exists, skipping"
fi

export PATH="${STACK_ROOT}/openmpi-${OPENMPI_VERSION}/bin:$PATH"
export LD_LIBRARY_PATH="${STACK_ROOT}/openmpi-${OPENMPI_VERSION}/lib:${STACK_ROOT}/libfabric-${LIBFABRIC_VERSION}/lib:${STACK_ROOT}/hwloc-${HWLOC_VERSION}/lib:${STACK_ROOT}/libevent-${LIBEVENT_VERSION}/lib:${STACK_ROOT}/pmix-${PMIX_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 6. libaec (szip replacement for HDF5)
# ============================================================================
log "Building libaec ${LIBAEC_VERSION}..."
if [ ! -f "${STACK_ROOT}/libaec-${LIBAEC_VERSION}/lib/libaec.so" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/Deutsches-Klimarechenzentrum/libaec/releases/download/v${LIBAEC_VERSION}/libaec-${LIBAEC_VERSION}.tar.gz
    tar -xf libaec-${LIBAEC_VERSION}.tar.gz
    cd libaec-${LIBAEC_VERSION}
    mkdir -p build && cd build
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="${STACK_ROOT}/libaec-${LIBAEC_VERSION}" \
        -DCMAKE_BUILD_TYPE=Release
    make -j${NCPUS}
    make install
    log "libaec ${LIBAEC_VERSION} installed"
else
    log "libaec ${LIBAEC_VERSION} exists, skipping"
fi

# ============================================================================
# 7. HDF5 1.14.0
# ============================================================================
log "Building HDF5 ${HDF5_VERSION}..."
if [ ! -f "${STACK_ROOT}/hdf5-${HDF5_VERSION}/bin/h5dump" ]; then
    cd "$BUILD_DIR"
    wget -q https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-1.14/hdf5-${HDF5_VERSION}/src/hdf5-${HDF5_VERSION}.tar.gz
    tar -xf hdf5-${HDF5_VERSION}.tar.gz
    cd hdf5-${HDF5_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/hdf5-${HDF5_VERSION}" \
        --enable-parallel \
        --enable-fortran \
        --enable-hl \
        --with-zlib="${STACK_ROOT}/zlib-${ZLIB_VERSION}" \
        --with-szlib="${STACK_ROOT}/libaec-${LIBAEC_VERSION}" \
        CC=mpicc FC=mpifort \
        CFLAGS="$OPTFLAGS" FCFLAGS="$OPTFLAGS"

    make -j${NCPUS}
    make install

    log "HDF5 ${HDF5_VERSION} installed"
else
    log "HDF5 ${HDF5_VERSION} exists, skipping"
fi

export PATH="${STACK_ROOT}/hdf5-${HDF5_VERSION}/bin:$PATH"
export LD_LIBRARY_PATH="${STACK_ROOT}/hdf5-${HDF5_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 8. NetCDF-C 4.9.2
# ============================================================================
log "Building NetCDF-C ${NETCDF_C_VERSION}..."
if [ ! -f "${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/bin/nc-config" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/Unidata/netcdf-c/archive/refs/tags/v${NETCDF_C_VERSION}.tar.gz
    tar -xf v${NETCDF_C_VERSION}.tar.gz
    cd netcdf-c-${NETCDF_C_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}" \
        --enable-parallel-tests \
        --disable-dap \
        CC=mpicc \
        CFLAGS="$OPTFLAGS" \
        CPPFLAGS="-I${STACK_ROOT}/hdf5-${HDF5_VERSION}/include -I${STACK_ROOT}/zlib-${ZLIB_VERSION}/include" \
        LDFLAGS="-L${STACK_ROOT}/hdf5-${HDF5_VERSION}/lib -L${STACK_ROOT}/zlib-${ZLIB_VERSION}/lib"

    make -j${NCPUS}
    make install

    log "NetCDF-C ${NETCDF_C_VERSION} installed"
else
    log "NetCDF-C ${NETCDF_C_VERSION} exists, skipping"
fi

export PATH="${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/bin:$PATH"
export LD_LIBRARY_PATH="${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 9. NetCDF-Fortran 4.6.0
# ============================================================================
log "Building NetCDF-Fortran ${NETCDF_FORTRAN_VERSION}..."
if [ ! -f "${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/bin/nf-config" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v${NETCDF_FORTRAN_VERSION}.tar.gz
    tar -xf v${NETCDF_FORTRAN_VERSION}.tar.gz
    cd netcdf-fortran-${NETCDF_FORTRAN_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}" \
        CC=mpicc FC=mpifort \
        CFLAGS="$OPTFLAGS" FCFLAGS="$OPTFLAGS" \
        CPPFLAGS="-I${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/include" \
        LDFLAGS="-L${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/lib"

    make -j${NCPUS}
    make install

    log "NetCDF-Fortran ${NETCDF_FORTRAN_VERSION} installed"
else
    log "NetCDF-Fortran ${NETCDF_FORTRAN_VERSION} exists, skipping"
fi

export LD_LIBRARY_PATH="${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 10. udunits2 2.2.28
# ============================================================================
log "Building udunits2 ${UDUNITS_VERSION}..."
if [ ! -f "${STACK_ROOT}/udunits-${UDUNITS_VERSION}/bin/udunits2" ]; then
    cd "$BUILD_DIR"
    wget -q https://downloads.unidata.ucar.edu/udunits/${UDUNITS_VERSION}/udunits-${UDUNITS_VERSION}.tar.gz
    tar -xf udunits-${UDUNITS_VERSION}.tar.gz
    cd udunits-${UDUNITS_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/udunits-${UDUNITS_VERSION}" \
        CC="$CC" \
        CFLAGS="$OPTFLAGS"

    make -j${NCPUS}
    make install

    log "udunits2 ${UDUNITS_VERSION} installed"
else
    log "udunits2 ${UDUNITS_VERSION} exists, skipping"
fi

export PATH="${STACK_ROOT}/udunits-${UDUNITS_VERSION}/bin:$PATH"
export LD_LIBRARY_PATH="${STACK_ROOT}/udunits-${UDUNITS_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 11. ESMF 8.6.1 (VALIDATED VERSION)
# ============================================================================
log "Building ESMF ${ESMF_VERSION} (VALIDATED)..."
if [ ! -f "${STACK_ROOT}/esmf-${ESMF_VERSION}/bin/ESMF_Info" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/esmf-org/esmf/archive/refs/tags/v${ESMF_VERSION}.tar.gz
    tar -xf v${ESMF_VERSION}.tar.gz
    cd esmf-${ESMF_VERSION}

    export ESMF_DIR=$(pwd)
    export ESMF_INSTALL_PREFIX="${STACK_ROOT}/esmf-${ESMF_VERSION}"
    export ESMF_COMM=openmpi
    export ESMF_COMPILER=gfortran
    export ESMF_NETCDF=nc-config
    export ESMF_NETCDF_INCLUDE="${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/include"
    export ESMF_NETCDF_LIBS="-L${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/lib -L${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/lib -lnetcdff -lnetcdf"
    export ESMF_CXXCOMPILEOPTS="$OPTFLAGS"
    export ESMF_F90COMPILEOPTS="$OPTFLAGS -I${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/include"

    make -j${NCPUS}
    # Manual install for ESMF 8.6.1 (install_libs target doesn't exist in this version)
    # Copy built libraries, modules, headers, and create esmf.mk
    cp -r lib "${ESMF_INSTALL_PREFIX}/"
    cp -r mod "${ESMF_INSTALL_PREFIX}/"
    cp -r src/include "${ESMF_INSTALL_PREFIX}/"
    # Generate esmf.mk metadata file
    make info_mk

    # CRITICAL: ESMF 8.6.1 builds libesmf.so WITHOUT a SONAME. When GCHP links
    # against a SONAME-less library, the linker records the full build-time path
    # as the NEEDED entry (e.g. /tmp/.../libesmf.so), which breaks at runtime when
    # the stack is deployed at a different path via FSx. Set the SONAME so GCHP
    # records just "libesmf.so", resolvable via RUNPATH/LD_LIBRARY_PATH.
    ESMF_SO=$(find "${ESMF_INSTALL_PREFIX}/lib" -name "libesmf.so" -type f | head -1)
    if [ -n "$ESMF_SO" ]; then
        patchelf --set-soname libesmf.so "$ESMF_SO"
        log "Set SONAME on ${ESMF_SO}"
    else
        log "WARNING: libesmf.so not found for SONAME fix"
    fi

    log "ESMF ${ESMF_VERSION} installed"
else
    log "ESMF ${ESMF_VERSION} exists, skipping"
fi

export ESMF_ROOT="${STACK_ROOT}/esmf-${ESMF_VERSION}"
export LD_LIBRARY_PATH="${ESMF_ROOT}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 12. GCHP 14.7.1
# ============================================================================
log "Building GCHP ${GCHP_VERSION}..."
if [ ! -d "${STACK_ROOT}/gchp-${GCHP_VERSION}" ]; then
    cd "$BUILD_DIR"
    git clone --depth 1 --branch ${GCHP_VERSION} https://github.com/geoschem/GCHP.git gchp-${GCHP_VERSION}
    cd gchp-${GCHP_VERSION}
    git submodule update --init --recursive

    mkdir -p build && cd build

    # Build RPATH for portable binaries
    GCHP_RPATH="${STACK_ROOT}/esmf-${ESMF_VERSION}/lib/libO/Linux.gfortran.64.openmpi.default"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/openmpi-${OPENMPI_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/hdf5-${HDF5_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/udunits-${UDUNITS_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/gcc-${GCC_VERSION}/lib64"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/libfabric-${LIBFABRIC_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/hwloc-${HWLOC_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/pmix-${PMIX_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/libevent-${LIBEVENT_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/zlib-${ZLIB_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/gmp-${GMP_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/mpfr-${MPFR_VERSION}/lib"
    GCHP_RPATH="${GCHP_RPATH}:${STACK_ROOT}/mpc-${MPC_VERSION}/lib"

    cmake .. \
        -DCMAKE_INSTALL_PREFIX="${STACK_ROOT}/gchp-${GCHP_VERSION}" \
        -DCMAKE_C_COMPILER=mpicc \
        -DCMAKE_CXX_COMPILER=mpicxx \
        -DCMAKE_Fortran_COMPILER=mpifort \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_RPATH="${GCHP_RPATH}" \
        -DCMAKE_BUILD_RPATH="${GCHP_RPATH}" \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=TRUE \
        -DMPI_LOAD_BALANCE=ON \
        -DNETCDF_C_LIBRARY="${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/lib/libnetcdf.so" \
        -DNETCDF_C_INCLUDE_DIR="${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/include" \
        -DNETCDF_F_LIBRARY="${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/lib/libnetcdff.so" \
        -DNETCDF_F90_INCLUDE_DIR="${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/include" \
        -DNETCDF_F77_INCLUDE_DIR="${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/include" \
        -Dudunits_LIBRARY="${STACK_ROOT}/udunits-${UDUNITS_VERSION}/lib/libudunits2.so" \
        -Dudunits_INCLUDE_DIR="${STACK_ROOT}/udunits-${UDUNITS_VERSION}/include" \
        -Dudunits_XML_PATH="${STACK_ROOT}/udunits-${UDUNITS_VERSION}/share/udunits/udunits2.xml"

    make -j${NCPUS}
    make install

    log "GCHP ${GCHP_VERSION} installed"
else
    log "GCHP ${GCHP_VERSION} already exists, skipping"
fi

# ============================================================================
# 13. Create environment setup script
# ============================================================================
log "Creating environment setup script..."
cat > "${STACK_ROOT}/gchp-env.sh" <<EOF
#!/bin/bash
# GCHP Validated Environment Setup (ARM64/Graviton)
# Stack: ${STACK_NAME}
# Self-contained, OS-agnostic, RELOCATABLE

# Derive STACK_ROOT from this script's own location so the stack works at ANY
# mount path (e.g. /fsx/stacks/aarch64/...). Must be sourced, not executed.
if [ -n "\${BASH_SOURCE[0]}" ]; then
    STACK_ROOT="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
else
    STACK_ROOT="${STACK_ROOT}"  # fallback to build-time path
fi

# GCC ${GCC_VERSION}
export PATH="\$STACK_ROOT/gcc-${GCC_VERSION}/bin:\$PATH"
export LD_LIBRARY_PATH="\$STACK_ROOT/gcc-${GCC_VERSION}/lib64:\$STACK_ROOT/gmp-${GMP_VERSION}/lib:\$STACK_ROOT/mpfr-${MPFR_VERSION}/lib:\$STACK_ROOT/mpc-${MPC_VERSION}/lib:\$LD_LIBRARY_PATH"

# CMake ${CMAKE_VERSION}
export PATH="\$STACK_ROOT/cmake-${CMAKE_VERSION}/bin:\$PATH"

# OpenMPI ${OPENMPI_VERSION}
export PATH="\$STACK_ROOT/openmpi-${OPENMPI_VERSION}/bin:\$PATH"
export LD_LIBRARY_PATH="\$STACK_ROOT/openmpi-${OPENMPI_VERSION}/lib:\$STACK_ROOT/libfabric-${LIBFABRIC_VERSION}/lib:\$STACK_ROOT/hwloc-${HWLOC_VERSION}/lib:\$STACK_ROOT/libevent-${LIBEVENT_VERSION}/lib:\$STACK_ROOT/pmix-${PMIX_VERSION}/lib:\$LD_LIBRARY_PATH"

# zlib ${ZLIB_VERSION}
export LD_LIBRARY_PATH="\$STACK_ROOT/zlib-${ZLIB_VERSION}/lib:\$LD_LIBRARY_PATH"

# HDF5 ${HDF5_VERSION}
export PATH="\$STACK_ROOT/hdf5-${HDF5_VERSION}/bin:\$PATH"
export LD_LIBRARY_PATH="\$STACK_ROOT/hdf5-${HDF5_VERSION}/lib:\$LD_LIBRARY_PATH"

# NetCDF-C ${NETCDF_C_VERSION}
export PATH="\$STACK_ROOT/netcdf-c-${NETCDF_C_VERSION}/bin:\$PATH"
export LD_LIBRARY_PATH="\$STACK_ROOT/netcdf-c-${NETCDF_C_VERSION}/lib:\$LD_LIBRARY_PATH"

# NetCDF-Fortran ${NETCDF_FORTRAN_VERSION}
export LD_LIBRARY_PATH="\$STACK_ROOT/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/lib:\$LD_LIBRARY_PATH"

# udunits ${UDUNITS_VERSION}
export PATH="\$STACK_ROOT/udunits-${UDUNITS_VERSION}/bin:\$PATH"
export LD_LIBRARY_PATH="\$STACK_ROOT/udunits-${UDUNITS_VERSION}/lib:\$LD_LIBRARY_PATH"

# ESMF ${ESMF_VERSION} (lib lives in an arch-specific libO/Linux.gfortran.*.openmpi.default subdir)
export ESMF_ROOT="\$STACK_ROOT/esmf-${ESMF_VERSION}"
ESMF_LIBDIR="\$(dirname "\$(find "\$ESMF_ROOT/lib" -name libesmf.so -type f 2>/dev/null | head -1)")"
export LD_LIBRARY_PATH="\${ESMF_LIBDIR:-\$ESMF_ROOT/lib}:\$LD_LIBRARY_PATH"

# GCHP ${GCHP_VERSION}
export GCHP_ROOT="\$STACK_ROOT/gchp-${GCHP_VERSION}"

# OpenMPI/PMIx relocation: these tools bake their configure --prefix into their
# binaries. Override it so mpirun/PMIx find their plugins + help files regardless
# of where the stack is mounted. Without these, mpirun fails with "unknown option".
export OPAL_PREFIX="\$STACK_ROOT/openmpi-${OPENMPI_VERSION}"
export PMIX_PREFIX="\$STACK_ROOT/pmix-${PMIX_VERSION}"

echo "✅ GCHP Validated Stack (ARM64): ${STACK_NAME}"
gcc --version | head -1
mpirun --version | head -1
echo "ESMF: ${ESMF_VERSION} (validated)"
echo "Architecture: ARM64/AArch64 (Graviton)"
EOF

chmod +x "${STACK_ROOT}/gchp-env.sh"

# Ship the run-dir helper in the stack if it's available next to this build script
# (so deployed clusters have one-command run setup). Harmless if absent.
HELPER_SRC="$(dirname "$0")/../../scripts/gchp-setup-rundir.sh"
if [ -f "$HELPER_SRC" ]; then
    cp "$HELPER_SRC" "${STACK_ROOT}/gchp-setup-rundir.sh"
    chmod +x "${STACK_ROOT}/gchp-setup-rundir.sh"
    log "Bundled gchp-setup-rundir.sh into stack"
fi

# ============================================================================
# 14. Create manifest
# ============================================================================
log "Creating manifest..."
cat > "${STACK_ROOT}/manifest.yaml" <<EOF
---
stack_name: ${STACK_NAME}
created_date: $(date +%Y-%m-%d)
build_host: $(hostname)
os_agnostic: true
architecture: aarch64
optimizations: ${OPTFLAGS}

compiler:
  name: GCC
  version: ${GCC_VERSION}
  from_source: true

mpi:
  name: OpenMPI
  version: ${OPENMPI_VERSION}
  efa_support: true
  libfabric_version: ${LIBFABRIC_VERSION}
  from_source: true

libraries:
  - name: ESMF
    version: ${ESMF_VERSION}
    note: "VALIDATED version from GCHP Spack scope"
  - name: HDF5
    version: ${HDF5_VERSION}
  - name: NetCDF-C
    version: ${NETCDF_C_VERSION}
  - name: NetCDF-Fortran
    version: ${NETCDF_FORTRAN_VERSION}
  - name: udunits2
    version: ${UDUNITS_VERSION}
  - name: CMake
    version: ${CMAKE_VERSION}

application:
  name: GCHP
  version: ${GCHP_VERSION}

dependencies_from_source:
  - gmp-${GMP_VERSION}
  - mpfr-${MPFR_VERSION}
  - mpc-${MPC_VERSION}
  - zlib-${ZLIB_VERSION}
  - libaec-${LIBAEC_VERSION}
  - hwloc-${HWLOC_VERSION}
  - libevent-${LIBEVENT_VERSION}
  - pmix-${PMIX_VERSION}
  - libfabric-${LIBFABRIC_VERSION}

deployment:
  method: FSx Lustre S3-backed
  portable: true
  os_dependencies: none (kernel only)

notes: |
  Completely self-contained GCHP stack for ARM64/Graviton.
  All dependencies built from source.
  ESMF 8.6.1 is the validated version from GCHP Spack scope.
  No OS package dependencies beyond kernel.
  Optimized for AWS Graviton 3/4 (Neoverse V1).
  Compatible with Graviton 2 (neoverse-v1 is backwards compatible).
  Ready for S3 export via FSx Lustre.
EOF

log "=========================================="
log "Build complete!"
log "=========================================="
log "Stack: ${STACK_ROOT}"
log "Environment: source ${STACK_ROOT}/gchp-env.sh"
log ""
log "Verify:"
log "  source ${STACK_ROOT}/gchp-env.sh"
log "  gcc --version"
log "  mpirun --version"
log "  ompi_info | grep osc"
log ""
log "Build log: ${LOG_FILE}"
