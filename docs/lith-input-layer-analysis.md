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
at 48 ranks on one node and 96 ranks across two, with zero read errors and zero
fallbacks. It works, and it is believed to be the first time GCHP has run with its
input tree on object storage.

**Performance is a wash-to-slight-edge for lith warm, and a clear lith win cold.
It is not the reason to adopt it either way** — the reasons are provisioning time
and standing cost. All four arms, C24 TransportTracers:

| comparison | FSx | lith | |
|---|---|---|---|
| 1-node 48-rank, **warm vs warm**, init | 16.66 s | 15.94 s | tie (~4% lith) |
| 1-node 48-rank, **warm vs warm**, to sim end | 34.2 s | 34.2 s | **dead tie** |
| 1-node, **cold vs cold**, init | 45.26 s | 26.09 s | **lith 1.73×** |
| 1-node, **cold vs cold**, to sim end | 90.4 s | 55.3 s | **lith 1.63×** |
| 2-node 96-rank, init | 33.13 s (**warm**) | 41.43 s (**cold**) | not like-for-like |

**Which temperature is the honest one depends on whether the FSx volume is
standing, and that is a cost decision, not a physical fact.** This document
briefly argued that warm FSx was the operationally honest baseline because
pre-launch `lfs hsm_restore` is standing policy. That was wrong on its own terms:
pre-hydration is only cheap because two 1.2 TB `/input` volumes are kept alive at
~$168/month each *specifically* to dodge the ~33 min setup penalty. Retire them —
which is the entire point of adopting lith — and every fresh ephemeral cluster
gets a **cold** FSx. **Ephemeral, on-demand clusters are the normal case in the
cloud, so cold-vs-cold is the comparison that matters, and lith wins it 1.73×.**

The 2-node row is cold lith against warm FSx and should not be read as a lith
loss; 2-node FSx **cold** was never measured. The 1-node cold arm is the only
like-for-like cold evidence we have.

Two arguments against lith that were made here and do **not** hold up:

- *"Repeat runs favour FSx, because hydration amortises while lith's mem-cache
  dies each job."* This was an artifact of the harness, not of lith: the probe
  launched daemons per job with `--mem-cache 2GB` against a 4.1 GB working set.
  Mount lith once at cluster boot from post-install with `--mem-cache 32GB` — on a
  node with 384–768 GB — and the working set stays cached for the cluster's whole
  life. The amortisation advantage largely evaporates.
- *"Init is ~0.1% of a C180 fullchem sim-day (~3.2 h on 48 cores), so this cannot
  matter."* True, but symmetric: it dissolves FSx's warm advantage exactly as much
  as lith's cold one. It is an argument for deciding on provisioning and cost, not
  an argument for FSx.

The byte advantage over a whole init is **1.43×**, not the 9.3× a single hyperslab
suggested, and in-region S3→EC2 bytes are free, so that column decides nothing
either way.

**Topology: per-node FUSE mounts, but the choice is now a preference rather than a
constraint.** On lith v1.1.1 one shared `lith serve nfs` gateway could not complete
a 96-rank init at all. v1.1.2 fixes that, and the race that was never run is a
**dead heat** (mounts 34.72 s init / 72.72 s to sim end; gateway 35.20 s / 69.20 s,
both 144/144). Mounts stay the default for having fewer moving parts; the gateway
earns its place only where bytes are metered, where it saves a measured **1.28×**
(*Gate 2, part two*).

**The decisive terms:** lith removes ~$168/month per retired `/input` volume, takes
time-to-first-run from ~33 min of FSx create+import to a ~4 s mount, and deletes
five separately-recorded deployment traps (the create+import WaitCondition timeout,
the v2.15-or-mount-fails version pin, the Lustre-ports security group, AZ pinning,
and pre-hydration itself). For a fleet of two-hour clusters, 33 minutes is a third
of the cluster's life.

**Working-set scale was the last real unknown, and it has now been measured: the
cold advantage grows.** The table above is C24 TransportTracers. Against a fullchem
working set derived from an official run directory — **30.2 GiB, 485 objects, 57
families**, 7.4× TT — lith reads the whole set in 49.8 s to FSx's 113.8 s, and that
**≥2.29×** is a floor because FSx was ~57% pre-hydrated. On the fully-cold C180
restart (13.1 GB, the *only* resolution-dependent input) it is **4.92×**. The reason
is structural, not incidental: FSx hydrates from S3 at ~120 MB/s regardless of
concurrency, measured twice independently, so the bigger the cold working set the
worse it does (*Gate 4*).

Gate 4 also turned up an argument no measurement had reached before: **an FSx
S3-linked volume is a point-in-time snapshot, and lith reads live S3.** The five GMI
alias objects this project has a recorded workaround for exist in `s3://gcgrid`
(2026-09-12) but are permanently invisible on the `/input` volume created 2026-06-28
with `AutoImportPolicy: NONE`. lith serves them today, which deletes the `GMI_OVL`
overlay hack rather than porting it.

**The last open question — does fullchem's read pattern get *correct bytes* through
lith — is now answered, and the answer is yes, to the bit.** C24 fullchem, 48 ranks,
one simulated day, the same run directory pointed first at lith and then at FSx:
`md5(gcchem_internal_checkpoint)` is **`f3dd15b2191bbce63dadcbfc100196a6` on both
arms** (*Gate 5*). A completion would have proved nothing — a FUSE layer returning
subtly wrong bytes still writes a file — so the gate was defined on byte-identity
from the start. Fullchem's per-family byte behaviour differs sharply from TT's, and
that is where the remaining engineering interest is: **HEMCO is the amplifier at
2.46×**, against 1.21× for met and 1.04× for the restart.

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
2. ~~**Per-node mount vs `lith serve nfs`.**~~ **MEASURED 2026-09-17, then RE-MEASURED
   on lith v1.1.2 2026-09-18 — see *Gate 2 results* and *Gate 2, part two* below.
   Per-node mounts are still the recommendation, but every reason given here for it
   turned out to be wrong.** On v1.1.1 the gateway could not run GCHP at all
   (ESTALE under concurrent GETATTR, reproduced standalone, root-caused upstream to
   `go-nfs-client`); **v1.1.2 fixes that and the gateway now completes 96-rank GCHP,
   in a dead heat with per-node mounts.** The "aggregate bandwidth grows with
   readers" premise never engaged either: reads are *not* centralised, so per-node
   mounts fetch the working set once per node — a byte argument *for* a gateway,
   opposite to the guess recorded here, though the measured saving is only **1.28×**
   rather than the ~2× that topology implies.

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
   **lith#233 is now MEASURED 2026-09-17 — see *lith#233 confirmation* below.
   Confirmed on 4 MB–1.17 GB met objects, and it does not bite us: GCHP never
   enters the regime the bug is about.**
4. **A/B control.** Keep one FSx `/input` run in the matrix. lith reached 1.0
   eleven days after its first commit and the read path is still moving — the
   detector rule and the fetch policy both changed after our measurements. The
   campaign is publication-bound; an input-layer change must not silently
   confound comparisons with existing numbers, and the lith version must be
   recorded with every run.
5. ~~**Working-set scale.**~~ **MEASURED 2026-09-18, head node only, no spend — see
   *Working-set scale* below. The cold advantage grows: 1.73× (C24 TT) → ≥2.29×
   (30.2 GiB fullchem manifest, a floor because FSx was ~57% pre-hydrated) → 4.92×
   (fully-cold C180 restart).** The planned C24→C90→C180 ladder turned out to be
   unnecessary rather than merely slow: `grep -icE "c24|c48|c90|c180" ExtData.rc`
   returns **0**, so every resolution reads the same input bytes and only the restart
   file scales. Mechanism (7.4×) dominates resolution (~1.4×). Also found: the FSx
   S3-linked mirror is a point-in-time snapshot and cannot see objects added to
   gcgrid after its creation, which lith can.
6. ~~**fullchem correctness.**~~ **MEASURED 2026-09-18 — PASS, see *Gate 5* below.**
   C24 fullchem, 48 ranks, 1 simulated day, one run directory pointed at lith and then
   at FSx: `md5(gcchem_internal_checkpoint)` identical
   (`f3dd15b2191bbce63dadcbfc100196a6`), 144/144 timesteps both arms, zero read errors.
   The gate was deliberately defined on byte-identity rather than completion. New
   finding: **HEMCO is fullchem's read amplifier at 2.46×** (met 1.21×, restart 1.04×,
   overall 1.79×), driven by a 783/4750 prefetch hit rate on small scattered emissions
   hyperslabs. Remaining: fullchem at C180 and fullchem multi-node, both folded into
   the campaign run at zero marginal cost.

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

### The headline: the shared gateway cannot run GCHP — *on v1.1.1*

> **Superseded for v1.1.2.** Everything in this section is a true record of lith
> v1.1.1. The gateway failure was root-caused upstream to `go-nfs-client` and fixed;
> see *Gate 2, part two* below, where the same harness on v1.1.2 runs the gateway to
> 144/144 and the race is a dead heat.

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

From the outside this looked like a file-handle→object mapping that does not
survive concurrent GETATTR — a bounded/recycled handle table or a racy lookup —
which the numbers located rather than the code, since lith's internals were not
read here.

**That inference was wrong, and it is the only part of this section that was.**
Root-caused upstream within the hour (lith#244), from the categorized STALE logging
that was asked for here and shipped in lith#245:

- lith's handles are **computed**, not tabled — `(sha256[:8] of index, inode)`, 16
  bytes, no table, no eviction, no lock. So there is nothing to exhaust or recycle.
- The handler is `-race`-clean at 96 goroutines × 200 `ToHandle`→`FromHandle`
  round-trips, with **zero** STALE. lith provably emits correct handle bytes.
- The logged failures are `inode not found` and `root id mismatch`, never
  `bad length`, and the handles arrive with **4-byte-word-level corruption of the
  tail** — inode low word zeroed, inode fully zeroed, or root-id low word zeroed.
- So the corruption appears strictly on the **wire round-trip**: it is in
  `go-nfs` v0.0.4's opaque-handle XDR encode/frame/decode, not in lith. Leading
  suspect is the multi-entry response path (READDIRPLUS packs a filehandle per
  entry) mis-framing under load, which the client then caches and replays on
  GETATTR — consistent with GETATTR-only failures whose rate tracks GETATTR volume.

Two lessons worth keeping. First, **the measurements all held and only the
mechanism guess failed** — which is the argument for labelling inference as
inference rather than dropping it: the wrong-but-explicit guess is what made the
diagnostic ask concrete. Second, `serve nfs` is now documented with a **~32-reader
ceiling** (`docs/serving-a-cluster.md`), so the envelope is bounded even though
`go-nfs` v0.0.4 is the newest tag and there is nothing to bump to yet. #244 stays
open pending that upstream fix.

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
traffic. On byte volume that is an argument **for** a shared gateway, the opposite of
what this gate predicted.

> **Correction (2026-09-18).** The original text here said "~8.3 GB for a 3.3 GB
> distinct working set", implying the gateway would roughly halve S3 bytes. That
> 3328 MB was `distinct_bytes_read` at **48 ranks on one node** (gate 3c) — a
> per-node logical measure, not the 2-node distinct set, so it should not have been
> used as one. Directly measured on v1.1.2, one gateway serving both nodes fetches
> **6443.8 MB against the mounts' 8277.8 MB: a 1.28× saving, not ~2×.** See *Gate 2,
> part two*.

Two reasons it does not change the recommendation:

- The gateway is unavailable anyway until the ESTALE defect is fixed. *(No longer
  true as of v1.1.2.)*
- The duplication is economically ~free: in-region S3 → EC2 transfer costs nothing,
  and the request cost is ~3800 GETs per node per run, i.e. **fractions of a cent**.
  It duplicates bytes that were never billed.

It would start to matter at high node counts on a metered path (cross-region, or a
requester-pays bucket), which is the condition under which the gateway is worth
revisiting.

### Verdict (v1.1.1 — superseded, see *Gate 2, part two*)

**Use per-node lith FUSE mounts. Do not use `lith serve nfs` for GCHP.** Not
because it is slower — that race was never run — but because it cannot complete an
init at 96 ranks. Per-node mounts, meanwhile, ran multi-node GCHP to completion at
96 ranks across 2 nodes, twice, with zero read errors and zero fallbacks, which is
the first multi-node confirmation of the gate 3c result.

Reported upstream on lith#210 (multi-node results and both corrections) and filed
as lith#244 with the standalone repro and the threshold table. Both are answered:
#244 is root-caused to `go-nfs`, and lith#245 ships the two asks made here
(categorized STALE logging, and a documented concurrency ceiling).

## Gate 2, part two — lith v1.1.2 fixes it, and the race finally ran (2026-09-18)

v1.1.2 carries the `go-nfs-client` `ReadOpaque` short-read fix. Upstream verified it
with single-host `dd` and explicitly could not reproduce a real MPI client, so the
96-rank answer was only available here.

### The head-node control: clean sweep

`LITHVER=1.1.2 scripts/lith/gate2-nfs-errno-probe.sh`, same ladder, same
`noac,actimeo=0`:

| concurrent readers | v1.1.1 | **v1.1.2** |
|---|---|---|
| 32 | 0 / 640 | 0 / 640 |
| 48 | 63 / 960 (6.6%) | **0 / 960** |
| 64 | 221 / 1280 (17.3%) | **0 / 1280** |
| 96 | 304 / 1920 (15.8%) | **0 / 1920** |
| 128 | 542 / 2560 (21.2%) | **0 / 2560** |

Zero failures across 7360 reads and 51298 GETATTRs. Wall time per rung is
unchanged (0.64 s vs 0.60 s at C=48), so v1.1.1's failing reads were failing
*fast* and the ladder timings were never a proxy for correctness.

(The `gw_threads`/`gw_fds` columns are blank in this artifact: the head node still
had the pre-fix copy of the probe with the hardcoded `pgrep -f 'lith-1.1.1 serve'`
pattern, so the pid resolution returned empty again. Diagnostic columns only — the
failure counts are unaffected. The `ss`-based fix is in the repo copy and is
unvalidated by a run.)

**The new per-op counters (lith#248) also settle the question raised on #244:**

```
lith_nfs_ops_total{op="getattr"} 51298     lith_nfs_ops_total{op="lookup"} 2
lith_nfs_ops_total{op="read"}     7360     lith_nfs_ops_total{op="access"} 5
lith_nfs_ops_total{op="unparsed"}     3     (no readdir/readdirplus counter at all)
```

**READDIRPLUS was served zero times and LOOKUP twice**, against 51298 GETATTRs — so
the multi-entry-framing hypothesis could not have been the carrier in this repro,
and the per-request `ReadOpaque` short read that upstream actually found is the
shape the data supported. Worth noting `unparsed = 3` is nonzero: that counter is
the canary for go-nfs changing its trace format, and it sits at a low constant
rather than zero.

### The headline: one shared gateway now runs 96-rank GCHP to completion

Job 9, two `c8g.48xlarge`, 96 ranks at 48/node, C24 TransportTracers, lith v1.1.2,
both arms in the **same job** on the **same nodes** — which is the only honest way
to run a race that previously never started.

| arm | init | to sim end | wall | steps | |
|---|---|---|---|---|---|
| `mount-r1` — per-node FUSE, 5 daemons × 2 nodes | 34.72 s | 72.72 s | 73.8 s | 144/144 | ✅ |
| `nfs-r1` — **one shared `lith serve nfs`** | 35.20 s | **69.20 s** | 70.7 s | 144/144 | ✅ |

On v1.1.1 the `nfs-r1` arm aborted 4 s in. **Zero STALE anywhere** — the only lines
in all five gateway logs are two benign `No handler for 100227.0` NFS_ACL probes
each, now routed through lith's slog as JSON (the lith#248 bonus, visible working).

**Gate 2's original prediction is refuted on performance as well as on premise.**
The prediction was that per-node mounts would win at 48–192 ranks because
"aggregate bandwidth grows with readers, no shared lock." The measured race is a
dead heat: the gateway is 0.48 s slower to init and 3.52 s *faster* to sim end.
There is no meaningful difference at this scale.

### Correction: the gateway's byte win is 1.28×, not ~2×

This is a correction to what this document and lith#210 both claim, and it matters
because upstream re-prioritised #244 partly on the strength of my number.

| arm | fetched from S3 |
|---|---|
| `mount-r1` node 1 | 4149.1 MB |
| `mount-r1` node 2 | 4128.7 MB |
| `mount-r1` **total** | **8277.8 MB** |
| `nfs-r1` single gateway | **6443.8 MB** |

The gateway saves **22.2% of bytes (1.28×)** — not the ~2× that "both nodes fetch
the whole working set" implies. Where the earlier "8.3 GB for 3.3 GB distinct"
framing went wrong: 3328 MB was `distinct_bytes_read` measured at **48 ranks on one
node** (gate 3c), and using it as the 2-node distinct set conflated a per-node
logical measure with a cluster-wide one. The gateway measurement is the better
instrument, and it says duplication is 1.28×.

Note the gateway fetched **1.57×** what a single node fetches alone (4105.4 MB at
gate 3c), when perfect dedup would be ~1.0×. Cache pressure does not explain it:
the bulk MERRA-2 daemon ran `--mem-cache 32GB` against a ~3.3 GB working set.
**Inference, flagged as such:** with 96 ranks initialising in a burst, both nodes
request the same ranges near-simultaneously, so absent in-flight request
coalescing (single-flight) each collision becomes its own S3 GET. If that is right,
most of the gateway's remaining byte advantage is being left on the table — which
is precisely the regime (cross-region, requester-pays, high node counts) where the
gateway is worth having.

> **That inference was wrong, and measuring it changed what the 1.28× means — see
> *Gateway dedup is exact* below.** The gateway already single-flights across
> connections. The residual is the workload's access geometry, not a missing
> feature.

### Gateway dedup is exact; the 1.28× is workload geometry — measured 2026-09-18

Upstream corrected the single-flight guess (the block store de-dupes concurrent
fetches keyed by `(key, etag, chunk)`, and one gateway is one block store) and
offered two alternatives: either 96 ranks genuinely touch a larger distinct set than
48, or there is a coalescing-window gap. **Both are decidable on the head node for
$0**, using one trick: point **two NFS clients at one gateway and have them read the
identical list**. Identical lists fix the distinct set by construction, so any excess
over a one-client baseline is coalescing alone. (`nosharecache` on the second mount
is load-bearing — otherwise the Linux client shares one superblock and the second
reader never reaches the gateway.)

| arm | client bytes | gateway → S3 | GETs | ampl |
|---|---|---|---|---|
| MERRA-2 July 2019, 217 files, one client | 90.7 GiB | **97360.3 MB** | 13136 | 1.000× |
| same list, two clients, lockstep | 2 × 90.7 GiB | **97367.6 MB** (+0.008%) | 13143 | 1.000× |
| one day, 7 files, 2.93 GiB, one client | 2.93 GiB | **3143.3 MB** | 424 | 1.000× |
| same day, two clients, in phase | 2 × 2.93 GiB | **3143.3 MB** | 424 | 1.000× |
| same day, two clients, **file order reversed** | 2 × 2.93 GiB | **3143.3 MB** | 424 | 1.000× |
| same day, two clients, **disjoint 8 MiB blocks** | 2.93 GiB interleaved | **3143.3 MB** | 679 | 1.000× |
| one 287.8 MiB file, **disjoint 64 KiB extents**, one client | 301.7 MB | **301.7 MB** | — | 1.000× |
| same file, two clients, **disjoint 64 KiB extents** | 301.9 MB | **301.7 MB** | — | 1.000× |

The day-set arms are scoped to 2.93 GiB against `--mem-cache 8GB` on purpose, so
capacity eviction cannot masquerade as a coalescing failure. Three independent ways
of breaking alignment — same-range collision, temporal phase divergence, and
disjoint interleaved sub-file ranges — and the fetch set comes back **byte-identical
to the MB**. The last arm is the one that matters, because disjoint sub-file ranges
are the shape pFIO actually produces; it costs more, smaller GETs (424 → 679) and
more uncovered prefetch (53 → 343), which is lith#229/#233 behaving as
characterised, but not one duplicate byte.

The last two rows close the sub-chunk case upstream raised on lith#250: two clients
reading **alternate 64 KiB extents inside shared 1 MiB chunks** — the granularity
where a chunk-keyed cache could plausibly fetch the same chunk twice for two
different sub-ranges — still pull the object exactly once (301.7 MB = the file), and
the two-client arm finishes *faster* (1.66 s vs 2.75 s) because more concurrency
drives the same single fetch set. Dedup is by chunk, and the chunk is the fetch unit,
so sub-chunk disjointness never reaches S3 twice.

If dedup is exact, the gateway's fetch set *is* the union of the two nodes' demand,
and the mount arm measured each node separately — so the overlap is solvable:

```
node 1 alone         4149.1 MB
node 2 alone         4128.7 MB
sum                  8277.8 MB
gateway (= union)    6443.8 MB
overlap              1834.0 MB   = 44.3% of a node's set
unique to each node ~2300    MB
dedup achieved          1.285x   = sum / union
```

**The two nodes overlap on less than half of what each fetches** — which is what
domain decomposition predicts. pFIO gives each rank its own subdomain, ranks on
different nodes want different byte ranges of the same objects, and per-connection
readahead rounds each node's ranges up to blocks. There is little duplicate demand
*to* remove, so 1.28× is near the geometric ceiling at two nodes rather than a
half-realised 2×.

**Consequence for how a shared gateway should be pitched, ours included:** dedup ≈
Σ(per-node demand) / union(demand), a property of the *workload's* access geometry,
not of lith. "One gateway fetches the working set once" is true for N readers that
each want the whole set, and false for MPI subdomain readers, where the saving is
bounded by the *shared* fraction (the global fields every rank needs). So the
gateway's byte case for GCHP is real but small, and it does not improve with node
count the way 1/N framing suggests.

Two caveats on the arithmetic, which is inference, not measurement: it assumes each
node's gateway-side demand equals its mount-side fetch set (readahead is
per-connection and a gateway's budget is shared, so they need not be identical —
settling it needs `distinct_bytes_read` *and* `s3_bytes` scraped from the gateway —
see immediately below, that is not currently possible); and both coalescing clients
ran on one host over loopback, so cross-host dedup is assumed rather than shown.

**`lith_distinct_bytes_read` is not wired into the `serve nfs` path**, which is why
the arithmetic above has to stay inference. Same object, same `dd … bs=4M` to EOF,
one path apart:

| path | `distinct_bytes_read` | `s3_bytes_total` | `cache_misses_total` |
|---|---|---|---|
| `serve nfs` (gateway, read over NFS) | **0** | 301740437 | 8 |
| `mount` (FUSE) | 301793280 | 301740437 | 43 |

It is exported in gateway mode and never advances, so scraping it there returns a
plausible-looking zero rather than an error — the shape that misleads, because
`s3_bytes / distinct_bytes` computes as an amplification of *zero* for exactly the
question it would be used to answer. Reported upstream on lith#250; until it lands,
gateway-side amplification is only obtainable by differencing separate per-node mount
runs, which is what we did.

Harnesses: `scripts/lith/coalesce-probe.sh`, `coalesce-phase.sh`,
`coalesce-interleave.sh`, `coalesce-extent.sh`. Raw:
`data/lith-gates/gateway-coalescing.txt`.

### One unexplained observation, n=1

`mount-r1` init was **34.72 s** here against **41.43 s** and **41.88 s** on v1.1.1
in two earlier jobs that agreed to ~1 s. That is well outside prior
reproducibility. v1.1.2 contains nothing that obviously touches the FUSE path, so
this may be between-job variation (different physical hosts, S3 weather) rather
than a lith improvement. **Not claimed as a win** — it needs a repeat before it
means anything.

### Revised verdict

**Per-node FUSE mounts remain the recommendation, but no longer because the
gateway is broken — now purely because it is one less moving part.** Both
topologies complete 96-rank GCHP and neither is meaningfully faster. The gateway
becomes the better choice when bytes are metered (cross-region, requester-pays) or
at node counts where 1.28× duplication is real money. That case will not strengthen
with a lith fix: dedup is already exact, so 1.28× is the workload's ceiling at two
nodes, not a half-realised 2×.

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

## Working-set scale — does the cold advantage survive fullchem? Measured 2026-09-18

> Harness files are named `gate4-*`; numbered gate 4 in the list above is the
> unrelated A/B control. This is the working-set-scale gate, listed as item 5.

This document's Summary named one remaining unknown: every number in it was C24
TransportTracers (~4.1 GB, a handful of input families), and it said the 1.73× cold
advantage "grows, holds, or inverts" at fullchem scale was untested and "the one
thing that could still change this recommendation." **It grows.** All of gate 4 ran
on the standing head node: no compute nodes, no MPI, no spend.

### First, the premise: there is no ladder to climb

The plan was C24 → C90 → C180. That plan was based on a wrong assumption, and
checking it cost one `grep`:

```
$ grep -icE "c24|c48|c90|c180" ExtData.rc
0
```

**GCHP's inputs are cubed-sphere-resolution-independent.** MAPL/ExtData regrids met
and emissions online from their native lat-lon grids, so `createRunDir.sh` has no
resolution prompt at all — `CS_RES` is set afterwards in `setCommonRunSettings.sh`.
The *only* resolution-dependent input byte is the restart file:

| restart (fullchem, 20190701) | size |
|---|---|
| c24 | 710 MB |
| c48 | 1.30 GB |
| c90 | 5.45 GB |
| **c180** | **13.1 GB** |

So the two axes are not comparable in size, and only one of them needed a
measurement:

- **mechanism** TT → fullchem: ~4.1 GB → **30.2 GiB**, ~**7.4×**
- **resolution** C24 → C180: + 12.4 GiB of restart, ~**+40%**

A C90 rung would have read *identical* input bytes to C24 for all 57 families and
differed only in a single file whose whole size curve was already available from
`s3 ls`. One fullchem run directory therefore serves every resolution, and the right
move was to jump — not out of impatience, but because the intermediate rung carries
no information.

### The manifest: derived from an official run directory, and labelled INFERRED

Per CLAUDE.md, no hand-rolled run directory: `scripts/lith/mk-fullchem-rundir.expect`
drives GCHP's own `createRunDir.sh` (fullchem, MERRA-2 **0.5x0.625** — the same met
option the existing TT run dir used, so the comparison varies the mechanism and not
the met resolution). `scripts/lith/gate4-fullchem-manifest.py` then parses
`ExtData.rc` + `HEMCO_Config.rc`:

```
ExtData tpls : 231
HEMCO   tpls : 322   (extensions off: 100 104 107 108 125 126 130 131)
objects      : 485
total bytes  : 32409726478 (30.2 GiB)
families     : 57
unresolved   : 29
```

This is an **INFERRED** manifest and an **upper bound** on files: HEMCO decides at
runtime which entries it actually opens, and my `$YYYY` fallback rule ("nearest year
present on disk") is mine, not HEMCO's. A MEASURED list would come from `HEMCO.log`
of a real run, which costs a compute node. Neither caveat can bias the layer
comparison, because **the same manifest is read through both layers** — manifest
error is common-mode. Sizes came from `stat()` on the FSx mount, which carries S3
metadata without hydrating content: zero bytes, zero GETs.

Largest families are `HEMCO/GMI` (11.4 GiB, 117 obj), `GEOS_0.5x0.625` (6.0 GiB,
13 obj), `HEMCO/CEDS` (5.4 GiB, 40), `HEMCO/EDGARv43` (3.1 GiB, 56).

### Results

Whole-file sequential reads, 8 concurrent readers, page cache dropped between arms.
lith ran **first** deliberately: the FSx cold arm is **one-shot by physics** —
reading a `released` file hydrates it permanently and there is no un-hydrate — so
the repeatable arm shakes out harness bugs before the single-use one is spent.

| | prior C24 TT | **fullchem manifest** | **C180 restart** |
|---|---|---|---|
| working set | ~4.1 GB, few families | 30.2 GiB, 485 obj, 57 families | 13.1 GB, 1 file |
| lith cold | — | **49.75 s / 651.5 MB/s** (8066 GETs, ampl **1.000×**) | **23.53 s / 556.9 MB/s** (1577 GETs = 8.3 MB/GET) |
| lith cold, repeat | — | **48.13 s / 673.4 MB/s** (8073 GETs) | — |
| FSx cold | — | 113.80 s / 284.8 MB/s (**~57% pre-warm**) | 115.73 s / 113.2 MB/s (`released`, verifiably cold) |
| **lith advantage** | **1.73×** (init) | **≥ 2.29×** (floor) | **4.92×** |

lith reproduces to 3.3% (49.75 s vs 48.13 s, same bytes to the 0.1 MB) — worth
having, since every other arm in this gate is n=1.

Fetch amplification is **1.000×** on the manifest: whole-file sequential reads
fetch exactly the working set, no waste. (Gate 3c's 1.31× was GCHP's *hyperslab*
pattern, which is a different question.)

### The FSx arm was not fully cold, so 2.29× is a floor, not a measurement

`lfs hsm_state` on a 60-file sample before the arm: 24 `released` (cold), 36
`archived` without `released` (already hydrated by earlier work). The `df` delta
across the arm — 86 G → 99 G — says only **~13 GiB of the 30.2 GiB came from S3**;
the other ~17 GiB was served off Lustre disk. **FSx got a 57% head start and still
lost by 2.29×.**

I sampled 60 of 485 files before spending the one shot, so the full pre-state is now
unrecoverable. Reporting 2.29× as a floor is the honest form.

Decomposing it anyway (EXTRAPOLATED, flagged): ~13 GiB from S3 in ~113.8 s is an
FSx hydration rate of **~120 MB/s**. That figure is independently corroborated by
the restart arm, where a verifiably-`released` file hydrated at **113.2 MB/s**. At
that rate a fully-cold FSx would have needed ~260 s for the manifest, putting the
true advantage near **5×** — which is exactly what the fully-cold restart arm
measured (4.92×). Two independent arms converging on the same FSx ceiling is the
strongest thing in this gate.

**lith's numbers are floors too.** 651–673 MB/s is 5.2–5.4 Gbps on a `c7g.4xlarge`
whose baseline is 7.5 Gbps, so lith was running at ~72% of the instance's network
allowance. On a compute-class node the gap would likely be wider, not narrower.

### A new argument that no measurement had surfaced: the FSx mirror is stale by construction

The manifest's 29 unresolved entries include the five GMI aliases this project has
a recorded trap for (`IPMN`, `NPMN`, `RIPA`, `RIPB`, `RIPD`, ~99 MB each). They are
absent from `/input`. They are **present in `s3://gcgrid`**:

```
2026-09-12 10:44:38   99698098 HEMCO/GMI/v2015-02/gmi.clim.IPMN.geos5.2x25.nc
2026-09-12 10:44:39   99698098 HEMCO/GMI/v2015-02/gmi.clim.NPMN.geos5.2x25.nc
2026-09-12 10:44:40   98272423 HEMCO/GMI/v2015-02/gmi.clim.RIPA.geos5.2x25.nc
2026-09-12 10:44:40   98272423 HEMCO/GMI/v2015-02/gmi.clim.RIPB.geos5.2x25.nc
2026-09-12 10:44:41   98272423 HEMCO/GMI/v2015-02/gmi.clim.RIPD.geos5.2x25.nc
```

`/input` is `fs-0804c4d8e01897d21`, ImportPath `s3://gcgrid`, created **2026-06-28**,
`AutoImportPolicy: NONE`. The aliases landed in the bucket on **2026-09-12**. **An
FSx S3-linked volume is a point-in-time snapshot; lith reads live S3.** Those objects
are permanently invisible on this Lustre volume without re-creating it or enabling
AutoImport.

**Measured through lith, not assumed (2026-09-18, head node, $0).** A fresh index
over the same prefix — built at test time, because a stale index would hide new
objects exactly the way a stale FSx does — and a 4-byte header read on each file,
since appearing in a listing is not the same as being readable:

| file | FSx `/input` | lith | size | header |
|---|---|---|---|---|
| `gmi.clim.IPMN…` | absent | **present** | 99698098 | HDF5 magic |
| `gmi.clim.NPMN…` | absent | **present** | 99698098 | HDF5 magic |
| `gmi.clim.RIPA…` | absent | **present** | 98272423 | HDF5 magic |
| `gmi.clim.RIPB…` | absent | **present** | 98272423 | HDF5 magic |
| `gmi.clim.RIPD…` | absent | **present** | 98272423 | HDF5 magic |
| `gmi.clim.PMN…` (base) | present | present | 99698098 | HDF5 magic |
| `gmi.clim.RIP…` (base) | present | present | 98272423 | HDF5 magic |

Each alias matches its base file's size to the byte, consistent with the S3-side
copies the recorded fix called for.

This inverts the recorded GMI trap: the `GMI_OVL` overlay hack exists to work around
FSx-from-S3 not carrying the aliases, and adopting lith **deletes** that workaround
rather than porting it. It also sharpens the freshness axis from a nice-to-have into
the deciding constraint for this run directory: fullchem references all five, so
against this `/input` it **cannot run at all** without building the overlay, and
through lith it runs with no workaround. TransportTracers — everything else in this
analysis — never touches GMI, which is why the gate-3 and gate-2 runs never hit it. (14.7.1 fullchem uses `v2015-02`, confirmed from the run
directory, so the separate `v2022-11` missing-NPMN hazard does not apply here.) The
other 10 unresolved entries — APEI, DICE_Africa ×5, FINNv25, HTAPv3 ×2, SOA/NVOC —
are absent from gcgrid itself, so they are common-mode and say nothing about either
layer.

### Verdict

**lith's cold advantage grows with working-set scale: 1.73× at C24 TT → ≥2.29× on
the 30.2 GiB fullchem manifest → 4.92× on the fully-cold C180 restart.** The one
thing that could have changed the recommendation instead reinforced it, and it did so
for a structural reason rather than a lucky benchmark: FSx hydration is rate-limited
at ~120 MB/s regardless of concurrency, so the larger the cold working set, the worse
it does. Fullchem at C180 is the largest cold working set this workload has.

**Still not measured *here*:** an actual fullchem *simulation* through lith. Gate 3c
proved correctness for TT at 48 and 96 ranks; nothing in this section re-proves it for
fullchem's different read pattern. The recommendation is **not** to buy a C180 fullchem
run for lith — it is to mount lith as `/input` in the C180 fullchem run already
scheduled in the scaling campaign, where the marginal cost is zero. If an earlier
correctness signal is wanted, C24 fullchem on one node is cheap.

> **Taken up immediately, because it was cheap: see *Gate 5* below.** C24 fullchem on
> one node cost ~25 minutes of one `c8g.48xlarge` and returned a byte-identical
> checkpoint. The C180 recommendation is unchanged — fold it into the campaign run —
> but it is now a scale confirmation rather than the first correctness evidence.

## Gate 5 — fullchem correctness through lith, decided by checkpoint MD5 (2026-09-18)

Everything before this gate ran **TransportTracers**. TT never touches GMI, never
loads a chemistry mechanism, and reads a far narrower emissions set, so none of it
speaks to fullchem's read pattern. This gate closes that.

**The test is a byte-identical checkpoint, not a completion.** "It ran and looked
plausible" is not a correctness result: a FUSE layer that returned subtly wrong bytes
would still produce a file, and the model would still march 144 timesteps. So both
arms run the **same run directory** — same binary, same config, same restart, same
48-rank layout, same 1 simulated day — differing only in where input comes from, and
the gate passes only if `md5(Restarts/gcchem_internal_checkpoint)` matches.

`scripts/lith/gate5-fullchem-ab.sbatch` (+ `gate5-fullchem-prep.sh`), lith v1.1.2,
`c8g.48xlarge`, C24 fullchem, NX=2 NY=24 = 48 ranks, 2019-07-01 → 07-02.

### Result: PASS

| arm | input | init | to sim end | to completion | `cap_restart` | checkpoint md5 |
|---|---|---|---|---|---|---|
| **lith** | live `s3://gcgrid`, 5 mounts | 188.98 s | 375.98 s | 397.2 s | `20190702` | `f3dd15b2…96a6` |
| **fsx** | `/input` + `GMI_OVL` overlay | 81.05 s | 254.05 s | 274.9 s | `20190702` | `f3dd15b2…96a6` |

**`f3dd15b2191bbce63dadcbfc100196a6` on both arms.** 144/144 timesteps each. Zero
read errors, zero fallbacks. Fullchem's chemistry is bit-reproducible over lith.

This is the first fullchem GCHP simulation run with its entire input tree on object
storage, and it is the first arm where lith's advantage is **not** a performance claim
at all — it is that the FSx arm **cannot run without a workaround lith does not need**.
Building the `GMI_OVL` overlay was a prerequisite for the control arm — a 3-level
symlink farm, **226 symlinks + 5 real files, 494.3 MB of duplicated GMI objects**,
which themselves had to be copied *through lith* because they exist nowhere on Lustre.
The lith arm read the same five aliases straight from live gcgrid with no overlay at
all. (Counts verified on the head node after the run, not from the script's own echo.)

### The timings are recorded, not claimed

The 189 s vs 81 s init gap is **not** a cold-vs-cold comparison and must not be read as
one: this gate did not control FSx HSM residency (no `lfs hsm_release`, no
`hsm_restore`), the lith arm mounted fresh with an empty cache every job, and the FSx
met tree had been read by earlier work. Gate 3c and Gate 4 are where the controlled
temperature comparisons live. What *is* meaningful here is that **sim-only wall is a
dead heat**: 187.0 s (lith) vs 173.0 s (FSx), 1.08×. The whole difference sits in
init, which is where every previous gate found it too.

### Where fullchem's bytes actually go — HEMCO, not met

Per-mount, over the whole lith run:

| mount | from S3 | distinct | ampl | GETs | prefetch used/issued | uncovered |
|---|---|---|---|---|---|---|
| MERRA-2 2019/07 | 3936.6 MB | 3254.3 MB | **1.21×** | 3550 | 2355/2951 | 3138 |
| **HEMCO** | **9086.9 MB** | **3698.2 MB** | **2.46×** | 8089 | **783/4750** | 7260 |
| restart | 796.7 MB | 767.3 MB | 1.04× | 109 | 716/744 | 16 |
| CHEM_INPUTS | 4.4 MB | 5.6 MB | — | 78 | 0/2 | 76 |
| MERRA-2 2015/01 (CN) | 0.8 MB | 0.9 MB | — | 1 | 0/0 | 1 |
| **total** | **13825.4 MB** | **7726.2 MB** | **1.79×** | 11827 | | |

(The two sub-1.0 rows are chunk-granularity artifacts — `distinct_bytes_read` rounds
up to the 1 MiB chunk while `s3_bytes_total` is the actual transfer — and are too
small to move the total.)

**HEMCO is where lith's read amplification lives in fullchem, and its prefetcher is
the reason.** HEMCO moves 2.3× the met mount's bytes from S3 while wanting a
*smaller* distinct set, and its prefetch hit rate is **783 used of 4750 issued with
7260 uncovered** — against met's 2355/2951. Emissions files are small (~13 MB) and
read as scattered hyperslabs across dozens of families per timestep, so the
read-ahead window is repeatedly established and then abandoned. Met, which is large
and read in bigger contiguous runs, prefetches well.

That reframes gate 3b's finding rather than contradicting it: 3b predicted HEMCO was
the regime where lith would look worst, and at fullchem's family count that
prediction lands — as **bytes**, not as wall time. In-region S3→EC2 bytes are free
and 11827 GETs is $0.005, so this costs us nothing today; it matters as the one
concrete read-pattern improvement left on the table, and it is worth filing upstream
with these counters.

### Five harness traps, all of which cost real node time

Four jobs failed before job 14 passed, for reasons worth recording — none of them
lith's, all of them harness or GCHP-config:

1. **`lith mount --daemon` daemons survive `scancel`.** Daemonizing detaches from the
   Slurm cgroup, so the next job silently inherits stale mounts. Job 13's lith arm
   got "Permission denied" from `mkdir` on live mountpoints, five "daemon failed to
   start", then **counted the five stale mounts as success** and ran GCHP against dead
   daemons — dead in 10 s. Fix: unmount + `pkill` before mounting, and verify each
   daemon *answers on its metrics port* rather than counting `mount` entries.
2. **The harness manufactured a scientific claim out of its own breakage.** With the
   lith md5 the literal string `"n/a"`, the verdict logic printed **"FAIL —
   checkpoints DIFFER"**. A non-completion was reported as a correctness failure. Fix:
   blank `"n/a"` before comparing and report INCONCLUSIVE. A harness must not be able
   to produce a result it did not measure.
3. **`TOTAL_CORES` is a third independent knob**, not derived from `NUM_NODES` ×
   `NUM_CORES_PER_NODE`. Job 11 died silently because it was still 96.
4. **Never discard the GCHP setup scripts' output.** Job 11's cause —
   `ERROR: TOTAL_CORES must equal to NUM_NODES times NUM_CORES_PER_NODE` — was
   printed correctly by `setCommonRunSettings.sh` and thrown away by
   `>/dev/null 2>&1`. The official tooling had diagnosed it; the harness hid it.
5. **`Run_Duration` is `"YYYYMMDD HHmmSS"`.** The run directory default
   `"00000100 000000"` is **one month**, not one day. Job 12 ran a projected 1:29:36
   per arm against a 1:30 wall limit. (It did establish, before being cancelled, that
   fullchem runs through lith at all: 254 timesteps, 1.75 sim-days, 148 GB high-water,
   zero read errors.)

Job 10 additionally proved the entry-point preflight earns its keep: `/input-lith` is
**node-local**, the `mkdir` had been moved into head-node prep, and all five daemons
failed on a missing mountpoint — caught *before* `mpirun`, so no model time burned.

Total gate cost: ~25 min of one `c8g.48xlarge` across five submissions.

### Verdict

**Gate 5 passes on its own terms.** fullchem is bit-identical over lith at 48 ranks,
so the input-layer recommendation now rests on correctness evidence for **both**
mechanisms rather than TT alone. The two things still not measured are fullchem at
**C180** and fullchem **multi-node** — and the standing recommendation covers both at
zero marginal cost: mount lith as `/input` in the campaign's scheduled C180 fullchem
run and compare checkpoints there.

## lith#233 confirmation — the cold-sequential first-block tax, measured 2026-09-17

Head node only, no cluster spend. `scripts/lith/gate233-block0-probe.sh`, lith
v1.1.1, real gcgrid MERRA-2 objects from `GEOS_0.5x0.625/MERRA2/2019/01`, fresh
cold mount and dropped page cache for **every** rung.

**Verdict: lith#233 is real, reproduced exactly, and irrelevant to GCHP.** The
mechanism is confirmed to the GET; the cost decays with size as claimed; and the
reason it does not bite us is that GCHP never reaches the regime where the tax is
an *extra* cost.

### The mechanism, confirmed to the GET

A 1 MiB-stepped ladder across the first-block boundary of a 1168.4 MB object,
`dd bs=128k`:

| first N MiB read | GETs | MB from S3 | prefetch issued |
|---|---|---|---|
| 7 | 7 | 7.0 | 0 |
| **8** | **8** | **8.0** | **0** |
| **9** | **9** | **9.0** | **264** |
| 10 | 10 | 10.0 | 264 |
| 12 | 22 | 116.0 | 264 |
| 16 | 47 | 272.0 | 272 |
| 24 | 50 | 288.0 | 280 |

This is #233 exactly as described. The first 8 MiB costs **8 GETs where 1 would
do** — one 1 MiB GET per 128 KiB×8 of reading, no coalescing at all — and
`prefetch issued` stays at **0** for the whole of block 0. It becomes 264 at
**N=9**, the first read that crosses into block 1. Establishment requires a
block-advance, so it cannot fire until the reader leaves block 0, and block 0 is
therefore paid for at 1 MiB granularity. The predicate is confirmed too: the FUSE
read-size histogram is `128K:513` for a 64 MiB read — 512 reads plus one, i.e.
**MaxWrite is pinned at 128 KiB**, so a sequential reader really does need ~64
reads to advance one 8 MiB block.

### Correction to my own first reading: the amplification is prefetch, not waste

The first run of this probe showed a 16 MiB read pulling **248 MB** from S3 and I
noted it as ~15× amplification that "no version of the #233 mechanism predicts".
That reading was wrong, and part B is what settles it — on reads that run to EOF,
bytes fetched land on the file size **exactly**:

| file | size MB | GETs | ideal | excess | excess % | MB from S3 | wall |
|---|---|---|---|---|---|---|---|
| `MERRA2.20190104.soil` | 4.3 | 5 | 1 | +4 | +400.0% | **4.3** | 0.53 s |
| `MERRA2.20190116.A1` | 292.5 | 51 | 37 | +14 | +37.8% | **292.5** | 1.59 s |
| `MERRA2.20190112.A3dyn` | 1168.4 | 161 | 147 | +14 | +9.5% | **1168.4** | 2.39 s |

Zero byte over-fetch. The 272–288 MB seen on the truncated rungs is the
read-ahead window doing its job for bytes my `dd` then declined to read — an
artifact of stopping early, not a defect. `prefetch_evicted_unread` cannot
corroborate that either way here, because the probe unmounts rather than evicting.
Note also that the truncated rungs are the only *non-reproducible* numbers between
the two runs (16 MiB: 42 GETs/248 MB vs 49/280) precisely because they sample an
async ramp mid-flight; every deterministic rung reproduced exactly.

So the real cost of #233 is **GET count and latency, not bytes** — which matters,
because in-region S3→EC2 bytes are free and GETs are $0.0004/1000.

### Size decay confirmed, but the constant is +14 GETs, not +7

The excess is **stable in absolute terms at +14 GETs** across a 4× size range,
which is what makes it decay as a percentage (+400% → +37.8% → +9.5%). Block 0
accounts for +7 of that. The arithmetic on both large files fits the first **two**
8 MiB blocks being fetched at 1 MiB granularity (16 GETs where 2 would do): for
the 292.5 MB file, 8 + 8 + 35 coalesced ≈ 51 observed. That is inference from GET
counts, not from reading lith's source — offered upstream as a hypothesis, not a
claim. It is a slightly larger constant than the +8 upstream measured on a 30 MB
object, so the ramp may not be size-invariant.

The wall cost is bounded the same way: block 0 moves 8 MiB at ~32 MB/s (0.25 s)
against 489 MB/s steady-state on the 1.17 GB read, so the tax is a **~0.23 s
fixed cold-start per object**. That is ~10% of a 1.17 GB read and over half of a
4.3 MB one — consistent with upstream's "+55% on 30 MB", and it explains the
decay without needing a second mechanism.

### Why it does not bite GCHP

From the committed gate 3c metric dump, over a **full GCHP init** on the MERRA-2
mount: `lith_s3_requests_total{get,ok} = 3647` for `lith_s3_bytes_total = 4105.4
MB`, i.e. **~1125 KB per GET**, with `lith_fill_runs_total = 0`.

GCHP runs at 1 MiB granularity for the *entire* init, not just for block 0. It
reads netCDF hyperslabs — 53% of each file, scattered — so the sequential
detector never establishes and no fill runs are ever issued. The block-0 tax is
not an *incremental* cost for GCHP; it is the whole cost model, and it is the one
lith already beat FSx cold by 1.73× while paying. Fixing #233 would speed up
whole-file sequential consumers (`cp`, `tar`, staging tools, and any pre-hydration
step) and would do nothing measurable for the model.

That is the useful conclusion for our architecture: **#233 needs no action from
us and should not gate the input-layer decision.** It would become interesting if
we ever add a bulk-staging path that reads whole met files start to finish.

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
