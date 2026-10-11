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

RESULTS 2: variant C (02:24-02:36Z; binary gchp-pr46fin md5 5dee3da1cbb6; full MAPL diff vs 14.7.1 in pr46fin.patch)
  cell  rc   ckpt md5      double_free  improper  throughput      cap_restart at  mpirun exit at  teardown
  A-1   134  f2e423040f1d  12           0         yes (714.9)     121 s           247 s           126 s
  C-1   0    f2e423040f1d  0            0         yes (783.1)     111 s           112 s           1 s
  A-2   134  f2e423040f1d  12           0         yes (818.2)     106 s           232 s           126 s
  C-2   0    f2e423040f1d  0            0         yes (719.0)     120 s           122 s           2 s
  No stray ranks, no waits needed. Throughput first-seen now valid (fresh allPEs.log): it lands at cap_restart time.
  Scoring: C WORKS (both reps: rc 0, no double free, no launcher complaint, md5 == A). Prediction right; the risk
    (double free inside MPI_Finalize) did not occur, which also places the double-freed vector's destructor in
    _dl_fini, after MPI_Finalize, consistent with the June backtrace.
  Net: PR #46 + MPI_Finalize-before-_exit gives a clean exit code under OpenMPI 4.1.7 mpirun on aarch64.
  Not yet covered: srun/Slurm launch, multi-node (EFA), x86_64, Intel MPI/MVAPICH.

ADDENDUM PRE-REGISTRATION, MN + X86 (2026-10-11 ~02:55Z, before either ran)
MN: scripts/gchp-mapl46-mn.sbatch on gchp-lith-ab's compute queue: 2 nodes (c8g.48xl or m9g.48xl, EFA forced
  with pml=cm mtl=ofi provider efa), 48 ranks (24/node), C24 TT 1 day, run dir on head-node /scratch (NFS),
  per-node lith mounts. Same binaries A/B/C. Cells: A,B,C under mpirun; A,B,C under srun --mpi=pmix; then a
  second C under each launcher. Each cell waits for the launcher to exit.
  Predictions:
    mpirun: A rc 134-class + double frees; B rc 1 + "exiting improperly"; C rc 0. md5 A == B == C (48-rank md5 will
      differ from the 12-rank head-node md5; that is expected, decomposition changes roundoff).
    srun: A nonzero (ranks SIGABRT); B rc 0 -- Slurm judges by rank exit codes, and _exit(0) is 0, so the
      "improperly" failure is specific to OpenMPI's mpirun/ORTE; C rc 0.
    Risk: srun cannot launch this OpenMPI (PMIx mismatch) -> fails at init, all srun cells score "launcher
      unsupported", reported as such. Risk: multi-node C24 checkpoint path differs (HUNG detection at 180 s).
X86: one spawn instance (c7a.24xlarge, AMD Zen 4, x86_64; ~1 h, TTL 2h) builds the same three variants from GCHP
  14.7.1 against the x86 stack (stock, + PR #46, + MPI_Finalize line), then runs A/B/C x 2 reps at 12 ranks under
  mpirun, single node, lith v1.12.0 (amd64) over gcgrid. Predictions: same as the aarch64 head node (A 134 + double
  free, B rc 1 + improper, C rc 0; md5 A == B == C, though not equal to aarch64's).

RESULTS 3: MN (Slurm job 26, 02:47-03:05Z, 2x c8g.48xlarge, EFA 2 endpoints/node, pml=cm/mtl=ofi forced; 48 ranks)
  cell         rc    ckpt md5      double_free  improper  cap_restart at  launcher exit at  strays after exit
  1 A mpirun   134   0c0c98b6192f  48           0         99 s            102 s             0
  2 B mpirun   1     0c0c98b6192f  0            2         75 s            77 s              11 (gone within the 3 s pkill window)
  3 C mpirun   0     0c0c98b6192f  0            0         75 s            78 s              0
  4 A srun     HUNG  0c0c98b6192f  48           0         75 s            killed at 288 s   4 (waited 80 s)
  5 B srun     0     0c0c98b6192f  0            0         76 s            82 s              0
  6 C srun     0     0c0c98b6192f  0            0         74 s            77 s              0
  7 C mpirun   0     0c0c98b6192f  0            0         75 s            77 s              0
  8 C srun     0     0c0c98b6192f  0            0         76 s            79 s              0
  Scoring vs predictions: ALL as predicted. mpirun: A 134 + double free, B rc 1 + "exiting improperly", C rc 0.
    srun: B rc 0 (the "improper" failure is OpenMPI-mpirun/ORTE-specific; Slurm judges by rank exit codes), C rc 0.
    md5 identical across all 8 cells (48-rank decomposition; differs from 12-rank as expected). srun launches this
    OpenMPI fine (pmix_v5).
  Not predicted: stock under srun did not exit: srun reported 44 of 48 tasks "Aborted" (most "core dumped"), then
    "forcing job termination", and was still alive 180 s after cap_restart; killed by the harness. Likely cause
    (inference, not measured): core dumps from the aborting ranks to the NFS run dir under Slurm's core limit.
  CORRECTION to RESULTS 1's "stock teardown costs ~125 s": that is the 16-core head node (loaded, slow I/O). On
    c8g.48xlarge under mpirun the stock abort completes ~3 s after the checkpoint. The teardown cost is box-dependent.

RESULTS 4: X86 (spawn i-0b39e8efa48ce07d4, c7a.24xlarge AMD Zen 4, 03:36-03:53Z; 12 ranks, mpirun, lith v1.12.0 amd64)
  Two failed launches first, both before any cell ran (~2 + ~3 min of instance time): the spawn AMI lacks `make`
  (added make/perl/m4/which/diffutils), then CMake could not generate because the x86_64 stack's esmf.mk still points
  its include paths at the ESMF build tree (esmf-8.6.1/src/include) and /fsx/stacks/gchp14.7.1-validated/netcdf-c;
  build-gchp-mapl46.sh now maps both to the installed layout the aarch64 esmf.mk already uses.
  bins: A 4dbb432730f5  B 3e264b72bf9a  C 5c6a60f72021  P (production x86) 6ad40a37d43b
  cell  rc   ckpt md5      double_free  improper  cap_restart at  mpirun exit at
  A-1   134  266f2b3365b3  12           0         152 s           153 s
  B-1   1    266f2b3365b3  0            2         121 s           121 s
  C-1   0    266f2b3365b3  0            0         120 s           121 s
  P-1   134  266f2b3365b3  12           0         120 s           121 s
  A-2   134  266f2b3365b3  12           0         120 s           121 s
  B-2   1    266f2b3365b3  0            2         121 s           121 s
  C-2   0    266f2b3365b3  0            0         120 s           121 s
  P-2   134  266f2b3365b3  12           0         121 s           122 s
  Scoring: all as predicted. On x86 the production binary's md5 EQUALS the fresh build's (unlike aarch64), so the
    aarch64 P mismatch is specific to how that production binary was built. Teardown <= 1 s for every arm here.
OVERALL: across aarch64 1-node (head), aarch64 2-node EFA, x86_64 1-node; mpirun and srun:
  stock      -> double free every run; mpirun 134; srun hangs (2-node)
  PR #46     -> no double free, md5 unchanged; mpirun rc 1 ("exiting improperly"), srun rc 0
  PR #46 + MPI_Finalize before _exit -> rc 0 under both launchers, md5 unchanged, every run (8 cells: 2 head node, 4 two-node, 2 x86)
