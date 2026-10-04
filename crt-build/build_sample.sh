#!/bin/bash
set -x
dnf install -y git cmake gcc gcc-c++ tar gzip >/dev/null 2>&1
I=/out/crt-install
# re-clone aws-c-s3 (container is fresh each run) + build WITH the sample against installed libs
git clone --depth 1 https://github.com/awslabs/aws-c-s3.git /tmp/aws-c-s3 >/dev/null 2>&1
# extract the prebuilt install libs back into place
mkdir -p $I; tar xzf /out/crt-install.tar.gz -C $I 2>/dev/null
cmake -S /tmp/aws-c-s3 -B /tmp/aws-c-s3/build -DCMAKE_INSTALL_PREFIX=$I -DCMAKE_PREFIX_PATH=$I \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF >/out/sample_cm.log 2>&1
cmake --build /tmp/aws-c-s3/build -j$(nproc) >>/out/sample_cm.log 2>&1
find /tmp/aws-c-s3/build -name s3 -type f -exec cp {} /out/s3-crt \; 2>/dev/null
[ -x /out/s3-crt ] && echo "SAMPLE_OK" > /out/sample-status.txt || { echo "SAMPLE_MISSING $(tail -3 /out/sample_cm.log|tr '\n' '|')" > /out/sample-status.txt; ls /tmp/aws-c-s3/build/samples/s3/ >> /out/sample-status.txt 2>&1; }
