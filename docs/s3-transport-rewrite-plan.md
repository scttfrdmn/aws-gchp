# S3 transport rewrite — microbenchmark-first plan (Phase C2 throughput fix)

## Why
The C180 off-node timeout (~19 min/superstep) was diagnosed as an IMPLEMENTATION artifact:
`chem_remote_s3.c` does `system("aws s3api <op>")` once per object per op -> ~1920 CLI process
launches/superstep at C180 (192 slices x ~10 ops) x ~0.6s python-CLI cold-start = ~19 min in
process-spawn ALONE. NOT an S3 bandwidth limit (design bench s3_handoff_bench.c moved 27GB in ~32s
via multipart-concurrent `aws s3 cp`). So: fix the transport, don't abandon S3.

## The performant primitive (user pointer): AWS CRT `aws-c-s3` (awslabs/aws-c-s3)
Async C99 S3 client "focused on maximizing throughput": AUTOMATIC request-splitting into part-sized
parallel multipart chunks, per-chunk retries, DNS load-balancing across the S3 fleet, thread pools,
connection reuse. This is what powers fast `aws s3 cp` / CRT SDKs — but linkable directly in C (no
python, no per-op fork). Apache-2.0. Deps (CMake, build-in-order): aws-lc + s2n-tls (Linux TLS),
aws-c-common, aws-checksums, aws-c-cal, aws-c-io, aws-c-compression, aws-c-http, aws-c-sdkutils,
aws-c-auth, aws-c-s3. Creds via aws-c-auth (instance-role default chain). Bundled samples/s3 `cp`.
API in include/aws/s3 (aws_s3_client / aws_s3_meta_request / aws_s3_make_meta_request — confirm in
headers). Env: AWS_CRT_S3_MEMORY_LIMIT_IN_GIB, AWS_CRT_S3_MAX_PARTS_PENDING_READ.

## Microbenchmark FIRST (de-risk before any C180 cluster spend) — ~$5
Isolate WHICH factor dominates, on ONE cheap node, with a realistic C180-per-rank payload
(~230 MB/rank; at K=4, 4 slices of ~57 MB, or batched = 1 object of 230 MB). Compare transport
variants for a SINGLE rank's superstep round-trip (write -> PUT -> GET -> read):
  V0  per-object `system(aws s3api)`      -- reproduces the slow path (baseline; expect seconds x forks)
  V1  per-object `aws s3 cp` (multipart)  -- removes s3api single-stream, keeps 1 fork/op
  V2  ONE `aws s3 cp` for a BATCHED object (all K slices concatenated) -- 1 fork total
  V3  persistent client, no fork:
      V3a  boto3 long-lived process over a pipe (SDK, transfer-manager multipart), OR
      V3b  aws-c-s3 CRT linked into a tiny C harness (the performant target)
Metric: wall for the full round-trip of 230 MB, and EXTRAPOLATE to 48 ranks x K slices/superstep.
Target: approach the ~32s/27GB (=~1.2 GB/s agg) the design bench showed => handoff << chem compute
at C180, so off-node speedup becomes achievable.

## Decision gate (after the microbench)
- If V2 (batch + `aws s3 cp`) alone gets close to target -> cheap win, minimal code, no CRT dep.
- If only V3 (persistent/CRT) hits target -> integrate aws-c-s3 (heavier build, but the real fix).
- Then rewrite chem_remote_s3.c accordingly + batch K-slices-per-rank into one object + concurrent
  poll, and ONLY THEN re-run the C180 off-node throughput test.

## What stays solid regardless
S3 elasticity / decoupled-provisioning / fault-tolerance are PROVEN byte-identical @C24 (they don't
depend on per-object throughput). On-node shm M>N = 2.23x@C180 proven. This plan only unblocks the
S3 off-node THROUGHPUT number, currently deferred.
