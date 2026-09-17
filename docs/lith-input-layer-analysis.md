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

**Answered by the integration A/B (gate 3c, below):** GCHP 14.7.1 completed a
full simulation with **100% of its input served from `s3://gcgrid` through lith**,
at 48 ranks on one node, twice, with zero read errors and zero fallbacks. Against
FSx Lustre at the same temperature: **1.73× faster init cold, parity warm.** The
byte advantage over a whole init is **1.43×**, not the 9.3× a single hyperslab
suggested — the win is cold latency and the deleted pre-hydration step, not
bandwidth.

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
- The cost is **per open** — but **not** per rank, contrary to what this document
  and lith#210 originally claimed. MAPL reads through a small reader set (default
  1); see *Gate 1, answered* below. It still recurs across time steps, restarts
  and campaign reruns.

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

## Upstream outcome — shipped in lith v1.1.0

lith#210 is closed and **the fixes shipped in
[v1.1.0](https://github.com/scttfrdmn/lith/releases/tag/v1.1.0), 2026-09-16**,
which is the version to test against. Both findings were accepted as the
workload-shaped evidence the `docs/scope.md` gate asks for, **one of our two
causal claims was measured and refuted, and the fix that landed is neither thing
we proposed.** Recorded here so the campaign does not carry the wrong story.

The v1.1.0 changelog names this workload directly — "cut over-read 72–92% on the
GEOS-Chem gcgrid workload, ledger-confirmed" — so the release is traceable back
to these measurements.

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

**The bigger win for us is the second v1.1.0 change, which we did not ask for.**
lith#229 gates *all* broad fetching — open-time parts-fetch, the initial readahead
ramp, and the post-seek re-anchor — on one signal: whether reads in a trailing
window actually tile. Nothing broad is fetched until the pattern establishes. Its
measured effect on **HDF5 hyperslab reads is 92.5× → 6.3× amplification**, with
COG windows 22.1× → 1.27× and GRIB `.idx` 8.1× → 3.35×; streaming and the
CargoShip tree walk stay byte-identical.

That matters more to `/input` than the metadata fix does. A hyperslab *is* what
ExtData issues — one variable, one time slice, out of a file holding 50 of them —
so it is the bulk of our traffic, whereas the metadata walk is a per-open cost.
It also subsumes the small-file case (`ALD2`, 13.7 MB, whole-loaded by
parts-fetch rather than by the detector: lith#220 → lith#229).

The stated cost is a cold sequential copy paying roughly one extra round-trip for
its first block — byte-identical, cold-only, shrinking with file size. That is
lith#233, still open in M17. For 1–4 GB met files it should be noise; worth
confirming rather than assuming, since cold reads are exactly our shape.

**Our own proposal was deprioritized on its merits, correctly.** With the detector
fixed, the residual over-read is window re-growth during the initial contiguous
superblock burst — not repeated reads of the same extents across files, so it is
not memoization's case. Learned metadata extents is deferred with a trigger under
lith#211.

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

1. ~~**Collective MPI-IO reads.**~~ **ANSWERED 2026-09-17 by source inspection,
   no spend — and the answer removes the restriction.** MAPL does **not** use
   collective MPI-IO: `nf90_open_par`, `nf90_create_par` and `H5FD_MPIO` have
   **zero** occurrences in `GEOS-ESM/MAPL`, even though our own HDF5 is built
   `--enable-parallel` (`build-gchp-stack-validated-arm64.sh:350`), so the
   capability is present and simply unused. Instead:
   - **Restarts:** `base/NCIO.F90` ~2218–2290 — `amIRoot = MAPL_am_i_root(layout)`
     → `formatter%get_var(...)` on that rank only → `ArrayScatter` /
     `ArrayScatterShm`, or `MAPL_CommsBcast` in the non-tiled branch.
     `num_readers` **defaults to 1** (`base/FileIOShared.F90:107`), capped at `NY`
     and required to divide it evenly.
   - **ExtData (the bulk):** `griddedio/GriddedIO.F90:1288` issues
     `i_Clients%collective_prefetch_data(...)` with each rank's own
     `localStart`/`globalStart`/`globalCount`. Ranks *request* subdomains and a
     pFIO reader set serves them — a request/serve design specifically so the file
     is not opened once per rank.

   Consequences: (a) the cross-node-locking boundary in lith's `docs/scope.md` is
   **not in play** for GCHP reads — a restart read is one rank doing ordinary
   POSIX reads, so restarts need not be kept off lith as this document first
   assumed; (b) the "multiplies by 48–192 ranks" claim was wrong and has been
   corrected upstream (lith#210 comment); (c) `num_readers` is now a *tuning knob
   for the lith experiment* — raising it toward `NY` spreads metadata opens across
   ranks, which is the natural A/B against a single-reader baseline.
2. ~~**Per-node mount vs `lith serve nfs`.**~~ **MEASURED 2026-09-17 — results in
   *Gate 2 results* below. Per-node mounts win, but not for the predicted reason,
   and the prediction below was wrong twice over.** The shared gateway does not
   lose a performance race; it **cannot run GCHP at all** (ESTALE under concurrent
   GETATTR, reproduced standalone). And the "aggregate bandwidth grows with
   readers" premise never engaged: measurement showed reads are *not* centralised
   to begin with, so per-node mounts fetch the whole working set **once per node**
   rather than sharing it — a byte argument *for* a gateway, opposite to the guess
   recorded here.

   Original framing, kept for provenance: Expect per-node mounts to win for
   48–192-rank nodes, for the same reason the S3-wide handoff beat shared Lustre
   by ~9×: no shared lock, and aggregate bandwidth grows with readers.
3. **MEASURED 2026-09-17 — read cost on `v1.1.0`, lith vs an FSx control.** Results
   in *Gate 3 results* below. lith wins cold by **8.5–29×**, matches FSx warm to
   within noise, moves **5.4–16× fewer bytes**, and returns **byte-identical
   data** (checksums match on all six file/day pairs). The GCHP-init integration
   run on `m9g.48xlarge` is still outstanding; everything below is head-node
   microbenchmark on the authentic HDF5 1.14.0 that GCHP links.

   Original framing of this gate, kept for provenance: The original framing of this
   gate (quantify the 224-GET / 1 MiB-granularity cost to size what the upstream
   feature is worth) is obsolete: the cost was largely removed upstream before we
   measured it on a cluster. What is worth measuring now is GCHP init and ExtData
   read time on a lith `/input` at **v1.1.0**, which carries both the gap-aware
   detector (`e203b55d`) and the unified fetch policy (`1f4d1e22`); neither is in
   v1.0.1. Install from the release's **deb/rpm** — v1.1.0 ships packages, an
   SBOM, cosign signatures and SLSA provenance (lith#207), so nodes need no Go
   toolchain and the artifact is verifiable, which suits a published campaign.
   Record the exact version and `parts-fetch` setting with every run.
   Two open M17 items to watch for our shape: lith#233 (the cold-sequential
   first-block round-trip that lith#229 costs us) and lith#230 (byte-vs-request
   tradeoff by storage class — gcgrid is Standard, so this should not bite).
4. **A/B control.** Keep one FSx `/input` run in the matrix. lith reached 1.0
   eleven days after its first commit and the read path is still moving — the
   detector rule and the fetch policy both changed after our measurements. The
   campaign is publication-bound; an input-layer change must not silently
   confound comparisons with existing numbers, and the lith version must be
   recorded with every run.

## Gate 3 results — lith v1.1.0 vs FSx Lustre, measured 2026-09-17

Cluster `gchp-lith-ab`, head node `c7g.4xlarge`, us-east-1a. lith 1.1.0 from the
release rpm. Reads issued through **the GCHP stack's own HDF5 1.14.0**
(`/sw/hdf5-1.14.0`), not a Python approximation, so the access pattern is the one
MAPL actually produces. Three replicates on three different days (2019-07-02/03/04)
so every cold number is a genuinely cold file. Harnesses:
`scripts/lith/gate3-read-cost.sh`, `scripts/lith/gate3b-hemco-walk.sh`,
`scripts/lith/slabread.c`. Raw data: `data/lith-gates/gate3*-results.tsv`.

`--nic-gbps 15` passed explicitly — autodetection fails on ParallelCluster both
ways (lith#237), which would have clamped `parts-max` to 4 MiB. Derived settings
recorded per run: `parts-max` 64 MiB, readahead 67 blocks, coalesce gap 585,937 B.

> **Correction — the 15 was wrong, and the real numbers are better than the table.**
> `c7g.4xlarge` is "Up to 15 Gigabit" but its `DescribeInstanceTypes`
> **baseline is 7.5 Gbps**; 15 is the burst peak. `--nic-gbps` wants the baseline,
> so every cold number below was taken with the NIC overstated 2×. Re-measured on
> the same file, 3 reps each: at the correct **7.5** the `A3dyn` cold slab moves
> **382 MB, amplification 3.5×**, versus 654 MB / 6.0× at 15 — **42% fewer bytes
> for no wall-time change** (read 2.4–3.3 s either way, ranges overlapping).
> So the bias ran *against* lith: its true byte advantage over FSx on that read is
> **9.3×** (382 vs 3564 MB), not the 5.4× the table states, and the wall-clock
> comparisons are unaffected. Reported upstream on lith#237.

| read shape | FSx cold | lith cold | lith adv. | FSx bytes | lith bytes |
|---|---|---|---|---|---|
| `A1` 0.95 GB, 3.3 MB slab (`/ALBEDO`, 1 step) | 6.9 s | **0.24 s** | **29×** | 954 MB | **3.0 MB** |
| `A3dyn` 3.5 GB, 239 MB slab (`/U`, 1 step × 72 lev) | 24.8 s | **2.90 s** | **8.5×** | 3564 MB | **654 MB** |
| HEMCO walk, 31 files, 502 MB | 39.7 s | **3.6 s** | **11×** | 502 MB | **31 MB** |
| any of the above, warm | 0.02–1.12 s | 0.02–1.12 s | parity | 0 | **0** |

Medians of 3; spread was tight (`A3dyn` cold open 22.5/24.4/23.6 s FSx,
0.09/0.11/0.16 s lith).

**The cold win is not a read-speed win — it is the whole-object lazy load.** On
FSx, touching a file's *metadata* costs hydrating the entire object: `A3dyn` cold
`H5Fopen` alone took **22.5–24.4 s** while the subsequent 239 MB `H5Dread` took
1.18 s. lith's `H5Fopen` on the same file: **0.09–0.16 s**. GCHP opens a file and
reads a few variables; FSx charges for all 3.5 GB of it.

This is precisely the cost that our `lfs hsm_restore` pre-hydration ritual exists
to pay up front (memory `fsx_prehydrate_before_runs`). So the honest framing is:
**FSx warm equals lith warm on read speed — but reaching FSx warm costs the full
hydration of the working set, and lith's "cold" *is* its steady state.** lith does
not make reads faster than Lustre; it deletes a provisioning step.

**Byte-identical.** `slabread` FNV-checksums the returned buffer; all six
file/day pairs matched between backends exactly. The 110 MB `distinct_bytes_read`
for the `A3dyn/U` slice also independently confirms Finding 2's predicted 114.6 MB
contiguous time slice.

**Residual amplification, and one refuted prediction of ours.** lith's cold
over-read is 5.9× on the big hyperslab (654 MB fetched for 110 MB used) at the
overstated NIC setting, and **3.5× (382 MB) at the correct 7.5 Gbps baseline** —
either way bracketing lith#229's own 6.3× hyperslab figure, independently
reproduced on different hardware and through the C library rather than h5py.
FSx's equivalent is 32× (3564/110), so lith moves 5.4–9.3× fewer bytes *despite*
its amplification. Small files amplify worst: 8.0× on the HEMCO walk (31 MB for
3.9 MB), though trivial in absolute terms.

Gate 3b was designed to find the regime where lith loses — HEMCO files are 13 MB,
below `parts-max` 64 MiB, so we predicted lith would whole-fetch them and move the
same 502 MB FSx does. **Wrong: lith moved 31 MB.** #229's "nothing broad until
reads tile" means a metadata-only walk never triggers the parts path at all. The
prediction was mine, and the measurement refuted it — the same lesson as
`blockstore.go:717`, on the same branch.

Not yet explained: `lith_sibling_prefetch_total` stayed at **0** across a 31-file
walk opened in sorted key order, so the sibling-walk detector never fired. Asked
upstream rather than guessed at.

## Gate 3c results — the integration A/B: real GCHP, lith v1.1.1 vs FSx Lustre

Gate 3 measured read shapes with a harness. Gate 3c runs **the model**, so
ExtData/HEMCO/pFIO issue the reads, and 48 MPI ranks hit the FUSE mounts
concurrently — the risk no head-node measurement could retire.

Cluster `gchp-lith-ab`, compute `m9g.48xlarge` (192 cores, 742 GB, 100 Gbps),
us-east-1a, lith **v1.1.1**. GCHP 14.7.1, C24 TransportTracers, MERRA-2
0.5°×0.625°, 1 simulated day, **48 ranks**, aarch64. The two run directories
differ only in where input comes from — same binary (`cmp`-identical), same
`CAP.rc`/`GCHP.rc`/`HISTORY.rc`, same restart, same resolution, same rank count.
`--nic-gbps 100` (the authoritative `DescribeInstanceTypes` baseline, not a peak).
Harnesses: `scripts/lith/gate3c-gchp-init.sbatch` (four arms),
`scripts/lith/gate3c-fsxcold.sbatch` (the paired cold arms),
`scripts/lith/gate3c-preflight.sbatch`.

### All four arms completed a full simulation

Every arm reached `2019/01/02 00:00`, advanced `cap_restart`, and wrote a
checkpoint. Zero read errors, zero fallbacks. **100% of model input on the lith
arms came from `s3://gcgrid` through five prefix-scoped FUSE mounts** — met,
the date-pinned 2015 constant field, HEMCO, CHEM_INPUTS, and the restart. There
were no residual `/input/` references in the run directory, so silent fallback
to Lustre was not possible.

| arm | init | to completion | vs FSx same temperature |
|---|---|---|---|
| **FSx cold** (HSM released, 6.25 GB working set) | 45.26 s | 90.4 s | — |
| **lith cold** (fresh mounts, nothing cached) | **26.09 s** | **55.3 s** | **1.73× / 1.64× faster** |
| FSx warm (fully hydrated Lustre) | 16.66 s | 34.2 s | — |
| **lith warm** (mem-cache) | **15.94 s** | **34.2 s** | **parity** |

"init" is wall seconds to the first completed timestep — startup plus all
ExtData/HEMCO/restart reads. Interleaved for reference: FSx *hydrated but
page-cache-cold* sat between at 22.34 s / 42.2 s.

**Cold, lith beats a Lustre filesystem that has to hydrate: 1.73× on init,
1.64× to completion. Warm, it is a tie — 15.94 s vs 16.66 s init and 34.2 s vs
34.2 s to completion.** That is the gate 3 conclusion reproduced by the actual
model rather than inferred from read shapes: lith does not make reads faster
than Lustre, it deletes the provisioning step.

### Reproducibility

`lith cold` was measured twice, in two separate jobs, on the same node:

| | init | to completion | S3 bytes | GETs | amplification |
|---|---|---|---|---|---|
| run 1 | 26.02 s | 55.3 s | 4361.9 MB | 3822 | 1.31× |
| run 2 | 26.09 s | 55.3 s | 4363.3 MB | 3819 | 1.31× |

0.07 s apart on init and 0.03% apart on bytes, independently.

### Bytes: 1.31× amplification, 1.43× advantage

| mount | distinct | from S3 | ampl. | GETs | KB/GET |
|---|---|---|---|---|---|
| MERRA2 2019/01 | 3222.9 MB | 4105.4 MB | 1.27× | 3647 | 1099 |
| HEMCO | 65.4 MB | 216.4 MB | 3.31× | 124 | 1704 |
| restarts | 38.8 MB | 38.9 MB | 1.00× | 46 | 827 |
| MERRA2 2015/01 + CHEM_INPUTS | 1.2 MB | 1.2 MB | ~1× | 5 | — |
| **total** | **3328.2 MB** | **4361.9 MB** | **1.31×** | **3822** | **1115** |

FSx moved the whole working set — **6252.1 MB**, measured directly (`released
15/15 files, 6252076702 bytes`), not estimated. So lith's byte advantage on a
cold init is **1.43×**.

**This is much smaller than gate 3's 9.3×, and that is the honest headline for
anyone sizing lith for this workload.** Gate 3's figure was a single hyperslab —
the adversarial case. Across a whole init GCHP reads **53% of the bytes of every
met file it opens** (3328 MB distinct of 6252 MB on disk), and there is only so
much a lazy reader can save against a workload that dense. Size the byte win at
~1.4×; the real prize is the cold latency above and the deleted provisioning
step (no `lfs hsm_restore` ritual, no 33-minute `ImportPath` hydration, no
1.2 TiB filesystem minimum).

Amplification is also *better* under the real model than under the harness —
1.31× here versus 3.5× for the synthetic hyperslab at the correct baseline.
#229's "nothing broad until reads tile" is being vindicated: ExtData reads many
fields out of each collection, so the access genuinely tiles and the broad fetch
is the right call.

### 48-rank concurrency: not a problem

The largest open risk in the proposal, retired. 48 concurrent 4 MB readers
against one FUSE mount: **0.08 s**, no deadlock, no `EACCES` (preflight). Under
the real model, 48 ranks drove 3822 GETs through five daemons with zero errors
and zero fallbacks, twice.

### The warm arm issued *no* S3 requests at all

The metrics after `lith-warm` are **byte-for-byte identical** to those after
`lith-cold` — same `s3_bytes_total`, same GET count. The entire 3.3 GB working
set stayed resident in the bounded mem-cache, so the second run went to S3 zero
times. That is why warm lith ties warm Lustre.

Note `--mem-cache` must be bounded explicitly per mount: its default is 25% of
system memory **per daemon**, so five mounts default to reserving 125% of the
box. On a 742 GB m9g that is 192 GB apiece, and GCHP wants that memory.

### lith#237 datapoint: the size table underestimates m9g 2×

On `m9g.48xlarge`, whose authoritative baseline is **100.0 Gbps**:

```
[INFO] nic 50.0 Gbps (source=imds-estimate) → parts-max 64 MiB, inflight 1192 MiB
       — estimated from m9g.48xlarge size (DescribeInstanceTypes denied)
```

A **2× underestimate**, where the same table was exact on `c7g.4xlarge` (7.5).
Conservative rather than harmful — `parts-max` still clamps at its 64 MiB
ceiling, and under-stating the baseline fetches *fewer* wasted bytes — but wrong.
Reported upstream.

It also answers the open worry I raised in #237, that a 100 Gbps baseline might
blow amplification up to multiple GB: **it does not.** Real-workload
amplification went 1.17× (15 Gbps, 6 ranks) → 1.31× (100 Gbps, 48 ranks). The
near-linear bytes-vs-NIC scaling I saw on the synthetic hyperslab does not
reproduce on the model.

### Caveats

Single replicate per arm on the timing (the two cold runs excepted); C24, which
is the smallest useful resolution, so init is a large fraction of a 34–90 s
total and the *relative* cold penalty will shrink on production-length runs;
one node — multi-node is now covered by *Gate 2 results* below, where per-node
mounts carried 96 ranks across 2 nodes to completion. GCHP's own
post-checkpoint `double free or corruption (!prev)` in `_dl_fini` is present on
both backends identically and is unrelated to lith; the harness polls for GCHP's
own completion evidence rather than waiting on `mpirun`, which never returns.

### Two ParallelCluster traps this cost us four self-terminated m9g nodes

Both surfaced as EC2 `StateReason: Client.InstanceInitiatedShutdown` with
clustermgtd reporting "power up state without valid backing instance" — which
reads exactly like a capacity or AMI problem and is neither. The breadcrumb is
the CloudWatch stream `<node>.bootstrap_error_msg`.

1. **A queue-level `CustomAction` script in S3 is fetched by the compute node
   role**, not the head node role. `AmazonS3ReadOnlyAccess` under `HeadNode/Iam`
   does not grant it; the head node bootstrapped fine while every compute node
   got `HeadObject 403`. Needs `Iam.AdditionalIamPolicies` on the queue too.
2. **Compute nodes have no internet egress** — no public IP, no NAT, only an S3
   gateway endpoint. `dnf install fuse3` therefore works (AL2023 repos are
   S3-backed) while `curl https://github.com` stalls 136 s and fails. The lith
   rpm is now mirrored into the project bucket and pulled over the S3 endpoint,
   which is better provenance anyway.

## Gate 2 results — per-node mounts vs one shared `lith serve nfs`, 2 nodes, 96 ranks

Cluster `gchp-lith-ab`, **two `c8g.48xlarge`** (192 vCPU, 384 GiB, aarch64, EFA)
in us-east-1a, 96 MPI ranks at 48 per node, GCHP 14.7.1 C24 TransportTracers,
1 simulated day, lith v1.1.1. Layout `NX=4, NY=24` — not invented for this test:
`setCommonRunSettings.sh` lists `(NX=4,NY=24) -> 96 cores` as a *good* example and
puts C24's ceiling at 216 cores, so no new run directory was needed and
`AutoUpdate_NXNY=ON` derived it. Harness `scripts/lith/gate2-mount-vs-nfs.sbatch`.

### The headline: the shared gateway cannot run GCHP

| arm | topology | `NUM_READERS` | init | to sim end | steps |
|---|---|---|---|---|---|
| `fsx-r1` | FSx Lustre (warm) — anchor | 1 | 33.13 s | 69.13 s | 144/144 |
| `mount-r1` | per-node lith FUSE, cold | 1 | 41.43 s | 88.43 s | 144/144 |
| `mount-r24` | per-node lith FUSE, cold | 24 | 41.88 s | 93.88 s | 144/144 |
| `nfs-r1` | one shared `lith serve nfs` | 1 | — | — | **0/144, aborted at 4 s** |

`fsx-r1` and `mount-r1` reproduced across two separate jobs to ~1 s, so the
per-node numbers are not single-shot. Note the FSx anchor here is **warm**
(hydrated) against a **cold** lith, the same asymmetry as gate 3c — where cold
FSx lost to cold lith by 1.73×. This is not a like-for-like temperature
comparison and should not be read as one.

`NUM_READERS=24` changed nothing measurable (41.43 → 41.88 s, ~1%), which is
consistent with gate 1: `NUM_READERS` governs only the **restart** read (39 MB),
and the bulk is ExtData/pFIO (~3.2 GB), which it does not touch.

The gateway arm died 4 s in, on many ranks at once:

```
nf90_open: returned error code (-51) opening gchp_restart.nc4 [NetCDF: Unknown file format]
nf90_open: returned error code (116) opening gchp_restart.nc4 [Stale file handle]
pe=00071 FAIL at line=00297  NetCDF4_FileFormatter.F90  <status=-51>
pe=00071 FAIL at line=00517  MAPL_GridManager.F90       <status=-51>
```

`MAPL_GridManager.F90:517` is **not** gated by `NUM_READERS`, so all 96 ranks open
that one file simultaneously — which is precisely the load that breaks.

### Root cause, isolated on the head node for $0: ESTALE under concurrent GETATTR

"GCHP crashed" is not a bug report, so the failure was reduced to a standalone
repro with no MPI, no model and no compute nodes — three probes on the head node,
which was already billing. Each compares bytes against the *same S3 object* as
materialised by FSx (`md5 909d6648…`, 38736962 B).

1. `gate2-nfs-concurrency-probe.sh` — 96 concurrent `md5sum` of one file through
   the gateway: **perfectly clean**. But its own metrics said why that proved
   nothing: `op="read" 39`, `s3_bytes 3.87e7` — *one* file's worth. The kernel NFS
   client's page cache served the other 95 readers, so the gateway never saw
   concurrency. Any single-host cached sequential test is structurally incapable of
   reproducing this.
2. `gate2-nfs-random-read-probe.sh` — random 1 MiB offsets with `iflag=direct` to
   defeat that cache, verified per offset. **Reproduced:** 232/1920 reads failed at
   C=96, while the FUSE control at the same concurrency was clean.
3. `gate2-nfs-errno-probe.sh` — captures the errno and walks the threshold.

| concurrent readers | plain `nolock,ro` | with `noac,actimeo=0` |
|---|---|---|
| 32 | 0 / 640 | 0 / 640 |
| 48 | 0 / 960 | 63 / 960 (6.6%) |
| 64 | 2 / 1280 (0.2%) | 221 / 1280 (17.3%) |
| 96 | 1 / 1920 (0.1%) | 304 / 1920 (15.8%) |
| 128 | 1 / 2560 (0.0%) | 542 / 2560 (21.2%) |

**Every** failure, in both columns, is the same thing: `ESTALE` ("Stale file
handle") returned on **`fstat`/GETATTR**, never on READ. What this rules out:

- **Not corruption.** `mismatch=0` on every rung of every probe — the gateway never
  served a wrong byte. That matters: a silent-corruption bug would be far worse.
- **Not the network or S3.** 6.5–7.7 GB served from mem-cache against 37.7 MB
  fetched from S3.
- **Not a timeout or retransmit.** Client `retrans=0` throughout; the server
  answers promptly and *chooses* to return `NFS3ERR_STALE`.
- **Not fd or thread exhaustion.** Gateway threads 14→17, fds flat at 10–14.
- **Not my mount flags.** `noac` amplifies the rate ~100× (it raises GETATTR ~10:1,
  59068 vs 15598), but the plain-options control still fails at C≥64 — and gate 2's
  GCHP arm used plain options. The flags change the rate, not the existence.

So it looks like a file-handle→object mapping that does not survive concurrent
GETATTR — a bounded/recycled handle table or a racy lookup — which the numbers
locate rather than the code, since lith's internals were not read here.

### Why a 0.04% failure rate is nonetheless fatal

The plain-options rate looks negligible: 1 bad read in 2560. It is still a hard
stop for this workload, because **an MPI job has no retry semantics at file open.**
One rank getting ESTALE from `nf90_open` aborts that rank, and one aborted rank
takes down all 96. At GCHP's scale — 96 ranks × 2 client hosts, each opening the
same restart plus 15 met files — even a per-open failure probability of 10⁻³ makes
a successful init unlikely. That asymmetry (a rate a filesystem would shrug off
being fatal to a tightly-coupled job) is the transferable lesson, and it is also
why the `-51 NetCDF: Unknown file format` and `116 Stale file handle` errors appear
*together*: one cause, two renderings, depending on whether HDF5 got ESTALE while
reading the superblock or had it surfaced verbatim.

### The read-topology finding, which inverts the gate's own premise

Per-node `lith_s3_bytes_total`, `mount-r1`:

| node | fetched from S3 |
|---|---|
| `compute-dy-nodes-1` | 4152.1 MB |
| `compute-dy-nodes-2` | 4127.7 MB |

Both nodes independently fetch **the entire ~4.1 GB working set** — reads are *not*
centralised at stock settings, and per-node mounts therefore move ~8.3 GB of S3
traffic for a 3.3 GB distinct working set. On byte volume that is an argument
**for** a shared gateway, the opposite of what this gate predicted. Two reasons it
does not change the recommendation:

- The gateway is unavailable anyway until the ESTALE defect is fixed.
- The duplication is economically ~free: in-region S3 → EC2 transfer costs nothing,
  and the request cost is ~3800 GETs per node per run, i.e. **fractions of a cent**.
  It duplicates bytes that were never billed.

It would start to matter at high node counts on a metered path (cross-region, or a
requester-pays bucket), which is the condition under which the gateway is worth
revisiting.

### Verdict

**Use per-node lith FUSE mounts. Do not use `lith serve nfs` for GCHP.** Not
because it is slower — that race was never run — but because it cannot complete an
init at 96 ranks. Per-node mounts, meanwhile, ran multi-node GCHP to completion at
96 ranks across 2 nodes, twice, with zero read errors and zero fallbacks, which is
the first multi-node confirmation of the gate 3c result.

Reported upstream on lith#210 with the standalone repro and the threshold table.

### Harness bugs worth remembering

Three of these cost real allocation time, and all three are the same species —
a diagnostic that lies rather than fails:

- `grep` treats a 96-rank mpirun log as **binary** (NUL bytes from interleaved
  output) and prints "binary file matches" *instead of* the matching line, so
  `init`/`sim_end` silently became `NA` while the run itself was perfect. `-c` and
  `-q` are unaffected, which is exactly why it hid: the step count and the
  SIM_COMPLETE verdict still worked. **`grep -a` for any field extraction.**
- `pgrep -fc '[l]ith-1.1.1 serve'` returned **15 for 5 servers** and skipped both
  NFS arms while all five gateways were up and serving. Each server contributes
  three matching command lines (the ssh-spawned `bash -c`, the `setsid nohup`
  wrapper, the real process). The bracket trick defeats *self*-matching, not
  *launcher*-matching. **Check a bound socket with `ss`, not a process count.**
  Relatedly, `pkill -f` still kills its own ssh shell if the plain string appears
  anywhere else in the same command line — including in a later command.
- A bare `wait` in bash 5 also waits on the process substitution from
  `exec > >(tee …)`, and `tee` never exits, so the probe deadlocked with every
  reader already finished. **Collect PIDs and `wait "${pids[@]}"`.**

And `ssh host 'cmd &'` never returns even with all three fds redirected; use
`ssh -f -n` with a `timeout` guard. `lith mount --daemon` self-detaches, but
`lith serve nfs` has no `--daemon`, which is what made the difference.

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
policy — the hyperslab win), lith#233 (its cold first-block cost).
Both shipped in **lith v1.1.0** (2026-09-16), which is the version this branch
should test. `docs/scope.md:142` is the gate this analysis answers.
