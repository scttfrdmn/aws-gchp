#!/bin/bash
#
# GCHP Software Stack Builder
# Builds: gcc12.3-ompi4.1.7-gchp14.7.1
#
# Run on: Amazon Linux 2023 builder cluster head node
# Duration: ~3-4 hours for full build
# Output: /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/
# S3 Sync: s3://gchp-shared-storage-us-east-2/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/

set -e  # Exit on error
set -u  # Error on undefined variables

# Configuration
STACK_NAME="gcc12.3-ompi4.1.7-gchp14.7.1"
STACK_ROOT="/fsx/stacks/${STACK_NAME}"
BUILD_DIR="/tmp/gchp-build"
LOG_FILE="/fsx/build-${STACK_NAME}.log"
NCPUS=$(nproc)

# Software versions (GCHP 14.7.1 compatible)
GCC_VERSION="12.3.0"
OPENMPI_VERSION="4.1.7"
HDF5_VERSION="1.14.6"
NETCDF_C_VERSION="4.10.0"
NETCDF_FORTRAN_VERSION="4.6.2"
ESMF_VERSION="8.9.1"
GCHP_VERSION="14.7.1"
CMAKE_VERSION="3.28.3"

# Optimization flags (AMD Zen 3 compatible - works on Zen 3/4/5)
OPTFLAGS="-O3 -march=znver3 -mtune=znver3"

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=========================================="
log "GCHP Stack Build: ${STACK_NAME}"
log "=========================================="
log "Stack root: ${STACK_ROOT}"
log "Build directory: ${BUILD_DIR}"
log "CPUs available: ${NCPUS}"
log "Optimization: ${OPTFLAGS}"

# Install AL2023 system prerequisites
log "Installing system prerequisites..."
sudo dnf install -y --allowerasing \
    gcc gcc-c++ gcc-gfortran \
    make cmake automake libtool \
    bzip2 curl wget git \
    zlib-devel bzip2-devel \
    libcurl-devel openssl-devel \
    expat-devel \
    perl perl-Data-Dumper \
    m4 diffutils patch

# Check AWS EFA installer
if ! command -v fi_info &> /dev/null; then
    log "Installing AWS EFA..."
    cd /tmp
    curl -O https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
    tar -xf aws-efa-installer-latest.tar.gz
    cd aws-efa-installer
    sudo ./efa_installer.sh -y --minimal
    [ -f /etc/profile.d/efa.sh ] && source /etc/profile.d/efa.sh || true
fi

# Create directories
mkdir -p "$STACK_ROOT"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# ============================================================================
# 1. GCC 12.3.0 (from source)
# ============================================================================
log "Building GCC ${GCC_VERSION}..."
if [ ! -f "${STACK_ROOT}/gcc-${GCC_VERSION}/bin/gcc" ]; then
    cd "$BUILD_DIR"
    wget -q https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
    tar -xf gcc-${GCC_VERSION}.tar.xz
    cd gcc-${GCC_VERSION}

    # Download prerequisites
    ./contrib/download_prerequisites

    # Configure
    mkdir -p build && cd build
    ../configure \
        --prefix="${STACK_ROOT}/gcc-${GCC_VERSION}" \
        --enable-languages=c,c++,fortran \
        --disable-multilib \
        --disable-bootstrap

    # Build (this takes ~2 hours)
    make -j${NCPUS}
    make install

    log "GCC ${GCC_VERSION} installed successfully"
else
    log "GCC ${GCC_VERSION} already exists, skipping"
fi

# Set up GCC environment for remaining builds
export PATH="${STACK_ROOT}/gcc-${GCC_VERSION}/bin:${PATH:-}"
export LD_LIBRARY_PATH="${STACK_ROOT}/gcc-${GCC_VERSION}/lib64:${LD_LIBRARY_PATH:-}"
export CC="${STACK_ROOT}/gcc-${GCC_VERSION}/bin/gcc"
export CXX="${STACK_ROOT}/gcc-${GCC_VERSION}/bin/g++"
export FC="${STACK_ROOT}/gcc-${GCC_VERSION}/bin/gfortran"
export F77="${STACK_ROOT}/gcc-${GCC_VERSION}/bin/gfortran"

log "Using GCC $(gcc --version | head -1)"

# ============================================================================
# 2. CMake 3.28.3 (GCHP requires >=3.24)
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

    log "CMake ${CMAKE_VERSION} installed successfully"
else
    log "CMake ${CMAKE_VERSION} already exists, skipping"
fi

export PATH="${STACK_ROOT}/cmake-${CMAKE_VERSION}/bin:$PATH"

# ============================================================================
# 3. OpenMPI 4.1.7 (with EFA support)
# ============================================================================
log "Building OpenMPI ${OPENMPI_VERSION}..."
if [ ! -f "${STACK_ROOT}/openmpi-${OPENMPI_VERSION}/bin/mpirun" ]; then
    cd "$BUILD_DIR"
    wget -q https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-${OPENMPI_VERSION}.tar.gz
    tar -xf openmpi-${OPENMPI_VERSION}.tar.gz
    cd openmpi-${OPENMPI_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/openmpi-${OPENMPI_VERSION}" \
        --with-libfabric=/opt/amazon/efa \
        --enable-mpirun-prefix-by-default \
        --without-verbs \
        CC="$CC" CXX="$CXX" FC="$FC"

    make -j${NCPUS}
    make install

    log "OpenMPI ${OPENMPI_VERSION} installed successfully"
else
    log "OpenMPI ${OPENMPI_VERSION} already exists, skipping"
fi

export PATH="${STACK_ROOT}/openmpi-${OPENMPI_VERSION}/bin:$PATH"
export LD_LIBRARY_PATH="${STACK_ROOT}/openmpi-${OPENMPI_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 4. HDF5 1.14.6
# ============================================================================
log "Building HDF5 ${HDF5_VERSION}..."
if [ ! -f "${STACK_ROOT}/hdf5-${HDF5_VERSION}/bin/h5dump" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/HDFGroup/hdf5/releases/download/hdf5_1.14.6/hdf5-${HDF5_VERSION}.tar.gz
    tar -xf hdf5-${HDF5_VERSION}.tar.gz
    cd hdf5-${HDF5_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/hdf5-${HDF5_VERSION}" \
        --enable-parallel \
        --enable-fortran \
        CC="mpicc" FC="mpifort" \
        CFLAGS="$OPTFLAGS" FCFLAGS="$OPTFLAGS"

    make -j${NCPUS}
    make install

    log "HDF5 ${HDF5_VERSION} installed successfully"
else
    log "HDF5 ${HDF5_VERSION} already exists, skipping"
fi

export PATH="${STACK_ROOT}/hdf5-${HDF5_VERSION}/bin:$PATH"
export LD_LIBRARY_PATH="${STACK_ROOT}/hdf5-${HDF5_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 5. NetCDF-C 4.10.0
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
        CC="mpicc" \
        CFLAGS="$OPTFLAGS" \
        CPPFLAGS="-I${STACK_ROOT}/hdf5-${HDF5_VERSION}/include" \
        LDFLAGS="-L${STACK_ROOT}/hdf5-${HDF5_VERSION}/lib"

    make -j${NCPUS}
    make install

    log "NetCDF-C ${NETCDF_C_VERSION} installed successfully"
else
    log "NetCDF-C ${NETCDF_C_VERSION} already exists, skipping"
fi

export PATH="${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/bin:$PATH"
export LD_LIBRARY_PATH="${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 6. NetCDF-Fortran 4.6.2
# ============================================================================
log "Building NetCDF-Fortran ${NETCDF_FORTRAN_VERSION}..."
if [ ! -f "${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/bin/nf-config" ]; then
    cd "$BUILD_DIR"
    wget -q https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v${NETCDF_FORTRAN_VERSION}.tar.gz
    tar -xf v${NETCDF_FORTRAN_VERSION}.tar.gz
    cd netcdf-fortran-${NETCDF_FORTRAN_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}" \
        CC="mpicc" FC="mpifort" \
        CFLAGS="$OPTFLAGS" FCFLAGS="$OPTFLAGS" \
        CPPFLAGS="-I${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/include" \
        LDFLAGS="-L${STACK_ROOT}/netcdf-c-${NETCDF_C_VERSION}/lib"

    make -j${NCPUS}
    make install

    log "NetCDF-Fortran ${NETCDF_FORTRAN_VERSION} installed successfully"
else
    log "NetCDF-Fortran ${NETCDF_FORTRAN_VERSION} already exists, skipping"
fi

export LD_LIBRARY_PATH="${STACK_ROOT}/netcdf-fortran-${NETCDF_FORTRAN_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 7. udunits2 2.2.28
# ============================================================================
UDUNITS_VERSION="2.2.28"
log "Building udunits2 ${UDUNITS_VERSION}..."
if [ ! -f "${STACK_ROOT}/udunits-${UDUNITS_VERSION}/bin/udunits2" ]; then
    cd "$BUILD_DIR"
    wget -q https://downloads.unidata.ucar.edu/udunits/${UDUNITS_VERSION}/udunits-${UDUNITS_VERSION}.tar.gz
    tar -xf udunits-${UDUNITS_VERSION}.tar.gz
    cd udunits-${UDUNITS_VERSION}

    ./configure \
        --prefix="${STACK_ROOT}/udunits-${UDUNITS_VERSION}" \
        CC="mpicc" \
        CFLAGS="$OPTFLAGS"

    make -j${NCPUS}
    make install

    log "udunits2 ${UDUNITS_VERSION} installed successfully"
else
    log "udunits2 ${UDUNITS_VERSION} already exists, skipping"
fi

export PATH="${STACK_ROOT}/udunits-${UDUNITS_VERSION}/bin:$PATH"
export LD_LIBRARY_PATH="${STACK_ROOT}/udunits-${UDUNITS_VERSION}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 8. ESMF 8.9.1
# ============================================================================
log "Building ESMF ${ESMF_VERSION}..."
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
    make install

    log "ESMF ${ESMF_VERSION} installed successfully"
else
    log "ESMF ${ESMF_VERSION} already exists, skipping"
fi

export ESMF_ROOT="${STACK_ROOT}/esmf-${ESMF_VERSION}"
export LD_LIBRARY_PATH="${ESMF_ROOT}/lib:$LD_LIBRARY_PATH"

# ============================================================================
# 9. GCHP 14.7.1
# ============================================================================
log "Building GCHP ${GCHP_VERSION}..."
if [ ! -d "${STACK_ROOT}/gchp-${GCHP_VERSION}" ]; then
    cd "$BUILD_DIR"
    git clone --depth 1 --branch ${GCHP_VERSION} https://github.com/geoschem/GCHP.git gchp-${GCHP_VERSION}
    cd gchp-${GCHP_VERSION}
    git submodule update --init --recursive

    mkdir -p build && cd build
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="${STACK_ROOT}/gchp-${GCHP_VERSION}" \
        -DCMAKE_C_COMPILER=mpicc \
        -DCMAKE_CXX_COMPILER=mpicxx \
        -DCMAKE_Fortran_COMPILER=mpifort \
        -DCMAKE_BUILD_TYPE=Release \
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

    log "GCHP ${GCHP_VERSION} installed successfully"
else
    log "GCHP ${GCHP_VERSION} already exists, skipping"
fi

# ============================================================================
# 10. Create environment setup script
# ============================================================================
log "Creating environment setup script..."
cat > "${STACK_ROOT}/gchp-env.sh" <<'EOF'
#!/bin/bash
# GCHP Environment Setup
# Stack: gcc12.3-ompi4.1.7-gchp14.7.1

STACK_ROOT="/fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1"

# GCC 12.3.0
export PATH="$STACK_ROOT/gcc-12.3.0/bin:$PATH"
export LD_LIBRARY_PATH="$STACK_ROOT/gcc-12.3.0/lib64:$LD_LIBRARY_PATH"

# CMake 3.28.3
export PATH="$STACK_ROOT/cmake-3.28.3/bin:$PATH"

# OpenMPI 4.1.7
export PATH="$STACK_ROOT/openmpi-4.1.7/bin:$PATH"
export LD_LIBRARY_PATH="$STACK_ROOT/openmpi-4.1.7/lib:$LD_LIBRARY_PATH"

# HDF5 1.14.6
export PATH="$STACK_ROOT/hdf5-1.14.6/bin:$PATH"
export LD_LIBRARY_PATH="$STACK_ROOT/hdf5-1.14.6/lib:$LD_LIBRARY_PATH"

# NetCDF-C 4.10.0
export PATH="$STACK_ROOT/netcdf-c-4.10.0/bin:$PATH"
export LD_LIBRARY_PATH="$STACK_ROOT/netcdf-c-4.10.0/lib:$LD_LIBRARY_PATH"

# NetCDF-Fortran 4.6.2
export LD_LIBRARY_PATH="$STACK_ROOT/netcdf-fortran-4.6.2/lib:$LD_LIBRARY_PATH"

# ESMF 8.9.1
export ESMF_ROOT="$STACK_ROOT/esmf-8.9.1"
export LD_LIBRARY_PATH="$ESMF_ROOT/lib:$LD_LIBRARY_PATH"

# GCHP 14.7.1
export GCHP_ROOT="$STACK_ROOT/gchp-14.7.1"

echo "✅ Loaded GCHP stack: gcc12.3-ompi4.1.7-gchp14.7.1"
gcc --version | head -1
mpirun --version | head -1
EOF

chmod +x "${STACK_ROOT}/gchp-env.sh"

# ============================================================================
# 10. Create manifest file
# ============================================================================
log "Creating manifest file..."
cat > "${STACK_ROOT}/manifest.yaml" <<EOF
---
stack_name: gcc12.3-ompi4.1.7-gchp14.7.1
created_date: $(date +%Y-%m-%d)
build_host: $(hostname)
status: testing
architecture: x86_64
optimizations: ${OPTFLAGS}

compiler:
  name: GCC
  version: ${GCC_VERSION}
  source: https://ftp.gnu.org/gnu/gcc/

mpi:
  name: OpenMPI
  version: ${OPENMPI_VERSION}
  efa_support: true
  transport: ofi
  process_manager: pmi

libraries:
  - name: HDF5
    version: ${HDF5_VERSION}
  - name: NetCDF-C
    version: ${NETCDF_C_VERSION}
  - name: NetCDF-Fortran
    version: ${NETCDF_FORTRAN_VERSION}
  - name: ESMF
    version: ${ESMF_VERSION}
  - name: CMake
    version: ${CMAKE_VERSION}

application:
  name: GCHP
  version: ${GCHP_VERSION}
  features:
    - MPI_LOAD_BALANCE
    - EFA_NETWORKING
  compatibility:
    gcc_min: 10
    gcc_max: 12
    cmake_min: 3.24

build_info:
  duration_hours: ~3-4
  cpus_used: ${NCPUS}
  base_os: Amazon Linux 2023

notes: |
  Production stack for GCHP 14.7.1
  GCC 12.3 built from source (GCHP requires <13)
  All dependencies self-contained in stack
  Ready for multi-node EFA validation
EOF

log "=========================================="
log "Build complete!"
log "=========================================="
log "Stack location: ${STACK_ROOT}"
log "Environment: source ${STACK_ROOT}/gchp-env.sh"
log ""
log "Next steps:"
log "1. Test the stack: source ${STACK_ROOT}/gchp-env.sh"
log "2. Verify versions: gcc --version && mpirun --version"
log "3. Sync to S3: aws s3 sync ${STACK_ROOT}/ s3://gchp-shared-storage-us-east-2/stacks/${STACK_NAME}/ --exclude '*.o' --exclude '*.mod'"
log ""
log "Build log: ${LOG_FILE}"
EOF

chmod +x "${STACK_ROOT}/build-gchp-stack.sh"
