#!/usr/bin/env python3
"""S3 elastic chemistry worker — Phase C2 off-node decoupling (the paper headline).

Runs on ANY node, launched on its OWN schedule (separate cluster / ASG / spot fleet — no EFA,
no placement group, no co-scheduling with the GCHP transport ranks). It:

  1. LISTs the work queue prefix  s3://<bucket>/chemq/<jobid>/<step>/  for  *.in  objects
  2. CLAIMs one atomically (S3 conditional PUT of a  .claim  marker; if the marker already
     exists it's taken -> skip). This is the lease that prevents two workers double-solving.
  3. GETs the .in blob, runs  kpp_worker <in> <out>  (the SAME KPP solve, byte-identical),
  4. PUTs the .out blob, then the .done marker (so the rank polls .done, not a race on .out).
  5. Spot-tolerant: if this worker dies mid-solve, its .claim lease expires (mtime + TTL) and
     another worker re-claims -> the run still completes. N producers != M consumers, and they
     need not be co-alive: a worker can start LONG after the rank PUT its .in.

The rank side (chem_remote S3 backend) PUTs .in and polls for .done; see chem_remote_s3.c.
Idempotent, stateless, horizontally scalable: run as many copies as you have cores/nodes/spot.

Usage:  s3_chem_worker.py --bucket B --jobid J --worker-bin /path/kpp_worker [--claim-ttl 120]
"""
from __future__ import annotations
import argparse, subprocess, sys, time, os, tempfile

def _s3(*args, capture=True):
    return subprocess.run(["aws","s3api",*args], capture_output=capture, text=True)

def list_in_keys(bucket, prefix):
    r = _s3("list-objects-v2","--bucket",bucket,"--prefix",prefix,
            "--query","Contents[?ends_with(Key, `.in`)].Key","--output","text")
    return [k for k in (r.stdout or "").split() if k] if r.returncode==0 else []

def claim(bucket, in_key, ttl):
    """Atomic-ish claim via conditional PUT of <key>.claim using If-None-Match:* (S3 native
    conditional writes, GA 2024). Returns True if WE won the claim. A stale claim (> ttl old)
    is stolen (spot worker died) by deleting + re-claiming."""
    ckey = in_key + ".claim"
    # check staleness first
    h = _s3("head-object","--bucket",bucket,"--key",ckey)
    if h.returncode==0:
        # exists — is it stale? (LastModified age > ttl)
        import json,calendar,email.utils
        try:
            lm = json.loads(h.stdout)["LastModified"]
            # aws returns ISO; compare age via a fresh HEAD is simplest — approximate: steal if old
            age = _age_seconds(lm)
            if age is None or age < ttl:
                return False                      # fresh claim held by a live worker
            _s3("delete-object","--bucket",bucket,"--key",ckey)   # steal a dead worker's lease
        except Exception:
            return False
    # try to create the claim only if it does not exist (conditional write)
    with tempfile.NamedTemporaryFile("w",suffix=".claim",delete=False) as f:
        f.write(f"{os.uname().nodename}:{os.getpid()}\n"); tmp=f.name
    r = _s3("put-object","--bucket",bucket,"--key",ckey,"--body",tmp,
            "--if-none-match","*", capture=True)
    os.unlink(tmp)
    return r.returncode==0     # nonzero == PreconditionFailed == someone else won

def _age_seconds(iso_lastmodified):
    # best-effort; if we can't parse, treat as unknown (don't steal)
    try:
        import datetime
        t=datetime.datetime.fromisoformat(iso_lastmodified.replace("Z","+00:00"))
        return (datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()
    except Exception:
        return None

def solve_one(bucket, in_key, worker_bin):
    base = in_key[:-3]  # strip .in
    with tempfile.TemporaryDirectory() as d:
        inf, outf = os.path.join(d,"in.bin"), os.path.join(d,"out.bin")
        if _s3("get-object","--bucket",bucket,"--key",in_key,inf).returncode!=0: return False
        r = subprocess.run([worker_bin, inf, outf], capture_output=True, text=True)
        if r.returncode!=0 or not os.path.exists(outf):
            sys.stderr.write(f"worker failed on {in_key}: {r.stderr[:200]}\n"); return False
        if _s3("put-object","--bucket",bucket,"--key",base+".out","--body",outf).returncode!=0:
            return False
        # .done marker LAST (rank polls .done so it never GETs a half-written .out)
        with tempfile.NamedTemporaryFile("w",delete=False) as f: f.write("ok\n"); dm=f.name
        _s3("put-object","--bucket",bucket,"--key",base+".done","--body",dm); os.unlink(dm)
        return True

def main(argv=None):
    ap=argparse.ArgumentParser()
    ap.add_argument("--bucket",required=True); ap.add_argument("--jobid",required=True)
    ap.add_argument("--worker-bin",required=True)
    ap.add_argument("--claim-ttl",type=int,default=120)
    ap.add_argument("--idle-exit",type=int,default=0,help="exit after N idle polls (0=forever)")
    a=ap.parse_args(argv)
    prefix=f"chemq/{a.jobid}/"
    idle=0; solved=0
    sys.stderr.write(f"s3_chem_worker up: bucket={a.bucket} prefix={prefix} bin={a.worker_bin}\n")
    while True:
        keys=list_in_keys(a.bucket,prefix)
        # skip keys already done
        todo=[k for k in keys if not _exists(a.bucket,k[:-3]+".done")]
        got=False
        for k in todo:
            if claim(a.bucket,k,a.claim_ttl):
                if solve_one(a.bucket,k,a.worker_bin):
                    solved+=1; got=True; idle=0
                    # per-solve line so the pool's work is DIRECTLY countable (grep SLICE_SOLVED),
                    # not inferred from byte-identity. Flushed immediately (srun may truncate at exit).
                    sys.stderr.write(f"SLICE_SOLVED {k} (this worker total {solved})\n"); sys.stderr.flush()
                break
        if not got:
            idle+=1
            if a.idle_exit and idle>=a.idle_exit:
                sys.stderr.write(f"idle {idle} polls, exiting (solved {solved})\n"); sys.stderr.flush(); return 0
            time.sleep(1)

def _exists(bucket,key):
    return _s3("head-object","--bucket",bucket,"--key",key).returncode==0

if __name__=="__main__":
    sys.exit(main())
