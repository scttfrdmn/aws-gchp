#!/usr/bin/env python3
"""S3 elastic chemistry worker — Phase C2 off-node decoupling (the paper headline).

Runs on ANY node, launched on its OWN schedule (separate cluster / ASG / spot fleet — no EFA,
no placement group, no co-scheduling with the GCHP transport ranks). It:

  1. LISTs the work queue prefix  s3://<bucket>/chemq/<jobid>/  for  *.in  objects (recursive,
     so it finds the hash-prefixed subdirs the rank writes: chemq/<jobid>/<hh>/r<r>_k<k>_s<s>.in)
  2. CLAIMs one atomically (S3 conditional PUT of a  .claim  marker via If-None-Match:*; if the
     marker already exists it's taken -> skip). This lease prevents two workers double-solving.
  3. GETs the .in blob, runs  kpp_worker <in> <out>  (the SAME KPP solve, byte-identical),
  4. PUTs the .out blob, then the .done marker (so the rank polls .done, not a race on .out).
  5. Spot-tolerant: if this worker dies mid-solve, its .claim lease expires (mtime + TTL) and
     another worker re-claims -> the run still completes. N producers != M consumers, and they
     need not be co-alive: a worker can start LONG after the rank PUT its .in.

TRANSPORT: a PERSISTENT in-process boto3 client (connection pooling, NO per-object process fork).
This replaced the original `aws s3api` subprocess-per-object shim, which fork-stormed the node
(~6 forks/slice) and dominated the off-node wall at C90 (see campaign-logs/s3-sidecar-C90-derisk.txt).
The worker is already Python, so unlike the C rank side it needs no separate sidecar process --
the boto3 client lives in-process for the worker's whole lifetime. The kpp_worker binary is
unchanged, so byte-identity is preserved by construction; only the S3 I/O mechanism changed.

The rank side (chem_remote S3 backend) PUTs .in and polls for .done; see chem_remote_s3.c.
Idempotent, stateless, horizontally scalable: run as many copies as you have cores/nodes/spot.

Usage:  s3_chem_worker.py --bucket B --jobid J --worker-bin /path/kpp_worker [--claim-ttl 120]
"""
from __future__ import annotations
import argparse, subprocess, sys, time, os, tempfile, datetime

try:
    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError
except ImportError:
    sys.stderr.write("FATAL: boto3 not available; install python3-pip + boto3 on this node\n")
    sys.exit(2)

# One persistent client per worker process. Pool sized so concurrent GET/PUT reuse sockets
# instead of forking; adaptive retries ride out throttling from a large co-located pool.
_CFG = Config(max_pool_connections=64, retries={"max_attempts": 5, "mode": "adaptive"})
_S3 = boto3.client("s3", config=_CFG)


def list_all(bucket, prefix):
    """Every key under the jobid prefix (recursive), with LastModified. One paginated LIST per
    poll replaces the old per-key head-object storm: .in/.out/.done/.claim are all partitioned
    from this single listing below."""
    meta = {}
    paginator = _S3.get_paginator("list_objects_v2")
    try:
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                meta[obj["Key"]] = obj["LastModified"]
    except ClientError as e:
        sys.stderr.write(f"list_all error: {e}\n")
    return meta


def _age_seconds(last_modified):
    """last_modified is a tz-aware datetime from boto3."""
    try:
        return (datetime.datetime.now(datetime.timezone.utc) - last_modified).total_seconds()
    except Exception:
        return None


def claim(bucket, in_key, ttl, claim_lm):
    """Atomic claim via conditional PUT of <in_key>.claim (If-None-Match:*). Returns True if WE
    won. claim_lm = LastModified of an existing .claim from the poll's listing (or None). A stale
    claim (age > ttl, spot worker died) is stolen: delete + re-claim. This mirrors the original
    semantics exactly; only the S3 calls moved from `aws` forks to the boto3 client."""
    ckey = in_key + ".claim"
    if claim_lm is not None:
        age = _age_seconds(claim_lm)
        if age is None or age < ttl:
            return False                                   # fresh claim held by a live worker
        try:
            _S3.delete_object(Bucket=bucket, Key=ckey)      # steal a dead worker's lease
        except ClientError:
            return False
    body = f"{os.uname().nodename}:{os.getpid()}\n".encode()
    try:
        _S3.put_object(Bucket=bucket, Key=ckey, Body=body, IfNoneMatch="*")
        return True
    except ClientError:
        return False                                       # PreconditionFailed -> someone else won


def solve_one(bucket, in_key, worker_bin):
    base = in_key[:-3]  # strip .in
    with tempfile.TemporaryDirectory() as d:
        inf, outf = os.path.join(d, "in.bin"), os.path.join(d, "out.bin")
        try:
            _S3.download_file(bucket, in_key, inf)
        except ClientError as e:
            sys.stderr.write(f"get {in_key} failed: {e}\n"); return False
        r = subprocess.run([worker_bin, inf, outf], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(outf):
            sys.stderr.write(f"worker failed on {in_key}: {r.stderr[:200]}\n"); return False
        try:
            _S3.upload_file(outf, bucket, base + ".out")
            # .done marker LAST (rank polls .done so it never GETs a half-written .out)
            _S3.put_object(Bucket=bucket, Key=base + ".done", Body=b"ok\n")
        except ClientError as e:
            sys.stderr.write(f"put {base}.out/.done failed: {e}\n"); return False
        return True


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--bucket", required=True); ap.add_argument("--jobid", required=True)
    ap.add_argument("--worker-bin", required=True)
    ap.add_argument("--claim-ttl", type=int, default=120)
    ap.add_argument("--idle-exit", type=int, default=0, help="exit after N idle polls (0=forever)")
    a = ap.parse_args(argv)
    prefix = f"chemq/{a.jobid}/"
    idle = 0; solved = 0
    sys.stderr.write(f"s3_chem_worker up: bucket={a.bucket} prefix={prefix} bin={a.worker_bin} transport=boto3\n")
    sys.stderr.flush()
    while True:
        meta = list_all(a.bucket, prefix)
        # partition the single listing: skip .in whose .done already exists.
        done_bases = {k[:-5] for k in meta if k.endswith(".done")}      # base (strip .done)
        in_keys = [k for k in meta if k.endswith(".in")]
        todo = [k for k in in_keys if k[:-3] not in done_bases]         # k[:-3] = base
        got = False
        for k in todo:
            if claim(a.bucket, k, a.claim_ttl, meta.get(k + ".claim")):
                if solve_one(a.bucket, k, a.worker_bin):
                    solved += 1; got = True; idle = 0
                    # per-solve line so the pool's work is DIRECTLY countable (grep SLICE_SOLVED),
                    # not inferred from byte-identity. Flushed immediately (srun may truncate at exit).
                    sys.stderr.write(f"SLICE_SOLVED {k} (this worker total {solved})\n"); sys.stderr.flush()
                break
        if not got:
            idle += 1
            if a.idle_exit and idle >= a.idle_exit:
                sys.stderr.write(f"idle {idle} polls, exiting (solved {solved})\n"); sys.stderr.flush(); return 0
            time.sleep(1)


if __name__ == "__main__":
    sys.exit(main())
