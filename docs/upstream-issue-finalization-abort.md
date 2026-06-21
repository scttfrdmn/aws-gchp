# Upstream issue for geoschem/GCHP — FILED as #556
#
# https://github.com/geoschem/GCHP/issues/556 (filed 2026-06-21)

Review before filing. Post with:
```
gh issue create --repo geoschem/GCHP \
  --title "Benign double-free SIGABRT at finalization (std::vector<ompi_datatype_t*> dtor) on GCHP 14.7.1 / OpenMPI 4.1.7" \
  --body-file docs/upstream-issue-finalization-abort.md
```
(Delete this header block before filing — keep only the body below.)

---

## Description

On GCHP 14.7.1, a TransportTracers C24 run completes successfully — the time loop
finishes, the internal checkpoint restart is written, `cap_restart` advances, and the
MAPL timing report prints — but the process then **aborts during teardown** with:

```
double free or corruption (!prev)
Program received signal SIGABRT: Process abort signal.
```

The abort happens at process exit, **after** all useful work is done, so results are
valid. The only practical impact is a non-zero exit code, which makes schedulers (SLURM)
mark the job `FAILED` despite a successful run.

## Root cause (from the demangled backtrace)

The double-free is in the destructor of a `std::vector<ompi_datatype_t*>` running during
C++ static-object teardown (glibc `_dl_fini`):

```
#10 std::_Vector_base<ompi_datatype_t*>::_M_deallocate   bits/stl_vector.h:387
#11 std::_Vector_base<ompi_datatype_t*>::~_Vector_base    bits/stl_vector.h:366
#12 std::vector<ompi_datatype_t*>::~vector                bits/stl_vector.h:733
... (glibc _dl_fini, dl-fini.c:148)
```

This looks like an "MPI objects held in C++ statics" lifetime problem: `MPI_Finalize`
releases the MPI datatypes, then a static/long-lived `std::vector<ompi_datatype_t*>`
destructs at process exit and frees the same datatype handles a second time. (A vector of
`ompi_datatype_t*` points to MAPL's I/O layer.)

## Reproduction

- **Simulation:** TransportTracers, MERRA-2, C24, 1 day, single node, 48 ranks
- **Checkpoint:** default single writer (`NUM_WRITERS: 1`, `WRITE_RESTART_BY_OSERVER: NO`)
- Reproduces **identically on x86_64 (AMD c7a) and ARM64 (AWS Graviton c7g)** with
  independently built software stacks — so it is not architecture- or build-specific.

## What we ruled out

- **Not a newer-version fix:** GCHP 14.7.1 is the latest release.
- **Not the checkpoint-writer bug #519:** that is the *multiple-writers* case producing a
  corrupt (all-zeros) checkpoint and aborting mid-write. We run a **single writer** and
  write a **valid** checkpoint; the abort is at teardown, not during the write.
- **Not fixed by `WRITE_RESTART_BY_OSERVER: YES`:** tested on a live run — the abort still
  occurs, confirming it is not in the checkpoint-write path.
- **No matching OpenMPI 4.1.x issue** found for datatype double-free at finalize, so this
  appears to be a MAPL-side static-lifetime issue rather than a generic OpenMPI bug.

## Environment

- GCHP 14.7.1 (MAPL 2.59)
- OpenMPI 4.1.7 (built from source), GCC 12.2.0
- ESMF 8.6.1, HDF5 1.14.0, NetCDF-C 4.9.2 / Fortran 4.6.0
- Amazon Linux 2023, glibc 2.34; AWS ParallelCluster + FSx Lustre
- Both x86_64 and aarch64 stacks

## Question

Is this a known MAPL finalization issue? Is there a way to ensure the
`std::vector<ompi_datatype_t*>` is cleared before `MPI_Finalize`, or to guard the datatype
free against double-free during static destruction? Happy to provide full logs or test
patches.
