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
- On lith's demand path a ~1 KB metadata read pulls a 1 MiB cache chunk
  (`internal/blockstore/blockstore.go:717`), so the worst case is ~224 MiB
  fetched to deliver 200 KiB (~1000× amplification) unless the byte-exact
  sparse-fill path (`internal/blockstore/extent.go`, `fill.go:93`) covers it.
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

## Recommendation to lith

Filed upstream as [lith#210](https://github.com/scttfrdmn/lith/issues/210). In
short:

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
3. **Cold-open latency with learned extents absent.** Measure GCHP init time on
   a lith `/input` today (224-GET opens, 1 MiB granularity) to quantify what the
   upstream feature is worth before it exists.
4. **A/B control.** Keep one FSx `/input` run in the matrix. lith is nine days
   old with no external users; the campaign is publication-bound, and an input
   layer change must not silently confound comparisons with existing numbers.

## Provenance

Every number here was measured on 2026-09-14 against live `s3://gcgrid` objects
via ranged reads (no full-object downloads, no cluster spend). Reproduce with
`scripts/lith/h5probe.py` and `scripts/lith/h5chunks.py`.

Refs: [`scttfrdmn/lith#210`](https://github.com/scttfrdmn/lith/issues/210)
(HDF5/NetCDF4 measured demand — filed 2026-09-14 with these measurements);
`docs/scope.md:142` is the gate this analysis answers.
