/* handoff_transport_bench.c — complete the decoupled-handoff measurement.
 *
 * shardbench.c already proved the per-rank state handoff over shared-FS DISK is catastrophic
 * (175 s/superstep for 230 MB/rank fullchem-scale). This benchmark measures the SAME handoff over
 * the two MEMORY-SPEED media the decoupled design would actually use, so we can compare directly:
 *
 *   1. DISK   : each rank writes its chunk to shared Lustre (the baseline; expect ~catastrophic)
 *   2. SHM    : each rank writes its chunk to /dev/shm (tmpfs = on-node memory; models the
 *               on-node shared-memory chemistry-tier handoff)
 *   3. RDMA   : each rank MPI_Put's its chunk into a partner rank's window over EFA (models the
 *               inter-node memory-speed transport — the one-sided path the monolith already uses)
 *
 * For each medium + chunk size we report the ALL-RANKS-FINISH wall (the real superstep boundary
 * cost). The decoupled design pays iff SHM/RDMA are ~free relative to the chemistry step (tens of s);
 * the disk baseline shows what a naive per-shard-to-disk handoff costs by contrast.
 *
 * Build: mpicc -O2 handoff_transport_bench.c -o handoff_transport_bench   (OMPI_CC override on /sw)
 * Run:   mpirun -n <N> --mca mtl_ofi_provider_include efa ./handoff_transport_bench <MB> <shmdir> <lustredir>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mpi.h>

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec/1e9; }

static double write_file(const char*dir,int rank,char*buf,long bytes){
    char fn[512]; snprintf(fn,512,"%s/rank-%05d.bin",dir,rank);
    double t0=now();
    FILE*f=fopen(fn,"wb"); if(!f) return -1.0;
    fwrite(buf,1,bytes,f); fflush(f); fclose(f);
    return now()-t0;
}

int main(int argc,char**argv){
    MPI_Init(&argc,&argv);
    int rank,n; MPI_Comm_rank(MPI_COMM_WORLD,&rank); MPI_Comm_size(MPI_COMM_WORLD,&n);
    long mb = argc>1?atol(argv[1]):230;
    const char*shmdir    = argc>2?argv[2]:"/dev/shm";
    const char*lustredir = argc>3?argv[3]:"/scratch/handoff_out";
    long bytes = mb*1024L*1024L;

    char*src = malloc(bytes); memset(src,(rank&0x3f)+1,bytes);   /* simulated INTERNAL-state chunk */

    /* ---- 1. DISK (shared Lustre) ---- */
    double d_disk = write_file(lustredir,rank,src,bytes);
    MPI_Barrier(MPI_COMM_WORLD);

    /* ---- 2. SHM (tmpfs, on-node memory) ---- */
    double d_shm = write_file(shmdir,rank,src,bytes);
    MPI_Barrier(MPI_COMM_WORLD);

    /* ---- 3. RDMA one-sided: each rank Put's its chunk into partner (rank^1) window over EFA ---- */
    char*win_buf=NULL;
    MPI_Win win;
    MPI_Win_allocate(bytes, 1, MPI_INFO_NULL, MPI_COMM_WORLD, &win_buf, &win);
    int partner = rank ^ 1; if(partner>=n) partner=rank;   /* pair ranks; odd-man maps to self */
    MPI_Barrier(MPI_COMM_WORLD);
    double r0=now();
    MPI_Win_fence(0,win);
    MPI_Put(src, bytes, MPI_BYTE, partner, 0, bytes, MPI_BYTE, win);
    MPI_Win_fence(0,win);           /* completes the one-sided transfer */
    double d_rdma = now()-r0;
    MPI_Win_free(&win);

    /* all-ranks-finish wall = max across ranks for each medium (the real boundary cost) */
    double disk_max,shm_max,rdma_max;
    MPI_Reduce(&d_disk,&disk_max,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);
    MPI_Reduce(&d_shm,&shm_max,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);
    MPI_Reduce(&d_rdma,&rdma_max,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);

    if(rank==0){
        double tot=(double)n*mb;
        printf("HANDOFF ranks=%d chunkMB=%ld total_GB=%.1f | "
               "DISK all_finish=%.4fs (%.0f MB/s) | SHM all_finish=%.4fs (%.0f MB/s) | "
               "RDMA all_finish=%.4fs (%.0f MB/s)\n",
               n, mb, tot/1024.0,
               disk_max, tot/disk_max,
               shm_max,  tot/shm_max,
               rdma_max, tot/rdma_max);
    }
    free(src); MPI_Finalize(); return 0;
}
