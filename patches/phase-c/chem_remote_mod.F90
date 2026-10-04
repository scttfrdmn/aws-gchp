!------------------------------------------------------------------------------
!                  GEOS-Chem High Performance (GCHP)                          !
!------------------------------------------------------------------------------
!BOP
!
! !MODULE: chem_remote_mod.F90
!
! !DESCRIPTION: Decoupled-Chemistry Phase 1b transport layer. Hands the KPP
!  flat gather buffers from a GCHP MPI rank to a co-located, SEPARATE
!  kpp_worker process through POSIX shared memory + two named semaphores, and
!  synchronizes one chemistry superstep.
!
!  ZERO-COPY design: the six _1D buffers (C_1D, RCONST_1D, ICNTRL_1D,
!  RCNTRL_1D, ISTATUS_1D, RSTATE_1D) are mmap'd shared segments; fullchem's
!  own module POINTERs are C_F_POINTER'd onto them (exactly as the
!  MPI_LOAD_BALANCE backend does with MPI windows), so gather and scatter run
!  unchanged and there is no pack step. A semaphore pair is the memory barrier:
!  the rank posts `ready` after the gather completes, the worker solves in
!  place and posts `done`, and the rank's scatter reads the solved bytes.
!
!  SAFETY VALVE: the rank waits with sem_timedwait (never unbounded). On
!  timeout / worker refusal it returns solved_remotely=.FALSE., and fullchem
!  falls back to its verbatim in-process Phase-0 solve loop over the same
!  (still-resident) shm buffers — bit-identical, non-fatal.
!
!  This module is deliberately self-contained: it USEs only ISO_C_BINDING, so
!  it compiles standalone into BOTH the GeosCore library (rank side, via
!  fullchem_mod) and the kpp_worker executable (worker side) with an identical
!  BIND(C) control-struct layout. It has no GEOS-Chem State_* dependencies.
!
! !INTERFACE:
!
MODULE Chem_Remote_Mod
!
! !USES:
!
  USE ISO_C_BINDING

  IMPLICIT NONE
  PRIVATE
!
! !PUBLIC MEMBER FUNCTIONS:
!
  ! Rank (GCHP) side
  PUBLIC :: Chem_Remote_Init      ! create segments+sems, return data c_ptrs
  PUBLIC :: Chem_Remote_SetConst  ! one-time: write ATOL/RTOL/MW into const seg
  PUBLIC :: Chem_Remote_Solve     ! one superstep handoff (post/timedwait)
  PUBLIC :: Chem_Remote_Final     ! sentinel + close/unlink/detach
  PUBLIC :: Chem_Remote_Active    ! .TRUE. once Init succeeded (rank side)
  ! Worker (kpp_worker) side
  PUBLIC :: Chem_Remote_Worker_Attach   ! bounded-retry attach, return c_ptrs
  PUBLIC :: Chem_Remote_Worker_Wait     ! sem_wait(ready), return command
  PUBLIC :: Chem_Remote_Worker_Done     ! sem_post(done)
  PUBLIC :: Chem_Remote_Worker_Detach   ! munmap + sem_close (NO unlink)
  PUBLIC :: Chem_Remote_Worker_Slice    ! M>N: this worker's [lo,hi) for the step
  PUBLIC :: gcr_slices             ! (2*GCR_MAXW) lo,hi pairs (0-based half-open)
  ! Shared control page + const arrays (public so both sides read/write fields)
  PUBLIC :: gcr_ctl                ! pointer to the BIND(C) control struct
  PUBLIC :: gcr_const              ! pointer to [ATOL(NVAR) RTOL(NVAR) MW(NSPEC)]
  PUBLIC :: Chem_Ctl_T
  ! command codes
  PUBLIC :: GCR_CMD_IDLE, GCR_CMD_SOLVE, GCR_CMD_EXIT
  ! transport backend selector (Phase C: off-node). shm is the proven default.
  PUBLIC :: GCR_TRANSPORT_SHM, GCR_TRANSPORT_RDMA, GCR_TRANSPORT_S3
  PUBLIC :: Chem_Remote_Transport   ! resolved backend for this run (from env)
!
! !PUBLIC DATA MEMBERS:
!
  ! Command values written into gcr_ctl%command by the rank, read by the worker
  INTEGER(C_INT), PARAMETER :: GCR_CMD_IDLE  = 0
  INTEGER(C_INT), PARAMETER :: GCR_CMD_SOLVE = 1
  INTEGER(C_INT), PARAMETER :: GCR_CMD_EXIT  = 2

  ! Transport backend (Phase C). shm = on-node zero-copy (built, proven byte-identical).
  ! rdma = co-scheduled off-node over EFA one-sided (C1). s3 = elastic off-node, no
  ! co-scheduling (C2, the paper headline). Selected at runtime by GCHP_CHEM_TRANSPORT;
  ! default shm so every existing run and the K=1..4 gate are byte-for-byte unchanged.
  INTEGER, PARAMETER :: GCR_TRANSPORT_SHM  = 0
  INTEGER, PARAMETER :: GCR_TRANSPORT_RDMA = 1
  INTEGER, PARAMETER :: GCR_TRANSPORT_S3   = 2
  INTEGER, SAVE      :: Chem_Remote_Transport = GCR_TRANSPORT_SHM

  ! Magic / ABI stamp so a mismatched worker/rank build fails loud
  INTEGER(C_INT), PARAMETER :: GCR_MAGIC = 1112493901  ! 0x424D4B0D "chem" ish
  INTEGER(C_INT), PARAMETER :: GCR_ABI   = 1

  ! Element byte sizes of the flat buffers. fullchem uses REAL(fp)=real64 and
  ! default INTEGER=int32; the KPP worker uses REAL(dp)=real64 and INTEGER.
  ! Both sides agree on these, so the segment sizes computed here match.
  INTEGER(C_SIZE_T), PARAMETER :: FP_BYTES  = 8_C_SIZE_T
  INTEGER(C_SIZE_T), PARAMETER :: INT_BYTES = 4_C_SIZE_T

  ! Fixed control leading dimensions of ICNTRL/RCNTRL/ISTATUS/RSTATE (KPP = 20)
  INTEGER(C_INT), PARAMETER :: NCTRL = 20
!
! !DERIVED TYPE:
!
  ! Fixed-layout control page shared by rank and worker. BIND(C) guarantees the
  ! two independent compilations lay it out identically. Scalars only — the
  ! large ATOL/RTOL/MW arrays live in the separate `const` segment.
  TYPE, BIND(C) :: Chem_Ctl_T
     INTEGER(C_INT) :: magic
     INTEGER(C_INT) :: abi
     INTEGER(C_INT) :: nspec
     INTEGER(C_INT) :: nreact
     INTEGER(C_INT) :: nvar
     INTEGER(C_INT) :: nfix
     INTEGER(C_INT) :: ncell_total
     INTEGER(C_INT) :: ncell_local      ! written by rank each step
     INTEGER(C_INT) :: ar_flag          ! Use_AutoReduce (1/0)
     INTEGER(C_INT) :: ss_flag          ! .not.Do_SulfateMod_SeaSalt (1/0)
     INTEGER(C_INT) :: command          ! GCR_CMD_*
     INTEGER(C_INT) :: worker_status    ! 0 ok, <0 fatal (worker sets)
     INTEGER(C_INT) :: nworkers         ! M>N: # co-located workers for THIS rank (>=1)
     REAL(C_DOUBLE) :: dt               ! chem timestep [s], written each step
  END TYPE Chem_Ctl_T
  ! M>N: the per-worker cell slices [lo,hi) live in a SEPARATE fixed-stride shm
  ! segment `_slices` (2*MAXW int32: lo_0,hi_0, lo_1,hi_1, ...), so the BIND(C)
  ! control page stays fixed-size (the worker attaches it before it knows K).
  ! Rank writes the K active pairs each superstep; worker k reads pair k. K=1 puts
  ! [0,ncell_local) in slot 0 -> byte-identical to the pre-M>N single-batch path.
  INTEGER(C_INT), PARAMETER :: GCR_MAXW = 64    ! max workers/rank (192 cores/6 min ranks)
!
! !PRIVATE MODULE STATE:
!
  LOGICAL,             SAVE :: Chem_Remote_Active = .FALSE.
  TYPE(Chem_Ctl_T), POINTER :: gcr_ctl   => NULL()
  REAL(C_DOUBLE),   POINTER :: gcr_const(:) => NULL()
  INTEGER(C_INT),   POINTER :: gcr_slices(:) => NULL()  ! (2*GCR_MAXW): lo,hi pairs
  INTEGER,             SAVE :: nworkers = 1              ! rank-side K (from env), >=1

  ! A concrete instance of the control type, used purely to take its byte size
  ! via C_SIZEOF (both sides compute the identical control-page size this way).
  TYPE(Chem_Ctl_T), SAVE :: ctl_template

  ! shm base addresses (kept for detach)
  TYPE(C_PTR), SAVE :: p_ctl   = C_NULL_PTR
  TYPE(C_PTR), SAVE :: p_const = C_NULL_PTR
  TYPE(C_PTR), SAVE :: p_slices= C_NULL_PTR
  TYPE(C_PTR), SAVE :: p_C     = C_NULL_PTR
  TYPE(C_PTR), SAVE :: p_RCONST= C_NULL_PTR
  TYPE(C_PTR), SAVE :: p_ICNTRL= C_NULL_PTR
  TYPE(C_PTR), SAVE :: p_RCNTRL= C_NULL_PTR
  TYPE(C_PTR), SAVE :: p_ISTAT = C_NULL_PTR
  TYPE(C_PTR), SAVE :: p_RSTATE= C_NULL_PTR
  ! semaphore handles
  TYPE(C_PTR), SAVE :: sem_ready = C_NULL_PTR
  TYPE(C_PTR), SAVE :: sem_done  = C_NULL_PTR

  ! segment byte sizes (recomputed identically both sides)
  INTEGER(C_SIZE_T), SAVE :: sz_ctl, sz_const, sz_C, sz_RCONST
  INTEGER(C_SIZE_T), SAVE :: sz_ICNTRL, sz_RCNTRL, sz_ISTAT, sz_RSTATE
  INTEGER(C_SIZE_T), SAVE :: sz_slices

  ! object name stems (built from jobid+rank), kept for unlink at Final
  CHARACTER(LEN=192), SAVE :: stem = ''

  ! S3 backend state (Phase C2). In S3 mode the buffers are plain heap (crs3_alloc),
  ! NOT shm — the rank owns them and ships copies to S3. gcr_rank is this rank's index
  ! (for the S3 key), gcr_step counts supersteps (unique keys per step), gcr_tmpdir is a
  ! node-local scratch dir for the serialize/deserialize temp files.
  INTEGER,            SAVE :: gcr_rank = -1
  INTEGER,            SAVE :: gcr_step = 0
  CHARACTER(LEN=256), SAVE :: gcr_tmpdir = '/tmp'
  ! kept C_PTRs to the 6 heap buffers (S3 mode) for serialize + free
  TYPE(C_PTR), SAVE :: s3_C=C_NULL_PTR, s3_RCONST=C_NULL_PTR, s3_ICNTRL=C_NULL_PTR
  TYPE(C_PTR), SAVE :: s3_RCNTRL=C_NULL_PTR, s3_ISTAT=C_NULL_PTR, s3_RSTATE=C_NULL_PTR

  ! rank-side timeout (seconds), from env GCHP_CHEM_DEADLINE_S (default 60)
  REAL(C_DOUBLE), SAVE :: deadline_s = 60.0_C_DOUBLE

  ! handoff-cost accounting (rank side): wall time spent in the post(ready)->
  ! timedwait(done) bracket, accumulated over supersteps and reported at Final.
  ! This is the "cost of moving the solve across the process boundary" the
  ! Phase-1b measurement wants (zero-copy => essentially 2 sem ops + first-touch
  ! cache-coherence, since the worker solves in place).
  INTEGER(KIND=8), SAVE :: handoff_ticks = 0_8
  INTEGER(KIND=8), SAVE :: handoff_rate  = 0_8
  INTEGER,         SAVE :: handoff_count = 0
!
! !PRIVATE C SHIM INTERFACE (chem_remote_shm.c):
!
  INTERFACE
     FUNCTION crshm_create(name, nbytes) BIND(C, name="crshm_create")
       IMPORT :: C_PTR, C_CHAR, C_SIZE_T
       TYPE(C_PTR)                          :: crshm_create
       CHARACTER(KIND=C_CHAR), INTENT(IN)   :: name(*)
       INTEGER(C_SIZE_T),      VALUE        :: nbytes
     END FUNCTION crshm_create

     FUNCTION crshm_attach(name, nbytes) BIND(C, name="crshm_attach")
       IMPORT :: C_PTR, C_CHAR, C_SIZE_T
       TYPE(C_PTR)                          :: crshm_attach
       CHARACTER(KIND=C_CHAR), INTENT(IN)   :: name(*)
       INTEGER(C_SIZE_T),      VALUE        :: nbytes
     END FUNCTION crshm_attach

     FUNCTION crshm_detach(addr, nbytes) BIND(C, name="crshm_detach")
       IMPORT :: C_PTR, C_SIZE_T, C_INT
       INTEGER(C_INT)              :: crshm_detach
       TYPE(C_PTR),      VALUE     :: addr
       INTEGER(C_SIZE_T), VALUE    :: nbytes
     END FUNCTION crshm_detach

     FUNCTION crshm_unlink(name) BIND(C, name="crshm_unlink")
       IMPORT :: C_CHAR, C_INT
       INTEGER(C_INT)                       :: crshm_unlink
       CHARACTER(KIND=C_CHAR), INTENT(IN)   :: name(*)
     END FUNCTION crshm_unlink

     FUNCTION crshm_unlink_stale(name) BIND(C, name="crshm_unlink_stale")
       IMPORT :: C_CHAR, C_INT
       INTEGER(C_INT)                       :: crshm_unlink_stale
       CHARACTER(KIND=C_CHAR), INTENT(IN)   :: name(*)
     END FUNCTION crshm_unlink_stale

     FUNCTION crsem_create(name, val) BIND(C, name="crsem_create")
       IMPORT :: C_PTR, C_CHAR, C_INT
       TYPE(C_PTR)                          :: crsem_create
       CHARACTER(KIND=C_CHAR), INTENT(IN)   :: name(*)
       INTEGER(C_INT),         VALUE        :: val
     END FUNCTION crsem_create

     FUNCTION crsem_attach(name) BIND(C, name="crsem_attach")
       IMPORT :: C_PTR, C_CHAR
       TYPE(C_PTR)                          :: crsem_attach
       CHARACTER(KIND=C_CHAR), INTENT(IN)   :: name(*)
     END FUNCTION crsem_attach

     FUNCTION crsem_post(sem) BIND(C, name="crsem_post")
       IMPORT :: C_PTR, C_INT
       INTEGER(C_INT)       :: crsem_post
       TYPE(C_PTR), VALUE   :: sem
     END FUNCTION crsem_post

     FUNCTION crsem_wait(sem) BIND(C, name="crsem_wait")
       IMPORT :: C_PTR, C_INT
       INTEGER(C_INT)       :: crsem_wait
       TYPE(C_PTR), VALUE   :: sem
     END FUNCTION crsem_wait

     FUNCTION crsem_timedwait(sem, deadline) BIND(C, name="crsem_timedwait")
       IMPORT :: C_PTR, C_INT, C_DOUBLE
       INTEGER(C_INT)          :: crsem_timedwait
       TYPE(C_PTR),    VALUE   :: sem
       REAL(C_DOUBLE), VALUE   :: deadline
     END FUNCTION crsem_timedwait

     FUNCTION crsem_close(sem) BIND(C, name="crsem_close")
       IMPORT :: C_PTR, C_INT
       INTEGER(C_INT)       :: crsem_close
       TYPE(C_PTR), VALUE   :: sem
     END FUNCTION crsem_close

     FUNCTION crsem_unlink(name) BIND(C, name="crsem_unlink")
       IMPORT :: C_CHAR, C_INT
       INTEGER(C_INT)                       :: crsem_unlink
       CHARACTER(KIND=C_CHAR), INTENT(IN)   :: name(*)
     END FUNCTION crsem_unlink

     FUNCTION crsem_unlink_stale(name) BIND(C, name="crsem_unlink_stale")
       IMPORT :: C_CHAR, C_INT
       INTEGER(C_INT)                       :: crsem_unlink_stale
       CHARACTER(KIND=C_CHAR), INTENT(IN)   :: name(*)
     END FUNCTION crsem_unlink_stale

     SUBROUTINE crshm_msleep_ms(ms) BIND(C, name="crshm_msleep_ms")
       IMPORT :: C_INT
       INTEGER(C_INT), VALUE :: ms
     END SUBROUTINE crshm_msleep_ms

     ! --- S3 transport backend (chem_remote_s3.c; Phase C2) ---
     FUNCTION crs3_alloc(nbytes) BIND(C, name="crs3_alloc")
       IMPORT :: C_PTR, C_SIZE_T
       TYPE(C_PTR)              :: crs3_alloc
       INTEGER(C_SIZE_T), VALUE :: nbytes
     END FUNCTION crs3_alloc
     SUBROUTINE crs3_free(p) BIND(C, name="crs3_free")
       IMPORT :: C_PTR
       TYPE(C_PTR), VALUE :: p
     END SUBROUTINE crs3_free
     FUNCTION crs3_write_in(path,nspec,nreact,nvar,nfix,lo,hi,ar,ss,dt,        &
                            atol,rtol,mw,C,RCONST,ICNTRL,RCNTRL)               &
                            BIND(C, name="crs3_write_in")
       IMPORT :: C_INT, C_CHAR, C_DOUBLE, C_PTR
       INTEGER(C_INT)                     :: crs3_write_in
       CHARACTER(KIND=C_CHAR), INTENT(IN) :: path(*)
       INTEGER(C_INT), VALUE :: nspec,nreact,nvar,nfix,lo,hi,ar,ss
       REAL(C_DOUBLE), VALUE :: dt
       TYPE(C_PTR),    VALUE :: atol,rtol,mw,C,RCONST,ICNTRL,RCNTRL
     END FUNCTION crs3_write_in
     FUNCTION crs3_read_out(path,nspec,lo,hi,C,RSTATE,ISTATUS)                 &
                            BIND(C, name="crs3_read_out")
       IMPORT :: C_INT, C_CHAR, C_PTR
       INTEGER(C_INT)                     :: crs3_read_out
       CHARACTER(KIND=C_CHAR), INTENT(IN) :: path(*)
       INTEGER(C_INT), VALUE :: nspec,lo,hi
       TYPE(C_PTR),    VALUE :: C,RSTATE,ISTATUS
     END FUNCTION crs3_read_out
     FUNCTION crs3_put_in(rank,sub,step,localpath) BIND(C, name="crs3_put_in")
       IMPORT :: C_INT, C_CHAR
       INTEGER(C_INT)                     :: crs3_put_in
       INTEGER(C_INT), VALUE              :: rank,sub,step
       CHARACTER(KIND=C_CHAR), INTENT(IN) :: localpath(*)
     END FUNCTION crs3_put_in
     FUNCTION crs3_get_out(rank,sub,step,localpath) BIND(C, name="crs3_get_out")
       IMPORT :: C_INT, C_CHAR
       INTEGER(C_INT)                     :: crs3_get_out
       INTEGER(C_INT), VALUE              :: rank,sub,step
       CHARACTER(KIND=C_CHAR), INTENT(IN) :: localpath(*)
     END FUNCTION crs3_get_out
     FUNCTION crs3_poll_done(rank,sub,step,deadline_s) BIND(C, name="crs3_poll_done")
       IMPORT :: C_INT, C_DOUBLE
       INTEGER(C_INT)        :: crs3_poll_done
       INTEGER(C_INT), VALUE :: rank,sub,step
       REAL(C_DOUBLE), VALUE :: deadline_s
     END FUNCTION crs3_poll_done
     FUNCTION crs3_cleanup(rank,sub,step) BIND(C, name="crs3_cleanup")
       IMPORT :: C_INT
       INTEGER(C_INT)        :: crs3_cleanup
       INTEGER(C_INT), VALUE :: rank,sub,step
     END FUNCTION crs3_cleanup
  END INTERFACE

CONTAINS
!EOC
!------------------------------------------------------------------------------
! Helpers
!------------------------------------------------------------------------------

  ! Convert a Fortran string to a NUL-terminated C_CHAR array.
  PURE FUNCTION cstr(s) RESULT(carr)
    CHARACTER(LEN=*), INTENT(IN)  :: s
    CHARACTER(KIND=C_CHAR)        :: carr(LEN_TRIM(s)+1)
    INTEGER :: i, n
    n = LEN_TRIM(s)
    DO i = 1, n
       carr(i) = s(i:i)
    END DO
    carr(n+1) = C_NULL_CHAR
  END FUNCTION cstr

  ! Compute all segment byte sizes from the mechanism counts. Called with the
  ! same arguments on both sides so the sizes agree exactly.
  SUBROUTINE compute_sizes(nspec, nreact, nvar, ncell_total)
    INTEGER, INTENT(IN) :: nspec, nreact, nvar, ncell_total
    INTEGER(C_SIZE_T)   :: nc, ns, nr, nv
    nc = INT(ncell_total, C_SIZE_T)
    ns = INT(nspec,       C_SIZE_T)
    nr = INT(nreact,      C_SIZE_T)
    nv = INT(nvar,        C_SIZE_T)
    sz_ctl    = C_SIZEOF(ctl_template)
    sz_const  = (2_C_SIZE_T*nv + ns) * FP_BYTES
    sz_C      = ns * nc * FP_BYTES
    sz_RCONST = nr * nc * FP_BYTES
    sz_ICNTRL = INT(NCTRL,C_SIZE_T) * nc * INT_BYTES
    sz_RCNTRL = INT(NCTRL,C_SIZE_T) * nc * FP_BYTES
    sz_ISTAT  = INT(NCTRL,C_SIZE_T) * nc * INT_BYTES
    sz_RSTATE = INT(NCTRL,C_SIZE_T) * nc * FP_BYTES
    sz_slices = 2_C_SIZE_T * INT(GCR_MAXW,C_SIZE_T) * INT_BYTES  ! lo,hi per worker
  END SUBROUTINE compute_sizes

  ! Build the object-name stem "/gchp_<jobid>_r<rank>" from env. Returns the
  ! integer rank (>=0) or -1 on failure. `which` selects OMPI_COMM_WORLD_RANK
  ! (rank side) or GCHP_CHEM_RANK (worker side).
  SUBROUTINE build_stem(worker_side, rank_out)
    LOGICAL, INTENT(IN)  :: worker_side
    INTEGER, INTENT(OUT) :: rank_out
    CHARACTER(LEN=64) :: jobid, rankstr
    INTEGER :: dlen, dstat, ios
    rank_out = -1
    jobid = ''
    CALL get_environment_variable('GCHP_JOBID', jobid, dlen, dstat)
    IF ( dstat /= 0 .OR. dlen == 0 ) jobid = '0'
    IF ( worker_side ) THEN
       CALL get_environment_variable('GCHP_CHEM_RANK', rankstr, dlen, dstat)
    ELSE
       CALL get_environment_variable('OMPI_COMM_WORLD_RANK', rankstr, dlen, dstat)
    END IF
    IF ( dstat /= 0 .OR. dlen == 0 ) RETURN
    READ(rankstr, *, IOSTAT=ios) rank_out
    IF ( ios /= 0 ) THEN
       rank_out = -1
       RETURN
    END IF
    WRITE(stem, '(a,a,a,i0)') '/gchp_', TRIM(jobid), '_r', rank_out
  END SUBROUTINE build_stem

!------------------------------------------------------------------------------
! Rank (GCHP) side
!------------------------------------------------------------------------------
!BOP
! !IROUTINE: Chem_Remote_Init
! !DESCRIPTION: Create the shm segments + semaphores for this rank and return
!  the six data-buffer C pointers so the caller (fullchem) can C_F_POINTER its
!  own module pointers onto them. Writes the static control fields. The
!  ATOL/RTOL/MW const arrays are filled later by Chem_Remote_SetConst (they are
!  not yet populated at Init time). On ANY failure, sets active=.FALSE. and
!  returns ok=.FALSE. so the caller keeps its plain-ALLOCATE Phase-0 path
!  (never fatal).
!EOP
  SUBROUTINE Chem_Remote_Init( nspec, nreact, nvar, nfix, ncell_total,        &
                               cp_C, cp_RCONST, cp_ICNTRL, cp_RCNTRL,         &
                               cp_ISTAT, cp_RSTATE, ok )
    INTEGER,        INTENT(IN)  :: nspec, nreact, nvar, nfix, ncell_total
    TYPE(C_PTR),    INTENT(OUT) :: cp_C, cp_RCONST, cp_ICNTRL, cp_RCNTRL
    TYPE(C_PTR),    INTENT(OUT) :: cp_ISTAT, cp_RSTATE
    LOGICAL,        INTENT(OUT) :: ok

    INTEGER :: rank, dlen, dstat, iread
    CHARACTER(LEN=64) :: dbuf

    ok = .FALSE.
    Chem_Remote_Active = .FALSE.
    cp_C=C_NULL_PTR; cp_RCONST=C_NULL_PTR; cp_ICNTRL=C_NULL_PTR
    cp_RCNTRL=C_NULL_PTR; cp_ISTAT=C_NULL_PTR; cp_RSTATE=C_NULL_PTR

    CALL build_stem(.FALSE., rank)
    IF ( rank < 0 ) THEN
       WRITE(6,*) 'Chem_Remote_Init: no OMPI_COMM_WORLD_RANK; remote OFF'
       RETURN
    END IF

    ! optional deadline override
    CALL get_environment_variable('GCHP_CHEM_DEADLINE_S', dbuf, dlen, dstat)
    IF ( dstat == 0 .AND. dlen > 0 ) THEN
       READ(dbuf, *, IOSTAT=iread) deadline_s
       IF ( iread /= 0 .OR. deadline_s <= 0.0_C_DOUBLE ) deadline_s = 60.0_C_DOUBLE
    END IF

    ! M>N: how many co-located workers serve THIS rank (env GCHP_CHEM_NWORKERS,
    ! default 1 = the proven 1:1 path). Clamped to [1, GCR_MAXW]. The launcher
    ! spawns exactly this many kpp_worker --service tasks keyed to this rank, each
    ! with a distinct GCHP_CHEM_SUBRANK in 0..nworkers-1.
    nworkers = 1
    CALL get_environment_variable('GCHP_CHEM_NWORKERS', dbuf, dlen, dstat)
    IF ( dstat == 0 .AND. dlen > 0 ) THEN
       READ(dbuf, *, IOSTAT=iread) nworkers
       IF ( iread /= 0 .OR. nworkers < 1 ) nworkers = 1
       IF ( nworkers > GCR_MAXW ) nworkers = GCR_MAXW
    END IF

    ! Transport backend (Phase C). Default shm (on-node, proven). rdma/s3 are off-node.
    Chem_Remote_Transport = GCR_TRANSPORT_SHM
    CALL get_environment_variable('GCHP_CHEM_TRANSPORT', dbuf, dlen, dstat)
    IF ( dstat == 0 .AND. dlen > 0 ) THEN
       SELECT CASE ( TRIM(ADJUSTL(dbuf)) )
       CASE ('rdma','RDMA'); Chem_Remote_Transport = GCR_TRANSPORT_RDMA
       CASE ('s3','S3');     Chem_Remote_Transport = GCR_TRANSPORT_S3
       CASE DEFAULT;         Chem_Remote_Transport = GCR_TRANSPORT_SHM
       END SELECT
    END IF
    IF ( Chem_Remote_Transport /= GCR_TRANSPORT_SHM ) THEN
       WRITE(6,'(a,i0,a)') 'Chem_Remote_Init: NOTE transport=', Chem_Remote_Transport, &
            ' (0=shm 1=rdma 2=s3) -- off-node backend selected'
    END IF

    CALL compute_sizes(nspec, nreact, nvar, ncell_total)

    ! ================= S3 BACKEND INIT (Phase C2) =================
    ! No shm, no semaphores, no co-located worker. Allocate PLAIN HEAP buffers (the rank
    ! owns them; it serializes+ships copies to S3 each superstep). Return their C_PTRs so
    ! fullchem C_F_POINTERs onto them exactly as in the shm path. const (ATOL/RTOL/MW) also
    ! heap, filled later by SetConst. gcr_const/gcr_slices are plain heap here too (Solve
    ! uses the slice math + const arrays but never shm). Then EARLY RETURN.
    IF ( Chem_Remote_Transport == GCR_TRANSPORT_S3 ) THEN
       gcr_rank = rank
       gcr_step = 0
       CALL get_environment_variable('GCHP_CHEM_TMPDIR', dbuf, dlen, dstat)
       IF ( dstat == 0 .AND. dlen > 0 ) gcr_tmpdir = TRIM(dbuf)
       s3_C      = crs3_alloc(sz_C);      s3_RCONST = crs3_alloc(sz_RCONST)
       s3_ICNTRL = crs3_alloc(sz_ICNTRL); s3_RCNTRL = crs3_alloc(sz_RCNTRL)
       s3_ISTAT  = crs3_alloc(sz_ISTAT);  s3_RSTATE = crs3_alloc(sz_RSTATE)
       p_const   = crs3_alloc(sz_const)
       p_slices  = crs3_alloc(sz_slices)
       IF ( .NOT.(C_ASSOCIATED(s3_C).AND.C_ASSOCIATED(s3_RCONST).AND.            &
                  C_ASSOCIATED(s3_ICNTRL).AND.C_ASSOCIATED(s3_RCNTRL).AND.       &
                  C_ASSOCIATED(s3_ISTAT).AND.C_ASSOCIATED(s3_RSTATE).AND.        &
                  C_ASSOCIATED(p_const).AND.C_ASSOCIATED(p_slices)) ) THEN
          WRITE(6,*) 'Chem_Remote_Init[s3]: heap alloc failed; remote OFF (rank ',rank,')'
          RETURN
       END IF
       CALL C_F_POINTER(p_const,  gcr_const,  [2*nvar + nspec])
       CALL C_F_POINTER(p_slices, gcr_slices, [2*GCR_MAXW])
       gcr_slices(:) = 0_C_INT
       ! stash the mechanism counts locally (no ctl page in S3 mode); reuse a heap ctl
       p_ctl = crs3_alloc(sz_ctl); CALL C_F_POINTER(p_ctl, gcr_ctl)
       gcr_ctl%nspec=INT(nspec,C_INT);  gcr_ctl%nreact=INT(nreact,C_INT)
       gcr_ctl%nvar =INT(nvar,C_INT);   gcr_ctl%nfix  =INT(nfix,C_INT)
       gcr_ctl%ncell_total=INT(ncell_total,C_INT); gcr_ctl%nworkers=INT(nworkers,C_INT)
       cp_C=s3_C; cp_RCONST=s3_RCONST; cp_ICNTRL=s3_ICNTRL
       cp_RCNTRL=s3_RCNTRL; cp_ISTAT=s3_ISTAT; cp_RSTATE=s3_RSTATE
       Chem_Remote_Active = .TRUE.; ok = .TRUE.
       WRITE(6,'(a,i0,a,i0,a)') 'Chem_Remote_Init[s3]: rank ',rank,' ready (',   &
            nworkers,' slices/step -> S3 elastic pool)'
       RETURN
    END IF
    ! ==============================================================

    ! --- create the 9 segments (unlink-stale is inside crshm_create) ---
    p_ctl    = crshm_create(cstr(TRIM(stem)//'_ctl'   ), sz_ctl   )
    p_const  = crshm_create(cstr(TRIM(stem)//'_const' ), sz_const )
    p_slices = crshm_create(cstr(TRIM(stem)//'_slices'), sz_slices)
    p_C      = crshm_create(cstr(TRIM(stem)//'_C'     ), sz_C     )
    p_RCONST = crshm_create(cstr(TRIM(stem)//'_RCONST'), sz_RCONST)
    p_ICNTRL = crshm_create(cstr(TRIM(stem)//'_ICNTRL'), sz_ICNTRL)
    p_RCNTRL = crshm_create(cstr(TRIM(stem)//'_RCNTRL'), sz_RCNTRL)
    p_ISTAT  = crshm_create(cstr(TRIM(stem)//'_ISTATUS'),sz_ISTAT )
    p_RSTATE = crshm_create(cstr(TRIM(stem)//'_RSTATE'), sz_RSTATE)

    IF ( .NOT.(C_ASSOCIATED(p_ctl)   .AND. C_ASSOCIATED(p_const)  .AND.        &
               C_ASSOCIATED(p_slices).AND.                                     &
               C_ASSOCIATED(p_C)     .AND. C_ASSOCIATED(p_RCONST) .AND.        &
               C_ASSOCIATED(p_ICNTRL).AND. C_ASSOCIATED(p_RCNTRL) .AND.        &
               C_ASSOCIATED(p_ISTAT) .AND. C_ASSOCIATED(p_RSTATE)) ) THEN
       WRITE(6,*) 'Chem_Remote_Init: shm_create failed; remote OFF (rank ',rank,')'
       CALL teardown_segments(unlink_names=.TRUE.)
       RETURN
    END IF

    ! --- create the two semaphores, both init 0 ---
    sem_ready = crsem_create(cstr(TRIM(stem)//'_ready'), 0_C_INT)
    sem_done  = crsem_create(cstr(TRIM(stem)//'_done' ), 0_C_INT)
    IF ( .NOT.(C_ASSOCIATED(sem_ready) .AND. C_ASSOCIATED(sem_done)) ) THEN
       WRITE(6,*) 'Chem_Remote_Init: sem_create failed; remote OFF (rank ',rank,')'
       CALL teardown_segments(unlink_names=.TRUE.)
       RETURN
    END IF

    ! --- map control struct + const array + slice table; populate static fields ---
    CALL C_F_POINTER(p_ctl, gcr_ctl)
    CALL C_F_POINTER(p_const, gcr_const, [2*nvar + nspec])
    CALL C_F_POINTER(p_slices, gcr_slices, [2*GCR_MAXW])
    gcr_slices(:)       = 0_C_INT
    gcr_ctl%magic       = GCR_MAGIC
    gcr_ctl%abi         = GCR_ABI
    gcr_ctl%nspec       = INT(nspec,  C_INT)
    gcr_ctl%nreact      = INT(nreact, C_INT)
    gcr_ctl%nvar        = INT(nvar,   C_INT)
    gcr_ctl%nfix        = INT(nfix,   C_INT)
    gcr_ctl%ncell_total = INT(ncell_total, C_INT)
    gcr_ctl%ncell_local = 0_C_INT
    gcr_ctl%ar_flag     = 0_C_INT
    gcr_ctl%ss_flag     = 0_C_INT
    gcr_ctl%command     = GCR_CMD_IDLE
    gcr_ctl%worker_status = 0_C_INT
    gcr_ctl%nworkers    = INT(nworkers, C_INT)
    gcr_ctl%dt          = 0.0_C_DOUBLE
    ! const arrays (ATOL/RTOL/MW) are written later by Chem_Remote_SetConst

    ! hand the six data segment addresses back for the caller's C_F_POINTER
    cp_C=p_C; cp_RCONST=p_RCONST; cp_ICNTRL=p_ICNTRL
    cp_RCNTRL=p_RCNTRL; cp_ISTAT=p_ISTAT; cp_RSTATE=p_RSTATE

    Chem_Remote_Active = .TRUE.
    ok = .TRUE.
    WRITE(6,'(a,i0,a,f0.1,a)') 'Chem_Remote_Init: rank ', rank,               &
         ' shm ready (deadline ', deadline_s, 's)'
    ! unbuffered stderr diagnostic: the exact object stem this rank CREATED,
    ! so a rank<->worker keying mismatch is visible even if the run aborts.
    WRITE(0,'(a,i0,a)') '[CHEMREMOTE rank ', rank, '] created stem='//TRIM(stem)
    FLUSH(0)
  END SUBROUTINE Chem_Remote_Init
!EOC
!BOP
! !IROUTINE: Chem_Remote_SetConst
! !DESCRIPTION: One-time write of the ATOL/RTOL/MW constant arrays into the
!  `const` shm segment. Called from Do_FullChem after these are populated (they
!  are not available at Init time). Idempotent; a no-op if remote is inactive.
!EOP
  SUBROUTINE Chem_Remote_SetConst( nvar, nspec, ATOL, RTOL, MW )
    INTEGER,        INTENT(IN) :: nvar, nspec
    REAL(C_DOUBLE), INTENT(IN) :: ATOL(nvar), RTOL(nvar), MW(nspec)
    IF ( .NOT. Chem_Remote_Active ) RETURN
    IF ( .NOT. ASSOCIATED(gcr_const) ) RETURN
    gcr_const(1:nvar)                = ATOL(1:nvar)
    gcr_const(nvar+1:2*nvar)         = RTOL(1:nvar)
    gcr_const(2*nvar+1:2*nvar+nspec) = MW(1:nspec)
  END SUBROUTINE Chem_Remote_SetConst
!EOC
!BOP
! !IROUTINE: Chem_Remote_Solve
! !DESCRIPTION: One superstep handoff. Writes the dynamic control fields, posts
!  `ready`, and waits `done` with a bounded deadline. On success the solved
!  bytes are already in the shm buffers (zero-copy) and solved_remotely=.TRUE.
!  On timeout or a worker fatal-status, returns solved_remotely=.FALSE. so the
!  caller runs its verbatim in-process fallback loop.
!EOP
  SUBROUTINE Chem_Remote_Solve( ncell_local, dt, ar_flag, ss_flag,           &
                                solved_remotely )
    INTEGER,        INTENT(IN)  :: ncell_local, ar_flag, ss_flag
    REAL(C_DOUBLE), INTENT(IN)  :: dt
    LOGICAL,        INTENT(OUT) :: solved_remotely
    INTEGER(C_INT)  :: rc
    INTEGER(KIND=8) :: t0, t1
    INTEGER         :: k, lo, hi, base, extra, cur

    solved_remotely = .FALSE.
    IF ( .NOT. Chem_Remote_Active ) RETURN

    ! ---- M>N fan-out: partition [0,ncell_local) into `nworkers` CONTIGUOUS
    ! slices and publish them in the slice table. Contiguous + deterministic =>
    ! the union solved is exactly cells 1..ncell_local in the same order the
    ! single-batch path visits them, so (absent a double-failure) the result is
    ! byte-identical regardless of K. Front slices get the +1 remainder cell.
    ! Slot k holds [lo_k, hi_k) as 0-based half-open indices (worker adds 1). ----
    base  = ncell_local / nworkers
    extra = MOD(ncell_local, nworkers)
    cur   = 0
    DO k = 0, nworkers-1
       lo = cur
       hi = lo + base
       IF ( k < extra ) hi = hi + 1          ! distribute remainder to front slices
       gcr_slices(2*k+1) = INT(lo, C_INT)
       gcr_slices(2*k+2) = INT(hi, C_INT)
       cur = hi
    END DO

    ! ================= S3 BACKEND SOLVE (Phase C2) =================
    ! Off-node, no co-scheduling. For each slice: serialize [lo,hi) to a temp file in
    ! kpp_worker FILE-mode layout, PUT to S3; after ALL slices are PUT, the elastic worker
    ! pool (running independently) claims/solves/PUTs .out+.done; then poll each slice's
    ! .done + GET .out + deserialize into this rank's heap buffers at [lo,hi). One timeout
    ! -> in-process fallback (rank re-solves 1:ncell_local, same safety valve as shm).
    IF ( Chem_Remote_Transport == GCR_TRANSPORT_S3 ) THEN
       CALL SYSTEM_CLOCK(t0, handoff_rate)
       CALL Chem_Remote_Solve_S3( ncell_local, dt, ar_flag, ss_flag, solved_remotely )
       CALL SYSTEM_CLOCK(t1)
       handoff_ticks = handoff_ticks + (t1 - t0); handoff_count = handoff_count + 1
       gcr_step = gcr_step + 1
       RETURN
    END IF
    ! ==============================================================

    ! publish this step's work descriptor, then release ALL workers (K posts)
    gcr_ctl%ncell_local   = INT(ncell_local, C_INT)
    gcr_ctl%dt            = dt
    gcr_ctl%ar_flag       = INT(ar_flag, C_INT)
    gcr_ctl%ss_flag       = INT(ss_flag, C_INT)
    gcr_ctl%worker_status = 0_C_INT
    gcr_ctl%command       = GCR_CMD_SOLVE
    CALL SYSTEM_CLOCK(t0, handoff_rate)
    DO k = 1, nworkers
       rc = crsem_post(sem_ready)
       IF ( rc /= 0 ) RETURN         ! a post failed -> fall back (some may be stuck;
    END DO                           ! the deadline below bounds any partial state)

    ! counting barrier: wait for ALL K workers to post `done`. Any single timeout
    ! or fatal worker_status fails the whole superstep -> in-process fallback (the
    ! rank re-solves 1:ncell_local itself, overwriting whatever partial shm state).
    DO k = 1, nworkers
       rc = crsem_timedwait(sem_done, deadline_s)
       IF ( rc /= 0 ) THEN
          CALL SYSTEM_CLOCK(t1); handoff_ticks = handoff_ticks + (t1-t0)
          handoff_count = handoff_count + 1
          WRITE(6,*) 'Chem_Remote_Solve: worker timeout/err (rc=',rc,          &
                     ' at done ',k,'/',nworkers,') -> in-process fallback'
          RETURN
       END IF
    END DO
    ! accumulate the post->all-done bracket = handoff + slowest remote slice wall
    CALL SYSTEM_CLOCK(t1)
    handoff_ticks = handoff_ticks + (t1 - t0)
    handoff_count = handoff_count + 1
    IF ( gcr_ctl%worker_status < 0 ) THEN
       WRITE(6,*) 'Chem_Remote_Solve: worker_status=',gcr_ctl%worker_status,&
                  ' -> in-process fallback'
       RETURN
    END IF

    solved_remotely = .TRUE.

    ! Per-superstep handoff log (unit 0, flushed) so the cost is captured even
    ! if the run later hangs at the pnc4 checkpoint before Chem_Remote_Final.
    IF ( handoff_rate > 0_8 ) THEN
       WRITE(0,'(a,i0,a,f0.3,a)') '[CHEMREMOTE handoff] step ', handoff_count,  &
            ' post->done = ', 1000.0_C_DOUBLE*REAL(t1-t0,C_DOUBLE)/            &
            REAL(handoff_rate,C_DOUBLE), ' ms'
       FLUSH(0)
    END IF
  END SUBROUTINE Chem_Remote_Solve
!EOC

  ! S3-mode superstep: serialize each slice -> PUT all -> poll+GET all -> deserialize.
  ! Buffers are the heap arrays (s3_*); const is gcr_const. gcr_ctl/gcr_slices give the
  ! mechanism counts + slice bounds. solved_remotely=.TRUE. only if EVERY slice round-trips.
  SUBROUTINE Chem_Remote_Solve_S3( ncell_local, dt, ar_flag, ss_flag, solved_remotely )
    INTEGER,        INTENT(IN)  :: ncell_local, ar_flag, ss_flag
    REAL(C_DOUBLE), INTENT(IN)  :: dt
    LOGICAL,        INTENT(OUT) :: solved_remotely
    INTEGER :: k, lo, hi, nsp, nre, nvr, rc, iread
    CHARACTER(LEN=320) :: inpath, outpath
    TYPE(C_PTR) :: p_atol, p_rtol, p_mw
    solved_remotely = .FALSE.
    nsp = INT(gcr_ctl%nspec); nre = INT(gcr_ctl%nreact); nvr = INT(gcr_ctl%nvar)
    ! const sub-array pointers (gcr_const = [ATOL(nvar) RTOL(nvar) MW(nspec)])
    p_atol = C_LOC(gcr_const(1)); p_rtol = C_LOC(gcr_const(nvr+1)); p_mw = C_LOC(gcr_const(2*nvr+1))

    ! 1) serialize + PUT every slice (all in flight before we poll -> workers parallelize)
    DO k = 0, nworkers-1
       lo = INT(gcr_slices(2*k+1)); hi = INT(gcr_slices(2*k+2))
       IF ( hi <= lo ) CYCLE                         ! empty slice (K > ncell): nothing to ship
       WRITE(inpath,'(a,a,i0,a,i0,a,i0,a)') TRIM(gcr_tmpdir),'/crs3_r',gcr_rank,'_k',k,'_s',gcr_step,'.in'
       rc = crs3_write_in( cstr(TRIM(inpath)), nsp, nre, nvr, INT(gcr_ctl%nfix), &
              lo, hi, ar_flag, ss_flag, dt, p_atol, p_rtol, p_mw,                 &
              s3_C, s3_RCONST, s3_ICNTRL, s3_RCNTRL )
       IF ( rc /= 0 ) THEN; WRITE(6,*) 'crs3_write_in failed k=',k,' rc=',rc; RETURN; END IF
       rc = crs3_put_in( gcr_rank, k, gcr_step, cstr(TRIM(inpath)) )
       IF ( rc /= 0 ) THEN; WRITE(6,*) 'crs3_put_in failed k=',k,' rc=',rc; RETURN; END IF
    END DO

    ! 2) ATOMIC-COMMIT barrier: poll ALL slices' .done FIRST, writing NOTHING to the live
    ! buffers. Only if EVERY slice is done do we GET+deserialize (phase 3). This is essential:
    ! crs3_read_out overwrites s3_C[lo:hi] in place, so if we read slice k=0's result and THEN
    ! slice k=1 times out, the in-process fallback would re-solve cells that already hold SOLVED
    ! values (double chemistry -> divergence -- exactly the demo2 c3358aec bug). Deferring all
    ! writes until all-done guarantees the fallback re-solves from pristine inputs.
    DO k = 0, nworkers-1
       lo = INT(gcr_slices(2*k+1)); hi = INT(gcr_slices(2*k+2))
       IF ( hi <= lo ) CYCLE
       rc = crs3_poll_done( gcr_rank, k, gcr_step, deadline_s )
       IF ( rc /= 0 ) THEN
          WRITE(6,*) 'crs3_poll_done TIMEOUT k=',k,' step=',gcr_step,          &
                     ' -> in-process fallback (NO buffers written yet)'
          RETURN                                     ! s3_C untouched -> pristine fallback
       END IF
    END DO

    ! 3) all slices confirmed done -> the .out objects are ALL durably in S3 (each worker wrote
    ! .out BEFORE its .done marker), so GET can only fail transiently. RETRY the GET (up to 5x
    ! with a short sleep) rather than abort -- once we start writing s3_C we are committed, and
    ! aborting mid-write would leave the double-solve hazard. This makes phase 3 effectively
    ! always-succeed given phase 2 passed, so solved_remotely is all-or-nothing.
    DO k = 0, nworkers-1
       lo = INT(gcr_slices(2*k+1)); hi = INT(gcr_slices(2*k+2))
       IF ( hi <= lo ) CYCLE
       WRITE(outpath,'(a,a,i0,a,i0,a,i0,a)') TRIM(gcr_tmpdir),'/crs3_r',gcr_rank,'_k',k,'_s',gcr_step,'.out'
       DO iread = 1, 5
          rc = crs3_get_out( gcr_rank, k, gcr_step, cstr(TRIM(outpath)) )
          IF ( rc == 0 ) EXIT
          CALL crshm_msleep_ms(500_C_INT)
       END DO
       IF ( rc /= 0 ) THEN; WRITE(6,*) 'crs3_get_out failed k=',k,' rc=',rc,' (5 tries)'; RETURN; END IF
       rc = crs3_read_out( cstr(TRIM(outpath)), nsp, lo, hi, s3_C, s3_RSTATE, s3_ISTAT )
       IF ( rc /= 0 ) THEN; WRITE(6,*) 'crs3_read_out failed k=',k,' rc=',rc; RETURN; END IF
       rc = crs3_cleanup( gcr_rank, k, gcr_step )     ! best-effort key cleanup
    END DO
    solved_remotely = .TRUE.
  END SUBROUTINE Chem_Remote_Solve_S3
!BOP
! !IROUTINE: Chem_Remote_Final
! !DESCRIPTION: Signal the worker to exit (sentinel), then close/unlink the
!  semaphores and detach/unlink all segments. Creator (rank) owns the unlink.
!EOP
  SUBROUTINE Chem_Remote_Final()
    INTEGER(C_INT) :: rc
    REAL(C_DOUBLE) :: total_s, mean_ms
    INTEGER        :: k
    IF ( .NOT. Chem_Remote_Active ) RETURN

    ! report the accumulated handoff cost (post(ready)->timedwait(done) wall).
    IF ( handoff_count > 0 .AND. handoff_rate > 0_8 ) THEN
       total_s = REAL(handoff_ticks, C_DOUBLE) / REAL(handoff_rate, C_DOUBLE)
       mean_ms = 1000.0_C_DOUBLE * total_s / REAL(handoff_count, C_DOUBLE)
       WRITE(6,'(a,i0,a,f0.4,a,f0.3,a)')                                       &
            '### PHASE1B HANDOFF: ', handoff_count, ' supersteps, total ',     &
            total_s, ' s, mean ', mean_ms, ' ms/superstep (post->done wall)'
    END IF

    ! S3 mode: no sems/shm to sentinel-or-unlink. Free the heap buffers + done.
    ! (The elastic worker pool exits on its own --idle-exit or is torn down with its
    ! cluster; there is no co-scheduled worker to signal.)
    IF ( Chem_Remote_Transport == GCR_TRANSPORT_S3 ) THEN
       CALL crs3_free(s3_C);      CALL crs3_free(s3_RCONST)
       CALL crs3_free(s3_ICNTRL); CALL crs3_free(s3_RCNTRL)
       CALL crs3_free(s3_ISTAT);  CALL crs3_free(s3_RSTATE)
       CALL crs3_free(p_const);   CALL crs3_free(p_slices); CALL crs3_free(p_ctl)
       NULLIFY(gcr_ctl); NULLIFY(gcr_const); NULLIFY(gcr_slices)
       Chem_Remote_Active = .FALSE.
       RETURN
    END IF

    ! sentinel: tell ALL workers to break their service loop. Each worker consumes
    ! exactly one `ready` token per loop iteration, so with K workers we must post
    ! the EXIT command K times (a single post would wake one worker and leave the
    ! other K-1 blocked on sem_wait forever). Reap up to K done-acks (best-effort).
    IF ( C_ASSOCIATED(sem_ready) .AND. ASSOCIATED(gcr_ctl) ) THEN
       gcr_ctl%command = GCR_CMD_EXIT
       DO k = 1, nworkers
          rc = crsem_post(sem_ready)
       END DO
       DO k = 1, nworkers
          rc = crsem_timedwait(sem_done, 5.0_C_DOUBLE)   ! non-fatal if a worker died
       END DO
    END IF

    IF ( C_ASSOCIATED(sem_ready) ) rc = crsem_close(sem_ready)
    IF ( C_ASSOCIATED(sem_done ) ) rc = crsem_close(sem_done )
    rc = crsem_unlink_stale(cstr(TRIM(stem)//'_ready'))
    rc = crsem_unlink_stale(cstr(TRIM(stem)//'_done' ))

    CALL teardown_segments(unlink_names=.TRUE.)
    Chem_Remote_Active = .FALSE.
  END SUBROUTINE Chem_Remote_Final
!EOC

  ! Detach every mapped segment; optionally unlink the names (rank/creator).
  SUBROUTINE teardown_segments(unlink_names)
    LOGICAL, INTENT(IN) :: unlink_names
    INTEGER(C_INT) :: rc
    IF (C_ASSOCIATED(p_C     )) rc = crshm_detach(p_C     , sz_C     )
    IF (C_ASSOCIATED(p_RCONST)) rc = crshm_detach(p_RCONST, sz_RCONST)
    IF (C_ASSOCIATED(p_ICNTRL)) rc = crshm_detach(p_ICNTRL, sz_ICNTRL)
    IF (C_ASSOCIATED(p_RCNTRL)) rc = crshm_detach(p_RCNTRL, sz_RCNTRL)
    IF (C_ASSOCIATED(p_ISTAT )) rc = crshm_detach(p_ISTAT , sz_ISTAT )
    IF (C_ASSOCIATED(p_RSTATE)) rc = crshm_detach(p_RSTATE, sz_RSTATE)
    IF (C_ASSOCIATED(p_slices)) rc = crshm_detach(p_slices, sz_slices)
    IF (C_ASSOCIATED(p_const )) rc = crshm_detach(p_const , sz_const )
    IF (C_ASSOCIATED(p_ctl   )) rc = crshm_detach(p_ctl   , sz_ctl   )
    IF ( unlink_names .AND. LEN_TRIM(stem) > 0 ) THEN
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_C'     ))
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_RCONST'))
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_ICNTRL'))
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_RCNTRL'))
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_ISTATUS'))
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_RSTATE'))
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_slices'))
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_const' ))
       rc = crshm_unlink_stale(cstr(TRIM(stem)//'_ctl'   ))
    END IF
    p_C=C_NULL_PTR; p_RCONST=C_NULL_PTR; p_ICNTRL=C_NULL_PTR
    p_RCNTRL=C_NULL_PTR; p_ISTAT=C_NULL_PTR; p_RSTATE=C_NULL_PTR
    p_const=C_NULL_PTR; p_ctl=C_NULL_PTR; p_slices=C_NULL_PTR
    NULLIFY(gcr_ctl); NULLIFY(gcr_const); NULLIFY(gcr_slices)
  END SUBROUTINE teardown_segments

!------------------------------------------------------------------------------
! Worker (kpp_worker) side
!------------------------------------------------------------------------------
!BOP
! !IROUTINE: Chem_Remote_Worker_Attach
! !DESCRIPTION: Bounded-retry attach to the rank's segments/semaphores (launch
!  order is not guaranteed). Attaches the fixed-size control page first, reads
!  the mechanism counts from it, then attaches the const + six data segments and
!  returns their C pointers for the worker to C_F_POINTER. Verifies magic/abi
!  and the mechanism identity. ok=.FALSE. on hard mismatch or timeout.
!EOP
  SUBROUTINE Chem_Remote_Worker_Attach( w_nspec, w_nreact, w_nvar, w_nfix,   &
                                        max_wait_s,                          &
                                        cp_C, cp_RCONST, cp_ICNTRL,          &
                                        cp_RCNTRL, cp_ISTAT, cp_RSTATE, ok )
    INTEGER, INTENT(IN)  :: w_nspec, w_nreact, w_nvar, w_nfix
    ! Explicit C_DOUBLE (NOT bare REAL) so this dummy is ABI-identical whether
    ! or not the caller was compiled with -fdefault-real-8 (kpp_worker is).
    REAL(C_DOUBLE), INTENT(IN)  :: max_wait_s
    TYPE(C_PTR), INTENT(OUT) :: cp_C, cp_RCONST, cp_ICNTRL, cp_RCNTRL
    TYPE(C_PTR), INTENT(OUT) :: cp_ISTAT, cp_RSTATE
    LOGICAL, INTENT(OUT) :: ok

    INTEGER :: rank, tries, max_tries
    INTEGER(C_SIZE_T) :: sz_ctl_local

    ok = .FALSE.
    cp_C=C_NULL_PTR; cp_RCONST=C_NULL_PTR; cp_ICNTRL=C_NULL_PTR
    cp_RCNTRL=C_NULL_PTR; cp_ISTAT=C_NULL_PTR; cp_RSTATE=C_NULL_PTR

    CALL build_stem(.TRUE., rank)
    IF ( rank < 0 ) THEN
       WRITE(6,*) 'worker_attach: no GCHP_CHEM_RANK'; RETURN
    END IF
    ! unbuffered stderr diagnostic: the exact object stem this worker is
    ! trying to ATTACH — compare against the rank's "created stem=" line.
    WRITE(0,'(a,i0,a)') '[CHEMREMOTE worker ', rank, '] attach stem='//TRIM(stem)
    FLUSH(0)

    ! poll for the control segment (size known independent of ncell)
    sz_ctl_local = C_SIZEOF(ctl_template)
    max_tries = MAX(1, INT(max_wait_s / 0.1))
    DO tries = 1, max_tries
       p_ctl = crshm_attach(cstr(TRIM(stem)//'_ctl'), sz_ctl_local)
       IF ( C_ASSOCIATED(p_ctl) ) EXIT
       CALL msleep_100ms()
    END DO
    IF ( .NOT. C_ASSOCIATED(p_ctl) ) THEN
       WRITE(0,'(a,i0,a)') '[CHEMREMOTE worker ', rank,                        &
            '] control seg NEVER appeared for stem='//TRIM(stem); FLUSH(0)
       WRITE(6,*) 'worker_attach: control segment never appeared (rank ',rank,')'
       RETURN
    END IF
    WRITE(0,'(a,i0,a)') '[CHEMREMOTE worker ', rank, '] ATTACHED ok'; FLUSH(0)

    CALL C_F_POINTER(p_ctl, gcr_ctl)
    IF ( gcr_ctl%magic /= GCR_MAGIC .OR. gcr_ctl%abi /= GCR_ABI ) THEN
       WRITE(6,*) 'worker_attach: magic/abi mismatch'; RETURN
    END IF
    IF ( gcr_ctl%nspec  /= w_nspec  .OR. gcr_ctl%nreact /= w_nreact .OR.       &
         gcr_ctl%nvar   /= w_nvar   .OR. gcr_ctl%nfix   /= w_nfix ) THEN
       WRITE(6,*) 'worker_attach: MECHANISM MISMATCH ctl=(',gcr_ctl%nspec,    &
            gcr_ctl%nreact,gcr_ctl%nvar,gcr_ctl%nfix,') worker=(',            &
            w_nspec,w_nreact,w_nvar,w_nfix,')'
       RETURN
    END IF

    ! now sizes are known from the control page
    CALL compute_sizes(INT(gcr_ctl%nspec), INT(gcr_ctl%nreact),               &
                       INT(gcr_ctl%nvar),  INT(gcr_ctl%ncell_total))

    p_const  = crshm_attach(cstr(TRIM(stem)//'_const' ), sz_const )
    p_slices = crshm_attach(cstr(TRIM(stem)//'_slices'), sz_slices)
    p_C      = crshm_attach(cstr(TRIM(stem)//'_C'     ), sz_C     )
    p_RCONST = crshm_attach(cstr(TRIM(stem)//'_RCONST'), sz_RCONST)
    p_ICNTRL = crshm_attach(cstr(TRIM(stem)//'_ICNTRL'), sz_ICNTRL)
    p_RCNTRL = crshm_attach(cstr(TRIM(stem)//'_RCNTRL'), sz_RCNTRL)
    p_ISTAT  = crshm_attach(cstr(TRIM(stem)//'_ISTATUS'),sz_ISTAT )
    p_RSTATE = crshm_attach(cstr(TRIM(stem)//'_RSTATE'), sz_RSTATE)
    IF ( .NOT.(C_ASSOCIATED(p_const) .AND. C_ASSOCIATED(p_slices).AND.         &
               C_ASSOCIATED(p_C)     .AND.                                     &
               C_ASSOCIATED(p_RCONST).AND. C_ASSOCIATED(p_ICNTRL).AND.         &
               C_ASSOCIATED(p_RCNTRL).AND. C_ASSOCIATED(p_ISTAT) .AND.         &
               C_ASSOCIATED(p_RSTATE)) ) THEN
       WRITE(6,*) 'worker_attach: data segment attach failed'; RETURN
    END IF
    CALL C_F_POINTER(p_const, gcr_const, [2*INT(gcr_ctl%nvar)+INT(gcr_ctl%nspec)])
    CALL C_F_POINTER(p_slices, gcr_slices, [2*GCR_MAXW])

    ! attach both semaphores (must exist by now — rank created before posting)
    sem_ready = crsem_attach(cstr(TRIM(stem)//'_ready'))
    sem_done  = crsem_attach(cstr(TRIM(stem)//'_done' ))
    IF ( .NOT.(C_ASSOCIATED(sem_ready) .AND. C_ASSOCIATED(sem_done)) ) THEN
       WRITE(6,*) 'worker_attach: sem attach failed'; RETURN
    END IF

    cp_C=p_C; cp_RCONST=p_RCONST; cp_ICNTRL=p_ICNTRL
    cp_RCNTRL=p_RCNTRL; cp_ISTAT=p_ISTAT; cp_RSTATE=p_RSTATE
    ok = .TRUE.
    WRITE(6,'(a,i0,a)') 'worker_attach: rank ', rank, ' attached OK'
  END SUBROUTINE Chem_Remote_Worker_Attach
!EOC

  ! Block until the rank posts `ready`; return the command (SOLVE or EXIT).
  ! On sem error returns EXIT so the worker shuts down rather than spins.
  FUNCTION Chem_Remote_Worker_Wait() RESULT(cmd)
    INTEGER :: cmd
    INTEGER(C_INT) :: rc
    rc = crsem_wait(sem_ready)
    IF ( rc /= 0 ) THEN
       cmd = INT(GCR_CMD_EXIT)
       RETURN
    END IF
    cmd = INT(gcr_ctl%command)
  END FUNCTION Chem_Remote_Worker_Wait

  ! Signal the rank that the batch is solved.
  SUBROUTINE Chem_Remote_Worker_Done()
    INTEGER(C_INT) :: rc
    rc = crsem_post(sem_done)
  END SUBROUTINE Chem_Remote_Worker_Done

  ! M>N: return THIS worker's cell slice for the current superstep as 1-based
  ! inclusive [lo,hi] (the natural Fortran loop bound). The rank published the
  ! slot as 0-based half-open [lo0,hi0); we return lo0+1 .. hi0. The worker's slot
  ! index comes from env GCHP_CHEM_SUBRANK (0..K-1); default 0 (the 1:1 case, where
  ! slot 0 = the whole batch, so this reduces to 1..ncell_local exactly). An empty
  ! slice (lo>hi) is valid and means "no cells for me this step" (K > ncell_local).
  SUBROUTINE Chem_Remote_Worker_Slice( lo, hi )
    INTEGER, INTENT(OUT) :: lo, hi
    INTEGER, SAVE :: sub = -1
    CHARACTER(LEN=64) :: sbuf
    INTEGER :: dlen, dstat, ios
    IF ( sub < 0 ) THEN                 ! resolve subrank once
       sub = 0
       CALL get_environment_variable('GCHP_CHEM_SUBRANK', sbuf, dlen, dstat)
       IF ( dstat == 0 .AND. dlen > 0 ) THEN
          READ(sbuf, *, IOSTAT=ios) sub
          IF ( ios /= 0 .OR. sub < 0 .OR. sub >= GCR_MAXW ) sub = 0
       END IF
    END IF
    IF ( .NOT. ASSOCIATED(gcr_slices) ) THEN   ! defensive: behave as 1:1 whole-batch
       lo = 1; hi = INT(gcr_ctl%ncell_local); RETURN
    END IF
    lo = INT(gcr_slices(2*sub+1)) + 1          ! 0-based half-open -> 1-based inclusive
    hi = INT(gcr_slices(2*sub+2))
  END SUBROUTINE Chem_Remote_Worker_Slice

  ! Worker teardown: detach segments + close sems, but never unlink (rank owns).
  SUBROUTINE Chem_Remote_Worker_Detach()
    INTEGER(C_INT) :: rc
    IF ( C_ASSOCIATED(sem_ready) ) rc = crsem_close(sem_ready)
    IF ( C_ASSOCIATED(sem_done ) ) rc = crsem_close(sem_done )
    CALL teardown_segments(unlink_names=.FALSE.)
  END SUBROUTINE Chem_Remote_Worker_Detach

  ! ~100ms sleep that YIELDS the CPU (real nanosleep via the C shim). The old
  ! SYSTEM_CLOCK spin busy-waited a whole core; with M>N (up to `cores` workers
  ! per node all polling during the >60s GCHP init) that starved the ranks and
  ! slowed init enough that workers timed out -> in-process fallback -> SLOWER.
  SUBROUTINE msleep_100ms()
    CALL crshm_msleep_ms(100_C_INT)
  END SUBROUTINE msleep_100ms

END MODULE Chem_Remote_Mod
