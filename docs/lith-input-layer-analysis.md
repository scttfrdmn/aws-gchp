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

*Gate 5b* then took that apart with a five-arm test on the HEMCO mount, and both
candidate mechanisms lost. It is not `parts-max` (my hypothesis: flat) and not
principally the readahead window (upstream's). It is **prefetch precision**: shrinking
the window 4× cuts the *volume* of bad prefetch almost linearly (4086 → 2044 MB) and
leaves the hit rate untouched at **13–16%**, against 80% on the met mount in the same
process. Because lith builds one prefetcher per `Open`, every one of ~2400–4600 decisions
is made cold. **Window tuning bottoms out at 1.895× and ~2.0 GB of the waste is
unreachable by any flag**, so the remaining prize needs cross-handle state, not
configuration. Sim wall was 186–187 s in all five arms — a bytes-and-cost finding with no
in-region performance consequence.

*Gate 5c* then measured upstream's proposed fix — lith PR #259's
`--readahead-evidence-ratio k`, which bounds a committed window to `k ×` the bytes a
handle has actually read — on the same workload, and it **confirms 5b's conclusion rather
than escaping it**. At `k=8` amplification falls to **1.956×**, but prefetch `issued`
fell 45% while `used` fell **53%**, so the hit rate went **16.7% → 14.3%**: *down*. By
upstream's own stated criterion ("does `used/issued` move? — that's the one that
matters") the answer is no. What the gate actually achieves is the static minimum
window's saving *without* the static pin (`--max-readahead 1` = 1.925×,
`--readahead-evidence-ratio 8` = 1.956×, 1.5% apart), which is worth shipping as
ergonomics but is not a precision fix. The non-prefetch residual is now **1219.6–1265.9
MB across eight fetch policies** spanning 1.895×–2.438× — the strongest number in either
gate, and the reason ~1.23 GB of HEMCO's traffic is known not to be a prefetch problem at
all.

*Gate 5d* measured upstream's next hypothesis — PR #260's `--readahead-reestablish-max N`,
which stops re-establishing a handle after it has lost establishment `N` times — and it is
**inert on HEMCO** (2.451× at N=2 and 2.459× at N=4, against 2.405× for the same binary
with the flag unset, with **zero suppressions**). The PR's own new counters say why: HEMCO
loses establishment **10–17 times per run**, not the ~320 its premise assumed, because
`resetRandom` counts collapses to the Random *state* while `deEstablished` only counts
losses of an establishment that existed — two quantities that differ 20–30× here. The
consequence is the useful part: prefetch is only committed from an established handle, so
4500–4800 issued chunks against 10–17 establishment losses means **the waste comes from
handles that establish once and keep committing windows to close** — the defect is at
commitment and growth, not re-commitment. And the counter inverts across mounts: met, at a
79.7% hit rate, de-establishes **51** times to HEMCO's 10, so oscillation marks the
*healthy* reader here. Six defaults-equivalent arms across 5b–5d also hand over the
metric's null distribution — **2.440× ± 0.022 (CV 0.89%)** — which retroactively makes every
earlier verdict falsifiable rather than eyeballed. The demand-read residual now holds at
**1219.6–1265.9 MB across twelve policies**.

*Gate 5f* spends nothing and answers both threads upstream was waiting on. The
**~1.23 GB residual has a mechanism**, and it is not the branch this analysis had been
pointing at: `GetRange` is already extent-aware, so straddles are innocent, and the floor
is the in-chunk branch at `fs.go:778-786`, where byte-exact fetching is granted **only** in
`Random` — a `cold` handle, one the detector has not classified at all, is fetched as if it
were streaming. Measured on one handle: **17 reads served at 1 MiB apiece for 64 KiB each**
while the trace shows a 7.27 MB gap on every one of them (`fill_bytes{demand}` factors
uniquely as `17 × 16 extents + 95 × 1 extent`), invariant to alignment, to
`--coalesce-gap`, and to a 50× change in `--nic-gbps` — which is exactly why no fetch
policy ever moved it. Met's residual, computed here for the first time, is **1.7–1.8% of
distinct against HEMCO's 33%**. A second finding re-units the whole campaign:
**`used/issued` is a chunk-touch rate, not a byte rate** — 89% reported against ≤25.1%
byte follow-through on the same reader — so the 79.7%-vs-16.5% gap quoted throughout
*understates* the real difference, and the pre-registered scoring rule for the offline
replay scores bytes. On the gateway side, **48 concurrent `O_DIRECT` readers moved 5.37 GB
client-side and the gateway fetched the object exactly once, to the byte, from the same 21
GETs** — lith#250's coalescing-gap hypothesis is refuted with a measured upper bound of
zero. Filed on the way: lith#264, `--pf-trace` accepted, documented, and silently ignored.

*Gate 5g* then spends nothing testing the instrument that will answer the remaining
question, before buying the run that feeds it. The scorer's cold-tax counter **reproduces
the 17 exactly** by a different route and corrects our MiB figure (a kernel-merged 128 KiB
first read: 15.875, not 15.94) — but its follow-through denominator reports **1117
dispatched blocks where the mount's own counter says 91**, 9.37 GB against a 111.8 MB
object fetched once, because fidelity compares `Observe`'s output to a trace column that
also came from `Observe`. Two orders of magnitude, and it would have made prefetch look
worthless on both mounts. The AUC half of the pre-registered rule is decidable by arm
order (measured 0.500 on one population sampled twice) and vanishes when an arm dispatches
no prefetch — the HEMCO case — and the tool declared SEPARATION from ρ = −1.000 over five
handles with four ties. lith#265 is verified on live mounts in the same gate, including the
arm proving #263's loud-on-create-failure was unreachable while the flag was unwired. **The
capture is held until the denominator lands** — the scorer was the cheap half to fix.

*Gate 5h* verifies the landed fix, still at $0, on four live-mount arms in the shape the
pre-registered rule requires. The clamp holds: **215 replayed chunk-decisions against the
mount's own 182**, down from 12.3× over, with `obj_size` correct on every handle. The
residual 2.0–2.4× is not a bug but the **per-handle ceiling, now measured** — many handles
decide to prefetch blocks the global cache fetches once — so per-handle follow-through is a
lower bound by a factor ≥ 2, and larger under 48 ranks. The net cold tax **separates the two
mounts**: ~0% of the streaming handle's waste is genuine against **100% on every one of
twelve scatter handles, net == gross == 16,711,680 B twelve for twelve**, which closes the
open worry that the pre-registered 1.0–1.4 GB floor would be scored against the wrong
quantity. Arm order can no longer decide the verdict, and a class with zero prefetching
handles is now refused loudly instead of dropped. Stripping the new `size` column back out
reproduces upstream's inflation claim and goes further: follow-through **0.052 → 1.000**,
and the prefetching-handle population **drops 3 → 1** because the handles whose prefetch was
most wasteful estimate away entirely, while the sanity ratio inverts to a reassuring 0.07×.
One ask is still open — SEPARATION is declared from ρ = −1.000 over **three handles with a
two-way tie on both axes**, where the winning feature is a restatement of which handle read
enough rows to be scored. **The capture is now worth buying.**

*The capture* then buys it — one 48-rank C24 fullchem job with met and HEMCO traced from
the same `c922cc7` process — and the answer is that **the pre-registered rule cannot be
evaluated on a real GCHP mount at all**. met's 598 handles read **twelve distinct keys**
(mean 49.8 handles per key, **0 of 598 a sole reader**), because 48 ranks open the same
twelve MERRA-2 files; the scorer's fidelity gate consequently mismatches on **135 of met's
143 prefetching handles**, since only a handle that tried to dispatch can have a dispatch
suppressed by a sibling. Its headline `VERDICT: SEPARATION` (ρ = 0.616, AUC 0.670) is
computed over the population it voids; on the faithful subset ρ is **−0.412 / −0.082**,
sign-flipping between replicates, and AUC **0.438**, from n = 8 and n = 3. The sharing also
inflates per-handle net cold waste to 8431 MiB, **more than the mount's entire waste budget
of 5.32 GB**. What the capture *does* settle is the floor's multiplier — **~121 cold starts
per HEMCO object** — which makes gate 5f's one-handle tax a per-rank-per-file entry fee and
explains, necessarily, why eight per-handle policies left the floor constant. Controls all
held (MD5 identical, `c922cc7` behaviour-neutral, bytes unchanged), and **P3 was falsified:
`--pf-trace` costs +0.5%/+1.6% of wall despite documenting a global lock on every read.**

*The capture, follow-up* then answers upstream's one design question and **retracts two of my
own claims**. Trace rows are **not** in true order — 1.87–2.00% of met's rows carry a `gap`
that contradicts the row sequence, some impossibly — and a timestamp inside `tracePF` would
not fix it, because the decision is made under a different mutex that is released first; the
fix is a sequence number assigned inside `pfWrapper.observe`. And the fidelity mismatch is
**not** sibling suppression: `dispatched` is `len(pbs)` taken before `store.Prefetch` runs, so
nothing can suppress it. The real causes split by mount — met is 74.5% row reordering, HEMCO
is 94% **a missing `perHandleWindow` column**, since the live path calls `SetMax(budget /
open_handles)` before every `Observe` while the replay uses a static 223 against a measured
max of **17**. With my own halved-denominator error corrected (I passed one arm's counters as
the run total), the gap decomposes exactly: **2.70× window inflation × 3.43× genuine dedup =
9.25×**, so sharing dedup is 3.43×, not the 13.4× I reported, and upstream's 8× alarm
threshold is correctly placed. Consequence: the per-handle rule may be **evaluable after
all** once the window input is recorded, and the shared-cache replay should be built third,
not first.

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
7. **Which lith mechanism causes HEMCO's 2.46×.** **MEASURED 2026-09-18 — see *Gate 5b*
   below.** Three arms on the HEMCO mount alone (met/restart as in-run controls), all on
   v1.1.3, checkpoint MD5 gated in every arm and identical in every arm. Neither
   candidate mechanism survived: `--parts-max 0` is flat (2.420× vs 2.438×) and
   `--max-readahead 4` gets only to 2.135× against a 1.33× demand-read floor. The
   mechanism is **prefetch precision** — 13–16% used/issued on HEMCO vs 80% on met, and
   the rate is *invariant* to a 4× window reduction while the volume scales with it.
   Arms D/E (added after upstream corrected my units: `--max-readahead` is in 8 MiB
   blocks, so arm C capped at 32 MiB, not 4 MiB) reach **1.895×** at the minimum 1-block
   window with all three whole-file paths disabled, which bounds the flag-reachable
   saving and leaves **~2.0 GB requiring cross-handle state**. `--small-file` is a third
   whole-file path `--parts-max 0` does not disable, worth a measured 114.2 MB against a
   180.2 MB ceiling predicted from the manifest. Reported to lith#256; sim wall 186–187 s
   in all five arms.
8. **Does upstream's proposed fix (lith PR #259) recover the precision?** **MEASURED
   2026-09-19 — see *Gate 5c* below. No.** Three more arms on the HEMCO mount, served by
   a head-node build of PR #259 while the four control mounts stayed on released v1.1.3:
   flag unset reproduces arm A (2.425× vs 2.438×, so off-by-default is inert),
   `--readahead-evidence-ratio 8` reaches **1.956×** and `32` reaches 2.206×. But
   `issued` fell 45% while `used` fell 53%, so the hit rate went **16.7% → 14.3%** —
   evidence accrued by a handle is uncorrelated with whether its prefetch gets used. The
   knob is the static minimum window's saving without the static pin, which is worth
   shipping, and is not a precision fix. Checkpoint MD5 identical in all three arms; met
   control 1.209–1.210×. The demand-read residual is now constant across **eight** fetch
   policies.
9. **Does capping *re-establishment* (lith PR #260) recover it?** **MEASURED 2026-09-19 —
   see *Gate 5d* below. No, and the refutation comes from the PR's own new counters.**
   `--readahead-reestablish-max 2` gives 2.451× and `4` gives 2.459× against 2.405× for the
   same binary with the flag unset, with **zero suppressions** on HEMCO: the mount loses
   establishment **10–17 times per run**, not the ~320 the premise assumed, because
   `resetRandom` counts Random-state collapses whereas `deEstablished` counts only losses of
   an existing establishment. Since prefetch is committed only from an established handle,
   4500–4800 issued chunks against 10–17 losses means the waste is **handles that establish
   once and keep committing windows to close** — the live axis is commitment and growth, not
   re-commitment. Counter-intuitive corollary: met, the 79.7%-hit-rate mount, de-establishes
   **51** times to HEMCO's 10, so oscillation marks the healthy reader. An unrequested arm J
   capped met instead, where the mechanism *does* fire (16 suppressions) with no measurable
   harm (1.210×, 79.7%). Checkpoint MD5 identical in all four arms; residual now constant
   across **twelve** policies; six defaults-equivalent arms give the metric's own scatter at
   **±1%**.
10. **What *is* the ~1.23 GB residual, then?** **MEASURED 2026-09-19 — see *Gate 5f*
   below. A per-handle cold-start tax, and it is not in the branch I had been pointing
   at.** `GetRange` (the straddle path) is already extent-aware, so straddles are
   innocent; the floor is the in-chunk branch at `fs.go:778-786`, where byte-exactness is
   granted **only** in `Random` — so a `cold` handle, one the detector has not classified
   at all, is fetched whole-chunk. Measured on one handle: **17 reads served at 1 MiB for
   64 KiB each** while the trace shows a 7.27 MB gap on every one of them, and
   `fill_bytes{demand}` factors uniquely as `17 × 16 extents + 95 × 1 extent`. Invariant
   to 64 KiB alignment, to `--coalesce-gap`, and to a 50× change in `--nic-gbps` — the
   signature of the floor that held across twelve fetch policies. Bridge: 1224.3 MB ÷
   (1 MiB − 64 KiB) = **1245 pre-decision small reads**, falsifiable for free from a real
   `fh`-grouped trace. Second finding: `used/issued` is a **chunk-touch** rate — 89%
   reported against ≤25.1% byte follow-through on the same reader — so the met-vs-HEMCO
   gap quoted all campaign understates the real one. Reported to lith#256; the blocker
   found on the way (`--pf-trace` silently ignored) is lith#264.
11. **Does the shared gateway re-fetch bytes under concurrency (lith#250)?** **MEASURED
   2026-09-19 — see *Gate 5f* below. No, at K=48.** Five arms, one gateway, O_DIRECT
   readers so the NFS client cache cannot dedupe on lith's behalf: client-side bytes span
   1× → 48× (5.37 GB) and `s3_bytes` stays at **111,810,271 — the object size exactly, in
   every arm, from the same 21 GETs**, including the staggered-arrival shape that was the
   specific worry. Hypothesis 2 is refuted with a measured upper bound of zero bytes;
   hypothesis 1 (96-vs-48-rank distinct-set growth) is the answer, and the 1.28× gateway
   saving's assumption is now supported rather than merely unverified.
12. **Is the offline scorer that will answer question 10 trustworthy?** **MEASURED
   2026-09-19 — see *Gate 5g* below. It reproduces the cold-tax count exactly, and its
   follow-through denominator is 12× too large.** `lith-pfreplay` (lith PR #267) returns
   `cold_small_reads = 17` on the banked b2 trace — the same 17 the `fill_bytes{demand}`
   factorization gave, by a different route — and corrects the MiB figure (one of the 17
   reads was 128 KiB, kernel-merged, so 15.875 MiB not 15.94). But on a real trace it
   reports **1117 dispatched blocks where the mount's own `lith_prefetch_issued_total`
   says 91**, and 9.37 GB of dispatched bytes against an object of 111.8 MB fetched
   exactly once, because `max_readahead = 223` blocks are dispatched wholesale and ~94% of
   the denominator lies past EOF. Fidelity prints OK because it compares `Observe`'s output
   against a trace column that also came from `Observe`. Plus: the AUC half of the
   pre-registered rule is computed on `labels[0]` vs `labels[1]` only (so the four traces
   the train/test split requires can pair HEMCO against HEMCO, measured AUC 0.500), it
   vanishes entirely when one arm dispatches no prefetch — which is the HEMCO case — and
   the tool declared SEPARATION from ρ = −1.000 over five handles with four ties on both
   axes. Reported on lith#267; **the capture is held until the denominator lands.**
13. **Did the scorer's fix land, and is the capture now worth buying?** **MEASURED
   2026-09-19 — see *Gate 5h* below. Yes: the denominator is within 18% of the mount's own
   counter, and the residual is the per-handle ceiling rather than a bug.** On `c922cc7`
   the replay reports **215 chunk-decisions against a live `lith_prefetch_issued_total` of
   182** (was 1117 vs 91) with `obj_size` correct on all 24 handles. The remaining 2.0–2.4×
   is the same fact as the 2.02× denominator-sanity ratio: many handles decide to prefetch
   overlapping blocks that the global cache fetches once, so **per-handle byte
   follow-through is a lower bound by a factor ≥ 2**, and more under 48 ranks —
   `byte_follow_through_global` is load-bearing, not cosmetic. The net cold tax separates
   the mounts: **met 5.0 net of 21.0 MiB gross (24% genuine), HEMCO 95.6 of 95.6 (100%),
   net == gross == 16,711,680 B on twelve scatter handles for twelve** — so the
   pre-registered 1.0–1.4 GB floor is scored on the quantity it named. Arm order no longer
   decides the verdict, and a zero-prefetch class is now refused loudly. Stripping `size`
   back out reproduces upstream's inflation claim and extends it: mean follow-through
   **0.052 → 1.000**, the prefetching population **drops 3 → 1** (the most wasteful handles
   estimate away), and the sanity ratio inverts to a reassuring **0.07×** while
   "distinct objects" inflates to 6× the object (one estimate per handle). Still open:
   SEPARATION from ρ = −1.000 over **three handles with a two-way tie on both axes**, the
   winning feature confounded with which handle read enough rows to be scored at all.
14. **Does a first-k-reads feature predict whether a handle's prefetch gets used, on real
   GCHP traces?** **MEASURED 2026-09-19 — see *The capture* below. The question is
   UNEVALUABLE per-handle, because GCHP has ~50 handles per object and no per-handle
   locality to score.** met/a is 598 handles over **twelve distinct keys** (mean 49.8
   handles/key, max 77, **0 of 598 sole readers**); hemco/a is 6,272 handles over 204 keys
   (96% shared). The scorer's own fidelity gate mismatches on **135 of met's 143
   prefetching handles** — a dispatch can only be suppressed if the handle tried to
   dispatch, so the void population *is* the scored population. Its headline
   `VERDICT: SEPARATION` (ρ = 0.616, AUC 0.670) is computed over handles it rejects; on the
   faithful subset ρ goes **−0.412 / −0.082** (sign flips between replicates) and AUC
   **0.438**, from n = 8 and n = 3. Sharing also inflates per-handle net cold
   waste to 8431 MiB, **exceeding the mount's entire waste budget of 5.32 GB**.
   *(Corrected in the follow-up: the fidelity failure is **not** sibling suppression but
   trace row reordering on met and a **missing `perHandleWindow` column** on HEMCO, and the
   replay/mount gap is **2.70× window inflation × 3.43× dedup = 9.25×**, not the 13.4×
   dedup I first reported — so the rule may be evaluable once the window input is recorded.)*
   What the capture *does* settle is the floor's
   multiplier: **~121 cold starts per HEMCO object** (24,762 pre-decision cold reads over
   204 keys), so gate 5f's one-handle tax is paid once per rank per file, and gate 5b's
   "needs cross-handle state" follows necessarily. Controls: checkpoint MD5 identical in
   all three arms, `c922cc7` behaviour-neutral against the n = 6 null, and **P3 falsified —
   `--pf-trace` costs +0.5%/+1.6% wall, inside the 2% band, despite its own documentation's
   global-lock warning.**

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

**Version note, because gate 4 of this document demands the lith version be recorded
with every run: this ran v1.1.2 when v1.1.3 was already ~18 h old** (released
2026-09-18T04:10Z, job ran 22:10Z). The binary had been pinned earlier in the campaign
and I did not re-check for a release before spending node time. It does not move the
numbers, and that is verifiable rather than hopeful: `v1.1.2...v1.1.3` changes exactly
two non-test files, `internal/nfs/fs.go` (+9) and `internal/nfs/gateway.go` (+1) — the
#253 gateway distinct-bytes fix. **No blockstore, fetch-policy or prefetcher change**,
and the fix is gateway-only *because* the FUSE path already called `MarkDistinctRead`
(which is why the mount arm of the #253 repro reported bytes while the gateway reported
0). Gate 5 ran five per-node FUSE mounts, so every counter below predates and postdates
that patch identically. Still: **check for a release before spending node time**, since
lith is currently cutting one every few hours.

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

(The two sub-1.0 rows are granularity artifacts — `distinct_bytes_read` rounds up to
the **64 KiB extent** while `s3_bytes_total` is the actual transfer — and are too small
to move the total. I first wrote "1 MiB chunk" here; the rounding is 64 KiB, verified
exactly on two objects: 4565478 → 70 × 65536 = 4587520, and 301740437 → 4605 × 65536
= 301793280, both matching what lith reported.)

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
concrete read-pattern improvement left on the table. **Filed upstream as
[lith#256](https://github.com/scttfrdmn/lith/issues/256)** with the per-mount counters.

I filed one confound with it that turned out not to exist. I reported the mount as
running `--mem-cache 8GB` against 9.1 GB fetched, which would make prefetch-induced
eviction a live alternative explanation. It ran **`--mem-cache 32GB`** — 8GB was gate
3c's value, and I had misread my own harness. There was never capacity pressure, so
that hypothesis is excluded *by configuration* rather than needing an arm, and
`lith_prefetch_evicted_unread_total` reads **0** besides. (It is exported and was
present in the scrape all along; my `metrics_dump` regex enumerated
`prefetch_(issued|used|uncovered)_total` and omitted it, which is why I also told
upstream it was missing. A diagnostic you filtered out looks exactly like a diagnostic
that does not exist — the regex now takes whole counter families, not named members.)
Both corrections went to #256 before any follow-up arm was designed.

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

---

## Gate 5b — *which* mechanism whole-fetches HEMCO? Both hypotheses lose (2026-09-18)

*Five arms, three submissions. A–C answered "not parts-max, and the window is only a
contributor"; D–E, added after upstream corrected my units, bound how much of the waste
is reachable by configuration at all. The answer is: 2.0 GB of it is not.*

Gate 5 left one live question and upstream answered it with a source reading on
[lith#256](https://github.com/scttfrdmn/lith/issues/256): on a ~13 MB file the #229
coverage gate cannot discriminate, because a rank's own subdomain reads tile a span
that *is* most of the file, so the handle establishes and the readahead window jumps
straight to the NIC-derived `maxReadahead`. Whole file, every file, every timestep.

Their proposed test was `--nic-gbps 7.5` against `50`. **I did not run it, because
`lith doctor` says it cannot discriminate.** `--parts-max` defaults to `auto` = NIC
baseline × first-byte latency, clamped to `[--small-file, 64MiB]`, and it resolves to
**64 MiB at `--nic-gbps 50`** and **35 MiB at 7.5** — both far above a 13 MB file. Both
rungs whole-fetch on first read regardless of any window, so the arm would have
returned flat, and upstream's own stated decision rule would have read that flat result
as refuting their own correct analysis. `--nic-gbps` also moves four things at once
(inflight bytes, window, parts-max, coalesce gap), which is the opposite of what a
mechanism test wants.

So: cross the *file-size boundary* with direct knobs, one variable per arm, on the
HEMCO mount only. Met, restart, CHEM_INPUTS and the 2015 CN mount keep gate 5's flags
in every arm, making them in-run controls — if met's 1.21× moves, the arm changed
something it wasn't supposed to. Every arm's checkpoint MD5 is compared to gate 5's
banked `f3dd15b2…96a6`, because a fetch-policy flag that changes the bytes the model
reads is a far bigger finding than the amplification question.

| arm | HEMCO flags | window | S3 MB | ampl | waste | unread pf | = MB | residual | floor | used/iss | GETs | init s | sim s | met |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A | *defaults* | NIC-derived | 9015.2 | **2.438×** | 5317.0 | 3897 | 4086.3 | 1230.7 | 1.333× | 16.1% | 8183 | 180.81 | 187.0 | 1.210× |
| B | `--parts-max 0` | NIC-derived | 8951.4 | **2.420×** | 5252.3 | 3841 | 4027.6 | 1224.8 | 1.331× | 16.3% | 8248 | 181.91 | 187.0 | 1.210× |
| C | `+--max-readahead 4` | **32 MiB** | 7897.1 | **2.135×** | 4197.6 | 2840 | 2978.0 | 1219.7 | 1.330× | 13.0% | 9151 | 188.58 | 186.0 | 1.210× |
| D | `+--max-readahead 1` | **8 MiB** | 7122.3 | **1.925×** | 3422.7 | 2092 | 2193.6 | 1229.1 | 1.332× | 13.3% | 9246 | 189.45 | 187.0 | 1.210× |
| E | `D + --small-file 0` | 8 MiB | 7008.1 | **1.895×** | 3309.6 | 1949 | 2043.7 | 1265.9 | 1.342× | 13.8% | 9259 | 181.93 | 187.0 | 1.211× |

All three arms: `md5(gcchem_internal_checkpoint)` = `f3dd15b2191bbce63dadcbfc100196a6`,
equal to gate 5's v1.1.2 value. No fetch-policy flag perturbs the model's bytes. Arm A
also **re-verifies gate 5 on v1.1.3** and reproduces its 2.46× as 2.438× — the version
note below gate 5 said the tags' diff made a rerun unnecessary, and the rerun agrees.

**The control held.** In arm C the met mount read 1.210× with prefetch 2351/2949,
against gate 5's 1.21× and 2355/2951. Three runs of the same arm-invariant mount
landing within 0.2% is what licenses reading the HEMCO deltas as caused by the flags.

### My hypothesis is refuted

`--parts-max 0` is **flat**: 2.420× vs 2.438×, with an unchanged distinct set (3699.0
vs 3698.2 MB, which independently confirms a deterministic demand set across arms).
Whatever parts-max resolves to on a 13 MB file, it is not what fetches the extra 5.3 GB.

### Upstream's is a contributor, not the mechanism — and the sub-file rung proves it

Capping the window does move it, by exactly the predicted route: **99.1% of arm C's
−1118 MB is accounted for by the fall in unread prefetch blocks** (3897 → 2840 = −1108
MB at 1 MiB/chunk; upstream confirmed `prefetch_issued_total` is recorded per 1 MiB
chunk despite its help text saying "blocks", so this arithmetic is right and their help
text was wrong). The established window is real and spends real bytes.

**But arm C was mislabelled, by me.** `--max-readahead` is *"max sequential readahead
window **in blocks**"* and `--block-size` defaults to **8MiB** — verified directly
against `lith mount --help`, not merely accepted — so `--max-readahead 4` = **32 MiB**,
still ~2.5× a 13 MB file, and not the "4 MiB « 13 MB" this document first claimed. Arm C
never tested a sub-file window. Arm **D** (`--max-readahead 1` = 8 MiB) is the real
sub-file rung, and arm **E** adds `--small-file 0` to close the third whole-file path.

The two rungs give the decomposition the gate was actually for:

```
unread prefetch:   4086 -> 4028 -> 2978 -> 2194 -> 2044 MB     (window 4x smaller, C->D)
hit rate:         16.1% -> 16.3% -> 13.0% -> 13.3% -> 13.8%    (unchanged)
```

**Shrinking the window 4× cuts the volume of bad prefetch almost linearly and does not
improve the hit rate at all.** That is the cleanest available confirmation of upstream's
mechanism — the prefetcher is constructed inside the file-handle literal
(`fuse/fs.go:562`), so there is one fresh prefetcher per `Open` which dies at close, and
every one of ~2400–4600 decisions is therefore made **cold**, with no memory of the
~4000 that just came back unread. Precision is a property of the decision process and is
independent of how big each bet is. Window size only sizes the loss.

So of arm A's 5317 MB of waste:

- **2042 MB size-scaled** — recoverable by window tuning alone (4086 → 2044 MB).
- **2044 MB decision-scaled** — unread prefetch *surviving at the minimum 1-block window
  with all three whole-file paths disabled*. There is no flag below this.
- **1231 MB demand floor** — see below.

**Window tuning bottoms out at 1.895×**, and the ~2.0 GB between there and the demand
floor is **unreachable by any flag combination.** Arm E is also the experimental proof
that a *per-handle* governor cannot work: the window is already at its minimum and 86% of
prefetch is still unread, so there is no second chance inside a handle to adapt on. The
state has to outlive the handle — per-mount, or keyed by directory/family — which is
upstream's own correction to the governor shape I proposed, and it matches
`prefetch_window_halved_total` being **0 in all five arms** (`prefetch.go:404` needs an
intra-handle *seek*, which HEMCO's open-read-close never provides).

### The number to act on

`prefetch_used/issued` on HEMCO is **13–16% in every arm**. On the met mount — same
process, same job, same 1 MiB chunking, untouched in all five arms and reading **1.210×
five times** — it is **80%**. That control is what licenses reading the HEMCO deltas as
caused by the flags.

`lith_prefetch_reset_random_total` is 306–332 on HEMCO vs 113 on met, so the random
detector fires ~3× more often on the bad mount and thousands of prefetches still go out
behind it: detection works, suppression doesn't follow from it. Upstream's explanation
covers this too — that state is per-handle, so the detection dies with the file that
earned it.

### The issue's own framing was wrong: HEMCO is not where its bytes are

Both sides of #256 reasoned from "~13 MB emissions files", including the issue title.
From the fullchem manifest (471 HEMCO objects, whole-object sizes):

| size band | files | bytes |
|---|---|---|
| ≤4 MiB (`--small-file`) | 134 (28.5%) | 180.2 MB (0.7%) |
| 4–8 MiB (< 1 block) | 72 (15.3%) | 410.0 MB (1.6%) |
| 8–32 MiB (≤ arm C window) | 63 (13.4%) | 1113.8 MB (4.3%) |
| **> 32 MiB** | **202 (42.9%)** | **24435.5 MB (93.5%)** |

Against a 3698 MB distinct read, files ≤8 MiB hold only 590 MB *in total*, so **at most
16% of the distinct bytes can come from sub-block files — ≥84% comes from files larger
than one block and ≥54% from files larger than arm C's entire window.** "Many small
files" describes 44% of the file *count* and ~2% of the bytes.

This relocates the mechanism rather than weakening it: the expensive handles are
100 MB–1 GB files where a handle has *hundreds* of blocks to be right about and still
isn't, because GCHP reads a scattered hyperslab that tiles enough to establish and then
jumps. It explains why arm C helped at all (it capped the window on the 202 large
members, where the bytes live) and why D helped more. It is also the better news for a
cross-handle governor, which would have large, repeatedly opened files to learn on.

### `--small-file 0` is a real third path, and it is small — 114.2 MB

`--parts-max 0` does **not** disable `--small-file` (default 4MiB): it is a separate flag
with its own threshold, so arms B–D were all still whole-fetching 134 objects on first
read. Predicted ceiling from the manifest **before** running arm E: 180.2 MB. Measured:
**114.2 MB**. The bound held. It also zeroes `sibling_prefetch_total` (54 → 0), so
`--small-file` is what drives sibling prefetch.

### Retracting my own latency argument against `--max-readahead`

This document and #256 both said not to ship `--max-readahead 4` partly because arm C
initialized 4.3% slower on 968 extra GETs. **At n=5 that does not hold:** arm E has the
*most* GETs of any arm (9259) and the third-*lowest* init (181.93 s). Init spans
180.8–189.5 s with no clean ordering by GET count, so ±4% is run-to-run scatter and I
over-read a single pair. The bytes conclusion is unaffected. A readahead cap still
shouldn't be a default — but because it's a workaround for a classification bug, not
because it costs latency.

**Sim wall was 186–187 s in all five arms.** Whatever happens here, the model does not
notice. That is the honest frame for the whole of gate 5b: a cost and egress finding,
which would only become a bill cross-region or on requester-pays.

### The 1.33× demand floor is probably *not* separable

The non-prefetch residual is **1230.7 / 1224.8 / 1219.7 / 1229.1 / 1265.9 MB — constant
to ±2% across five different fetch policies**, which is the strongest number in the gate.
It is 1 MiB chunk granularity serving sub-MiB hyperslabs (`cache_misses` 7073–8304,
`read_straddle` ~3070, `fill_runs` 0 throughout: GCHP never establishes sequential,
consistent with the lith#233 section below). It ticks up only in arm E, where
`--small-file 0` correctly converts 134 whole-fetches into demand reads.

I had banked it as a separate, later problem. Upstream's reading says otherwise, and my
data is consistent with it: the byte-exact demand lane is gated on the handle being
confirmed Random (`fuse/fs.go:740`), so a **spuriously established** handle is *denied*
byte-exact reads and pays whole 1 MiB chunks for sub-MiB hyperslabs. That is exactly a
quantity no flag in these five arms touches, which is why it is invariant. If they're
right, spurious establishment costs twice and the target is not 1.33× but **~1.0×** —
so the measured prize on the mount carrying ~65% of a fullchem run's fetched bytes is
**1.895× → ~1.0–1.34×, none of it reachable by configuration.**

### The guard that cost an arm, and why it stays

Job 15 ran A and B and reported `C NOT-RUN`. Arm B left `/input-lith/HEMCO` attached —
the busiest mount, and the last one the 48 dying ranks held open — so arm C's
clean-state check refused to run GCHP against a stale layer:

```
ABORT ARM C: lith layer not usable — NOT running GCHP (a run against
      stale or dead daemons produces a failure that looks like a result)
```

**That is the guard working, not failing**, and it is trap 1 of gate 5 paying for
itself: job 13 had already run a whole arm against dead daemons and scored it. Losing
an arm to an abort costs 7 minutes; scoring a stale mount as a measurement costs the
finding. The bug was that a single `fusermount3 -u` is not enough between arms — fixed
with retries plus a lazy `-uz` fallback, which detaches the mountpoint while a
reference is still held and lets the daemon exit on its own, and the same lazy pass now
follows `clean_stale_lith`'s `pkill` (a mount whose daemon you just killed lingers as
an entry that no longer serves reads, and is indistinguishable from a healthy one in
`mount` output). Job 16 came up 0 stale mounts, 5/5 daemons answering.

Gate 5b cost ~40 min of one `c8g.48xlarge` across three submissions (A+B, C, then
D+E). `ARMLIST=` runs any
subset of arms against the banked checkpoint, so a fourth rung — a hit-rate-gated lith
build, say — is one submission and ~7 minutes.

## Gate 5c — upstream's fix measured: PR #259 caps volume, not imprecision (2026-09-19)

Gate 5b ended with a specific ask of upstream and a specific prediction from them. They
shipped **PR #259**, `--readahead-evidence-ratio k`, which bounds a committed readahead
window to `k ×` the bytes a handle has actually read — applied at establishment, at
window growth, *and* at re-establishment (because within-handle suppression isn't sticky:
coverage recovers over the trailing 16-read ring). It is off by default, deliberately,
since the narrow early window is exactly what lith#56's jump-to-full-window was added to
avoid. Then they asked for one arm, and predicted its outcome on the record.

That is the ideal shape for a gate: a mechanism, a knob, and a falsifiable prediction
made before the measurement. This section is the measurement.

### The arms, and why there are three rather than one

`scripts/lith/gate5b-hemco-prefetch-arms.sbatch`, extended. The HEMCO mount is served by
a head-node build of PR head `85b8102` (go1.27.1 linux-arm64, ldflags-stamped
`lith pr259-evidence-gate`, sha256 `c697f986…00cf1e`, the PR's own
`internal/prefetch/evidence_test.go` passing). **The four control mounts stay on released
v1.1.3**, so met's 1.210× remains comparable to arms A–E instead of moving for two
reasons at once. Preflight asserts the PR binary *has* the flag and the control binary
does *not*, so an arm cannot silently run as a duplicate of A.

| arm | HEMCO flags | binary |
|---|---|---|
| F0 | defaults (flag unset) | pr259 |
| F | `--readahead-evidence-ratio 8` | pr259 |
| G | `--readahead-evidence-ratio 32` | pr259 |

F0 is not ceremony. PR head `85b8102`'s merge-base with `origin/main` is `24b151f`, i.e.
the PR is main + 1 commit and main is v1.1.3 + #257 + #258 — and **#258 touched
`internal/fuse/fs.go`**. Without F0, a moved number in F could not be attributed to the
flag rather than to the 14 commits' worth of binary it arrived in. F0 also tests the claim
in the PR's own title, that the feature is off by default.

F0/F/G carry no `--parts-max`, `--small-file` or `--max-readahead` flags, on upstream's
instruction: the gate is meant to *replace* window tuning, not stack on it. Stacking D's
or E's caps underneath would have made any fall in amplification unattributable.

### Results

| arm | HEMCO flags | binary | s3 MB | ampl | used/issued | hit% |
|---|---|---|---|---|---|---|
| A | defaults | v1.1.3 | 9015.2 | 2.438× | 749/4646 | 16.1% |
| B | `--parts-max 0` | v1.1.3 | 8951.4 | 2.420× | 750/4591 | 16.3% |
| C | `+--max-readahead 4` (32 MiB) | v1.1.3 | 7897.1 | 2.135× | 424/3264 | 13.0% |
| D | `+--max-readahead 1` (8 MiB) | v1.1.3 | 7122.3 | 1.925× | — | 13.3% |
| E | D + `--small-file 0` | v1.1.3 | 7008.1 | 1.895× | — | 13.8% |
| **F0** | defaults | **pr259** | 8970.9 | **2.425×** | 775/4631 | 16.7% |
| **F** | `--readahead-evidence-ratio 8` | **pr259** | 7231.8 | **1.956×** | 366/2567 | **14.3%** |
| **G** | `--readahead-evidence-ratio 32` | **pr259** | 8159.9 | **2.206×** | 548/3633 | 15.1% |

Controls, all three arms: `md5(gcchem_internal_checkpoint)` =
**`f3dd15b2191bbce63dadcbfc100196a6`**, identical to gate 5's banked value; met mount
**1.210× / 1.209× / 1.210×** at 79.7–79.8% hit rate; `cap_restart` advanced to 20190702;
zero read errors, zero fallbacks. Init 178.80 / 183.39 / 186.13 s against arms A–E's
180.81–189.45 s scatter — F0 is the *fastest* init of all eight arms, which is worth
noting only because it is noise.

**F0 reproduces A to 0.5%**, so off-by-default is genuinely inert and everything below is
the flag rather than the branch.

### Upstream's predictions, scored

| prediction | outcome |
|---|---|
| HEMCO amplification 1.4–1.8× | **missed (high)**: 1.956× at `k=8` |
| `used/issued` up materially — *"that's the one that matters"* | **failed**: 16.7% → 14.3%, it went *down* |
| met unchanged at 1.210× | **held**: 1.209× |
| init within noise of A | **held**: 183.39 s vs A's 180.81 s |
| checkpoint MD5 | **held**: identical in all three |

### The mechanism: used fell *faster* than issued

The gate cut prefetch `issued` by **45%** (4631 → 2567) and cut `used` by **53%**
(775 → 366). Because used fell faster, the hit rate fell rather than rose. That is the
whole finding, and it is a stronger statement than "the fix didn't work": **accrued
evidence is uncorrelated with whether a prefetch gets used, and if anything is slightly
anti-correlated** — the handles that accumulate the most evidence are the ones reading
HEMCO's *large* files, whose scattered hyperslabs are precisely what the prefetcher cannot
predict. Gate 5b's 471-object histogram already relocated the bug there (≥84% of distinct
bytes come from files larger than one block); 5c is the confirmation from the other
direction.

`k` orders correctly, so the knob does what its help text says — this is not a
non-functional flag:

| `k` | issued | ampl |
|---|---|---|
| 8 | 2567 | 1.956× |
| 32 | 3633 | 2.206× |
| off | 4631 | 2.425× |

### What it *is* worth: the static floor without the static pin

```
D  --max-readahead 1  (a hard 8 MiB pin)     7122.3 MB   1.925×
F  --readahead-evidence-ratio 8              7231.8 MB   1.956×
```

Same floor, 1.5% apart. #259 reaches the minimum static window's saving **without**
pinning readahead for well-behaved readers: a sequential copy still earns the full window
once it has consumed `max-readahead × block-size / k`. As an ergonomics and safety
improvement over telling users to set `--max-readahead 1` globally — which would wreck
`cp`, `tar` and staging on the same mount — that is real, and the recommendation upstream
is to ship it. The one request made on the PR is that its CHANGELOG **not** describe it as
answering #256's precision question, because these numbers say it does not.

### The demand floor now survives a sixth policy — and a second *kind* of mechanism

`waste = s3 − distinct`; `unread = (issued − used) × 1 MiB`; `residual = waste − unread`.

| arm | s3 MB | ampl | waste MB | unread MB | **residual MB** |
|---|---|---|---|---|---|
| A | 9015.2 | 2.438× | 5317.0 | 4086.3 | **1230.7** |
| B | 8951.4 | 2.420× | 5252.3 | 4027.6 | **1224.7** |
| C | 7897.1 | 2.135× | 4197.6 | 2978.0 | **1219.6** |
| D | 7122.3 | 1.925× | 3423.3 | 2193.6 | **1229.1** |
| E | 7008.1 | 1.895× | 3309.1 | 2043.7 | **1265.9** |
| F0 | 8970.9 | 2.425× | 5272.1 | 4043.3 | **1228.8** |
| F | 7231.8 | 1.956× | 3534.1 | 2307.9 | **1226.2** |
| G | 8159.9 | 2.206× | 4460.3 | 3234.9 | **1225.4** |

**1219.6–1265.9 MB across eight fetch policies spanning 1.895×–2.438×**, and
1225.4–1228.8 MB across these three — a 0.3% span. Gate 5b established that constancy
across window and whole-file knobs; 5c extends it to a mechanism of an entirely different
kind, which is about as much evidence as this workload can produce that **~1.23 GB of
HEMCO's traffic is not a prefetch problem at all**.

Its fingerprint is stable too, and every one of these is a counter that *would* have moved
if the arms were touching it:

| counter | A | F0 | F | G |
|---|---|---|---|---|
| `read_straddle_total` | 3055 | 3066 | 3062 | 3033 |
| `prefetch_reset_random_total` | 332 | 316 | 307 | 321 |
| `prefetch_window_halved_total` | 0 | 0 | 0 | 0 |
| `fill_runs_total` | 0 | 0 | 0 | 0 |
| `prefetch_evicted_unread_total` | 0 | 0 | 0 | 0 |

That ~3060-read straddling population is the same one `internal/fuse/fs.go:740`
(`if sequential && h.pf.state() == prefetch.Random`) denies byte-exact reads to when a
handle is *spuriously* established. So the reading from 5b stands: the floor should move
when classification is fixed, and the target is **~1.0×**, not ~1.9×.

GETs rise as the gate tightens — same bytes wanted, smaller fetches: F0 8166, G 8827,
F 9237 (A 8183 … E 9259). At in-region rates that is ~$0.004 per run and in-region bytes
are free, so 5c is the same shape of finding as 5b: **cost and egress, with no performance
consequence.** Sim-only wall is 186–187 s in all eight arms.

### What is still unresolved, and the one thing that would have helped

**Nothing in the observable metrics distinguishes a window the gate refused from a window
it never wanted**, because the PR adds no counter for a clamped or denied commitment — the
only evidence of the gate acting is that `issued` fell, and everything else here is
inference from it. In particular the question "is the gate firing on the large files or
the small ones?" is not answerable from the current scrape, and it is the question that
would say whether an evidence bound could be *made* precise. A
`lith_prefetch_evidence_clamped_total`, ideally with clamped bytes, was requested on the
PR.

The precision defect itself is untouched and still needs what 5b concluded: state that
outlives a handle (per-mount or per-directory-family), plus revisiting the `fs.go:740`
gate so a misclassified handle is not punished twice.

Gate 5c cost ~31 min of one `c8g.48xlarge` across two submissions (F0, then F+G); the
head-node Go install and PR build were $0. Artifact:
`data/lith-gates/gate5c-evidence-gate-arms.txt`.

### A submission trap, not a harness bug

`sbatch --export=ALL,ARMLIST=F0,F,G` **does not do what it looks like**: sbatch splits
`--export` on commas, so `ARMLIST` was set to `F0` and sbatch then tried to export two
variables named `F` and `G`. Job 18 ran arm F0 alone, printed a completely correct
verdict for it, and silently dropped the two arms the job existed to run. Nothing in the
log was wrong — the submission was. The correct form, now recorded in the harness header,
is `ARMLIST=F,G sbatch --export=ALL <script>`. This is the mirror image of gate 5b's
stale-mount lesson: there, the harness refused to produce a number it hadn't earned; here
it produced a true number for the wrong question, which is harder to notice.

## Gate 5d — PR #260's re-establishment cap is inert, and its own counters relocate the defect (2026-09-19)

Upstream's hypothesis 4, built after withdrawing #259's precision claim.
`--readahead-reestablish-max N` stops re-establishing a handle once it has lost
establishment `N` times: contiguous progress is still recognized and reads still served,
but nothing further is committed. Their premise was explicit — HEMCO's handles *oscillate*
(establish → commit → jump → de-establish → coverage recovers → re-establish → commit),
and the cited evidence was `lith_prefetch_reset_random_total` = 307–332 per run on HEMCO
against 113 on met: "the detector notices ~320 times per run and then forgets."

Four arms in one submission, PR head `1dea9e4` built on the head node (base main =
`41322f4`, so #259 is already in the binary):

| arm | mount capped | N | HEMCO s3 MB | ampl | used/issued | hit% | GETs | init s |
|---|---|---|---|---|---|---|---|---|
| H0 | none (binary control) | – | 8891.1 | **2.405×** | 747/4533 | 16.5% | 8296 | 180.14 |
| H | HEMCO | 2 | 9063.7 | **2.451×** | 827/4763 | 17.4% | 7971 | 176.96 |
| I | HEMCO | 4 | 9091.7 | **2.459×** | 809/4779 | 16.9% | 8028 | 177.19 |
| J | **met** | 2 | 9102.7 | 2.461× | 865/4838 | 17.9% | 7964 | 175.79 |

`md5(gcchem_internal_checkpoint)` = `f3dd15b2…96a6` in all four; met 1.211 / 1.209 / 1.210
/ 1.210× at 79.7–79.8%; `cap_restart → 20190702`; 0 read errors, 0 fallbacks.

Arm J was mine, not requested. Upstream named a risk — a legitimate multi-pass reader
de-establishes between sweeps and would get capped — and met *is* that reader, so the
conservative rung they offered as an alternative is the one that ended up carrying the
finding.

### Their new counters, which are the result

| arm | mount | `deestablished_total` | `reestablish_suppressed_total` | size class |
|---|---|---|---|---|
| H0 | HEMCO | **10** | (no series) | 100% `>64MiB` |
| H | HEMCO | **17** | **0** | 100% `>64MiB` |
| I | HEMCO | **12** | **0** | 100% `>64MiB` |
| J | HEMCO | 15 | (no series) | 100% `>64MiB` |
| J | **met** | **51** | **16** | 100% `>64MiB` |

Predictions scored: `>64MiB` concentration **held exactly** (100% against my pre-registered
34.8% null); `deestablished ~300+` **missed by 20–30×**; `reestablish_suppressed` nonzero
**failed on HEMCO** (zero in every arm) though it held on met; amplification 1.5–1.9×
**missed** (2.451× / 2.459×); `used/issued` rose 16.5 → 17.4%, inside scatter; met, init
and md5 all held. Upstream's kill condition was "if amplification improves but the hit rate
doesn't … I withdraw it" — amplification didn't improve either.

### `reset_random` is not `deEstablished`

From the PR's own tree, `internal/prefetch/prefetch.go`:

```go
func (p *Prefetcher) deEstablish() {
    if p.established {          // :235-240
        p.deEstablished++
    }
    p.established = false
}
```

against the two `resetRandom++` sites — `:510` (`if p.state != Random`, the coverage gate)
and `:530` (second unexplained jump, unconditional). `resetRandom` counts collapses to the
Random **state**; `deEstablished` counts losses of an establishment that **existed**. On
HEMCO they differ by 20–30×: ~320 state collapses, 10–17 establishment losses. The premise
read the first number as if it were the second, so a cap at N=2 or N=4 has essentially
nothing to act on — zero suppressions, and amplification landing on top of three
independent defaults measurements.

### The positive finding: the defect is at commitment, not re-commitment

Prefetch is only committed from an *established* handle. HEMCO issues 4533–4838 chunks per
run and loses establishment 10–17 times, so those thousands of committed chunks are not the
product of repeated re-establishment. They come from handles that establish **once** — pass
the #229 coverage test legitimately — and then keep growing and committing windows their
subsequent reads never use, all the way to close, never tripping a de-establishment at all.

That is consistent with every arm to date: #259 bounds the window at establishment **and
growth** and moved volume 45%; #260 gates **re**-establishment and moved nothing; 5b showed
window *size* is irrelevant to the hit rate; 5c showed within-handle accrued evidence is
uncorrelated with follow-through. So the live target is the decision an **already
established** handle makes to commit its next window, and the discriminator cannot come from
that handle's own history — 5c measured that history and it does not carry the signal. Which
returns to state that outlives the handle, the thing #260 was designed to avoid needing.

### And the inversion: oscillation marks the *healthy* mount

| mount | `reset_random` | `deestablished` | share | hit rate | ampl |
|---|---|---|---|---|---|
| HEMCO (sick) | 321 | **10** | 3% | 16.5% | 2.405× |
| met (healthy) | 113 | **51** | 45% | 79.7% | 1.210× |

Met loses establishment 3–5× more often than HEMCO, absolutely *and* as a fraction of its
Random collapses — and met is the mount whose prefetch works. Met sweeps a field,
re-anchors, sweeps again, and that re-anchoring is exactly what #260 suppresses. So
de-establishment frequency does not separate the good reader from the bad one here; it
points the wrong way.

Arm J is the direct measurement of the named risk, and it is good news with an asterisk:
the cap fired 16 times on met and met did not budge (1.210×, 79.7%, used/issued 2347/2943
vs the control's 2351/2948) — but only because met's prefetch is accurate enough that 16
refused windows vanish into the noise. On a sweep-heavy mount with a lower baseline the same
16 refusals would be a real cost, and nothing in this gate says otherwise.

### A free by-product: the null distribution of the metric, n=6

H and I are behaviourally defaults (zero suppressions); H0, F0, A and J's HEMCO are literal
defaults. Six independent measurements of the same configuration on the same box:

```
2.438  2.425  2.405  2.451  2.459  2.461
mean 2.440   sd 0.022   CV 0.89%   range ±1.1%   2σ band 2.396 – 2.483
```

Amplification is good to about ±1%. Retroactively: arm B's 2.420× ("flat") is inside 1σ and
genuinely flat; C/D/E/F/G (2.135 / 1.925 / 1.895 / 1.956 / 2.206) are all far outside 2σ and
were real; H and I sit slightly *above* the control but inside the band, so the cap is inert
rather than harmful. This is what makes the earlier verdicts falsifiable instead of
eyeballed, and it came free from running a binary control in every gate — a second reason to
keep the F0/H0 rung upstream never asks for.

### The demand floor now survives twelve policies

| arm | ampl | waste MB | unread MB | residual MB |
|---|---|---|---|---|
| A | 2.438 | 5317.0 | 4086.3 | 1230.7 |
| B | 2.420 | 5252.3 | 4027.6 | 1224.7 |
| C | 2.135 | 4197.6 | 2978.0 | 1219.6 |
| D | 1.925 | 3423.3 | 2193.6 | 1229.1 |
| E | 1.895 | 3309.1 | 2043.7 | 1265.9 |
| F0 | 2.425 | 5272.1 | 4043.3 | 1228.8 |
| F | 1.956 | 3534.1 | 2307.9 | 1226.2 |
| G | 2.206 | 4460.3 | 3234.9 | 1225.4 |
| H0 | 2.405 | 5194.2 | 3969.9 | 1224.3 |
| H | 2.451 | 5365.9 | 4127.2 | 1238.7 |
| I | 2.459 | 5394.2 | 4162.8 | 1231.4 |
| J | 2.461 | 5404.0 | 4166.0 | 1238.0 |

1219.6–1265.9 MB across **twelve** fetch policies spanning 1.895–2.461×, four mechanisms of
different kinds — a 3.8% total span and 1.2% across this gate's four arms. HEMCO
`read_straddle_total` corroborates at 3074 / 3074 / 3087 / 3077 (A–G: 3033–3066). ~1.23 GB
of HEMCO's traffic is demand reads paying a whole 1 MiB chunk for a sub-MiB hyperslab, and
`fs.go:740` remains where that half has to be attacked.

### Counter papercut, reported on #260

`PrefetchReEstablish` only adds to the registry when the value is `> 0`, so a zero-valued
labelled counter emits **no series at all**. "Zero suppressions" had to be inferred from an
absent line, which in a scrape is indistinguishable from "the binary lacks the feature",
"the label value differs", and "the mount was never opened". It was resolvable here only
because arm J proved the same binary *does* emit the series when the cap fires — i.e. the
disambiguation came from an arm upstream hadn't asked for. Labelled counters should be
emitted at zero once a mount has served a read.

Gate 5d cost one submission, four GCHP runs, ~35 min of one `c8g.48xlarge`; the PR build was
$0. Artifacts: `data/lith-gates/gate5d-reestablish-cap-arms.txt`,
`data/lith-gates/gate5d-arms-job20.log`.

### Aftermath, all of it free: #260 withdrawn, #261 verified, and the instrument for the next question already exists

Upstream closed #260 and opened **#261**, which withdraws the cap, keeps the
`deEstablished` counter that refuted it, and fixes the zero-series papercut. Two things
were worth checking before endorsing it, both $0 on the head node.

**The zero-emit fix works end to end.** Same real HEMCO object, same flags, read
sequentially to EOF so there are no clamps and no de-establishments — the exact case that
emitted nothing before: the #260 build produces **0** labelled series, the #261 build
produces **2 at value 0**. The unlabelled sibling
(`lith_prefetch_evidence_withheld_blocks_total 0`) was present in *both*, which is what
made the trap invisible in the first place — the metric's own neighbour behaved correctly.
`go test -race` green on the full suite (aarch64).

**Gate 5d's numbers do transfer to the merged counter**, which mattered because the
CHANGELOG, the Prometheus `Help` string and the field comment all now cite HEMCO's 10 and
met's 51 as properties of it, and the PR describes itself as replacing "three bare
`established = false` assignments". `main` has four bare sites (`:323` in `Open`, `:401`,
`:454`, `:465`); #260 counted `:449`/`:514`/`:525`; #261 counts `:431`/`:484`/`:495` — the
same three events (contiguous-read coverage failure, #229 scattered landing, second
unexplained jump), with `Open` uncounted in both. A fourth call site would silently
falsify the `Help` text, which is now what tells an operator that a *high* value is a good
sign.

**And the instrument upstream's next step needs is already in the tree, undocumented.**
Their plan is to establish offline what predicts follow-through, from a recorded read
trace, instead of buying a ~35-minute cluster job per hypothesis. `LITH_PF_TRACE=<path>`
(`internal/fuse/fs.go:283`, `tracePF` at `:294`, called at `:785`) has shipped since before
v1.1.3 and writes one row per read: `key,off,len,blk,gap,state_before,state_after,peak_window`.
Probed on a real 106 MiB HEMCO object with three single-handle patterns via `os.pread`, it
records exactly the decisions at issue — a 40 × 1 MiB stride walk gives `cold → sequential`,
`sequential → cold`, `cold → sequential` and a matching `deestablished` increment.

Three gaps stop it from answering the question, filed as **lith#262**: rows carry `key` and
no handle discriminator (three handles on one object gave 576 unseparable rows, and under
48 ranks through one daemon it is dozens interleaved — fatal when the prefetcher is
per-`Open`); `fs.go:772` skips the prefetcher, and therefore the trace, while a whole-file
parts fetch is in flight, so on this mount the trace is a **biased sample with no marker**
(`parts-max auto` = 64 MiB at `--nic-gbps 50`, and 202 of 471 manifest objects are >32 MiB);
and there is no window/dispatch record to validate an offline replay against. With the first
two, the real 48-rank trace for the pathological mount *and* the healthy control can be
captured in the same process at zero marginal cost on an already-scheduled job, after which
hypothesis 5 costs a replay rather than a run — and "nothing in recorded reads separates
them" becomes a documented-limitation answer reached for free.

Artifact: `data/lith-gates/gate5e-pr261-verify-and-trace-probe.txt`. No cluster spend.

## Gate 5f — the floor is a cold-start tax, and the gateway never re-fetches (2026-09-19)

Both of the threads upstream was waiting on had stalled on the same excuse — "the number
needs a cluster job" — and neither did. `$0`, head node only, `main` at `c317522`
(v1.1.3 + #259 + #261 + #263), real `s3://gcgrid` objects, ~600 MB of in-region GETs.
Artifact: `data/lith-gates/gate5f-floor-mechanism-and-gateway-concurrency.txt`.

### Part A (lith#250) — 48 concurrent readers, zero re-fetch

Re-fetch is a property *inside* one gateway (one gateway is one block store no matter how
many clients face it), so concurrency on one box tests it. One `serve nfs` daemon, one
local NFSv3 client, fresh daemon per arm, and every reader on **`O_DIRECT`** so the client
page cache cannot dedupe on lith's behalf — stricter than two nodes, which have two
independent client caches.

| arm | K | pattern | `nfs_read_bytes` | `s3_bytes` | GETs |
|---|---|---|---|---|---|
| solo | 1 | whole file | 111,810,271 | **111,810,271** | 21 |
| k8-same | 8 | identical whole file, simultaneous | 894,482,168 | **111,810,271** | 21 |
| k8-jitter | 8 | identical, starts staggered 0–400 ms | 894,482,168 | **111,810,271** | 21 |
| k8-stripe | 8 | disjoint 1 MiB stripes | 111,810,271 | **111,810,271** | 21 |
| k48-same | 48 | identical whole file, simultaneous | 5,366,893,008 | **111,810,271** | 21 |

Client-side bytes span 1× → 48×; S3 bytes do not move by a single byte. **Measured upper
bound on the coalescing-gap hypothesis: zero bytes**, including the staggered-arrival
shape that was the specific worry. Untested on one box: two clients with independent page
caches, and arrival spread wider than 400 ms — neither changes the block store.

Trap for anyone repeating it: without `O_DIRECT` the probe is meaningless, because the NFS
client serves readers 2..K from its own page cache and the gateway never sees them.

### Part B (lith#256) — the floor: a `cold` handle is fetched as if it were streaming

First, a correction to the pointer this branch has carried since gate 5b: **the straddle
branch is not the floor.** `BlockStore.GetRange` is extent-aware per chunk (#118), so a
straddling sub-MiB read is byte-exact and HEMCO's constant 3074 straddles are innocent.

The floor is the in-chunk branch, `fs.go:778-786`:

```go
sequential := h.footerKind == footer.FormatNone || h.footerStream   // TRUE for every plain handle
if sequential && h.pf.state() == prefetch.Random {
    if t := f.byteExactThreshold(); t > 0 && end-off <= t { sequential = false }
}
chunk, err := f.store.Chunk(f.ctx, h.key, ci, h.size, lo, hi, sequential)
```

and in `Chunk`: `if sequential { want = maskForLen(chunkLenOf(ci, objSize)) }` — the whole
1 MiB chunk. Byte-exactness is granted **only** in `Random`, so a `cold` handle — one the
detector has not classified at all — pays whole chunks.

128 × 64 KiB reads, each 7 MiB past the last, 64 KiB-aligned, `--prefetch-budget 1MB` so
readahead cannot confound. The #263 trace:

```
rows 1-16    cold -> cold      gap = 7,274,496 on every read
row  17      cold -> random
rows 18-128  random -> random
```

`lith_fill_bytes_total{kind="demand"} = 24,051,712` = 367 × 64 KiB over 112 fills, which
factors **uniquely** as `17 × 16 extents + 95 × 1 extent` — and 17 is exactly the number
of reads the trace shows in `cold`. So the first 17 reads each paid **1 MiB for 64 KiB**
while the detector was looking at a 7.27 MB gap every time: **15.94 MiB of waste on one
handle** against 1.06 MiB requested in that phase.

| arm | alignment | flags | distinct | `s3_bytes` | straddles |
|---|---|---|---|---|---|
| b1 | misaligned | defaults | 16,777,216 | 30,277,632 | 15 |
| b2 | 64 KiB-aligned | defaults | 8,454,144 | **24,051,712** | 0 |
| b3 | 64 KiB-aligned | `--coalesce-gap 1B` | 8,454,144 | **24,051,712** | 0 |
| b4 | misaligned | `--coalesce-gap 1B` | 16,777,216 | 30,277,632 | 15 |
| b5 | 64 KiB-aligned | `--coalesce-gap 1B --nic-gbps 1` | 8,454,144 | **24,051,712** | 0 |

Byte-identical across the coalesce gap and across a 50× change in claimed NIC bandwidth;
misalignment doubles the extents a read touches (numerator *and* denominator) and leaves
the cold-phase tax untouched. **Nothing a fetch-policy flag reaches** — which is precisely
why the residual held at 1219.6–1265.9 MB across twelve policies spanning 1.895–2.461×:
the granularity commitment is bounded by no evidence, window, or ratio, it is decided by a
state the handle has not reached yet. Same defect as gate 5d's, one level over —
"sequential until proven random" where the honest posture is "unknown until proven
sequential".

Bridge, pre-registered as falsifiable: 1224.3 MB ÷ (1 MiB − 64 KiB) = **1245
pre-decision small reads** across all HEMCO handles in the 48-rank run; at ≤17 per handle
that needs ≥73 handles, which a 471-object working set re-opened per timestep under 48
ranks clears easily. From a real trace: group by `fh`, count `path=window` rows with
`len ≤ byteExactThreshold` and `state_before=cold`, multiply by (chunk length − extents
covered). **Prediction 1.0–1.4 GB; below 0.5 GB and the mechanism is wrong.**

Met's residual, computed here for the first time, is what rules out an inherent
granularity cost: **55.6–59.9 MB (1.7–1.8% of distinct) against HEMCO's 1224–1239 MB
(33%)**, on the same four arms of the same run.

### Part C (lith#256) — `used/issued` is a chunk-touch rate, and it has been steering us

Same object, same scattered pattern, readahead left on:

```
lith_prefetch_issued_total            91
lith_prefetch_used_total              81    -> 89.0% "hit rate"
lith_fill_bytes_total{kind="whole"}   95,033,055
lith_fill_bytes_total{kind="demand"}  12,320,768
lith_distinct_bytes_read              23,855,104
```

Granting *every* distinct byte to the readahead path, its bytes were read to at most
**25.1%**; netting out what the demand fills must have served, ~12%. Against **89%**
reported — a 1 MiB chunk counts as "used" when a 64 KiB read touches it. On met the two
nearly coincide (a sweep reads its chunks whole), so the **79.7% vs 16.5% gap quoted all
campaign understates the real difference**, and every arm scored "the hit rate didn't
move" was scored on the friendlier of the two numbers.

Hence the scoring rule for the replay scorer, pre-registered in writing before either side
has data (upstream writes the scorer, we capture the traces): score **bytes** — for each
dispatched block, the fraction of its bytes the same `fh` reads before close; separation
exists iff a feature from a handle's first k ≤ 8 reads predicts per-handle byte
follow-through at Spearman |ρ| ≥ 0.5 fit on one arm and tested on another; no separation
iff best |ρ| < 0.5 **and** met-vs-HEMCO distributions overlap at rank-sum AUC < 0.7.

Blocker found on the way and filed as **lith#264**: `--pf-trace <path>` is accepted,
documented in `docs/knobs.md`, and **silently ignored** — the flag is bound to a struct
field in `cmd_mount.go` and never placed in the `fuse.Config` literal at `:392-405`, so
`fs.go:288` sees `""`, falls through to the env var, and because the path is empty #263's
new loud-on-failure `ERROR` cannot fire. No file, no warning, exit 0. `LITH_PF_TRACE` still
works and is what every run here used. It is #262's own failure mode one level up: the
documented spelling yields silence.

## Gate 5g — drive the scorer before buying the capture (2026-09-19)

**$0.** Head node only, `pr/267` = `3625ee1` and `origin/main` `f75d737`. Upstream shipped
the offline scorer *before* our traces exist, deliberately, so neither side can tune it —
which also makes it the single point of failure for a capture that costs a 35-minute
48-rank job. Ground truth was already banked: gate 5f's b2 trace, whose cold-start tax came
from a unique integer factorization rather than from a replay.

### lith#265 verified — the documented spelling works, and #263's safety net was unreachable

| arm | how tracing was requested | result |
|---|---|---|
| a1 | `--pf-trace <path>` | file created, 128 rows + header |
| a2 | `LITH_PF_TRACE=<path>` (control) | file created, 128 rows |
| a3 | both set | flag file only; env path not created |
| a4 | `--pf-trace /nonexistent-dir/x.csv` | `level=ERROR "prefetch trace disabled: cannot create file"` |

a1 vs a2 diff identically modulo the `pid` column. a4 is the arm worth keeping: while
`PFTracePath` was always `""`, #263's loud-on-create-failure **could never fire through the
documented interface** — the feature added to prevent silent traces was itself unreachable.
Tracing does not perturb bytes (`s3_bytes = 24,051,712` in all traced arms, the untraced b2
figure). Ask filed: the mount *continues* after that ERROR, so a typo'd path on a capture
bills a full job and produces nothing; create-failure should be fatal at mount time.

### The scorer reproduces the 17 — and corrects our MiB

`cold_small_reads = 17` on a fresh trace and on the banked b2 trace, fidelity OK on both.
The waste figure differs from ours by exactly one 64 KiB extent, and the trace says why:
the handle's **first read is 131,072 B** (kernel-merged), so the true waste is
`16 × (1 MiB − 64 KiB) + 1 × (1 MiB − 128 KiB) = 16,646,144 = 15.875 MiB`, not 15.94 MiB.
The count stands; our rounding of one read was 0.4% high. A pure-64 KiB handle does report
exactly 16,711,680 — twelve for twelve in the part-C arms.

### Four defects, one of which would have voided the verdict

Two labelled arms × two replicates, 12 handles each, prefetch on, one real HEMCO object:

| arm | pattern | per-handle |
|---|---|---|
| stream (met surrogate) | 192 × 128 KiB contiguous | 24–65 cold reads, 22.0–56.9 MiB "waste" |
| scatter (HEMCO surrogate) | 48 × 64 KiB, 7 MiB apart | 17 cold reads, 16,711,680 B, **0 blocks dispatched** |

1. **Fidelity says OK while the dispatch total is 12× the mount's own counter.** Scorer:
   1117 blocks / 9,370,075,136 B dispatched over 5 handles, follow-through median 0.000.
   Mount, same run: `lith_prefetch_issued_total 91`, `s3_bytes_total 111,810,271` = the
   whole object, once. The object is 13.33 blocks long; `max_readahead = 223` is dispatched
   wholesale, so ~94% of the denominator is past EOF. The check compares `len(Observe(...))`
   against a trace column that also came from `Observe` — it validates the trace against
   itself, while the post-clamp truth is already exported. Bound from the counters instead:
   distinct 59,899,904 / `fill_bytes{whole}` 95,033,055 ≤ **63%** against the scorer's
   **0.45%**. Every follow-through number on both mounts would have come out ≈ 0, reading
   as "prefetch never pays off".
2. **AUC is computed on `labels[0]` vs `labels[1]` only, silently.** The rule needs ≥ 4
   traces; ordered `hemcoA hemcoB metA metB` it compares HEMCO against HEMCO. Measured:
   `AUC(sA vs sB) = 0.500 (n=5 vs 5)` — exactly right for one population sampled twice, and
   fed to a rule that reads AUC < 0.7 as evidence of *no separation*.
3. **The AUC line vanishes when one arm dispatches no prefetch — the HEMCO case.** All
   scatter handles are NaN (large gaps hold the detector in `Random`), so the label is
   empty, no AUC prints at all, and the verdict falls through to Spearman. HEMCO's real
   `prefetch_issued` is near zero by the same mechanism, so **the rule's no-separation
   branch may be unreachable on the data it was written for.**
4. **SEPARATION declared where nothing separates.** `best |rho| = 1.000 (frac_large_gap)`
   from five non-NaN handles: follow-through `(0.004514, 0, 0, 0, 0)`, feature
   `(0.000, 0.125, 0.125, 0.125, 0.125)` — four ties on both axes, one effective degree of
   freedom, taken as the max over 6 features × 4 labels with no out-of-sample gate. The
   `<- holds on both arms` annotation fires for two replicates of the *same* workload.

Plus two that change what our own prediction is scored against: `waste = chunk − read_len`
never nets out later coverage by the same handle (the streaming arm reports 259.9 MiB of
waste for chunks it reads whole — met is the streaming mount), and `state_before == cold`
counts re-entries into cold, not only the pre-decision phase. Both inflate. And the header
is self-describing for the *window* decision but not the *granularity* one:
`byteExactThreshold` is absent, so the cold-tax number depends on a flag the analyst must
set right.

Interpretive, not a bug: per-handle follow-through is what we agreed to score, but the cache
is **global** — under 48 ranks, bytes prefetched for handle A that handle B reads still save
a fetch, so the per-handle number is a lower bound on prefetch's value.

**Probe caveat.** The 12 stream handles read overlapping spans of one object, so the page
cache absorbed most reads (fh1 recorded 193 rows, the other eleven 24 each). This gate
demonstrates the *instrument's* behaviour on real traces; it is not evidence about GCHP's
handles.

**What it buys.** The capture is still the deliverable and still costs a job. Doing this
first means that job won't be spent producing a verdict that was void before the data
landed: defect 1 alone dilutes every number by ~12×, and 2 and 3 let arm order decide.
Artifacts: `data/lith-gates/gate5g-*`. Reported on lith#267, #264 and #256.

## Gate 5h — the fix landed; verify it before spending (2026-09-19)

**Cost: $0.** Head node only, ~500 MB of in-region GETs. Binaries built from `pr/267` =
`c922cc7`, which upstream pushed in response to gate 5g and directed us to build from
rather than waiting for the merge.

**Design.** Four arms, two classes, two replicates each — the shape the pre-registered
train-on-one-arm / test-on-another rule actually requires, which gate 5g could only
approximate. All against the same real object, `s3://gcgrid/HEMCO/AEIC/v2015-01/AEIC.nc`
(111,810,271 B). `met-a`/`met-b` are the streaming surrogate (6 handles × 240 × 128 KiB
contiguous); `hemco-a`/`hemco-b` are the scatter surrogate (6 handles × 48 × 64 KiB, 7 MiB
apart, **stopping early** — the shape whose object size cannot be inferred from its own
reads, which is the case the new `size` column exists for). Every trace carries it:
`fh,pid,key,size,off,len,blk,gap,path,state_before,state_after,window,dispatched,peak_window`.

**1. The clamp works: 12.3× over becomes 1.18×.**

```
denominator sanity: 215.9 MiB of dispatch DECISIONS against 106.6 MiB of distinct
                    objects (2.02x; >1x is normal)
vs live lith_prefetch_issued_total: replay 215 chunk-decisions, mount 182 chunks fetched
```

Against gate 5g's 1117 blocks / 9.37 GB where the mount said 91. Units line up: 215.9 MiB
of decisions ÷ 1 MiB `chunkSize` = 215, and `issued_total` counts 1 MiB chunks. `obj_size`
is the true 111,810,271 on all 24 handles.

*Plumbing ask:* `-issued` is one scalar compared **per trace**. `met-a` alone with
`-issued 91` compares the same 215 against 91 (2.36×); all four compare 215 against the
182 summed over four mounts. For a one-mount capture with N trace files it should compare
the summed replay, or take `-issued` per trace.

**2. The residual 2.0–2.4× is the per-handle ceiling, measured.** The 2.02× sanity ratio
and the 2.36× single-arm vs-live figure are the same fact: several handles *decide* to
prefetch overlapping blocks and the global cache fetches each once, which a per-handle
replay cannot dedupe. So gate 5g's caveat — per-handle follow-through is a lower bound on
prefetch's value — is now quantified at **≥ 2× on this arm**, and will be larger under 48
ranks sharing met and HEMCO files. `byte_follow_through_global` alongside the per-handle
column is load-bearing for interpreting the capture, and `-issued` is what makes the gap
visible at all.

**3. The net cold tax separates the two mounts — and net == gross on HEMCO.**

| class | NET waste | gross | genuine |
|---|---|---|---|
| met | 5.0 MiB | 21.0 MiB | 24% |
| hemco | 95.6 MiB | 95.6 MiB | **100%** |

Per handle: `met/a` fh1 (241 rows, pure stream) nets **0** of 8,257,536 gross — 0% genuine,
exactly the fictional waste gate 5g predicted; fh2–6 net 1,048,576 of 2,752,512 (38%); and
every one of the twelve scatter handles nets **16,711,680 = gross, twelve for twelve**.

Two consequences. First, the **#256 floor is genuine waste, not an accounting artifact** —
on HEMCO-shaped handles the netting changes nothing, so the pre-registered 1.0–1.4 GB
prediction and its < 0.5 GB falsifier are scored on the quantity they named. That was the
open worry in the #256 comment and it is closed. Second, 16,711,680 B is reproduced
exactly; gate 5f's b2 handle reported 16,646,144 only because the kernel merged its *first*
read to 128 KiB. Both are right for their handle. The netting also does interpretive work:
it takes one number that looked like waste on both mounts and shows it is ~0% genuine on
the streaming reader and 100% on the scattered one — the per-handle version of gate 5f's
met-1.8%-vs-HEMCO-33% residual split.

**4. Arm order can no longer decide the verdict.** Passing `met/a= met/b= hemco/a= hemco/b=`
— the exact ordering that used to make the AUC compare met against met, measured 0.500 —
now groups by class prefix and yields output identical to any other ordering. And the
silent drop when one class dispatches nothing is fixed loudly, firing on exactly the
population it was written for (hemco's twelve handles are all NaN; 7 MiB gaps keep the
detector in `Random`):

```
** class "hemco" has NO handles that dispatched prefetch: the AUC half of the rule cannot
   be evaluated for it, and "no separation" must NOT be concluded from its absence. **
```

**5. Still open: SEPARATION on one effective degree of freedom.** The minimum-n and
tie-mass guards asked for in gate 5g are not in `c922cc7`. The verdict still reads
`best |rho| = 1.000 (frac_large_gap)` → `VERDICT: SEPARATION`, and the data behind it is
`met/a`'s three non-NaN handles:

| fh | byte_follow_through | frac_large_gap |
|---|---|---|
| 1 | 0.155852 | 0.000 |
| 2 | 0.000000 | 0.125 |
| 6 | 0.000000 | 0.125 |

n = 3, a two-way tie on **both** axes, one handle differing — perfectly monotone by
construction. Worse, the winning feature is confounded with eligibility: fh1 is the only
handle that read enough rows (241 vs 16) to be scored, and `frac_large_gap = 0` restates
that. The AUC half correctly cannot run, so the verdict rests entirely on this. The
out-of-sample annotation is now right per the rule, but replicating a degenerate fit on a
replicate of the same workload adds no degree of freedom.

**6. The `size` column's value, reproduced independently — and worse than upstream
measured.** Upstream reported a size-less capture would score 1.000 where the truth is
0.407. Stripping the column out of these traces and rescoring the identical reads:

| | prefetching handles | follow-through (median/mean) | denominator sanity |
|---|---|---|---|
| met **with** `size` | 3 | 0.000 / 0.052 | 215.9 MiB vs 106.6 MiB (2.02×) |
| met **without** | 1 | 1.000 / 1.000 | 14.1 MiB vs 210.8 MiB (0.07×) |

Same direction, larger. Two things upstream did not state. **(a) The population is biased,
not only the ratio** — the count drops 3 → 1 because two handles that genuinely dispatched
are estimated to have so small an object that all their dispatches clamp away and they
leave the denominator. A size-less capture doesn't merely inflate the score; it silently
discards the handles whose prefetch was most wasteful. **(b) The sanity line inverts into
something reassuring** — without `size`, per-handle estimates can't be deduped onto one
object, so decisions collapse while "distinct objects" inflates (met 106.6 → 210.8 MiB;
hemco 106.6 → **633.0 MiB = 6 × 105.5**, one estimate per handle), turning 2.02× into
0.07×: "plenty of headroom" at the moment it is broken. The `ESTIMATED` warning does print,
so the net exists; the ratio should be suppressed rather than printed. HEMCO's floor is only
~3% sensitive to the column (92.6 vs 95.6 MiB net) — a scatter handle dispatches nothing
either way, so the inflation is a streaming-handle effect.

**What it decides.** Buy the capture. The three defects that would have voided its verdict
are fixed and verified on live mounts, and the cold-tax quantity is now the net one. Carry
forward: build from `c922cc7` on the compute node (a `main` trace would report ~1.000 and
drop the wasteful handles), pass `-issued` and read the sanity lines first, and expect the
per-handle number to understate by ≥ 2×.

**Probe caveat.** Instrument tests on real S3 objects, not evidence about GCHP's handles.
The met surrogate's six handles read overlapping spans of one object, so the page cache
absorbed most reads of handles 2–6 (16 rows each vs fh1's 241) — which is why n = 3 rather
than 6 and why §5's degeneracy is so sharp. HEMCO on the real mount *does* dispatch (gate 5
measured `prefetch_issued` 4750), so its AUC half should be evaluable there; these
surrogates are more extreme than reality.

Artifacts: `data/lith-gates/gate5h-*`. Reported on lith#267 and #256.

## The capture — real GCHP traces, and why the rule can't be scored on them (2026-09-19)

The run all of gate 5g and 5h was insurance for. Jobs 21 and 22 on one `c8g.48xlarge`,
48 ranks, C24 fullchem, one simulated day, `--nic-gbps 50` — the same node type, rank
count and run directory as every banked gate-5/5b number, so the whole bank is the
control. `lith` built from `c922cc7` on the compute node serves **met and HEMCO from the
same process**; the other three mounts stay on the 1.1.3 release in every arm.

| arm | met + HEMCO binary | `--pf-trace` |
|---|---|---|
| a | `c922cc7` | yes |
| b | `c922cc7` (replicate) | yes |
| c | `c922cc7` | **no** — the perturbation control |

**The four control predictions held.** Checkpoint MD5 `f3dd15b2…` in all three arms
(P1). Arm c reproduces the release on every axis — HEMCO amplification **2.4539×** inside
the n = 6 null of 2.440 ± 0.022, issued 4761 ∈ [4533, 4838], met distinct
3.254386688e9 an exact match to a banked arm, met hit rate 79.7%, wall 385.2 s ∈
[381, 393] — so `c922cc7` is behaviour-neutral and any deviation in a and b is tracing,
not the binary (P2). Bytes fetched are unchanged: HEMCO `s3_bytes` 9.0183 / 9.0099 /
9.0777 GB, −0.65% and −0.75%, and met amplification 1.2102 / 1.2098 / 1.2098 (P4) — the
traces describe an untraced run. **P3 was falsified and I was wrong**: `--pf-trace` is
documented to add a global lock to every read, I predicted a measurable slowdown at 48
ranks, and the falsifier (within 2% of arm c) fired — 387.2 s and 391.2 s against
385.2 s, +0.5% and +1.6%. At 25.7k–33.9k rows over a ~390 s run the mutex is not the
bottleneck; the reads are. Trace volume 3.5–4.1 MB per class, so "unbounded" never bit.

**The pre-registered rule is UNEVALUABLE, and that is the result.** At face value the
scorer returns `best |rho| = 0.616 (mean_abs_gap_blocks)`, `AUC(hemco vs met) = 0.670
(n=334 vs 286)`, `VERDICT: SEPARATION`. It also voids its own output on every arm:
`state-machine fidelity: ** MISMATCH on 137/598 handles ** — the detector replay is wrong;
everything below is void`, plus met's denominator tripping both new implausibility guards
(52,947 MiB of decisions against 5,978.9 MiB of distinct objects, 8.86×; replay 52,947
chunk-decisions against the mount's 2,944). And **the mismatch lands precisely on the
handles that carry the verdict**:

| class/arm | handles | mismatching | prefetching | prefetching **and** faithful |
|---|---|---|---|---|
| hemco/a | 6272 | 178 | 168 | 4 |
| hemco/b | 6279 | 175 | 166 | 3 |
| met/a | 598 | 137 | 143 | **8** |
| met/b | 603 | 137 | 143 | **8** |

135 of met's 143 prefetching handles are unfaithful. Rescored on the faithful subset, ρ
collapses to **−0.412 (met/a) and −0.082 (met/b)** — the sign flips between replicates —
and AUC to **0.438** (n = 7 vs 16). That is the letter of NO SEPARATION, but from n = 8
and n = 3, which is exactly the minimum-n degeneracy gate 5g asked upstream to guard. The
honest verdict is neither of the rule's two outcomes: **UNEVALUABLE at the fidelity the
instrument itself requires.** (My first reading of *why* — "the rule asks a per-handle
question of a workload that has no per-handle locality" — is **retracted** in the follow-up
below: the fidelity failure is two tool defects, not a property of the workload, so the rule
may be evaluable once the replay records the window input the live code uses.)

**Why, measured from the traces.** met/a is 25,666 rows over 598 handles and **twelve
distinct keys** — mean 49.8 handles per key, max 77, 100% of keys multi-handle, and
**0 of 598 handles is the sole reader of any object it touches**. hemco/a is 6,272
handles over 204 keys (30.7 per key, 96% shared, 8 sole readers, and **0** of the 164
mismatching prefetchers). 48 MPI ranks open the same twelve MERRA-2 files. The sharing is
real and it does inflate the per-handle instrument: per-handle net cold waste on HEMCO is
**8431.0 MiB, which exceeds the mount's entire waste budget** (9.0183 − 3.6979 = 5.32 GB
from all causes), because bytes a sibling reads count as this handle's waste, at an
inflation factor of handles-per-object (~30–50). Gate 5h saw the first 2.0–2.4× of this
with 6 handles on 1 object.

> **Correction — sharing is *not* what broke fidelity, and the dedup factor is 3.43×, not
> 13.4×.** I first attributed the mismatch to the mount suppressing a dispatch a sibling
> already holds. It cannot: `dispatched: len(pbs)` is taken straight from `h.pf.observe`
> (`fs.go:825-829`) **before** `go f.store.Prefetch` runs, so no sibling and no cache can
> reduce that column. And the 13.4× came partly from my own error — I passed arm a's
> counters as the run total, halving the denominator. See *The capture, follow-up* below:
> the real causes are trace row reordering (met, 74.5% of mismatches) and a **missing
> `perHandleWindow` column** (HEMCO, 94% of mismatches), and the replay/mount gap
> decomposes exactly as **2.70× window inflation × 3.43× genuine dedup = 9.25×**.

**What the capture does answer: the floor's multiplier.** P5's 1.0–1.4 GB is a
*mount*-level prediction (`fill_bytes{demand}`), measured directly at ~1.23 GB in gates
5c/5f and constant across eight policies; the per-handle instrument's 8.43 GB is inflated
by the sharing above and does not score it. What is new is the count gate 5f could not
see: **HEMCO pays 24,762 pre-decision cold reads over 204 keys — ~121 cold starts per
object**, 3.9 per handle, because 30–50 ranks each cold-start independently on the same
file. Gate 5f found the mechanism on one handle; the capture shows the floor's structure
is every rank paying the same entry fee on the same object. It also closes gate 5b from
the other side: the reason no per-handle flag could reach the waste across eight policies
is that the detector's state is per-open, the waste is per-open, and there are 30–50 opens
per object — **no setting of a per-open window can see the other 49.**

**The instrument behaved correctly, and that is why this gate produced a result rather
than a false one.** The fidelity gate and both implausibility guards fired on exactly the
arm that deserved them (met 8.86× flagged, HEMCO 0.94× not), and without them
`SEPARATION, ρ = 0.616` would have been reported as this campaign's answer. To make the
rule answerable the replay must model the **shared cache**: all handles of a mount against
one simulated cache, dispatch suppressed for a resident or in-flight block, credited as
used if *any* handle later reads it. That is `byte_follow_through_global`, asked for in
gate 5g as an interpretive nicety and now the only unit in which the question has an
answer on this workload; the per-handle column survives as a strict lower bound.

**Harness bug worth recording.** Job 21 lost arms a and b to
`(( miss )) && { …; return 1; }` as the last statement of `mount_lith` — with `miss=0` the
arithmetic is false, so the *function* returned 1 and both traced arms were skipped after
mounting cleanly and writing their traces. The guard added to prevent a silent capture
failure became one. Fixed with an explicit `return 0`; arm c skips that block, so it ran,
which is why the perturbation control exists at all. Related and reported to lith#264:
under `--daemon` an unwritable `--pf-trace` path still mounts successfully *and* the
`level=ERROR "prefetch trace disabled"` goes to `/tmp/lith-<uid>-mount.log` — the one
failure mode that costs a full run and yields nothing is both non-fatal and invisible in
exactly the mode a capture uses. The harness now proves both trace files exist before
launching `mpirun`.

Cost: ~35 min of one `c8g.48xlarge` across both jobs. Artifacts:
`data/lith-gates/capture-verdict.txt`, `capture-results.txt`, `capture-all4.handles.csv`,
`capture-subset-scoring.txt`, `capture-traces.tgz`.

## The capture, follow-up — #269 on the real traces, and two corrections to my own diagnosis (2026-09-19)

$0, head node, banked traces, lith `main` = `3bcb250` (includes #269 and #270). Upstream
asked one design question — *are trace rows written in true arrival order? if not I need a
timestamp column before you capture again* — and asserted that #269's degeneracy guards would
turn my hand-derived no-verdict into the tool's own output. Both are now measured, neither
answer was the expected one, and testing them retracted part of what I had just posted.

**Row order: no, and a timestamp in `tracePF` would not fix it.** `gap = off − lastReadEnd`,
and `lastReadEnd.Store(end)` happens *after* the row is written and only on the window path
(`fs.go:834`; the parts/footer branch correctly doesn't touch it, so the test is
unconfounded). So consecutive window rows of one `fh` in true issue order must satisfy
`gap == off − (prev_off + prev_len)`. They don't: **481/25,666 = 1.87% of met/a's rows are
gap-self-inconsistent** (met/b 2.00%, HEMCO 0.39%/0.44%), over 114–128 handles per arm, and
some are impossible in order rather than merely odd — `recorded_gap = 0` (meaning
`off == lastReadEnd` at decision time) on a handle whose previous row already ended 131,072 B
*past* that offset. The mechanism is a two-mutex gap: `pfWrapper.observe` decides under
`w.mu` and releases it (`internal/fuse/prefetch.go:43-48`), then `tracePF` takes
`f.pfTraceMu` (`fs.go:333-339`), and another read on the same handle can decide and append in
between. A timestamp inside `tracePF` would timestamp the *append*, not the *decision* — it
would record the wrong order faithfully. What makes the trace replayable is a **monotonic
sequence number assigned inside `pfWrapper.observe` while `w.mu` is held**, which also
supplies the global decision order a shared-cache replay needs. Related: `after`, `window`
and `peak` are read after `observe` returns and outside `w.mu` (`fs.go:827-828`), so on a
concurrently-read handle those columns can describe a different read's transition.

**Correction 1 — the fidelity mismatch is not sibling suppression.** `dispatched: len(pbs)`
comes straight from `h.pf.observe` (`fs.go:825-829`), **before** `go f.store.Prefetch` runs
(831), so no sibling and no cache can reduce that column; my mechanism was wrong. The real
causes are two and they split by mount: of met's 137 mismatching handles **102 (74.5%)** are
also gap-inconsistent, versus **11 of 178 (6.2%)** on HEMCO. met is the reordering above.
HEMCO is not — 167 of 178 have perfectly self-consistent gaps.

**HEMCO's cause: the trace is missing an input the live code uses on every call.**
`pfWrapper.observe` calls `w.pf.SetMax(maxWindow)` before *every* `Observe`, with
`maxWindow = perHandleWindow() = clamp(budgetBlocks / len(f.handles), 2, maxReadahead)`
(`fs.go:1250-1270`) — mount-wide and varying with the number of open handles. The replay does
`prefetch.New(cfg.maxReadahead)` once (`cmd/lith-pfreplay/main.go:291`) and never calls
`SetMax` again, and **there is no trace column for that argument**. The trace's own `window`
column bounds what the mount used from below: met's **max is 17 blocks over 25,666 reads**
(p99 17, mean-nonzero 9.7), HEMCO's p99 is 11 with 87% zeros — against a replayed **223**.
That is a different program, which is exactly what a state-machine fidelity check exists to
catch, and did.

**Correction 2 — the denominator decomposes exactly, and my sharing number was wrong twice.**
I had passed **arm a's** counters (met 2944, HEMCO 4680) as the run total; the four traces are
two arms, so the sum is **15,214** and the tool's line is **9.25×**, not 18.45×. Precisely the
error `-issued` exists to catch — it caught mine. With that fixed the gap splits using a
column already emitted:

| | blocks | ratio |
|---|---|---|
| replay | 17,587 | |
| the mount's own `dispatched` column | 6,524 | **2.70× window inflation** |
| 6,524 blocks = 52,192 MiB intended vs 15,214 chunks fetched | | **3.43× genuine dedup** |
| | | product **9.25×** (tool prints 9.25×) |

So **genuine sharing dedup is 3.43×, not the 13.4× I claimed** — inside the 1.2–4.6× band
upstream calibrated the alarm on, so their 8× threshold is right and my advice to recalibrate
it for ~50× sharing is withdrawn. What tripped the alarm was the missing window input (2.70×)
times my halved denominator (2×). Corollary worth keeping: **summing the trace's own
`dispatched` column** is an independent check needing no new column, and it separates "is the
replay dispatching what the mount dispatched" from "did the cache dedupe it".

**What that retracts, and what stands.** Retracted: the sibling-suppression mechanism, the
13.4× figure, and the strong reading that the rule is unevaluable *because the workload has
no per-handle locality*. The sharing is real (598 met handles over twelve keys, 0/598 sole
readers) and does make per-handle follow-through a **3.43× lower bound**, but it is not what
broke fidelity on 135/143 met prefetchers — so with `max_window` recorded, most of those
handles should become faithful and **the rule may be evaluable on this workload after all.**
Unaffected, because they depend on neither the window nor `issued`: the ~121 cold starts per
HEMCO object, the per-open/per-object argument for the constant floor, the ~1.23 GB
mount-level figure, all three correctness controls, and P3.

**#269 does not produce the no-verdict output upstream predicted.** On the real traces `main`
still prints `best |rho| = 0.616 (mean_abs_gap_blocks)` → `VERDICT: SEPARATION`, with
`<- |rho|>=0.5 on 2+ QUALIFYING arms`, because `--min-n` counts *scored* handles (143 ≥ 8) and
nothing connects it to the fidelity gate that said "everything below is void" eleven lines
earlier. The guard needed is not min-n; it is **the verdict respecting the fidelity gate**.
#269's other two fixes did land (the summed `-issued` check is what caught my own error; the
inverted size-less ratio is suppressed), and #270 makes an unwritable `--pf-trace` fail the
mount and relaxes the mutex warning to the measured +0.5%/+1.6%.

Proposed order of work upstream: (1) `max_window` column, (2) decision sequence number under
`w.mu`, (3) *then* the shared-cache replay — building (3) first would layer sharing onto a
2.70×-overstated window. (2) is re-scorable against the banked traces; (1) needs one fresh
capture, worth funding when it lands.

Artifact: `data/lith-gates/capture-followup-269.txt`. Reported on lith#267 and #256.

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
