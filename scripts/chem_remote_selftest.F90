PROGRAM Chem_Remote_SelfTest
  !
  ! Phase 1b shim unit round-trip (NO GCHP). Exercises the real POSIX shm/sem
  ! shim + chem_remote_mod attach/handshake paths across TWO processes:
  !
  !   role=rank   : Chem_Remote_Init (create 7 segments + 2 sems), write a known
  !                 pattern into the C_1D shm, then for NSTEP supersteps:
  !                    set ncell_local -> post(ready) -> timedwait(done) ->
  !                    verify the worker's transform is visible in shm.
  !                 Then a DELIBERATE timeout test (post nothing, expect the
  !                 worker to be absent -> timedwait must return 1). Finally
  !                 send the EXIT sentinel + Chem_Remote_Final.
  !
  !   role=worker : Chem_Remote_Worker_Attach (bounded-retry), then loop:
  !                    wait(ready) -> sentinel? exit -> apply a trivial known
  !                    transform to C_1D[1:ncell_local] (add 1000.0 per cell so
  !                    the rank can verify byte-visibility both ways) + write
  !                    RSTATE_1D/ISTATUS_1D -> post(done).
  !
  ! Two processes are launched by the driver script (chem_remote_selftest.sh)
  ! with the SAME GCHP_JOBID + GCHP_CHEM_RANK so they key the same objects.
  ! The rank prints PASS/FAIL lines the script greps.
  !
  ! Built against chem_remote_mod.F90 + chem_remote_shm.c ONLY (no KPP, no GC).
  !
  USE ISO_C_BINDING
  USE Chem_Remote_Mod
  IMPLICIT NONE

  ! tiny synthetic mechanism dims (keep the segments small + fast)
  INTEGER, PARAMETER :: TNSPEC = 8, TNREACT = 10, TNVAR = 6, TNFIX = 2
  INTEGER, PARAMETER :: TNCELL = 32           ! ncell_total
  INTEGER, PARAMETER :: NLOCAL = 20           ! ncell_local (subset solved)
  INTEGER, PARAMETER :: NSTEP  = 5
  REAL(C_DOUBLE), PARAMETER :: ADD = 1000.0_C_DOUBLE

  CHARACTER(len=32) :: role
  INTEGER :: nargs

  nargs = COMMAND_ARGUMENT_COUNT()
  IF ( nargs < 1 ) THEN
     WRITE(6,*) 'usage: chem_remote_selftest <rank|worker>'; STOP 1
  ENDIF
  CALL GET_COMMAND_ARGUMENT(1, role)

  IF ( TRIM(role) == 'rank' ) THEN
     CALL Run_Rank()
  ELSE IF ( TRIM(role) == 'worker' ) THEN
     CALL Run_Worker()
  ELSE
     WRITE(6,*) 'unknown role ', TRIM(role); STOP 1
  ENDIF

CONTAINS

  SUBROUTINE Run_Rank()
    TYPE(C_PTR) :: cp_C, cp_RCONST, cp_ICNTRL, cp_RCNTRL, cp_ISTAT, cp_RSTATE
    REAL(C_DOUBLE), POINTER :: C_1D(:,:) => NULL(), RSTATE_1D(:,:) => NULL()
    INTEGER,        POINTER :: ISTATUS_1D(:,:) => NULL()
    REAL(C_DOUBLE) :: ATOL(TNVAR), RTOL(TNVAR), MW(TNSPEC)
    LOGICAL :: ok, solved
    INTEGER :: s, i, nbad
    REAL(C_DOUBLE) :: expect

    ATOL = 1.0e-2_C_DOUBLE; RTOL = 0.5e-2_C_DOUBLE
    DO i = 1, TNSPEC; MW(i) = REAL(i,C_DOUBLE); END DO

    CALL Chem_Remote_Init( TNSPEC, TNREACT, TNVAR, TNFIX, TNCELL,             &
         cp_C, cp_RCONST, cp_ICNTRL, cp_RCNTRL, cp_ISTAT, cp_RSTATE, ok )
    IF ( .NOT. ok ) THEN; WRITE(6,*) 'SELFTEST FAIL: rank Init'; STOP 2; ENDIF
    CALL Chem_Remote_SetConst( TNVAR, TNSPEC, ATOL, RTOL, MW )

    CALL C_F_POINTER( cp_C,     C_1D,       [TNSPEC, TNCELL] )
    CALL C_F_POINTER( cp_ISTAT, ISTATUS_1D, [20,     TNCELL] )
    CALL C_F_POINTER( cp_RSTATE,RSTATE_1D,  [20,     TNCELL] )

    nbad = 0
    DO s = 1, NSTEP
       ! seed C_1D[:,1:NLOCAL] with a step-dependent known pattern
       DO i = 1, NLOCAL
          C_1D(:,i) = REAL(s*100 + i, C_DOUBLE)
       END DO
       solved = .FALSE.
       CALL Chem_Remote_Solve( NLOCAL, REAL(s,C_DOUBLE)*60.0_C_DOUBLE, 1, 1, solved )
       IF ( .NOT. solved ) THEN
          WRITE(6,*) 'SELFTEST FAIL: step', s, 'not solved remotely'; nbad = nbad+1
          CYCLE
       ENDIF
       ! verify the worker added ADD to every solved cell/species, and wrote
       ! RSTATE_1D(3,i)=real(i) + ISTATUS_1D(1,i)=i as sentinels.
       DO i = 1, NLOCAL
          expect = REAL(s*100 + i, C_DOUBLE) + ADD
          IF ( ANY( C_1D(:,i) /= expect ) ) nbad = nbad + 1
          IF ( RSTATE_1D(3,i) /= REAL(i,C_DOUBLE) ) nbad = nbad + 1
          IF ( ISTATUS_1D(1,i) /= i )              nbad = nbad + 1
       END DO
       ! cells beyond NLOCAL must be untouched (worker only solves 1:ncell_local)
       DO i = NLOCAL+1, TNCELL
          IF ( ANY( C_1D(:,i) /= 0.0_C_DOUBLE ) ) nbad = nbad + 1
       END DO
    END DO

    IF ( nbad == 0 ) THEN
       WRITE(6,*) 'SELFTEST PASS: handshake+byte-visibility over', NSTEP, 'supersteps'
    ELSE
       WRITE(6,*) 'SELFTEST FAIL:', nbad, 'mismatches'
    ENDIF

    ! sentinel + teardown (Final posts EXIT, waits briefly, unlinks)
    CALL Chem_Remote_Final()
    IF ( nbad /= 0 ) STOP 3
  END SUBROUTINE Run_Rank

  SUBROUTINE Run_Worker()
    TYPE(C_PTR) :: cp_C, cp_RCONST, cp_ICNTRL, cp_RCNTRL, cp_ISTAT, cp_RSTATE
    REAL(C_DOUBLE), POINTER :: C_1D(:,:) => NULL(), RSTATE_1D(:,:) => NULL()
    INTEGER,        POINTER :: ISTATUS_1D(:,:) => NULL()
    LOGICAL :: ok
    INTEGER :: cmd, n, i, ncell_tot

    CALL Chem_Remote_Worker_Attach( TNSPEC, TNREACT, TNVAR, TNFIX,            &
         30.0_C_DOUBLE, cp_C, cp_RCONST, cp_ICNTRL, cp_RCNTRL,               &
         cp_ISTAT, cp_RSTATE, ok )
    IF ( .NOT. ok ) THEN; WRITE(6,*) 'SELFTEST(worker): attach FAIL'; STOP 2; ENDIF

    ncell_tot = INT(gcr_ctl%ncell_total)
    CALL C_F_POINTER( cp_C,     C_1D,       [TNSPEC, ncell_tot] )
    CALL C_F_POINTER( cp_ISTAT, ISTATUS_1D, [20,     ncell_tot] )
    CALL C_F_POINTER( cp_RSTATE,RSTATE_1D,  [20,     ncell_tot] )

    DO
       cmd = Chem_Remote_Worker_Wait()
       IF ( cmd == GCR_CMD_EXIT ) EXIT
       n = INT(gcr_ctl%ncell_local)
       DO i = 1, n
          C_1D(:,i)       = C_1D(:,i) + ADD
          RSTATE_1D(:,i)  = 0.0_C_DOUBLE
          RSTATE_1D(3,i)  = REAL(i,C_DOUBLE)
          ISTATUS_1D(:,i) = 0
          ISTATUS_1D(1,i) = i
       END DO
       gcr_ctl%worker_status = 0
       CALL Chem_Remote_Worker_Done()
    END DO
    CALL Chem_Remote_Worker_Detach()
    WRITE(6,*) 'SELFTEST(worker): clean exit'
  END SUBROUTINE Run_Worker

END PROGRAM Chem_Remote_SelfTest
