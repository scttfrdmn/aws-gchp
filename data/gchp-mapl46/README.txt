GCHP#556 finalization double free: head-node A/B of geoschem/MAPL PR #46 (head b6de899c1c)
PRE-REGISTRATION (2026-10-11, written while the build ran, before any cell ran)

Setup: head node c7g.4xlarge (Graviton3, aarch64), /sw stack (GCC 12.2.0, OpenMPI 4.1.7, ESMF 8.6.1).
  GCHP 14.7.1 (503642d), MAPL 80d66d0. 12 ranks, C24 TransportTracers, 1 day, mpirun on one node.
  Input from s3://gcgrid via 5 lith mounts (main b67fda3). Run dir copied fresh per cell; rank knobs
  set via setCommonRunSettings.sh and validated by checkRunSettings.sh; stale checkpoints deleted.
  Build: scripts/build-gchp-mapl46.sh (one tree, one cmake configure; stock make -> gchp-stock, then
  `git apply` of PR #46's MAPL_Cap.F90 hunks, incremental make -> gchp-pr46).
  Harness: scripts/gchp-mapl46-ab.sh. Arms P (production /sw binary), A (gchp-stock), B (gchp-pr46),
  2 reps, order A B P per rep. Unlike the lith gates, every cell waits for mpirun to EXIT
  (HUNG if still alive 180 s after cap_restart advances).

Per cell: mpirun exit code, wall, cap_restart, checkpoint md5, count of "double free" and
  "Backtrace for this error", count of OpenMPI "exiting improperly"/"without calling finalize",
  "Model Throughput:" line present, stray gchp processes, last log line.

What PR #46 changes: MAPL_Finalize now runs before ESMF_Finalize(KEEPMPI), after report_throughput.
  finalize_mpi no longer calls MPI_Finalize; it does MPI_Barrier then _exit(0) when MAPL initialized
  MPI itself (GCHP's case). _exit skips atexit handlers and static destructors (where the double
  free lives), and also skips libgfortran/stdio buffer flushes and MPI_Finalize.

Scoring:
  FIX WORKS iff every B cell has rc=0, double_free=0, checkpoint md5 == the A cells' md5, and
    "Model Throughput:" present.
  CONTROL HOLDS iff every A and P cell aborts with double_free > 0 (rc != 0) and A md5 == P md5.
  Science unchanged iff md5(B) == md5(A) == md5(P) across all reps.

Predictions:
  1. A and P abort at teardown (rc 134 or mpirun's nonzero rc), after a valid checkpoint; A md5 == P md5.
  2. B: no double free, and checkpoint md5 identical to A/P.
  3. Risk I am watching, not predicting: with MPI_Finalize skipped, OpenMPI 4.1.7's mpirun may treat
     the ranks as having exited "improperly" and return nonzero even though every rank calls _exit(0).
     If it does, the fix moves the failure from the process to the launcher. If rc=0, it doesn't.
  4. Risk: _exit skips buffer flushes, so the tail of the log (the throughput line, printed before
     _exit) could be lost when stdout is redirected to a file. Prediction: present, since MAPL's
     logger flushes the line; reported either way.
Cost: $0 (head node).
