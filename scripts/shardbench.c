#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mpi.h>
int main(int argc,char**argv){
  MPI_Init(&argc,&argv);
  int rank,n; MPI_Comm_rank(MPI_COMM_WORLD,&rank); MPI_Comm_size(MPI_COMM_WORLD,&n);
  long mb = argc>1?atol(argv[1]):27;         // per-rank chunk MB (TT ~27, fullchem ~230)
  long bytes = mb*1024L*1024L;
  char*src=malloc(bytes); memset(src,rank&0xff,bytes);   // simulated INTERNAL-state buffer
  char*buf=malloc(bytes);
  struct timespec t0,t1,t2;
  clock_gettime(CLOCK_MONOTONIC,&t0);
  memcpy(buf,src,bytes);                     // serialize step (memory copy)
  clock_gettime(CLOCK_MONOTONIC,&t1);
  char fn[256]; snprintf(fn,256,"%s/rank-%05d.bin",argv[2],rank);
  FILE*f=fopen(fn,"wb"); size_t w=fwrite(buf,1,bytes,f); fflush(f); fclose(f);  // independent write, no barrier
  clock_gettime(CLOCK_MONOTONIC,&t2);
  double ser=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)/1e9;
  double wr =(t2.tv_sec-t1.tv_sec)+(t2.tv_nsec-t1.tv_nsec)/1e9;
  // all-ranks-finish wall = max write-completion across ranks (the real boundary cost)
  double mine=ser+wr, allmax; MPI_Reduce(&mine,&allmax,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);
  double sermax,wrmax; MPI_Reduce(&ser,&sermax,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);
  MPI_Reduce(&wr,&wrmax,1,MPI_DOUBLE,MPI_MAX,0,MPI_COMM_WORLD);
  if(rank==0) printf("SHARDBENCH ranks=%d chunkMB=%ld serialize_max=%.4fs write_max=%.4fs all_ranks_finish=%.4fs agg_MBps=%.0f per_rank_write_MBps=%.0f\n",
     n,mb,sermax,wrmax,allmax,(n*mb)/allmax,mb/wrmax);
  free(src);free(buf); MPI_Finalize(); return 0;
}
