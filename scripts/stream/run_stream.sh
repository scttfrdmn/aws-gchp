#!/bin/bash
# Runs on the target EC2 instance via user-data or SSH. Compiles STREAM (large arrays to exceed
# cache), runs OpenMP Triad across all cores, prints one RESULT line, then the instance self-terminates.
set -e
sudo dnf install -y gcc >/dev/null 2>&1 || sudo yum install -y gcc >/dev/null 2>&1
NCORE=$(nproc)
# array size: 8x last-level cache to guarantee we're hitting DRAM, not cache. Use 200M doubles = 1.6GB/array.
cat > /tmp/stream.c <<'CEOF'
#include <stdio.h>
#include <omp.h>
#include <sys/time.h>
#define N 200000000L
static double a[N], b[N], c[N];
double wtime(){struct timeval t;gettimeofday(&t,0);return t.tv_sec+t.tv_usec*1e-6;}
int main(){
  long j; double scalar=3.0, t, best=1e30;
  #pragma omp parallel for
  for(j=0;j<N;j++){a[j]=1.0;b[j]=2.0;c[j]=0.0;}
  for(int k=0;k<10;k++){
    t=wtime();
    #pragma omp parallel for
    for(j=0;j<N;j++) a[j]=b[j]+scalar*c[j];
    t=wtime()-t; if(t<best)best=t;
  }
  double gb=3.0*sizeof(double)*N/1e9;   // Triad: 2 reads + 1 write
  printf("STREAM_TRIAD_GBps=%.1f cores=%d\n", gb/best, omp_get_max_threads());
  return 0;
}
CEOF
gcc -O3 -fopenmp -o /tmp/stream /tmp/stream.c
OMP_NUM_THREADS=$NCORE OMP_PROC_BIND=spread /tmp/stream
