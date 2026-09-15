#!/usr/bin/env python3
"""Report the on-disk byte layout of HDF5 chunks for one dataset, to see whether
a GCHP-style read (one time slice = all levels) is contiguous in the file."""
import sys, io, boto3, h5py
from botocore import UNSIGNED
from botocore.config import Config

BUCKET, KEY, VAR = sys.argv[1], sys.argv[2], sys.argv[3]
s3 = boto3.client('s3', config=Config(signature_version=UNSIGNED))
SIZE = s3.head_object(Bucket=BUCKET, Key=KEY)['ContentLength']


class S3File(io.RawIOBase):
    def __init__(self):
        self.pos = 0
        self.gets = 0

    def readable(self): return True
    def seekable(self): return True

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else (self.pos + off if whence == 1 else SIZE + off)
        return self.pos

    def tell(self): return self.pos

    def readinto(self, b):
        n = len(b)
        if self.pos >= SIZE or n == 0:
            return 0
        end = min(self.pos + n, SIZE) - 1
        r = s3.get_object(Bucket=BUCKET, Key=KEY, Range=f'bytes={self.pos}-{end}')['Body'].read()
        self.gets += 1
        b[:len(r)] = r
        self.pos += len(r)
        return len(r)


f = S3File()
h = h5py.File(f, 'r')
d = h[VAR]
n = d.id.get_num_chunks()
print(f"{KEY.split('/')[-1]}  var={VAR}  shape={d.shape} chunks={d.chunks} "
      f"filter={d.compression}/{d.compression_opts}")
print(f"chunks on disk: {n}")

info = [d.id.get_chunk_info(i) for i in range(min(n, 160))]
print(f"\n{'idx':>4} {'chunk coord':<18}{'offset':>13}{'size':>10}{'gap to prev':>13}")
prev_end = None
gaps = []
for i, ci in enumerate(info):
    gap = '' if prev_end is None else f"{ci.byte_offset - prev_end:>+13}"
    if prev_end is not None:
        gaps.append(ci.byte_offset - prev_end)
    if i < 8 or i in (71, 72, 73):
        print(f"{i:>4} {str(ci.chunk_offset):<18}{ci.byte_offset:>13}{ci.size:>10}{gap}")
    prev_end = ci.byte_offset + ci.size

sizes = [ci.size for ci in info]
print(f"\ncompressed chunk size: min {min(sizes)/1e6:.2f} MB  max {max(sizes)/1e6:.2f} MB  "
      f"mean {sum(sizes)/len(sizes)/1e6:.2f} MB")
adjacent = sum(1 for g in gaps if g == 0)
print(f"adjacent (zero-gap) chunk pairs: {adjacent}/{len(gaps)}")
if gaps:
    print(f"gap stats: min {min(gaps)} max {max(gaps)}")
mono = all(info[i].byte_offset < info[i+1].byte_offset for i in range(len(info)-1))
print(f"file offsets monotonic in chunk index order: {mono}")
print(f"\nrange spanned by first 72 chunks (one 3-D time slice, all levels): "
      f"{(info[min(71,len(info)-1)].byte_offset + info[min(71,len(info)-1)].size - info[0].byte_offset)/1e6:.1f} MB")
print(f"S3 GETs used for this whole inspection: {f.gets}")
