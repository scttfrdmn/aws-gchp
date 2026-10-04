#!/usr/bin/env python3
"""crs3_sidecar.py — persistent boto3 S3 sidecar for the decoupled-chem S3 transport.

ONE long-lived process per GCHP rank. The C shim (chem_remote_s3.c) spawns it ONCE at
Chem_Remote_Init and speaks a tiny line protocol over its stdin/stdout, so NO per-operation
`aws` CLI fork is paid (that fork cost was ~9.4 min/superstep at C180 — the whole reason the
per-object shim timed out). Holds a persistent boto3 client + a tuned multipart TransferConfig
(the winning microbench config: max_concurrency=64, so a single object's parts upload in
parallel — 0.70s/228MB on m9g, ~10x the shipped path and NIC-bound, not client-bound).

PROTOCOL (one command per line on stdin; one reply line "OK <ms>" or "ERR <msg>" on stdout):
  PUT  <local_path> <key>       -> upload  (multipart, concurrent)
  GET  <key> <local_path>       -> download
  HEAD <key>                    -> "OK 0" if object exists, "ERR missing" otherwise
  DEL  <key>                    -> delete (best-effort; always OK)
  PING                          -> "OK 0"  (readiness handshake)
  QUIT                          -> exit

Keys are used VERBATIM (the C side builds the hash-prefixed chemq/... path). Bucket from
env GCHP_CHEM_S3_BUCKET. Region auto (instance). stdout is line-buffered + flushed per reply
so the C side's blocking read never stalls.
"""
from __future__ import annotations
import os, sys, time, boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config

BUCKET = os.environ.get("GCHP_CHEM_S3_BUCKET", "")
# generous connection pool so concurrent multipart parts don't queue on connections
_botocfg = Config(max_pool_connections=128, retries={"max_attempts": 5, "mode": "adaptive"})
_s3 = boto3.client("s3", config=_botocfg)
_xfer = TransferConfig(max_concurrency=64,
                       multipart_threshold=8 * 1024 * 1024,
                       multipart_chunksize=16 * 1024 * 1024,
                       use_threads=True)

def _reply(ok: bool, ms: float = 0.0, msg: str = ""):
    sys.stdout.write(f"OK {ms:.1f}\n" if ok else f"ERR {msg}\n")
    sys.stdout.flush()

def main() -> int:
    if not BUCKET:
        sys.stderr.write("crs3_sidecar: GCHP_CHEM_S3_BUCKET unset\n"); return 2
    sys.stderr.write(f"crs3_sidecar up: bucket={BUCKET} conc=64\n"); sys.stderr.flush()
    for line in sys.stdin:                      # blocks until the C side writes a command
        parts = line.rstrip("\n").split()
        if not parts:
            continue
        cmd = parts[0]
        try:
            if cmd == "PUT":
                lp, key = parts[1], parts[2]
                t0 = time.time(); _s3.upload_file(lp, BUCKET, key, Config=_xfer)
                _reply(True, (time.time() - t0) * 1e3)
            elif cmd == "GET":
                key, lp = parts[1], parts[2]
                t0 = time.time(); _s3.download_file(BUCKET, key, lp, Config=_xfer)
                _reply(True, (time.time() - t0) * 1e3)
            elif cmd == "HEAD":
                key = parts[1]
                try:
                    _s3.head_object(Bucket=BUCKET, Key=key); _reply(True)
                except Exception:
                    _reply(False, msg="missing")
            elif cmd == "DEL":
                key = parts[1]
                try: _s3.delete_object(Bucket=BUCKET, Key=key)
                except Exception: pass
                _reply(True)
            elif cmd == "PING":
                _reply(True)
            elif cmd == "QUIT":
                return 0
            else:
                _reply(False, msg=f"badcmd:{cmd}")
        except Exception as e:
            _reply(False, msg=str(e).replace("\n", " ")[:200])
    return 0

if __name__ == "__main__":
    sys.exit(main())
