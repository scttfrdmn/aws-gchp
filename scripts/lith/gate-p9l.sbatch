#!/bin/bash
#SBATCH --job-name=p9l-48
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=48
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=/scratch/lith-gates/p9l/slurm-%j.log
# Gate 5f-P9l (lith#349 cell 2 / #350): gate-p9j.sh at 48 ranks on one c8g.48xlarge, lith v1.6.0.
# Pre-registered in data/lith-gates/inregion-streams.txt. Same harness as the 12-rank head-node cell.
echo "node $(hostname)  $(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-type)  nproc $(nproc)"
command -v fusermount3 >/dev/null || { echo "fuse3 missing on compute node"; exit 1; }
RANKS=48 REPS=2 LITH=/scratch/lith-gates/v160/lith OUT=/scratch/lith-gates/p9l RD=/scratch/gchp_p9l_TT \
  bash /scratch/lith-gates/gate-p9j.sh
