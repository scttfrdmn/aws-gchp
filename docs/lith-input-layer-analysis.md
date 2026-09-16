# lith as the GCHP `/input` layer — measured analysis

**Date:** 2026-09-14
**Branch:** `lith/input-layer` (deliberately isolated so it cannot confound the
Phase C decoupled-chemistry results)
**Subject:** [`scttfrdmn/lith`](https://github.com/scttfrdmn/lith) — read-only
POSIX filesystem over an S3 bucket in its native key layout — as a replacement
for the FSx Lustre `/input` volume.

## Summary

Replacing FSx Lustre with lith for `/input` (gcgrid) is supported by measurement.
`/scratch` must stay on Lustre. The HDF5 support lith needs for this workload is
**not** a chunk-grid parser — it is metadata-read memoization, and the chunk
layout measurement is what rules the parser out.

## What lith is

- Read-only by definition; every mutating op returns `EROFS`. No sidecar objects,
  nothing written to the bucket, no re-layout.
- One index build makes `readdir`/`lookup`/`getattr`/`open` cost zero S3 calls.
- 1 MiB cache chunks, 8 MiB fills, readahead sized from the NIC's
  bandwidth-delay product, byte-exact sparse fills for projections.
- Format-aware plans today: Zarr chunk grid (tier 2: fixed/varying axis
  classification) and a "footer family" (Parquet/ORC/Arrow/zip).
- `lith mount` per node, or `lith serve nfs` for one node serving a cluster.
- Single static Go binary; Linux/FUSE only.

The design claim that matters for us: read-only is not a limitation but the
enabling constraint — it is what buys free local metadata, an index that two
uncoordinated readers agree on, and a cluster cache that never needs
invalidation.

## Measurements against real gcgrid objects

Method: open each object through an instrumented range-reading file object
(`h5py` over a seekable S3 reader) and count every range GET. Metadata only — no
full downloads. Scripts: `scripts/lith/h5probe.py`, `scripts/lith/h5chunks.py`.

All families checked are HDF5-backed NetCDF-4 (magic `\x89HDF\r\n\x1a\n`). No
NetCDF-3 classic (`CDF\x01/\x02/\x05`) found in the hot path.

| object | size | datasets | chunk shape | filter | chunks | metadata GETs | metadata bytes |
|---|---|---|---|---|---|---|---|
| `GEOS_0.25x0.3125/GEOS_FP/2019/07/GEOSFP.20190701.A1.025x03125.nc` | 1.00 GB | 50 | `(1,721,1152)` | gzip/5 | 1131 | **224** | 200 KiB |
| `…/GEOSFP.20190701.A3dyn.025x03125.nc` | 3.78 GB | 9 | `(1,1,721,1152)` | gzip/5 | 2884 | **102** | 215 KiB |
| `HEMCO/CEDS/v2021-06/2019/ALD2-em-anthro_CMIP_CEDS_2019.nc` | 13.7 MB | 11 | `(1,360,720)` | gzip/1 | 110 | **62** | 43 KiB |

### Finding 1 — metadata is tiny, numerous, and scattered through the whole object

`A1` needed **224 range GETs for 200 KiB**, spread across a 907 MB byte span.
Only 59 KiB of that lies in the first 4 MiB; **zero** in the last 4 MiB.

Consequences:

- The footer-family plan (fetch the tail on open) does not apply to HDF5.
- A naive `--header-window N` (fetch the first N MiB) does not either — the
  metadata is interleaved with the data, not clustered at either end.
- The amplification is real and large, but **our inferred cause was wrong** — see
  *Upstream outcome* below. We read `blockstore.go:717` ("a small read fetches a
  single 1 MiB chunk") and blamed demand-path chunk rounding; that comment was
  stale, and the bytes were actually whole-chunk *readahead*.
- The cost is **per open**, so it multiplies by ranks (48–192/node here) and by
  every re-read across time steps, restarts, and campaign reruns.

### Finding 2 — the chunks are already sequential on disk

For `A3dyn/U` (`shape=(8,72,721,1152)`, `chunks=(1,1,721,1152)`, gzip/5):

- 576 chunks, compressed 1.12–1.94 MB, mean 1.62 MB.
- **157/159 adjacent chunk pairs have zero gap**; max gap 7312 B.
- File offsets are **strictly monotonic in chunk-index order**.
- One GCHP time slice (all 72 levels) = **114.6 MB of contiguous bytes**.
- The entire inspection cost 23 range GETs.

So a GCHP read is a plain sequential scan of a ~115 MB region, which lith's
existing sequential detector, 8 MiB fills, and parallel parts already serve at
NIC line rate. **An HDF5 chunk-index parser would buy nothing for this
workload.**

## Recommendation to lith (as filed)

Filed upstream as [lith#210](https://github.com/scttfrdmn/lith/issues/210), now
**closed as resolved** — the outcome, including where this recommendation was
wrong, is in *Upstream outcome* below. As filed:

**Do not build HDF5 chunk-grid tier 2.** The spec surface (B-tree v1,
fixed/extensible array, implicit indexes) is large, it is a well-known fuzzing
target under lith's hostile-bytes rule (#101), and Finding 2 says the payoff for
sequential-chunked NetCDF-4 is approximately zero.

**Build learned metadata extents instead** — which is not a format feature:

1. Record the byte extents read before the first large sequential read (at index
   build, or on first open).
2. Store that extent list in the index next to the key.
3. On later opens, issue those extents as a few coalesced, byte-exact, parallel
   GETs — reusing the sparse-extent machinery already built for Parquet
   projection.
4. Treat it strictly as a hint: any read outside the recorded set falls through
   to the normal path, so there is no correctness dependency — the same posture
   as the Zarr planner degrading to tier 1.

Why it fits lith's thesis rather than bolting onto it: lith already serves
*filesystem* metadata locally after an index build; this serves *in-object*
metadata locally, and it is sound for exactly the stated reason the no-write path
buys everything else — **the bucket is read-only, so the read set is stable and
two uncoordinated readers agree on it.** It is also format-agnostic: the same
mechanism serves HDF5, NetCDF-4, GRIB, FITS and COG, so it adds one general
capability instead of a format family.

Secondary, ranked: confirm the demand path uses byte-exact sparse fills for small
scattered reads rather than 1 MiB chunks (that alone removes the amplification);
skip NetCDF-3 classic until a bucket-wide magic sweep finds any; leave chunk-grid
tier 2 deferred, noting that if a future store *does* have shuffled chunks the
Zarr tier-2 fixed/varying-axis planner ports over almost unchanged with byte
ranges substituted for keys.

## Upstream outcome (as of 2026-09-16)

lith#210 is closed. Both findings were accepted as the workload-shaped evidence
the `docs/scope.md` gate asks for, **one of our two causal claims was measured
and refuted, and the fix that landed is neither thing we proposed.** Recorded
here so the campaign does not carry the wrong story.

**Held — Finding 2.** HDF5 chunk-grid tier 2 stays deferred, with #210 as the
recorded evidence. Zero-gap monotonic chunks mean the existing sequential
machinery already serves the natural read unit; a chunk planner buys ~nothing.

**Refuted — our diagnosis of Finding 1's cause.** Upstream implemented the
demand-path byte-exact fix we ranked first (their step 1a, lith#212) and measured
it against our three objects staged into their bench bucket: **A1 −0.4%, A3dyn
~0%, ALD2 unchanged**, GET counts identical. Demand fills were only 1–2% of the
bytes; **97–99% were whole-chunk readahead.** The `blockstore.go` comment we
reasoned from was stale — #118 had already made straddling demand reads
extent-aware.

**The actual lever was the prefetch detector.** `inBand` in
`internal/prefetch/prefetch.go` compared positions in 8 MiB *block* space, so an
ascending HDF5 metadata walk with 8–870 MiB byte gaps still read as Sequential
(A3dyn: 51 of 55 reads), the window grew to 16 blocks / 128 MiB, and lith
prefetched straight through the scatter. Requiring the *byte* gap ≤ one block
(lith#213, merged `e203b55d`) gives, cold, 3-run medians on our objects:

| object | S3 bytes before → after | GETs | amplification |
|---|---|---|---|
| `A1` | 676 → **186 MB** (−72%) | 95 → 67 | 199× → 55× |
| `A3dyn` | 3701 → **291 MB** (−92%) | 450 → 86 | 980× → 82× |

Wall-clock neutral-to-faster (A3dyn 6.1 → 2.5 s). Cross-checked against a
CloudTrail S3 data-event ledger, not just lith's own counters (lith#214).

**Our proposal was deprioritized on its merits, correctly.** With the detector
fixed, the residual over-read is window re-growth during the initial contiguous
superblock burst — not repeated reads of the same extents across files, so it is
not memoization's case. Learned metadata extents is deferred with a trigger under
lith#211. The small-file case (`ALD2`, 13.7 MB, whole-loaded by parts-fetch
rather than by the detector) is covered separately by lith#220 → lith#229.

**Lesson for our own reasoning:** a code comment is not a measurement. The
`blockstore.go:717` inference was the one claim in this document not backed by a
number we took ourselves, and it was the one that was wrong.

## What this changes in our architecture

### Move to lith: `/input` (gcgrid)

Read-only by nature, never written by GCHP, huge bucket with a small working set.
This removes, from our own accumulated ledger:

- the ~33-minute full-bucket `ImportPath` that timed out the head-node
  WaitCondition (forcing pre-created FSx referenced by ID);
- the FSx Lustre v2.15-vs-2.10 mount failures and the Lustre-ports security
  group requirement;
- AZ-specific FSx/instance capacity coupling;
- `lfs hsm_restore` pre-hydration of a scoped working set before every run;
- a standing sw-stack FSx that went FAILED on its own while still billing;
- the 1.2 TiB Lustre minimum.

Bytes moved also improves: FSx lazy-loads whole objects on first touch, so
touching one variable in `A3dyn` hydrates 3.78 GB, where lith moves the 114.6 MB
actually read. The size of that win depends on how many variables ExtData pulls
per file.

Index scoping: build per data family (`GEOS_FP/<year>/<month>`, `HEMCO/CEDS`,
`CHEM_INPUTS`) rather than over all of gcgrid — the same discipline the
pre-hydration work already landed on. One prebuilt index can back many prefix
mounts.

### Keep on Lustre: `/scratch`

Checkpoints, HISTORY output, restart writes. lith's own scope doc puts
checkpoint-heavy MPI, cross-node locking, and read-write scratch outside its
boundary, and our own measurements agree twice over (the per-column handoff over
shared Lustre cost ~175 s/superstep; the o-server checkpoint path needed real
filesystem semantics).

### Probably not worth it: `/sw`

`--exec` exists (reports mode 0555), but mmap'd shared libraries plus a 266 MB
binary launching across 192 ranks is an untested path, and the stack already
works on EBS. Low upside, new variable.

## Gates to test on this branch

1. **Collective MPI-IO reads.** Determine whether MAPL reads the cold-start
   restart via `H5FD_MPIO`. If it does, keep restarts off lith — cross-node
   locking is explicitly outside lith's scope. Met-field/emissions reads through
   ExtData are ordinary reads and are the bulk of the traffic.
2. **Per-node mount vs `lith serve nfs`.** Expect per-node mounts to win for
   48–192-rank nodes, for the same reason the S3-wide handoff beat shared Lustre
   by ~9×: no shared lock, and aggregate bandwidth grows with readers.
3. **Cold-open cost — pin the version, don't build from `main`.** The original
   framing of this gate (quantify the 224-GET / 1 MiB-granularity cost so we know
   what the upstream feature is worth) is obsolete: the cost was largely removed
   upstream before we measured it on a cluster. What remains worth measuring is
   GCHP init time on a lith `/input` **with the gap-aware detector in it**, which
   means **v1.1** — the fix (`e203b55d`) and the follow-on unified fetch policy
   (lith#229, `1f4d1e22`) both postdate the v1.0.1 tag. v1.1 is the M17
   "hardening by shape" milestone and is imminent as of 2026-09-16; wait for the
   tag rather than pinning a `main` SHA, so the campaign cites a release.
   Still open in M17 and worth watching for our shape: lith#233 (block-0
   coalescing on cold sequential reads), lith#230 (byte-vs-request tradeoff by
   storage class — gcgrid is Standard, so this should not bite us).
4. **A/B control.** Keep one FSx `/input` run in the matrix. lith reached 1.0
   eleven days after its first commit and the read path is still moving — the
   detector rule and the fetch policy both changed after our measurements. The
   campaign is publication-bound; an input-layer change must not silently
   confound comparisons with existing numbers, and the lith version must be
   recorded with every run.

## Provenance

Every number here was measured on 2026-09-14 against live `s3://gcgrid` objects
via ranged reads (no full-object downloads, no cluster spend). Reproduce with
`scripts/lith/h5probe.py` and `scripts/lith/h5chunks.py`.

The *Upstream outcome* numbers are **not ours** — they were measured by lith
upstream on their bench box against our three objects, and are cited from
lith#212 / #213 / #214.

Refs: [`scttfrdmn/lith#210`](https://github.com/scttfrdmn/lith/issues/210)
(HDF5/NetCDF4 measured demand — filed 2026-09-14 with these measurements, closed
resolved 2026-09-16); lith#212 (step 1a, verdict "little"), lith#213 (gap-aware
sequential classification — the fix), lith#214 (CloudTrail confirmation),
lith#211 (learned extents, deferred with a trigger), lith#229 (unified fetch
policy). `docs/scope.md:142` is the gate this analysis answers.
