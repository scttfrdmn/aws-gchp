/* s3_handoff_bench.c — the "really wide to S3" handoff measurement.
 *
 * The disk baseline was catastrophic (168 s) because 120 ranks contend on ONE shared Lustre
 * filesystem — a single lock/metadata domain. S3 is the opposite: a horizontally-scaled object
 * store with no shared lock, so N ranks each PUTting their OWN object spreads across partitions and
 * throughput scales WITH concurrency, not against it. This benchmark measures that directly.
 *
 * Each rank: (1) stages its 230 MB state chunk in /dev/shm (serialize = memory, ~free, measured
 * elsewhere at ~0.33 s), (2) PUTs it to its own S3 key via `aws s3 cp` (multipart-parallel => wide
 * WITHIN each rank too), (3) barrier, (4) GETs it back (the consumer read leg). We report
 * all-ranks-finish (max across ranks) for the PUT and GET legs — the real handoff round-trip.
 *
 * Unlike RDMA (fast but both endpoints must be alive + co-scheduled), the S3 handoff is DURABLE and
 * TEMPORALLY DECOUPLED: N producers -> M consumers, any time, dead workers' objects just get re-read.
 * That is the medium that actually enables the decoupled-design prize (spot / elastic / async / GPU
 * chemistry). Speed only has to be within an order of magnitude of the chemistry step (tens of s).
 *
 * Build: mpicc -O2 s3_handoff_bench.c -o s3_handoff_bench   (OMPI_CC=/sw/.../gcc)
 * Run:   mpirun -n <N> ./s3_handoff_bench <MB> s3://<bucket>/<prefix>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mpi.h>

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec/1e9; }

int main(int argc,char**argv){
    MPI_Init(&argc,&argv);
    int rank,n; MPI_Comm_rank(MPI_COMM_WORLD,&rank); MPI_Comm_size(MPI_COMM_WORLD,&n);
    long mb = argc>1?atol(argv[1]):230;
    const char*s3prefix = argc>2?argv[2]:"s3://gchp-shared-storage-us-east-1/handoff-bench";
    long bytes = mb*1024L*1024L;

    /* stage the serialized state chunk in /dev/shm (memory-speed; this is the "serialize" step) */
    char local[256]; snprintf(local,256,"/dev/shm/state-%05d.bin",rank);
    char*buf=malloc(bytes); memset(buf,(rank&0x3f)+1,bytes);
    double s0=now();
    FILE*f=fopen(local,"wb"); fwrite(buf,1,bytes,f); fflush(f); fclose(f);
    double stage=now()-s0;
    free(buf);

    char put_cmd[1024], get_cmd[1024], rb[256];
    snprintf(rb,256,"/dev/shm/rb-%05d.bin",rank);
    snprintf(put_cmd,1024,"aws s3 cp %s %s/rank-%05d.bin --region us-east-1 --only-show-errors",local,s3prefix,rank);
    snprintf(get_cmd,1024,"aws s3 cp %s/rank-%05d.bin %s --region us-east-1 --only-show-errors",s3prefix,rank,rb);

    /* ---- PUT leg (really wide: 120 ranks x multipart concurrency, no shared lock) ---- */
    MPI_Barrier(MPI_COMM_WORLD);
    double p0=now(); int prc=system(put_cmd); double put=now()-p0;

    /* ---- GET leg (the consumer read-back) ---- */
    MPI_Barrier(MPI_COMM_WORLD);
    double g0=now(); int grc=system(get_cmd); double get=now()-g0;

    int put_fail = (prc!=0), get_fail=(grc!=0), pf_tot, gf_tot;
    double stage_max,put_max,get_max;
    MPI_Reduce(&stage,&stage_max,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);
    MPI_Reduce(&put,&put_max,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);
    MPI_Reduce(&get,&get_max,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);
    MPI_Reduce(&put_fail,&pf_tot,1,MPI_INT,MPI_SUM,0,MPI_COMM_WORLD);
    MPI_Reduce(&get_fail,&gf_tot,1,MPI_INT,MPI_SUM,0,MPI_COMM_WORLD);

    if(rank==0){
        double tot=(double)n*mb;
        printf("S3HANDOFF ranks=%d chunkMB=%ld total_GB=%.1f | stage_max=%.3fs | "
               "PUT all_finish=%.3fs (%.0f MB/s agg) | GET all_finish=%.3fs (%.0f MB/s agg) | "
               "put_failures=%d get_failures=%d\n",
               n, mb, tot/1024.0, stage_max,
               put_max, tot/put_max, get_max, tot/get_max, pf_tot, gf_tot);
    }
    remove(local); remove(rb);
    MPI_Finalize(); return 0;
}
