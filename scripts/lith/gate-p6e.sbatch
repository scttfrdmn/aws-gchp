#!/bin/bash
#SBATCH --job-name=lith-p6e
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=/scratch/lith-gates/p6e-%j.log
# 5f-P6e: two arms of gate-p6e.sh on one node. Pre-registered: inregion-streams.txt "GATE 5f-P6e".
G=/scratch/lith-gates
TOK=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
echo "instance: $(curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-type)  host $(hostname)  cores $(nproc)  mem $(free -g | awk '/Mem:/{print $2}') GiB"
for m in 2GB 64GB; do
  echo "################ ARM T${m%B}  $(date -u +%FT%TZ)"
  MEMC=$m OUT=$G/p6e-T${m%B} RD=/scratch/gchp_p6e_TT DEADLINE=900 "$G/gate-p6e.sh"
done
echo "################ P6E DONE $(date -u +%FT%TZ)"
