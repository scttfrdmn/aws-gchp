#!/bin/bash
set -x
# amazonlinux:2023 aarch64 -> Linux/aarch64 CRT libs for the Graviton target
dnf install -y git cmake gcc gcc-c++ perl golang ninja-build openssl-devel tar gzip >/dev/null 2>&1
I=/out/crt-install; mkdir -p $I
cd /tmp
STATUS=/out/build-status.txt; : > $STATUS
for repo in aws-lc s2n-tls aws-c-common aws-checksums aws-c-cal aws-c-io aws-c-compression aws-c-http aws-c-sdkutils aws-c-auth aws-c-s3; do
  case $repo in aws-lc) url=https://github.com/aws/aws-lc.git;; s2n-tls) url=https://github.com/aws/s2n-tls.git;; *) url=https://github.com/awslabs/$repo.git;; esac
  git clone --depth 1 $url /tmp/$repo >/dev/null 2>&1 || { echo "$repo CLONE_FAIL" >>$STATUS; exit 1; }
  # aws-lc: DISABLE FIPS (the aarch64 ml_dsa ASM broke the on-m9g build) + no tests/tools
  EXTRA=""
  [ "$repo" = aws-lc ] && EXTRA="-DFIPS=OFF -DBUILD_LIBSSL=OFF -DBUILD_TOOL=OFF -DDISABLE_GO=OFF"
  [ "$repo" = s2n-tls ] && EXTRA="-DUNSAFE_TREAT_WARNINGS_AS_ERRORS=OFF"
  cmake -S /tmp/$repo -B /tmp/$repo/build -DCMAKE_INSTALL_PREFIX=$I -DCMAKE_PREFIX_PATH=$I \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF $EXTRA >/tmp/cm_$repo.log 2>&1
  if ! cmake --build /tmp/$repo/build --target install -j$(nproc) >>/tmp/cm_$repo.log 2>&1; then
    echo "$repo BUILD_FAIL: $(tail -5 /tmp/cm_$repo.log | tr '\n' '|')" >>$STATUS
    cp /tmp/cm_$repo.log /out/failed_$repo.log
    exit 1
  fi
  echo "$repo OK" >>$STATUS
done
# collect the s3 sample + libs
cp /tmp/aws-c-s3/build/samples/s3/s3 /out/s3-crt 2>/dev/null && echo "s3-crt binary OK" >>$STATUS || echo "s3 sample MISSING" >>$STATUS
tar czf /out/crt-install.tar.gz -C $I . 2>/dev/null && echo "crt-install.tar.gz OK" >>$STATUS
echo "DONE" >>$STATUS
