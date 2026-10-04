/* chem_remote_s3.c — S3 transport backend for decoupled chemistry (Phase C2).
 *
 * The RANK side of the S3-wide handoff. Writes a slice's flat KPP input buffers to a local
 * temp file in EXACTLY the kpp_worker FILE-mode layout, uploads it to a per-slice S3 key,
 * then (after releasing) polls for the worker's .done marker and downloads the .out blob.
 * The elastic worker pool (scripts/s3_chem_worker.py, launched SEPARATELY — no co-scheduling,
 * no EFA, spot-ok) does the GET/solve/PUT. This is the operational prize: transport ranks and
 * the chem fleet have independent lifecycles.
 *
 * Serialization MUST byte-match kpp_worker Run_File_Mode:
 *   record 1: int32  h_NSPEC,h_NREACT,h_NVAR,h_NFIX,NCELL,ar_flag,ss_flag
 *   record 2: f64    DT
 *   record 3: f64    ATOL(NVAR)
 *   record 4: f64    RTOL(NVAR)
 *   record 5: f64    MW(NSPEC)
 *   record 6: f64    C(NSPEC,NCELL)      [column-major, cell-contiguous]
 *   record 7: f64    RCONST(NREACT,NCELL)
 *   record 8: int32  ICNTRL(20,NCELL)
 *   record 9: f64    RCNTRL(20,NCELL)
 * NOTE: Fortran unformatted STREAM has NO record markers -> raw concatenation. We match that.
 * OUT blob (from worker, full contract): int32 NSPEC,NCELL ; f64 C ; f64 RSTATE(20,N) ; i32 ISTATUS(20,N).
 *
 * All object I/O shells to `aws s3api` (already on the AMI, IAM via instance role) — no SDK dep,
 * mirroring s3_chem_worker.py. Fortran-callable; policy (slicing, barrier) stays in chem_remote_mod.
 * This backend is SELECTED only when GCHP_CHEM_TRANSPORT=s3; the shm path never calls it.
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200112L
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <stdarg.h>
#include <stdint.h>
#include <sys/wait.h>

/* ============================================================================
 * PERSISTENT boto3 SIDECAR (the throughput fix). The original per-object
 * `system("aws s3api ...")` shim forked the whole AWS CLI once per object per op
 * (~1920 forks/superstep at C180 = ~9.4 min in process-spawn ALONE -> the C180
 * timeout). Instead we fork ONE long-lived crs3_sidecar.py per rank at first use
 * and speak a one-line-per-op protocol over pipes: NO per-op fork, and the sidecar
 * holds a persistent boto3 client + tuned multipart TransferConfig (max_concurrency
 * =64 -> 0.70s/228MB on m9g, ~10x the CLI, NIC-bound per the microbench). Falls back
 * to per-object `aws s3api` (the old aws() path) only if the sidecar can't be started.
 * ==========================================================================*/
static pid_t  crs3_sc_pid = -1;
static FILE  *crs3_sc_out = NULL;   /* write commands here (sidecar stdin)  */
static FILE  *crs3_sc_in  = NULL;   /* read replies here   (sidecar stdout) */

/* Start the sidecar once. Returns 0 on success. Idempotent. */
static int crs3_sidecar_start(void) {
    if (crs3_sc_pid > 0) return 0;                 /* already up */
    const char *script = getenv("GCHP_CHEM_S3_SIDECAR");   /* path to crs3_sidecar.py */
    if (!script) return 1;
    int to_sc[2], from_sc[2];                      /* parent->child, child->parent */
    if (pipe(to_sc) != 0 || pipe(from_sc) != 0) return 1;
    pid_t pid = fork();
    if (pid < 0) return 1;
    if (pid == 0) {                                /* child: wire pipes to stdio, exec python */
        dup2(to_sc[0], STDIN_FILENO); dup2(from_sc[1], STDOUT_FILENO);
        close(to_sc[0]); close(to_sc[1]); close(from_sc[0]); close(from_sc[1]);
        execlp("python3", "python3", script, (char*)NULL);
        _exit(127);
    }
    close(to_sc[0]); close(from_sc[1]);
    crs3_sc_out = fdopen(to_sc[1], "w");
    crs3_sc_in  = fdopen(from_sc[0], "r");
    crs3_sc_pid = pid;
    if (!crs3_sc_out || !crs3_sc_in) { crs3_sc_pid = -1; return 1; }
    /* readiness handshake: PING -> expect "OK" */
    fprintf(crs3_sc_out, "PING\n"); fflush(crs3_sc_out);
    char rep[256] = {0};
    if (!fgets(rep, sizeof rep, crs3_sc_in) || strncmp(rep, "OK", 2) != 0) {
        crs3_sc_pid = -1; return 1;
    }
    return 0;
}

/* Send one command, read one reply. Return 0 iff reply starts "OK". */
static int crs3_sc_cmd(const char *fmt, ...) {
    if (crs3_sc_pid <= 0) return -1;
    va_list ap; va_start(ap, fmt); vfprintf(crs3_sc_out, fmt, ap); va_end(ap);
    fputc('\n', crs3_sc_out); fflush(crs3_sc_out);
    char rep[256] = {0};
    if (!fgets(rep, sizeof rep, crs3_sc_in)) return -1;    /* sidecar died */
    return (strncmp(rep, "OK", 2) == 0) ? 0 : 1;
}

void crs3_sidecar_stop(void) {
    if (crs3_sc_pid > 0) {
        if (crs3_sc_out) { fprintf(crs3_sc_out, "QUIT\n"); fflush(crs3_sc_out); }
        int st; waitpid(crs3_sc_pid, &st, 0);
        crs3_sc_pid = -1;
    }
}

/* Plain heap buffers for S3 mode (no shm — the rank owns the data and ships copies).
 * Mirrors the shm path's "Init returns C_PTRs, fullchem C_F_POINTERs onto them". */
void *crs3_alloc(size_t nbytes) { return calloc(1, nbytes); }
void  crs3_free (void *p)       { free(p); }

/* CRITICAL: GCHP compiles ALL GeosChem Fortran with -fconvert=big-endian, so kpp_worker's
 * unformatted READ/WRITE are BIG-ENDIAN. aarch64 is little-endian, so this C shim must
 * byte-swap every int32/f64 it writes (and un-swap on read) to match the worker's I/O.
 * (Phase 1a/1b never hit this: Fortran wrote AND read, both big-endian, self-consistent.
 * Our C serialization is the first non-Fortran producer -> it MUST swap.) These write one
 * element at a time swapped; the payload is ~200MB but dominated by the chem solve, and the
 * whole handoff is still << compute (measured). */
static uint32_t bswap32(uint32_t x){ return __builtin_bswap32(x); }
static uint64_t bswap64(uint64_t x){ return __builtin_bswap64(x); }
/* write n int32 big-endian */
static size_t fwrite_be_i32(const int *p, size_t n, FILE *f){
    size_t w=0; for(size_t i=0;i<n;i++){ uint32_t v=bswap32((uint32_t)p[i]); w+=fwrite(&v,4,1,f);} return w; }
/* write n f64 big-endian */
static size_t fwrite_be_f64(const double *p, size_t n, FILE *f){
    size_t w=0; for(size_t i=0;i<n;i++){ uint64_t v; memcpy(&v,&p[i],8); v=bswap64(v); w+=fwrite(&v,8,1,f);} return w; }
/* read n int32 big-endian into native */
static size_t fread_be_i32(int *p, size_t n, FILE *f){
    size_t r=0; uint32_t v; for(size_t i=0;i<n;i++){ if(fread(&v,4,1,f)!=1)break; v=bswap32(v); memcpy(&p[i],&v,4); r++;} return r; }
/* read n f64 big-endian into native */
static size_t fread_be_f64(double *p, size_t n, FILE *f){
    size_t r=0; uint64_t v; for(size_t i=0;i<n;i++){ if(fread(&v,8,1,f)!=1)break; v=bswap64(v); memcpy(&p[i],&v,8); r++;} return r; }

/* Serialize one slice's inputs to `path` in EXACT kpp_worker FILE-mode byte layout
 * (Fortran unformatted stream = raw concatenation, no record markers). Buffers are the
 * rank's full-domain arrays; we write only columns [lo,hi) (0-based half-open), so NCELL=hi-lo.
 *   hdr: i32 nspec,nreact,nvar,nfix,ncell,ar,ss ; f64 dt ; f64 atol(nvar),rtol(nvar),mw(nspec) ;
 *   f64 C(nspec,ncell) ; f64 RCONST(nreact,ncell) ; i32 ICNTRL(20,ncell) ; f64 RCNTRL(20,ncell)
 * The column-major full arrays have stride = leading dim; column j lives at base + j*ld, so the
 * slice [lo,hi) is a contiguous block base+lo*ld .. base+hi*ld (cell-contiguous) — one fwrite each. */
int crs3_write_in(const char *path, int nspec, int nreact, int nvar, int nfix,
                  int lo, int hi, int ar, int ss, double dt,
                  const double *atol, const double *rtol, const double *mw,
                  const double *C, const double *RCONST,
                  const int *ICNTRL, const double *RCNTRL) {
    FILE *f = fopen(path, "wb");
    if (!f) return 1;
    int ncell = hi - lo;
    int hdr[7] = { nspec, nreact, nvar, nfix, ncell, ar, ss };
    double dt_local = dt;
    size_t ok = 1;
    ok &= fwrite_be_i32(hdr, 7, f) == 7;                     /* big-endian to match -fconvert */
    ok &= fwrite_be_f64(&dt_local, 1, f) == 1;
    ok &= fwrite_be_f64(atol, (size_t)nvar, f) == (size_t)nvar;
    ok &= fwrite_be_f64(rtol, (size_t)nvar, f) == (size_t)nvar;
    ok &= fwrite_be_f64(mw,   (size_t)nspec, f) == (size_t)nspec;
    ok &= fwrite_be_f64(C      + (size_t)lo*nspec,  (size_t)ncell*nspec,  f) == (size_t)ncell*nspec;
    ok &= fwrite_be_f64(RCONST + (size_t)lo*nreact, (size_t)ncell*nreact, f) == (size_t)ncell*nreact;
    ok &= fwrite_be_i32(ICNTRL + (size_t)lo*20,     (size_t)ncell*20,     f) == (size_t)ncell*20;
    ok &= fwrite_be_f64(RCNTRL + (size_t)lo*20,     (size_t)ncell*20,     f) == (size_t)ncell*20;
    fclose(f);
    return ok ? 0 : 2;
}

/* Read the worker's .out blob at `path` back into the rank's full arrays at columns [lo,hi).
 *   out layout: i32 nspec,ncell ; f64 C(nspec,ncell) ; f64 RSTATE(20,ncell) ; i32 ISTATUS(20,ncell)
 * Writes into C[lo*nspec..], RSTATE[lo*20..], ISTATUS[lo*20..]. Verifies nspec/ncell match. */
int crs3_read_out(const char *path, int nspec, int lo, int hi,
                  double *C, double *RSTATE, int *ISTATUS) {
    FILE *f = fopen(path, "rb");
    if (!f) return 1;
    int hdr[2]; int ncell = hi - lo;
    size_t ok = fread_be_i32(hdr, 2, f) == 2;               /* big-endian: worker wrote BE */
    if (!ok || hdr[0] != nspec || hdr[1] != ncell) { fclose(f); return 3; }
    ok &= fread_be_f64(C       + (size_t)lo*nspec, (size_t)ncell*nspec, f) == (size_t)ncell*nspec;
    ok &= fread_be_f64(RSTATE  + (size_t)lo*20,    (size_t)ncell*20,    f) == (size_t)ncell*20;
    ok &= fread_be_i32(ISTATUS + (size_t)lo*20,    (size_t)ncell*20,    f) == (size_t)ncell*20;
    fclose(f);
    return ok ? 0 : 2;
}

/* env-provided: bucket + jobid; set once by the launch script. */
static const char *crs3_bucket(void){ const char*b=getenv("GCHP_CHEM_S3_BUCKET"); return b?b:""; }
static const char *crs3_jobid (void){ const char*j=getenv("GCHP_JOBID"); return j?j:"0"; }

/* run `aws s3api <...>`; return 0 on success. Quiet unless CRS3_DEBUG. */
static int aws(const char *fmt, ...) {
    char cmd[4096];
    va_list ap; va_start(ap,fmt); vsnprintf(cmd,sizeof cmd,fmt,ap); va_end(ap);
    if (!getenv("CRS3_DEBUG")) { strncat(cmd," >/dev/null 2>&1", sizeof cmd-strlen(cmd)-1); }
    return system(cmd);
}

/* Build the slice object key with a HASH PREFIX for S3 request-rate spreading.
 * S3 allows ~3500 PUT/s PER PREFIX; 48 ranks x K slices under one flat prefix can throttle at
 * high superstep rates. A 2-hex-nibble hash of (rank,sub) fans keys across 256 prefixes -- S3's
 * own recommended high-throughput pattern. (This is a REQUEST-RATE guard, not a speed play; the
 * per-object throughput is NIC-bound either way per the microbench.) Layout:
 *   chemq/<jobid>/<hh>/r<rank>_k<sub>_s<step>.<suffix>
 * The elastic worker pool (s3_chem_worker.py) LISTs chemq/<jobid>/ recursively so it still finds
 * all slices regardless of the hash subdir. */
static void crs3_key(char *out, size_t n, int rank, int sub, int step, const char *suffix) {
    unsigned h = ((unsigned)rank * 2654435761u + (unsigned)sub * 40503u) & 0xffu;  /* 0..255 */
    snprintf(out, n, "chemq/%s/%02x/r%d_k%d_s%d.%s", crs3_jobid(), h, rank, sub, step, suffix);
}

/* PUT a local file to the slice .in key. Sidecar if up, else per-object aws fallback. */
int crs3_put_in(int rank, int sub, int step, const char *localpath) {
    char key[512]; crs3_key(key, sizeof key, rank, sub, step, "in");
    if (crs3_sidecar_start() == 0) return crs3_sc_cmd("PUT %s %s", localpath, key);
    return aws("aws s3api put-object --bucket %s --key %s --body %s", crs3_bucket(), key, localpath);
}

/* Does the worker's .done marker exist yet? 0 = yes (done), nonzero = not yet. */
int crs3_done_exists(int rank, int sub, int step) {
    char key[512]; crs3_key(key, sizeof key, rank, sub, step, "done");
    if (crs3_sidecar_start() == 0) return crs3_sc_cmd("HEAD %s", key);
    return aws("aws s3api head-object --bucket %s --key %s", crs3_bucket(), key);
}

/* GET the worker's .out blob to a local file. 0 on success. */
int crs3_get_out(int rank, int sub, int step, const char *localpath) {
    char key[512]; crs3_key(key, sizeof key, rank, sub, step, "out");
    if (crs3_sidecar_start() == 0) return crs3_sc_cmd("GET %s %s", key, localpath);
    return aws("aws s3api get-object --bucket %s --key %s %s", crs3_bucket(), key, localpath);
}

/* Best-effort cleanup of a slice's objects (rank owns its keys). */
int crs3_cleanup(int rank, int sub, int step) {
    char kin[512],kout[512],kdone[512],kclaim[512];
    crs3_key(kin,  sizeof kin,  rank,sub,step,"in");
    crs3_key(kout, sizeof kout, rank,sub,step,"out");
    crs3_key(kdone,sizeof kdone,rank,sub,step,"done");
    crs3_key(kclaim,sizeof kclaim,rank,sub,step,"in.claim");
    if (crs3_sc_pid > 0) {
        crs3_sc_cmd("DEL %s", kin);  crs3_sc_cmd("DEL %s", kout);
        crs3_sc_cmd("DEL %s", kdone); crs3_sc_cmd("DEL %s", kclaim);
    } else {
        aws("aws s3api delete-object --bucket %s --key %s", crs3_bucket(), kin);
        aws("aws s3api delete-object --bucket %s --key %s", crs3_bucket(), kout);
        aws("aws s3api delete-object --bucket %s --key %s", crs3_bucket(), kdone);
        aws("aws s3api delete-object --bucket %s --key %s", crs3_bucket(), kclaim);
    }
    return 0;
}

/* Poll crs3_done_exists up to deadline_s (sleep step_ms between). Return 0 if done, 1 timeout. */
int crs3_poll_done(int rank, int sub, int step, double deadline_s) {
    struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0);
    for (;;) {
        if (crs3_done_exists(rank,sub,step)==0) return 0;
        clock_gettime(CLOCK_MONOTONIC,&t1);
        double el=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)*1e-9;
        if (el>=deadline_s) return 1;
        struct timespec ns={0,200*1000*1000L}; nanosleep(&ns,NULL);   /* 200ms poll */
    }
}
