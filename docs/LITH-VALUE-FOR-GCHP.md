# The value of lith to GCHP

Assessment as of 2026-10-08. The numbers come from the pre-registered gates in
`data/lith-gates/inregion-streams.txt`; raw data is under `data/lith-gates/`.

**In short:** lith lets GCHP read its input directly from the public `s3://gcgrid` bucket, with
byte-identical results and no FSx input filesystem. Most of its value is cost, setup time and
simplicity. It doesn't make the model itself run faster.

## What it delivers (measured)

### Correctness
- GCHP runs entirely from `s3://gcgrid` through lith.
- TransportTracers and fullchem produce **byte-identical checkpoints** compared with FSx (C24
  fullchem checkpoint md5 `f3dd15b2…` on both).
- Runs completed with zero read errors, on 1 node (48 ranks) and 2 nodes (96 ranks).

### Speed, where it matters
- **From a cold start, lith beats a freshly created FSx volume, and the margin grows with the
  amount of input:**
  - 1.73× faster init for C24 TT (about 4 GB of input);
  - at least 2.29× for the fullchem input set (30 GiB);
  - 4.92× for a C180 restart file.

  FSx loads cold data from S3 at about 120 MB/s regardless of load, while lith reached
  550–670 MB/s.
- **Once FSx is fully loaded ("warm"), they tie** (34.2 s both for C24 TT), and model time per
  simulated day is essentially the same either way.
- So lith speeds up time to first result, not the simulation itself.

| C24 TT, 48 ranks | init | to completion |
|---|---|---|
| FSx cold | 45.26 s | 90.4 s |
| **lith cold** | **26.09 s** | **55.3 s** |
| FSx warm (pre-loaded) | 16.66 s | 34.2 s |
| lith warm | 15.94 s | 34.2 s |

### Cost and operations
- **It removes the FSx input layer.** That was about $168/month for each standing 1.2 TB volume
  (we had three, about $504/month, all now deleted), or about 33 minutes to create and load one
  per cluster.
- **Time to first run drops from about 33 minutes to seconds.**
- **Five deployment traps go away:** the head-node timeout during the FSx data import, the Lustre
  version pin, the Lustre security group, being tied to one availability zone, and pre-loading
  the data.
- **It reads the live bucket.** An FSx volume is a snapshot from when it was created; ours never
  picked up the 5 GMI alias files added to gcgrid later. lith serves them, so our overlay
  workaround can be deleted.
- **Reads in us-east-1 cost nothing for data**, plus about $0.005 of request charges per run.
- **It's what makes ephemeral clusters practical**, including the spawn-based (no
  ParallelCluster) EFA run that worked on 2026-10-05.

### Read efficiency (bytes fetched per byte actually needed)
- **The met-field mounts fetch about 1.2× what they need.** That's close to the limit, which
  comes from how the model splits work across ranks, not from lith.
- **The October 2026 fixes:**
  - the region-based gate (lith #368) brought one var1 reader from 54× to 2.65× over-fetch,
    and six concurrent readers from 5–9× to 1.00×;
  - the 16-reader prefetch collapse (#313) is gone;
  - the same-file-readers fix (#316/#387) brought 16 readers on one file from 40–67 s to
    2–3 s, though only about 9% of GCHP's met bytes follow that pattern.
- **#350/#381 cleared lith on latency.** Measured at the same moment, lith gets first bytes from
  S3 as fast as any other client. Its gradual ramp actually shields it from a roughly one-second
  slow start on each new connection.

## Limits and open risks
- **Fullchem's emissions (HEMCO) reads are wasteful:** about 2.46× over-fetch, because of how
  its many scattered reads are prefetched. It costs no money in-region and the results are still
  correct, but it's the one real read-efficiency gap left.
- **Memory:** lith's footprint is its cache plus whatever prefetch is in flight (#314), so the
  cache size (`--mem-cache`) has to be set deliberately on each node.
- **Region:** it's validated in us-east-1, where gcgrid lives. Cross-region use has a measured
  cost (1.96× slower on fast whole-file reads with the gate on), and the trade-off there is
  still open.
- **Maturity:** lith went through 11 releases in about a month, and several flags are still
  experimental. We've validated C24 (TT and fullchem) for 1-day runs and 2-node C24 TT, but
  not a long, multi-node C180 fullchem production run over lith.
- **It doesn't speed up the model.** The input load is small next to compute at production
  scale, so lith's gains are in time to first result, cost and simplicity.

## Bottom line
For GCHP on AWS, lith turns the input layer from a standing, AZ-tied, snapshot-based FSx volume
(about $168/month each, or 33 minutes to create) into a mount that's ready in seconds, reads the
live bucket, and gives identical output. It matches or beats FSx everywhere we measured: equal
when FSx is warm, 1.7–4.9× faster when both start cold. For the ephemeral clusters the
benchmarking and publication work relies on, cold start is the normal case, so that's where its
value shows.

**Recommendation:** make lith the default input layer for those clusters. Before relying on it
for long production runs, it needs one multi-node C180 fullchem validation, and its cache should
be sized for each node type.
