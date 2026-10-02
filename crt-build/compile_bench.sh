#!/bin/bash
set -x
dnf install -y gcc tar gzip >/dev/null 2>&1
I=/out/crt-install; mkdir -p $I; tar xzf /out/crt-install.tar.gz -C $I 2>/dev/null
# link order: dependents before dependencies
gcc -O2 /out/crt_s3_bench.c -o /out/crt_s3_bench \
  -I$I/include \
  -L$I/lib64 -L$I/lib \
  -laws-c-s3 -laws-c-auth -laws-c-http -laws-c-io -laws-c-cal -laws-c-sdkutils \
  -laws-c-compression -laws-checksums -laws-c-common -ls2n -lcrypto \
  -lpthread -lrt -lm -ldl 2>/out/compile.log
if [ -x /out/crt_s3_bench ]; then echo "COMPILE_OK" > /out/compile-status.txt; file /out/crt_s3_bench >> /out/compile-status.txt
else echo "COMPILE_FAIL" > /out/compile-status.txt; tail -25 /out/compile.log >> /out/compile-status.txt; fi
