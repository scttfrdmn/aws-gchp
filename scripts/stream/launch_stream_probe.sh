#!/bin/bash
# launch_stream_probe.sh — per-arch STREAM Triad memory-bandwidth probe (Phase D).
# Launches each instance with user-data that compiles+runs STREAM to a FILE, waits, SSHs in to
# read the result (durable — console-output is lost when a self-terminating instance dies), then
# terminates explicitly. ~$5 total, minutes.
set -uo pipefail
KEY="$HOME/.ssh/aws-gchp.pem"; REGION=us-east-1
SUB=subnet-f59636d4; SG=sg-0c7cedcbee728d27f    # cluster-access SG (port 22 open)
ARM=ami-02e447f4c654c7179; X86=ami-0fd6240f599091088
OUT="$(cd "$(dirname "$0")" && pwd)/stream_results.txt"; : > "$OUT"

UD=$(base64 <<'EOF'
#!/bin/bash
dnf install -y gcc >/dev/null 2>&1
cat > /tmp/s.c <<'C'
#include <stdio.h>
#include <omp.h>
#include <sys/time.h>
#define N 200000000L
static double a[N],b[N],c[N];
double w(){struct timeval t;gettimeofday(&t,0);return t.tv_sec+t.tv_usec*1e-6;}
int main(){long j;double s=3,t,best=1e30;
 #pragma omp parallel for
 for(j=0;j<N;j++){a[j]=1;b[j]=2;c[j]=0;}
 for(int k=0;k<10;k++){t=w();
  #pragma omp parallel for
  for(j=0;j<N;j++)a[j]=b[j]+s*c[j];
  t=w()-t;if(t<best)best=t;}
 FILE*f=fopen("/tmp/stream_result.txt","w");
 fprintf(f,"STREAM_TRIAD_GBps=%.1f cores=%d\n",3.0*8*N/1e9/best,omp_get_max_threads());fclose(f);return 0;}
C
gcc -O3 -fopenmp -o /tmp/s /tmp/s.c && OMP_PROC_BIND=spread /tmp/s
chmod 644 /tmp/stream_result.txt
EOF
)

declare -A AMI=( [c8g.48xlarge]=$ARM [m9g.48xlarge]=$ARM [c7a.48xlarge]=$X86 [c8a.48xlarge]=$X86 [c8i.48xlarge]=$X86 )
declare -A IID
for inst in "${!AMI[@]}"; do
  iid=$(AWS_PROFILE=aws timeout 40 aws ec2 run-instances --region "$REGION" --image-id "${AMI[$inst]}" \
    --instance-type "$inst" --subnet-id "$SUB" --security-group-ids "$SG" --key-name aws-gchp \
    --user-data "$UD" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Purpose,Value=streamD},{Key=Name,Value=strD-$inst}]" \
    --query 'Instances[0].InstanceId' --output text 2>/dev/null)
  IID[$inst]=$iid; echo "launched $inst -> $iid"
done

echo "waiting 210s for boot+compile+run..."; sleep 210
for inst in "${!IID[@]}"; do
  ip=$(AWS_PROFILE=aws timeout 40 aws ec2 describe-instances --region "$REGION" --instance-ids "${IID[$inst]}" \
       --query 'Reservations[].Instances[].PublicIpAddress' --output text 2>/dev/null)
  res=""
  for try in 1 2 3 4 5; do
    res=$(ssh -n -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=20 ec2-user@"$ip" \
          "cat /tmp/stream_result.txt 2>/dev/null" 2>/dev/null)
    [[ -n "$res" ]] && break; sleep 20
  done
  echo "$inst ${res:-NO_RESULT}" | tee -a "$OUT"
  AWS_PROFILE=aws timeout 40 aws ec2 terminate-instances --region "$REGION" --instance-ids "${IID[$inst]}" >/dev/null 2>&1
done
echo "=== STREAM DONE (results in $OUT); all probe instances terminated ==="
cat "$OUT"
