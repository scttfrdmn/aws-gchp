# ESMF VMK::customType datatype leak fix (NOT the finalization-abort fix)

Status: A/B-TESTED 2026-06-21 — this patch does **NOT** resolve the end-of-run
double-free SIGABRT (geoschem/GCHP#556). A patched `libesmf.so` (customType freed in
`VMK::finalize()`) aborted identically to stock in a controlled same-node A/B run with
the same GCHP binary. So `customType` is a genuine datatype *leak* but is not the vector
being double-freed at exit — a DIFFERENT static `std::vector<MPI_Datatype>` in ESMF is
responsible, not yet pinned (needs a debug-symbol ESMF build).

This remains a valid, small leak fix and applies cleanly to v8.6.1 AND develop, so it is
still worth offering upstream as a leak fix — but do NOT present it as resolving #556.

## Title
Free `VMK::customType` MPI datatypes in `VMK::finalize()` (double-free at process exit)

## Body

### Summary
`ESMCI::VMK::customType` is a program-lifetime `static std::vector<MPI_Datatype>`
(`src/Infrastructure/VM/src/ESMCI_VMKernel.C`). It is committed once in `VMK::init()`
via `MPI_Type_commit` but **never freed** in `VMK::finalize()`. Because the vector has
static storage duration, its destructor runs at process exit (`_dl_fini`), *after*
`MPI_Finalize`. The committed `MPI_Datatype` handles are torn down by `MPI_Finalize` and
then freed again during static destruction, aborting with:

```
double free or corruption (!prev)
... in std::vector<ompi_datatype_t*>::~vector  (bits/stl_vector.h:733)
... in _dl_fini
```

The abort happens **after** the application has completed successfully (in our case a
GCHP run: time loop done, restart written, timing report printed), so results are valid,
but the process exits non-zero — which makes batch schedulers report the job as FAILED.

### Reproduction
- ESMF 8.6.1, OpenMPI 4.1.7 (from source), GCC 12.2.0, glibc 2.34, Linux.
- Observed via GCHP 14.7.1 (TransportTracers C24) on AWS, reproduces identically on
  x86_64 and aarch64.
- Confirmed the offending code is unchanged in `develop` / v8.9.1.

### Root cause
`customType` handles outlive `MPI_Finalize`. Classic "MPI objects held in C++ statics"
lifetime bug.

### Fix
In `VMK::finalize()`, inside the `if (!finalized){` block and before `MPI_Comm_free`/
`MPI_Finalize`, free and null the committed datatypes:

```cpp
for (auto i=0; i<(signed)customType.size(); i++){
  if (customType[i] != MPI_DATATYPE_NULL){
    MPI_Type_free(&(customType[i]));
    customType[i] = MPI_DATATYPE_NULL;
  }
}
```

Nulling guards against a second `finalize()` on the shared static vector. `VMK::init()`
unconditionally re-commits `customType`, so a finalize→init cycle remains correct.

(Patch file: applies `-p1` to both v8.6.1 and develop.)
