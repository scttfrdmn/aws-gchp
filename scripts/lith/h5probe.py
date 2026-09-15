#!/usr/bin/env python3
"""Open a NetCDF-4/HDF5 object in S3 through a range-reading file object and
report (a) the dataset chunk layout and (b) exactly how many range GETs and
bytes the HDF5 library needed just to traverse metadata. No full download."""
import sys, io, boto3, h5py
from botocore import UNSIGNED
from botocore.config import Config

BUCKET, KEY = sys.argv[1], sys.argv[2]
s3 = boto3.client('s3', config=Config(signature_version=UNSIGNED))
SIZE = s3.head_object(Bucket=BUCKET, Key=KEY)['ContentLength']


class S3File(io.RawIOBase):
    """Minimal seekable read-only file over S3 ranged GETs, instrumented."""

    def __init__(self):
        self.pos = 0
        self.gets = 0
        self.bytes = 0
        self.spans = []

    def readable(self):
        return True

    def seekable(self):
        return True

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else (self.pos + off if whence == 1 else SIZE + off)
        return self.pos

    def tell(self):
        return self.pos

    def readinto(self, b):
        n = len(b)
        if self.pos >= SIZE or n == 0:
            return 0
        end = min(self.pos + n, SIZE) - 1
        r = s3.get_object(Bucket=BUCKET, Key=KEY,
                          Range=f'bytes={self.pos}-{end}')['Body'].read()
        self.gets += 1
        self.bytes += len(r)
        self.spans.append((self.pos, len(r)))
        b[:len(r)] = r
        self.pos += len(r)
        return len(r)


f = S3File()
h = h5py.File(f, 'r')
open_gets, open_bytes = f.gets, f.bytes
print(f"object   : s3://{BUCKET}/{KEY}")
print(f"size     : {SIZE/1e9:.2f} GB")
print(f"h5 open  : {open_gets} range GETs, {open_bytes/1024:.0f} KiB of metadata")
print()

rows = []


def visit(name, obj):
    if isinstance(obj, h5py.Dataset):
        rows.append((name, obj.shape, str(obj.dtype), obj.chunks,
                     obj.compression, obj.compression_opts, obj.nbytes))


h.visititems(visit)
print(f"{len(rows)} datasets. First 12:")
print(f"{'name':<26}{'shape':<22}{'chunks':<22}{'compr':<10}{'logical':>10}")
for name, shape, dt, ch, comp, copts, nb in rows[:12]:
    print(f"{name:<26}{str(shape):<22}{str(ch):<22}{str(comp)+('/'+str(copts) if copts is not None else ''):<10}{nb/1e6:>9.1f}M")
print()
print(f"metadata traversal total: {f.gets} range GETs, {f.bytes/1024:.0f} KiB")
print(f"  (of which {open_gets} GETs / {open_bytes/1024:.0f} KiB were the open itself)")

# How scattered is that metadata? Contiguity tells us how well one prefetch
# region could have covered it.
spans = sorted(f.spans)
if spans:
    lo, hi = spans[0][0], max(o + n for o, n in spans)
    print(f"  metadata byte span: {lo} .. {hi} ({(hi-lo)/1024:.0f} KiB window)")
    head = sum(n for o, n in spans if o < 4 << 20)
    tail = sum(n for o, n in spans if o > SIZE - (4 << 20))
    print(f"  in first 4 MiB: {head/1024:.0f} KiB | in last 4 MiB: {tail/1024:.0f} KiB")

# Chunk-map size: what lith would have to cache per dataset.
tot_chunks = 0
for name, shape, dt, ch, comp, copts, nb in rows:
    if ch:
        n = 1
        for s, c in zip(shape, ch):
            n *= -(-s // c)
        tot_chunks += n
print(f"  total chunks across all datasets: {tot_chunks}")
