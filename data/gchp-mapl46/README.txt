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

ADDENDUM PRE-REGISTRATION, variant C (2026-10-11 ~02:25Z, after the A/B/P results (RESULTS 1, below) were seen; written before C ran)
  Motivation: B removed the double free but mpirun rc=1 ("exiting improperly"), because PR #46 skips MPI_Finalize.
  The abort lives in _dl_fini (static destructors), which runs AFTER MPI_Finalize in stock. So: keep PR #46 but
  replace finalize_mpi's MPI_Barrier with MPI_Finalize, then _exit(0). Not upstream code; a candidate amendment.
  Build: one-line edit on top of PR #46 in the same tree, incremental make -> gchp-pr46fin.
  Cells: ARMS="A C", 2 reps (A as the same-session control). Harness fixes applied before running: allPEs.log and
    warnings_and_errors.log deleted per cell (they append, so try-2's "throughput first seen" times were stale),
    and each cell waits for the previous cell's stray gchp ranks to exit.
  Scoring: C WORKS iff both C cells: rc=0, double_free=0, improper=0, md5 == A's f2e423040f1d, throughput line present.
  Prediction: C works (rc 0). Risk: MPI_Finalize itself triggers the double free (the vector freed in finalize
    rather than at exit); then double_free > 0 and the abort just moves earlier.

RESULTS 1: arms A/B/P (try 2, 01:59-02:22Z; try 1 was stopped after A-1/B-1 to fix log capture, same verdicts, kept in ab-try1/)
  cell  rc   ckpt md5      double_free  improper  throughput line  cap_restart at  mpirun exit at  teardown
  A-1   134  f2e423040f1d  12           0         yes (737.9 d/d)  119 s           241 s           122 s
  B-1   1    f2e423040f1d  0            2         yes (308.2)      282 s           282 s           <1 s
  P-1   134  8cc8718ecfda  12           0         yes (800.1)      109 s           236 s           127 s
  A-2   134  f2e423040f1d  12           0         yes (801.2)      109 s           234 s           125 s
  B-2   1    f2e423040f1d  0            2         yes (789.6)      110 s           110 s           <1 s
  P-2   134  8cc8718ecfda  12           0         yes (798.8)      109 s           235 s           126 s
  Scoring:
    FIX WORKS: NO as pre-registered (needs rc=0). Double free gone (0 vs 12) and md5(B) == md5(A) both reps, and the
      throughput line + full profiler report survive _exit (prediction 4 right). But mpirun rc=1 both reps: OpenMPI
      4.1.7 reports "process rank N ... exiting improperly ... called init but exited without calling finalize".
      Prediction 3's risk happened: the failure moves from the ranks to the launcher; the job still reports failure.
    CONTROL HOLDS: partly. A and P abort with 12 double frees every rep. A md5 != P md5 (f2e42304 vs 8cc8718e), each
      stable across reps. Cause: build flags, not PR #46. The production binary has objects built with
      -march=armv8.2-a+crypto -mtune=neoverse-n1 and an extra 4 -O3 objects that this tree's configure didn't
      produce; A and B come from one tree and one configure and differ only in MAPL_Cap.F90. A vs B is the valid
      science comparison, and it is identical.
  Not predicted:
    - Stock teardown costs ~125 s of wall per run (12 ranks): the double free fires within 1-2 s of the checkpoint,
      then ranks sit in D state in pipe_write emitting ~380-frame -fbacktrace output. PR #46 exits <1 s after the
      checkpoint. Saves ~2 min per run on this box.
    - Stock leaves orphans: A-1 (try 2) had 6 gchp ranks still alive after mpirun returned.
    - B-1 ran slow (cap at 282 s, 308 d/d) because A-1's 6 orphan ranks overlapped it; harness now waits for strays.
    - The throughput "first seen" times in try 2 are invalid: allPEs.log appends and the source run dir carried 3 old
      runs. The per-cell throughput values above are each log's final (new) line.
