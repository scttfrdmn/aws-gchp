#!/bin/bash
# Stage the fat-NIC box from the gchp-lith-ab head node (binary, slabread + its HDF5/MPI libs)
# and from this repo (scripts). Usage: stage-fatnic.sh <fat-box-ip>
set -eu
FAT=$1; HEAD=${HEAD:-54.242.205.168}; K=~/.ssh/aws-gchp.pem; O="-o StrictHostKeyChecking=accept-new"
R=$(cd "$(dirname "$0")/../.." && pwd)
ssh -i $K $O ec2-user@$FAT 'mkdir -p /home/ec2-user/g/lib'
ssh -i $K ec2-user@$HEAD 'cd /scratch/lith-gates && tar c lith-315 slabread -C /sw hdf5-1.14.0/lib openmpi-4.1.7/lib' \
  | ssh -i $K $O ec2-user@$FAT 'cd /home/ec2-user/g && tar x && cp -a hdf5-1.14.0/lib/. openmpi-4.1.7/lib/. lib/'
scp -i $K $O "$R"/scripts/lith/{gate-streams2.sh,gate-slab-nic.sh,drive-fatnic.sh,sampler.py} \
  "$R"/data/lith-gates/fatnic-a3dyn-objects.txt ec2-user@$FAT:/home/ec2-user/g/
ssh -i $K $O ec2-user@$FAT 'cd /home/ec2-user/g && chmod +x *.sh lith-315 slabread && echo "missing libs: $(LD_LIBRARY_PATH=lib ldd slabread | grep -c "not found")"; which fusermount3 python3 bc curl'
