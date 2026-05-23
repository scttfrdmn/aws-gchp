#!/bin/bash
# Validate GCC 12.3 + GCHP 14.7.1 software stack
# Run this on cluster head node after creation

set -e

echo "=========================================="
echo "GCHP Stack Validation"
echo "=========================================="
echo ""

# 1. Load environment
echo "1. Loading environment..."
source /fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-env.sh

# 2. Verify GCC version
echo "2. Verifying GCC version..."
GCC_VERSION=$(gcc --version | head -1)
echo "   $GCC_VERSION"
if [[ ! "$GCC_VERSION" =~ "12.3.0" ]]; then
    echo "   ❌ FAILED: Expected GCC 12.3.0"
    exit 1
fi
echo "   ✅ PASSED"

# 3. Verify OpenMPI version
echo "3. Verifying OpenMPI version..."
MPI_VERSION=$(mpirun --version | head -1)
echo "   $MPI_VERSION"
if [[ ! "$MPI_VERSION" =~ "4.1.7" ]]; then
    echo "   ❌ FAILED: Expected OpenMPI 4.1.7"
    exit 1
fi
echo "   ✅ PASSED"

# 4. Check MPI configuration (EFA support)
echo "4. Checking MPI configuration..."
if ompi_info | grep -q "mtl.*ofi"; then
    echo "   ✅ PASSED: MPI has OFI transport (EFA-ready)"
else
    echo "   ⚠️  WARNING: MPI missing OFI transport"
fi

if ompi_info | grep -q "ess.*pmi"; then
    echo "   ✅ PASSED: MPI has PMI support (SLURM)"
else
    echo "   ⚠️  WARNING: MPI missing PMI support"
fi

# 5. Verify GCHP executable exists
echo "5. Verifying GCHP executable..."
GCHP_EXE="/fsx/stacks/gcc12.3-ompi4.1.7-gchp14.7.1/gchp-14.7.1/build/bin/gchp"
if [[ -f "$GCHP_EXE" ]]; then
    SIZE=$(ls -lh "$GCHP_EXE" | awk '{print $5}')
    echo "   ✅ PASSED: GCHP executable exists ($SIZE)"
else
    echo "   ❌ FAILED: GCHP executable not found"
    exit 1
fi

# 6. Check input data mount
echo "6. Checking input data mount..."
if [[ -d "/input" ]]; then
    COUNT=$(ls /input 2>/dev/null | wc -l)
    echo "   ✅ PASSED: /input mounted ($COUNT items)"
else
    echo "   ❌ FAILED: /input not mounted"
    exit 1
fi

# 7. Check scratch workspace
echo "7. Checking scratch workspace..."
if [[ -d "/scratch" ]]; then
    echo "   ✅ PASSED: /scratch mounted"
else
    echo "   ❌ FAILED: /scratch not mounted"
    exit 1
fi

# 8. Verify HDF5/NetCDF
echo "8. Verifying libraries..."
if nc-config --version &>/dev/null; then
    NC_VERSION=$(nc-config --version)
    echo "   ✅ PASSED: NetCDF-C $NC_VERSION"
else
    echo "   ❌ FAILED: NetCDF-C not found"
    exit 1
fi

if nf-config --version &>/dev/null; then
    NF_VERSION=$(nf-config --version)
    echo "   ✅ PASSED: NetCDF-Fortran $NF_VERSION"
else
    echo "   ❌ FAILED: NetCDF-Fortran not found"
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ ALL VALIDATION CHECKS PASSED"
echo "=========================================="
echo ""
echo "Stack is ready for benchmarking!"
echo ""
echo "Next steps:"
echo "  1. Create run directory: cp -r /fsx/stacks/.../gchp-14.7.1/run/GCHP /scratch/my-run"
echo "  2. Configure simulation: cd /scratch/my-run && edit setCommonRunSettings.sh"
echo "  3. Submit job: sbatch run.sh"
