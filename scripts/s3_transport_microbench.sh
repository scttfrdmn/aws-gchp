#!/bin/bash
# s3_transport_microbench.sh — isolate WHICH transport factor caused the C180 off-node timeout,
# BEFORE any C180 cluster re-test. Runs on ONE node. Simulates one rank's superstep round-trip
# (write local -> PUT to S3 -> GET back -> read) with a realistic C180 payload, across variants.
#
# C180 per-rank shipped state ~230 MB (measured); K=4 -> 4 slices of ~57 MB, OR 1 batched 230 MB obj.
# We time the ROUND-TRIP and extrapolate to 48 ranks x superstep. Target: approach the design bench's
# ~32s/27GB (~1.2 GB/s agg) so the handoff << C180 chem compute.
#
# Usage: s3_transport_microbench.sh [bucket] [nslices] [slice_mb]
set -uo pipefail
BUCKET="${1:-gchp-shared-storage-us-east-1}"
NSLICE="${2:-4}"        # K slices/rank
SMB="${3:-57}"          # MB per slice (C180 K=4)
PFX="chemq/microbench-$$"
TMP=$(mktemp -d)
now(){ date +%s.%N; }
say(){ printf '%s\n' "$*"; }

# make NSLICE slice files + one batched file
say "=== prep: $NSLICE slices x ${SMB}MB (+ 1 batched $((NSLICE*SMB))MB) in $TMP ==="
for k in $(seq 0 $((NSLICE-1))); do dd if=/dev/urandom of=$TMP/slice_$k.bin bs=1M count=$SMB status=none; done
cat $TMP/slice_*.bin > $TMP/batched.bin
GB=$(python3 -c "print(round($NSLICE*$SMB/1024.0,3))")
extrap(){ python3 -c "print(f'  -> per-rank {$1:.1f}s; extrapolated 48-rank superstep (parallel-ish) ~= {$1:.1f}s wall if concurrent, {$1*48:.0f}s if serial')"; }

# ---- V0: per-object `aws s3api` + system()-style (the SLOW path we shipped) ----
say "=== V0: per-object aws s3api put/get (reproduces the shipped slow path) ==="
t0=$(now)
for k in $(seq 0 $((NSLICE-1))); do
  aws s3api put-object --bucket $BUCKET --key $PFX/v0_$k.in --body $TMP/slice_$k.bin >/dev/null 2>&1
  aws s3api get-object --bucket $BUCKET --key $PFX/v0_$k.in $TMP/v0_$k.out >/dev/null 2>&1
done
t1=$(now); V0=$(python3 -c "print($t1-$t0)"); say "  V0 round-trip ($GB GB): ${V0}s"; extrap $V0

# ---- V1: per-object `aws s3 cp` (multipart-concurrent, but still 1 fork/op) ----
say "=== V1: per-object aws s3 cp (multipart, 1 fork/op) ==="
t0=$(now)
for k in $(seq 0 $((NSLICE-1))); do
  aws s3 cp $TMP/slice_$k.bin s3://$BUCKET/$PFX/v1_$k.in --only-show-errors 2>/dev/null
  aws s3 cp s3://$BUCKET/$PFX/v1_$k.in $TMP/v1_$k.out --only-show-errors 2>/dev/null
done
t1=$(now); V1=$(python3 -c "print($t1-$t0)"); say "  V1 round-trip ($GB GB): ${V1}s"; extrap $V1

# ---- V2: ONE `aws s3 cp` of the BATCHED object (all K slices concatenated; 1 fork total) ----
say "=== V2: batched single aws s3 cp (all K slices in ONE object) ==="
t0=$(now)
aws s3 cp $TMP/batched.bin s3://$BUCKET/$PFX/v2.in --only-show-errors 2>/dev/null
aws s3 cp s3://$BUCKET/$PFX/v2.in $TMP/v2.out --only-show-errors 2>/dev/null
t1=$(now); V2=$(python3 -c "print($t1-$t0)"); say "  V2 round-trip ($GB GB, 1 object): ${V2}s"; extrap $V2

# ---- V3a: persistent boto3 process (SDK transfer-manager multipart, NO per-op fork) ----
say "=== V3a: persistent boto3 client (transfer-manager multipart, no per-op fork) ==="
python3 - "$BUCKET" "$PFX" "$TMP" "$NSLICE" <<'PY'
import sys,time,boto3
bucket,pfx,tmp,ns=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
s3=boto3.client('s3')  # persistent client (built ONCE, like a long-lived worker)
t0=time.time()
s3.upload_file(f"{tmp}/batched.bin", bucket, f"{pfx}/v3.in")
s3.download_file(bucket, f"{pfx}/v3.in", f"{tmp}/v3.out")
t1=time.time()
print(f"  V3a round-trip (batched, persistent boto3): {t1-t0:.2f}s")
print(f"  -> boto3 default multipart threshold 8MB, 10 concurrent threads")
PY

say "=== cleanup ==="
aws s3 rm s3://$BUCKET/$PFX/ --recursive >/dev/null 2>&1
rm -rf "$TMP"
say "=== SUMMARY: V0(shipped) ${V0}s | V1(cp/obj) ${V1}s | V2(batched cp) ${V2}s | V3a(boto3) above ==="
say "  Decision: if V2 or V3a << V0 and near ~$(python3 -c "print(round($GB/1.2,1))")s (1.2GB/s target), the fix is code, not S3."
