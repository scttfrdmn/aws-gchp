# The Cloud Is Not M/M/∞: Capacity, Queuing Theory, and Why SLURM Can't Save You

*An analysis grounded in the GCHP multi-node benchmark (June 2026), where 4-node
placement-group requests for several instance types could not be satisfied in
`us-east-2b` despite single- and double-node requests succeeding freely.*

---

## 1. Three layers, three different queuing models

The mental model that gets people into trouble is that **the cloud is M/M/∞** — infinite
servers, every request served immediately, response time equals service time, no queue ever
exists. This is the marketing abstraction, and it is *approximately* true in the body of the
demand distribution: commodity instance types at modest counts behave as if servers were
infinite. (In this study, single c7g/c8g/c8gn instances launched on demand without a hitch.)

But a real deployment is **three stacked layers, each obeying a different model**, and they
do not compose cleanly:

| Layer | True queuing model | What it controls |
|-------|--------------------|------------------|
| Marketing abstraction | M/M/∞ (delay = service time) | the story you were sold |
| EC2 capacity layer | **M/M/c/c loss system (Erlang-B)** — *non-stationary, multi-tenant* | whether you can acquire a server *at all* |
| SLURM / ParallelCluster | M/M/c **delay** system (Erlang-C) | how acquired servers are *allocated* |

The abstraction holds in the middle and **breaks in the tail**: newest/scarcest SKUs,
specific AZs, GPU/accelerator parts, and — critically — **atomic batch requests** (give me
*k* identical nodes, co-located, *now*).

### The crucial property of the capacity layer: it is a *loss* system, not a *delay* system

When you call `RunInstances` and capacity isn't there, AWS does **not** put you in a line and
serve you when a slot frees. It returns `InsufficientInstanceCapacity` **immediately** —
*blocked and cleared*. There is no queue to stand in, no position, no ETA. This is the
defining feature of an Erlang-B loss system, and it is the root of everything that follows.

An on-prem HPC cluster is the opposite: a **delay** system. The nodes physically exist. You
submit, you *wait in a real queue*, and you are served when a busy node frees. `c` is small,
fixed, and — this is the whole point — **knowable**.

---

## 2. Why SLURM cannot help with availability

SLURM's entire value proposition — priority, fairshare, backfill, gang scheduling,
topology-aware placement, preemption — **presumes the servers are obtainable.** Every one of
those features is about allocating a *known, existing* server set optimally. None of them
addresses *"can I acquire the resource at all,"* because on a real M/M/c cluster that question
is trivially **yes**: the hardware is sitting in the rack.

Cloud scarcity is an **admission/acquisition** problem that lives at a layer SLURM does not
own and cannot see into. When ParallelCluster's resume fails, SLURM receives a bare boolean —
no queue position, no ETA, no pool depth, no "try again in 4 minutes." So it can only do the
dumbest possible thing: **retry blindly on a fixed backoff, then give up.** We watched exactly
this:

```
ruby_block[retrieve compute node info] ... Retrying, 29 attempts left
...
(Code:InsufficientInstanceCapacity) Failure when resuming nodes — setting nodes to DOWN
```

What ParallelCluster actually produces, then, is an **unintentional and badly-tuned retrial
queue** (the *orbit* model in queuing theory: blocked customers don't wait in line — they
leave and re-attempt after a random delay). The literature is unambiguous that retrial systems
perform *worse* than ordinary queues: the retry traffic itself adds load and depresses
effective throughput.

The implementation tell is almost poetic. ParallelCluster drives autoscaling through SLURM's
**power-save plugin** — a mechanism designed for *on-prem* nodes that physically exist and are
merely powered off. On-prem, "power back on" essentially never fails. Reusing that exact
mechanism to mean `RunInstances` — which *can* fail — bakes the wrong failure model in at the
lowest level. SLURM thinks it's flipping a power switch; it's actually placing a bet in a loss
system.

---

## 3. The placement-group cliff: blocking probability in *k*

The single-node and 2-node runs sailed through; the **4-node** runs never satisfied. That is
not a bug — it is a blocking-probability result.

A cluster placement group requires **k servers co-located simultaneously** — an *atomic batch*
acquisition. In a contended loss system:

> **P(can't find *k* free slots together) ≫ P(can't find 1 free slot), and it rises
> super-linearly in *k*.**

Heuristically, if a single acquisition is blocked with probability `b`, an idealized
independent batch of `k` is blocked with probability `1 − (1−b)^k` — and the real, correlated,
co-location-constrained case is *worse* than independent. So the cliff we hit (1 ✓, 2 ✓,
4 ✗) is exactly the predicted shape. The placement group converted a nuisance into a wall by
turning *k* independent draws into one atomic draw against the tail of the capacity
distribution.

This is also why the dry-run probe lied: `run-instances --dry-run --count 4` reported capacity
available, because **the dry run doesn't request a placement group**. Four *independent*
instances ≠ four *co-located* instances. The constraint is the contention.

---

## 4. The twist: `c_cloud ≫ c_onprem`, but you have *zero visibility* into how big

Here is the genuinely interesting question. It is *always* true that `c_cloud ≫ c_onprem`, no
matter how you slice it — AWS's pool for any instance type dwarfs any single on-prem cluster.
The practical translation is:

> *"For a contested resource (say a brand-new GPU), I will wait in **either** case — but I
> expect to wait **less** in the cloud. Can that be modeled, or is there not enough
> information?"*

The instinct is right, and the visibility problem is real: **you cannot observe `c_cloud`, and
you cannot observe the competing global load `ρ_cloud`.** Worse, the two are not separately
identifiable from acquisition data — many `(c, ρ)` pairs produce the same blocking behavior.
So the structural model is unobservable.

**But you don't need it.** The resolution is to stop trying to estimate `c` and instead
characterize the *availability process as you experience it* — which is fully observable from
your own retry history.

### 4a. Why the size advantage shows up as *recovery speed*

At saturation, instances free at rate ≈ (busy count) × μ ≈ `c·μ`. The cloud's enormous `c`
means the **absolute rate of freed instances is enormous even at 99.99% utilization.** Freed
slots reappear constantly. So the cloud's size advantage manifests **observably** as:

- **short shortage durations** (a "BAD" spell ends quickly because the giant pool turns over fast), and
- **low blocking frequency** (you rarely hit BAD at all).

You never see `c`. You only ever see its *consequences* — and for decision-making, the
consequences are all that matter, because your wait is a function of them, not of `c` directly.

### 4b. A reduced-form model that needs no knowledge of `c`

Model your **acquirability** `A(t) ∈ {GOOD, BAD}` as a 2-state continuous-time Markov chain
(a Gilbert–Elliott / Markov-modulated availability process):

```
        β  (recovery rate, 1/β = mean shortage duration)
  BAD  ───────────────▶  GOOD
       ◀───────────────
        γ  (1/γ = mean good-spell duration)
```

- Stationary blocking probability: **B = γ / (β + γ)** = long-run fraction of time you're shut out.
- A job that begins retrying at a random (stationary) time:
  - with prob `(1−B)` it starts in GOOD → acquires ~immediately, wait ≈ 0;
  - with prob `B` it starts in BAD → must wait for recovery; residual BAD time is Exp(β),
    mean `1/β` (memoryless).

So:

> **E[wait] ≈ B · (1/β) = γ / [β(β + γ)]**

**Every quantity on the right is estimable from your own probe/retry log — no `c`, no `ρ`:**

- `B` = fraction of attempts that fail.
- `1/β` = mean length of a *run* of consecutive failures (mean shortage duration).
- `1/γ` = mean length of a run of successes (and as a consistency check,
  `B = mean_BAD / (mean_BAD + mean_GOOD)`).

The unobservable pool size is **fully absorbed** into two observable numbers. A bigger `c_cloud`
doesn't change the *form* of the model — it just pushes `B` toward 0 and `β` toward ∞, driving
`E[wait]` toward 0. That **is** the formalization of "I'll wait less in the cloud."

### 4c. The head-to-head

| | On-prem (you know everything) | Cloud (you observe only outcomes) |
|---|---|---|
| Model | M/M/c delay | 2-state availability + retrial |
| Wait | `E[W] = C(c,a) / (cμ − λ)` (Erlang-C) | `E[W] ≈ B·(1/β)` |
| Inputs | `c, λ, μ` — all known | `B, β` — estimated from your own attempts |
| Identifiable? | Yes, structurally | Only the *reduced form* (and that's enough) |

Cloud wins whenever `B·(1/β) < ` the Erlang-C delay. For commodity instances `B ≈ 0` and/or
`1/β` is seconds → cloud wait ≈ 0 → it wins by a landslide. The model says *exactly* what the
benchmark showed.

### 4d. What you must assume — and where it breaks

The reduced-form estimate is honest only under:

1. **Stationarity** over your estimation window. Capacity is strongly **non-stationary**
   (diurnal cycles, demand shocks, launch events) — so `B` and `β` *drift*. Mitigate with
   windowed / exponentially-weighted estimation and by treating known regimes (e.g. business
   hours, launch weeks) separately.
2. **Representative probes.** Your sampled availability must reflect what you'll face at submit
   time. Co-location and count constraints must be probed *as you'll request them* (the dry-run
   lesson from §3 — probe the placement group, not bare instances).
3. **Autocorrelation captured, not assumed away.** Shortages are **bursty and persistent**, not
   independent Bernoulli trials — we saw `c8a` 4-node fail repeatedly over ~30 minutes. The
   2-state Markov model captures this *by design* (that's what `1/β > 0` means); a naive
   "independent retry with success prob `1−b`" model would badly **underestimate** the wait
   because it ignores that a failure now predicts a failure soon.

Net: **tractable and useful in steady state; unreliable in the tail — and the tail is exactly
when you care.** That is the honest bottom line of the modeling question.

---

## 5. A brand-new GPU at launch: it's *rationing*, not *scarcity of supply*

It is tempting — and a draft of this document did exactly this — to say that at the launch of a
scarce accelerator `c_cloud` is *small* (fab-limited) and so the cloud's size advantage
evaporates. **That framing is wrong, and correcting it makes the queuing story sharper.**

The CSPs are the **anchor / priority customers** of the fabs. They take first allocation of
assembly-line output, at volume, often via multi-quarter pre-purchase commitments — NVIDIA and
TSMC ship to the hyperscalers before almost anyone else can buy a unit. On top of that, CSPs do
**capacity demand-planning that is strictly more sophisticated than any on-prem shop's**: the
same forecasting problem, but with vastly more telemetry (global demand signal across every
customer), better math, and the capital + datacenter footprint to provision *ahead* of demand.
So even on day one, **`c_cloud` is typically *larger*, not smaller, than what you could field
on-prem** — frequently *infinitely* larger in the sense that matters, because you **cannot buy
the part at all** (back-ordered 6–12 months) while the CSP already has racks of it powered on.

So the scarcity a small on-demand customer experiences at launch is **not a raw-supply
phenomenon. It is an allocation / rationing phenomenon.** The CSP segments its (large,
actively-grown) pool into **priority tiers** and serves them in order:

```
   reserved / committed-contract  ─┐
   Capacity Blocks for ML          ├─ served first  → low B by contract
   on-demand                       ┤  ← the RESIDUAL → high B by policy
   spot                            ─┘  leftover-of-leftovers → highest B
```

> Your blocking probability `B` is set by **which tier you bought**, not by how big `c_cloud` is.

This recasts the CSP as the **provider-side Erlang-B engineer** — which is the *historical root*
of this entire theory: Erlang invented it to size telephone trunk groups to a target
call-blocking probability. The CSP provisions and rations `c` toward a **target grade of service
for its prioritized tiers**, and lets the on-demand/spot tiers absorb the variance. It is closer
to **airline yield management / revenue-managed capacity** than to a passive pool you race
strangers for. The `B ≈ 1` an on-demand customer sees for a hot new GPU is **manufactured by the
pricing/priority structure**, not dictated by silicon supply.

### What this does to the model

Nothing structural — and that's the point. The 2-state availability process of §4 still holds;
only the *interpretation of its parameters* changes:

- `B` and `1/β` are now **functions of your tier**, not of the global supply. Buying a
  reservation is literally **purchasing a smaller `B` and a shorter `1/β`** — moving yourself up
  the priority ladder is the control input.
- The unobservable quantity is no longer "how big is `c`" but **"how does the CSP ration the
  pool across tiers, and which tier am I in"** — still unobservable from outside, still fully
  absorbed into the observable `B` and `β` you can measure from your own attempts.

### The corrected launch-day ranking

| Option | Effective `B` for *you* | Why |
|--------|------------------------|-----|
| Cloud **on-demand**, newest GPU | high (≈1 at peak) | you're in the *residual* tier by design |
| Cloud **reservation / Capacity Block** | low, by contract | you bought a priority slot — *and it's often the **only** way to touch the part*, since on-prem hardware is unbuyable |
| **On-prem you already own** | `B = 0` for you | no external contention — *but you must have been able to acquire the silicon, which at launch you usually cannot* |

So the honest inversion is **not** "on-prem beats cloud at launch." It is:

> **Ownership converts contention from external-and-unbounded into internal-and-bounded — *if you
> can acquire the hardware at all.* For the newest parts you usually cannot, which makes the
> cloud's *reservation tier* the only path to a bounded wait.** On-demand cloud, by contrast,
> hands you the rationed residual: an eventually-but-unbounded wait. AWS's product line states
> this outright — On-Demand Capacity Reservations and **Capacity Blocks for ML** exist precisely
> so you can *buy `B` down* on parts the on-demand loss system deliberately won't serve.

The deeper unification: **on-prem capacity planning and CSP capacity planning are the same
Erlang-B problem** — forecast demand, provision `c` to a target blocking probability. The CSP
just plays it with more data, more money, and a *tiered* customer base it can revenue-manage.
You, the customer, no longer *do* the capacity planning; you **buy a position in someone else's**,
and the only lever you hold is which tier you pay for.

### This study's own evidence: newness ≠ scarcity

The cleanest confirmation that scarcity is **demand/rationing, not supply age** came from our own
runs, and it is counter-intuitive:

- **`m9g.48xl` (Graviton5) is *brand new*** — the newest silicon in the entire matrix. It
  acquired **1-node and 2-node on the first attempt** (`B ≈ 0`).
- **`c8a.48xl` (AMD compute) is *not new at all*** — an established, popular workhorse. It was
  the **hardest part to acquire**: its 4-node request never satisfied, and on the second round it
  **failed to acquire even a single node** in `us-east-2b` (`B ≈ 1`).

If scarcity tracked supply age, this would be backwards. It isn't backwards — it's exactly what
the rationing model predicts: **`c8a` is contended because it's *in demand*** (everyone's default
x86 compute part), while the shiny new Graviton5 is early on its adoption curve and lightly used.
Newness buys *availability* here, not scarcity. The hot, boring, established part is the one you
can't get.

---

## 6. Worked example: fitting the model to *this study's* acquisition data

This is the model of §4 applied to the real acquisition events from the benchmark. **Caveat
up front:** we were running a benchmark, not a controlled availability experiment, so this is
*opportunistic* data — irregular attempt times, small counts, a single AZ (`us-east-2b`), and
events reconstructed from cluster-creation and SLURM resume logs. The numbers below are
**illustrative of the method**, not a rigorous availability survey. Where a parameter rests on
an assumption, it says so.

### 6a. The observed events (us-east-2b, June 2026)

What we actually saw, per instance type, as **node-acquisition attempts** (a "fail" = a
`RunInstances` / SLURM resume that returned `InsufficientInstanceCapacity`):

| instance | 1-node | 2-node | 4-node (placement group) | character |
|----------|--------|--------|--------------------------|-----------|
| m9g.48xl (Graviton5) | ✓ 1st try | ✓ 1st try | ✗ blocked (≈30+ min, never satisfied) | new, lightly used |
| c8gn / c8g / c8i | ✓ | ✓ | ✗ blocked | mixed |
| **c8a.48xl (AMD)** | round 1 ✓, **round 2 ✗** (no 1-node) | round 1 ✓ | ✗ blocked both rounds (~30 min thrash) | established, in-demand |

The **count/co-location dimension dominates** the type dimension: *every* 192-core type cleared
1- and 2-node and failed 4-node-with-placement-group. That is the §3 blocking-in-*k* cliff, and
it's the single strongest signal in the data.

### 6b. Fit #1 — single-instance acquisition (the GOOD-dominated regime)

Across the whole study, single-node and 2-node acquisitions essentially always succeeded; the
one exception was c8a round 2. Treat each (cluster-launch or resume) as an attempt:

- single/2-node attempts ≈ **~14** across all instances/rounds; failures ≈ **1** (c8a r2).
- **B̂ = 1/14 ≈ 0.07** for "small" (non-batch) acquisition.
- The one failure spell resolved on the next-round retry within the session; we lack fine
  timestamps, but mean shortage duration was **minutes, not hours** ⇒ take `1/β ≈ 5 min` (the
  SLURM resume retry granularity at which we observed recovery).

> **E[wait]_small ≈ B · (1/β) ≈ 0.07 × 5 min ≈ 0.35 min ≈ 21 s.**

Interpretation: for ordinary (non-co-located) acquisition the cloud behaves *almost* like the
M/M/∞ ideal — expected wait of seconds. This is the regime where the marketing abstraction is
true, and the fit says so.

### 6c. Fit #2 — the 4-node placement-group acquisition (the BAD-dominated regime)

This is the regime that broke the benchmark, and the fit is qualitatively different. For the
192-core parts, 4-node-with-placement-group was the *modal* outcome of **blocked**:

- 4-node attempts (across c8a/c8i/c8g/m9g, multiple nudged retries) ≈ **many**; successes ≈ **0**
  in the contended window. **B̂ ≈ 1** over that window.
- Shortage spells persisted **≥ 30 min** under repeated retry without resolving (c8a's 4-node
  thrashed CONFIGURING↔PENDING for the full window). So `1/β ≳ 30 min`, lower-bounded only
  because we *stopped* rather than because it recovered.

> **E[wait]_4node ≈ B · (1/β) ≳ 1 × 30 min = unbounded-from-below-by-30-min** — i.e. the model
> correctly reports "you cannot estimate a finite wait from this window; it exceeded your
> patience." That **is** the honest answer, and it matches the decision we actually made (take
> the 1+2-node data, tear down).

The contrast between 6b (`B ≈ 0.07`, wait ≈ 21 s) and 6c (`B ≈ 1`, wait ≳ 30 min) — *same region,
same hour, same instance families* — is the entire thesis in two numbers: **the binding
constraint was the atomic-batch co-location requirement, not the instance or the pool.**

### 6d. The naive-model trap, shown numerically

A tempting wrong model: "each node acquires independently with success `p`, so 4 nodes succeed
with `p⁴`." If you naively set `p` from the *single-node* success rate (`p ≈ 0.93` from 6b),
you'd predict 4-node success `≈ 0.93⁴ ≈ 0.75` — **"should work 3 times out of 4."** We observed
**0 of many.** The naive model is off by a mile because it assumes (a) independence and
(b) no co-location constraint and (c) no autocorrelation — all three false. The 2-state Markov
model of §4, by contrast, *expects* the persistence (it lived in BAD with `1/β` large) and so
doesn't embarrass itself. This is the §4d warning made concrete: **independent-Bernoulli retry
math will tell you a blocked batch request is fine; it is not.**

### 6e. Live probe (2026-06-28, us-east-2) — and why the cheap probe has a hole

We ran the probes live to see what's *observable for free*. Three instruments, three answers:

*(This is the operational tool referenced by the §10.4 "intelligent retrial" layer.)*

**(i) Spot Placement Score (SPS)** — and a hard lesson in *not over-reading it*. SPS is AWS's
only published capacity-ish signal, and it is **much weaker than it looks.** Straight from AWS's
documentation:

- It is a **unitless ordinal 1–10**, *not* a probability or percentage. 10 = "highly
  likely—**but not guaranteed**—to succeed"; 1 = "not likely." **No time horizon** — it reflects
  capacity *"at the time of the request,"* and *"the same request can yield different scores when
  calculated at different times."* AWS says **"act on a score immediately."**
- AWS states plainly it **"does not provide any guarantees... serves only as a recommendation."**
- It is **Spot-only and valid only under the `capacity-optimized` allocation strategy** —
  *"otherwise the likelihood of getting available Spot capacity will not align with the score."*
  We launch **on-demand** for HPC, so SPS doesn't even describe our pool.
- It **requires ≥3 different instance types** or it "returns a low Spot placement score" *by
  rule.* **Our per-type probes specified a single type each — so they were structurally
  penalized and are largely meaningless as absolute numbers.** (This is why the `.48xlarge`
  singles read uniformly 1–3.)
- The same score can repeat across AZs/Regions — it's not even a strict ranking.

What we measured (single-type, on us-east-2, target 1 → 16), *with all those caveats*:

| type | t=1 | t=16 |
|------|-----|------|
| c8a.48xl | 2 | 1 |
| m9g.48xl | 2 | 1 |
| c8g.48xl | 3 | 1 |
| c8i.48xl | 1 | 1 |
| c8gn.16xl | 3 | 3 |

The *only* defensible reading is the **direction**: scores **fall as target count rises**
(c8g 3→1), echoing the §3 blocking-in-*k* cliff. The *absolute values are not trustworthy* — they
conflate the spot pool, the single-type penalty, and the no-units scale. **SPS is an ordinal hint
for Spot-fleet placement, not an availability gauge for on-demand HPC**, and it carries no
statistical weight you can put in a wait-time formula. Treat it as "is this obviously hopeless
right now? (1) vs not-obviously-hopeless (≥5)" and nothing finer.

**(ii) On-demand `RunInstances --dry-run`, no placement group:** **OK for every type at 1/2/4/8
nodes.** This is the reassuring-but-misleading signal that bit us during the benchmark.

**(iii) On-demand dry-run *with a real cluster placement group attached* (the actual benchmark
constraint):** **also "OK" for every type at 4 and 8 nodes** — at the very same region/AZ where,
under load, the real 4-node PG resume thrashed for ~30 min and never satisfied.

**The hole:** the dry-run validates **authorization and configuration, not capacity at
fulfillment**, and *even attaching the placement group doesn't make it test atomic-batch
capacity*. AWS does **not** expose a cheap, faithful probe of "can I get *k* co-located *right
now*." The only way to learn that is to **actually attempt the allocation** — and pay if it
succeeds.

So the clean "standing probe → live `B`, `1/β`" tool from the previous draft has a real
limitation worth stating plainly:

> **For ordinary (non-co-located) acquisition, a `--dry-run` standing probe gives a usable,
> consumption-free *yes/no* on capacity-config validity. For the atomic-batch (placement-group)
> case — the one that actually breaks tightly-coupled HPC — there is no faithful non-consumptive
> probe at all. The only honest measurement is to try to allocate, which means the measurement
> *is* the consumption.** Spot Placement Score does *not* fill the gap: it's Spot-only, unitless,
> single-type-penalized, and time-of-request-only (see (i)) — a coarse ordinal hint, not a
> measurement.

This is itself a finding, and it's worth stating bluntly: **AWS exposes no statistically
meaningful, on-demand, batch-aware capacity observable.** The free signals are either
binary-and-misleading (dry-run says "OK" then fulfillment fails) or unitless-and-Spot-only (SPS).
You can cheaply confirm the *body* of the distribution exists; the *tail* — the atomic batch that
matters for HPC — you can only measure by paying to enter it. The number that would let you
compute your own batch blocking probability is precisely the number AWS does not publish.

### 6f. Ablation: does the placement group actually help on top of EFA? (measured)

We ran the experiment the §10.3 advice rests on: one cluster, three queues, identical hpc7a.96xl
compute, C180 2-node × 60 ranks — the **only** variable per queue the network transport.
(`parallelcluster/configs/bench-pgtest-use2.yaml`, `scripts/gchp-pgtest-run.sh`; metric = GCHP
internal Avg throughput.)

| config | transport | internal Avg (d/d) | outcome |
|--------|-----------|--------------------|---------|
| **pg** | EFA + cluster placement group | **153.4** | ✓ |
| **nopg** | EFA, **no** placement group | **161.6** | ✓ |
| **tcp** | no EFA (forced TCP/sockets) | — | **FAILED — `MPI_Win_create` / no threaded one-sided over TCP** |

**Finding 1 — the placement group buys ≈ nothing on top of EFA (at this scale).** 161.6 (no PG)
vs 153.4 (PG) is a statistical tie, with the *no-PG* run marginally faster. EFA already delivers
SRD/RDMA on the AWS network; the PG's extra rack-level co-location added no measurable GCHP
throughput at 2 nodes. So the placement group — which *causes* the §3 atomic-batch blocking cliff
— is **discardable for free here**. (Caveat: re-measure at large `k`, where many concurrent flows
might make segment locality matter again.)

**Finding 2 (the bigger one) — EFA is a *functional* requirement, not a performance tuning knob.**
The TCP queue didn't run *slow*; it **could not run at all**. GCHP/MAPL uses MPI one-sided RMA
(`MPI_Win_create`) with `THREAD_MULTIPLE`; OpenMPI serves that via `osc/rdma` over EFA, but the
non-RDMA fallback `osc/pt2pt` **does not support threaded one-sided over the TCP BTL** → hard
abort (*"Workarounds are to run on a single node, or to use a system with an RDMA capable
network"*). **There is no TCP floor for multi-node GCHP — there is a TCP wall.** This *sharpens*
§8: EFA isn't a knob HPC chooses for speed, it's mandatory for the application to function
multi-node — so the entire forced-non-fungibility chain (single-AZ, largest-SKU, single-type) is
*mandatory*, not a preference. The one fungibility lever that IS free to pull is the placement
group (Finding 1) — and it's the only one.

---

## 7. The cost axis: sunk amortization vs. real-time billing (and "snipe-and-hold")

Everything to here measured **time**. But the on-prem-vs-cloud decision turns on a second axis
the queuing model ignores: **when, and how, you pay.** The two worlds have opposite cost
structures, and it reshapes what "wait" even costs you.

### 7a. Two opposite cost clocks

- **On-prem is a sunk cost with a diminishing amortization window.** You paid up front; the
  hardware depreciates whether you use it or not; every idle hour is amortization burned with
  nothing to show. Your *marginal* cost to run a job is ≈ electricity. So **waiting in the
  on-prem queue is nearly free at the margin** — you've already paid; the queue just delays
  *when* you extract value from a sunk asset. (And the on-prem wait, recall §6's troll, can be
  **days to weeks** on a contended shared resource — but those days cost you ~nothing extra.)
- **Cloud bills in real time.** You pay *only* while instances run — but you pay *continuously*
  while they run, including **every second they sit idle waiting for siblings.** Marginal cost
  is the whole sticker price per hour. So in the cloud, **waiting with resources held is
  expensive**, and waiting *without* holding (blocked) is free-but-fruitless.

This flips the intuition about the §6 numbers. On-prem's "30 min" (or 3-day) wait is cheap-but-
long; the cloud's wait is short-but-metered. The right comparison isn't wait-time alone, it's
**wait-time × marginal-cost-of-waiting**, and those marginal costs differ by orders of magnitude.

### 7b. "Snipe-and-hold": beating the atomic-batch cliff by paying for idle

The placement group fails because it demands *k* nodes **atomically** — all-or-nothing in one
co-located request (§3). But there's an alternative the loss system actually permits:
**acquire the nodes one (or a few) at a time as capacity blinks available, and *hold* them
until you've collected all *k*** — SLURM-style accumulation, but at the acquisition layer.

This trades the hard problem for an easier one:

> P(get *k* atomically, now) ≪ P(get 1 now) accumulated over a window until you reach *k*.

Each single acquisition draws from the *body* of the distribution (high success), not the tail.
Given enough time and persistence you assemble the set. **But it has two real costs:**

1. **You pay for held instances while you collect the rest.** Snipe node 1, it bills from second
   one while you hunt for nodes 2–4. If collection takes 40 min, you've paid 40 min × (held
   count) for instances doing nothing. This is the cloud's real-time clock biting exactly where
   on-prem's sunk clock wouldn't.
2. **It likely breaks the placement group.** A cluster PG wants its members **co-located in one
   allocation**; nodes sniped independently over time land wherever capacity happened to be —
   different racks, spine hops away. You may *get* `k` nodes but **lose the low-latency
   topology** the PG existed to guarantee. For embarrassingly-parallel work, fine. For
   tightly-coupled MPI with heavy halo exchange (i.e. GCHP), you've acquired the nodes and
   degraded the very thing that made multi-node worthwhile. (You can ask for a PG on the
   late-added nodes, but then *those* acquisitions inherit the batch-blocking problem you were
   trying to dodge.)

So snipe-and-hold converts an **availability** problem into a **cost + topology** problem. For a
short benchmark run it can be the pragmatic move (pay a few $ of idle to dodge a 30-min wall).
For sustained production it's usually a false economy.

### 7c. Why reservations are *not* obviously better than on-prem

The "just reserve it" fix (§10.1) buys `B = 0` — but at a cost structure that, on inspection, is
**on-prem's sunk cost wearing a cloud badge:**

- A reservation (or Capacity Block, or 1–3yr commitment) bills **whether or not you use it** —
  exactly the on-prem amortization clock, just rented instead of owned.
- So a reservation gives you on-prem's *cost disadvantage* (pay-for-idle) **without** on-prem's
  *cost advantage* (you eventually own a depreciated-but-usable asset; the reservation expires
  worth nothing).
- The reservation's *only* edge over owning is **elasticity at the boundaries** — you can size
  it per-project and let it lapse, no datacenter, no 3-year hardware bet. For steady,
  predictable, high-utilization HPC load, that edge is thin, and the math can favor **owning**
  — which is the uncomfortable conclusion the whole industry keeps rediscovering for
  flat, heavy workloads.

The clean way to see it: **reserving converts the cloud's loss system back into a private M/M/c,
but it also imports the sunk-cost clock to do so.** You don't escape the amortization trade-off;
you just rent into it. The cloud's genuine, unmatchable advantage remains the *bursty/variable*
regime where on-demand's pay-only-when-running clock wins precisely *because* you're not holding
idle capacity — which is exactly the regime where the loss system also rarely blocks you. The
cloud is best where its cost model and its availability model are *both* favorable; it's worst
(reservations, atomic batches, hot parts) where you're forced onto a cost model that looks like
on-prem's without the ownership upside.

---

## 8. The master principle: the cloud rewards *fungibility*, and HPC is maximally non-fungible

Before the tactics, the principle that unifies them — and it's hidden in plain sight in the SPS
fine print from §6e. Two clues:

1. SPS is *"only relevant... configured to use the **`capacity-optimized`** allocation strategy."*
2. SPS *"requires **≥3 different instance types**"* or it returns a low score by rule.

Decode `capacity-optimized` against the EC2 Fleet docs and the trick is exposed. A **capacity
pool** is one `(instance type × Availability Zone)` combination. The `capacity-optimized`
strategy *"identifies the pools with the highest capacity availability"* and routes you there —
but **it can only do that if you handed it multiple pools to choose from.** One instance type in
one AZ = exactly one pool = nothing to optimize. So:

> **`capacity-optimized` is AWS-speak for "tell me what you'll *accept*, not what you *want*, and
> I'll find you room." The ≥3-types rule is the same demand: express fungibility or get a bad
> answer.**

This reframes the entire document. Your **effective `c` is the union of every pool you're
willing to accept** — and blocking probability falls as that union grows. The cloud is
architected to reward **fungible demand**: "give me ~240 vCPUs of *roughly* this shape,
*anywhere* in the region, *any* of these 5 instance types" draws from a giant merged pool and
almost never blocks. AWS's whole capacity toolchain — Fleet, ASG, attribute-based selection,
capacity-optimized, even the SPS scoring rules — is built to **reward customers who relax
`(type, AZ, count-atomicity)` and penalize those who pin them.**

**HPC is the pathological opposite — it is maximally *non*-fungible. And the crucial point is
that its non-fungibility is not a *preference* — it's a *forced requirement chain*, most of it
rooted in one AWS feature: EFA.** And EFA is not optional: we measured (§6f) that multi-node GCHP
forced onto TCP doesn't run *slow*, it **fails outright** — MAPL's threaded one-sided RMA has no
working non-RDMA path. So EFA is a *functional* requirement, and the moment you require it, AWS's
own constraints strip away every fungibility knob, one after another:

```
tightly-coupled MPI (GCHP)
  └─ needs EFA/RDMA           (else TCP fallback ⇒ multi-node scaling dies)
       ├─ EFA only on the largest few sizes of a family*    ⇒ can't relax SIZE down  ("full instance" — FORCED, not picky)
       ├─ "EFA traffic can't cross Availability Zones"       ⇒ can't relax AZ    (a HARD AWS limit, not a latency preference)
       ├─ homogeneous ranks for MPI load balance             ⇒ can't relax TYPE  (one arch/clock/core-count)
       └─ + cluster placement group for lowest latency       ⇒ atomic, single-AZ, k-node batch
```
*EFA is offered only on the top one or two sizes of each family — e.g. the entire m9g and hpc7g
lines expose EFA *only* on `.48xl` / `.16xl` respectively; smaller m9g sizes return `EFA=False`
(we saw this directly). A few families (e.g. c8i) offer it on the top two sizes — so "largest,"
not literally "the single biggest," but never the small/cheap sizes you'd otherwise diversify into.

So the table below isn't a list of *choices* HPC happens to make — it's what the EFA requirement
*leaves you with*:

| The cloud rewards (lowers `B`)… | EFA-based HPC is *forced* into… | forced by |
|--------------------|------------------------------|-----------|
| any of N instance types | **one** type | MPI load balance (homogeneous ranks) |
| any instance *size* | the **largest** size(s) | **EFA only offered on the top SKU(s)** (m9g→.48xl only, hpc7g→.16xl only) |
| any AZ | **one** AZ | **hard rule: "EFA traffic can't cross Availability Zones"** (+ AZ-bound FSx) |
| capacity assembled over time from many pools | *k* nodes **co-located, atomically, now** | placement group for latency — **but §6f shows this one is discardable for free: EFA-no-PG ≈ EFA+PG** |
| interruptible / fungible units | identical, gang-scheduled, all-or-nothing | the MPI job is one barrier-synchronized unit |

The placement-group row is the **one** lever §6f proved you can actually relax at no throughput
cost — dropping it removes the atomic-batch co-location constraint (the §3 cliff) while EFA still
carries the traffic. Every *other* row is welded shut by the EFA functional requirement.

Every axis the cloud lets you relax to lower `B`, EFA-based HPC has *already had relaxed away by
requirement*. That's why we hit the wall: a single-type, single-largest-size, single-AZ,
atomic-*k*-node-placement-group request is **the single least-fungible thing you can ask an
elastic loss system for — and almost none of it was a free choice.** We didn't *decide* to be
picky; requiring EFA *made* us picky on four axes at once. We walked up to the capacity machinery
and asked it the one question it is explicitly architected to be bad at, because the workload
gave us no other question to ask.

And note the cruel twist for **benchmarking specifically**: you *must* be non-fungible, because
the entire point is to measure *one named instance type*. Diversifying across types — the cloud's
own prescribed fix — would mix the architectures you're trying to tell apart. **Benchmarking is
structurally adversarial to the cloud's capacity model.** (Production HPC has slightly more room —
"c8a OR c7a, 60 ranks/node" is tolerable if you accept a heterogeneous cluster — but the
co-location and single-AZ constraints remain, so even production HPC sits near the non-fungible
extreme.)

### The two models, and the tension

Step back and the whole document is **two models in tension:**

1. a **loss model** (Erlang-B) — the bare capacity layer, where blocking probability `B` rises
   with how *specific* (small `c`) your request is; and
2. a **relaxation model** — AWS's *answer* to the loss model: Fleet / capacity-optimized /
   attribute-based selection, all of which **lower `B` by letting you enlarge `c`** through
   fungibility (accept more types, sizes, AZs, assemble over time).

For most cloud workloads these two live in comfortable balance: the loss model threatens, the
relaxation model rescues, and you barely notice. **The HPC tragedy is that the relaxation model —
the cloud's built-in escape hatch from the loss model — is exactly the one EFA-based HPC is
*forbidden* to use.** Each requirement in the chain above closes one relaxation lever, and
tightly-coupled MPI closes *all four at once*. So HPC faces the loss model **naked**, with the
smallest possible `c`, and no access to the mechanism every other workload uses to escape it.

The unifying statement: **the cloud converts capacity risk into a fungibility tax — and EFA-based
HPC is constitutionally unable to pay it in the cheap currency (flexibility).** It can only pay in
the expensive currency: **dollars** (reserve capacity → §10.1, a private contention-free `c`) or
**blocking** (eat the loss-system wait, as we did). Reserving isn't a tactic among others; for
genuinely tightly-coupled work it's the *only* lever left, precisely because physics has revoked
all the others.

---

## 9. Data gravity: the fourth tension (and why "just AZ-shop" is glib)

§8's escape hatch for *some* of the blocking — "don't pin the AZ, take whichever has room" —
quietly assumed your **data** is free to follow the compute. It isn't. Data gravity is a fourth
force, and it fights the relaxation model directly: **every AZ you want to be able to shop into
needs your working set reachable there**, and bytes have a floor price.

### 9a. Where your source of truth lives decides the whole cost

| source of truth | cost to AZ-shop | transfer $ |
|---|---|---|
| **regional S3** (e.g. gcgrid) | re-hydrate a per-AZ cache (time only) | in-region S3→EC2 is **free** |
| **AZ-bound FSx/EBS only** | stuck — must replicate to the new AZ | cross-AZ **$0.02/GB each way** |
| **another region** | hydrate cross-region (slow) | cross-region egress **$0.02/GB** ← the "yikes" |

The resolution to *"am I supposed to replicate data all over?"* is **no — keep the authoritative
copy in regional S3 and treat FSx/EBS/NVMe as a disposable per-AZ cache hydrated from it.** S3 is
**regional, not AZ-bound**, equally reachable from every AZ, and S3→EC2 in-region is free. So
AZ-shopping costs *re-hydration latency*, not a transfer bill — **unless you cross regions**,
where it becomes both (this is exactly why the matrix's gcgrid-in-us-east-1 / compute-in-us-east-2
split made every FSx take ~33 min, and why CLAUDE.md says "deploy where the data lives").

So data gravity **reduces AZ fungibility** — the very lever §8 told you to pull. The two models
now bargain: *how many AZs do I pre-stage (cost/latency) vs. how much blocking do I eat?* For
bounded working sets (our C180 run: ~1 GB restart + a few GB of one day's met) the answer is easy
— stage from S3 on demand. For multi-TB GPU/ML weights+datasets the hydration tax dominates and
pre-staging across AZs gets genuinely expensive. **Data gravity is why "just be fungible" is cheap
advice for stateless web apps and expensive advice for data-heavy HPC/ML.**

### 9b. The staging-vs-acquisition ordering race

Worse, staging and acquisition are two async operations that **must both finish**, and you pay for
whichever wins first:

| order | failure mode | cost |
|---|---|---|
| **compute-first, then stage** | idle compute during `T_stage` | `$/hr × T_stage` (192-core @ $8/hr × 33 min ≈ **$4.40/run**) |
| **stage-first, then acquire** | capacity appears in a *different* AZ than you staged | wasted stage + re-stage (time) + cross-AZ egress $ |

Stage-first is the worse trap because it collides with 9a: you committed data to AZ-X, capacity
showed up in AZ-Y. **You don't fix this by picking an order — you fix it by making staging not be
on the critical path at all:** authoritative copy in regional S3 + either lazy-loading FSx (paging
overlaps compute — what the matrix did) or a quick `aws s3 cp` of the bounded working set to
**instance-local NVMe at boot**. Then "staging" becomes fast, overlappable, AZ-agnostic, and
idle-free instead of a slow blocking step you must sequence against scarce compute.

### 9c. The kicker: storage is *also* a loss system, and the draws are AZ-correlated

The cleanest framing, and the one that generalizes the whole document: **the Erlang-B loss model
is a property of provisioning *any* AZ-pinned physical resource on demand — not just compute.** FSx
Lustre returns `InsufficientCapacity` too (we hit transient FSx provisioning limits this session);
so do high-IOPS EBS and even Capacity Reservations. So "staging is the recoverable, just-takes-time
side" was too clean: **the FSx *create itself* can be blocked in the AZ where your compute landed.**

Data-heavy HPC therefore must win a **conjunction** of correlated AZ-pinned draws —
`{k co-located nodes} AND {FSx in the same AZ}` — and a hot AZ is hot for *everything*, so the two
blocks are **positively correlated** (anti-correlated with your need). The conjunction's blocking
probability is worse than either alone: the atomic-batch cliff, applied across two resource classes
at once.

This is the decisive argument for the **S3-regional + instance-local-NVMe** pattern: NVMe scratch
*comes with the instance* (win the compute draw, you already have the scratch — zero extra AZ draw),
and S3 is regional (no AZ draw at all). It is the **only** storage pattern that doesn't stack a
second correlated loss-system bet on top of the compute one. Per-run FSx and persistent-per-AZ FSx
both add that second bet — persistent-per-AZ in the worst way, since it *also* surrenders the AZ
fungibility of 9a (you can only shop among the AZs you pre-paid to stage). **Minimize the number of
distinct AZ-pinned resources a run requires; ideally one (the compute), with data riding S3 +
NVMe.** *(The session's own tooling reflects this: spore.host's `spawn` pulls bounded working sets
from regional S3 at launch, and `lagotto` watches for the single compute draw and fires when it
appears — data pre-staged AZ-agnostically, only compute acquired opportunistically.)*

---

## 10. The honest engineering responses

Every workable fix is, at root, **a way to become more fungible (pay the tax in flexibility) or
to opt out of the loss system entirely (pay it in dollars)** — i.e. to restore a knowable,
contention-free `c` that SLURM can actually schedule over:

1. **Reserve the capacity** (*pay the tax in dollars*) — On-Demand Capacity Reservations /
   Capacity Blocks. You pre-acquire *c* guaranteed servers; the pool becomes *yours*; resume can
   no longer fail; SLURM works as designed. You've bought back a genuine, private M/M/c — and
   imported its sunk-cost clock (§7c). *(The real fix for tightly-coupled HPC that can't relax.)*
2. **Diversify the pool** (*pay the tax in type/AZ fungibility* — the canonical §8 move) —
   multiple instance types per compute resource, multiple AZs/subnets. You sample from the
   *union* of pools `capacity-optimized` was built to exploit, raising effective `c` and
   **decorrelating** the availability processes — both push `B` down. (This study ran
   single-type, single-AZ: the *least* fungible, worst case. A `c8a OR c8i OR c7a` resource
   across `2a/2b/2c` would have had a far lower 4-node blocking probability — at the cost of a
   heterogeneous cluster, which a *benchmark* can't accept but production often can.)
3. **Drop the placement group** (*pay the tax in co-location fungibility — and it's nearly free*) —
   AWS's own guidance is *soft* (validator: a PG *"may improve network performance"*; **EFA does not
   require a PG** — its hard constraint is single-AZ, not single-segment). **We measured it** (§6f):
   a 2-node C180 ablation on hpc7a.96xl found **EFA-no-PG (161.6 d/d) ≈ EFA+PG (153.4 d/d)** — a
   statistical tie, with the *no-PG* run marginally faster. So at this scale the PG buys **no
   throughput on top of EFA**, while dropping it removes the atomic-batch co-location constraint
   that drives the §3 blocking cliff. **Dropping the PG is therefore a near-free `B` reduction** for
   small node counts. (It may matter more at large `k` where many flows contend; re-measure before
   assuming it scales. And for a *clean scaling benchmark* the PG keeps network conditions
   controlled — a methodological choice, not a performance one.)
4. **Make the retrial intelligent, not blind** — a meta-scheduler that holds the job *above*
   SLURM and retries on a smart schedule. For *non-batch* acquisition, drive it off a standing
   `--dry-run` probe (the by-hand technique used to unstick the matrix). For the *batch/PG* case,
   §6e showed there's **no faithful free probe at all** — SPS is Spot-only, unitless, and doesn't
   describe on-demand capacity — so the only real signal is **your own recent attempt history**
   (a windowed estimate of `B` and `1/β` from actual try-and-fail outcomes). Still strictly better
   than SLURM's blind fixed-backoff, but be honest that it's *learned from consumption*, not
   probed for free. Either way it should be a first-class layer, not a human with a terminal.
5. **Snipe-and-hold instead of atomic-batch** (§7b) — accumulate the *k* nodes one/few at a time
   from the high-probability *body* of the distribution and hold them, rather than demanding all
   *k* at once from the tail. Costs real-time billing for held-idle instances and usually
   sacrifices the placement-group topology — an availability win paid for in **dollars + latency**.
   Pragmatic for short runs, a false economy for sustained tightly-coupled production. **Note: AWS
   explicitly warns *against* this for cluster PGs** — *"use a single launch request"*; *"if you
   try to add more instances to the placement group later... you increase your chances of getting
   an insufficient capacity error."* So snipe-and-hold and a placement group are mutually exclusive
   in practice.
6. **Keep data AZ-agnostic** (*don't stack a second loss-draw* — §9) — authoritative copy in
   **regional S3**; per-AZ cache via lazy-loading FSx or a boot-time `aws s3 cp` to instance-local
   **NVMe**. This makes "staging" overlappable, idle-free, and AZ-agnostic, so AZ-shopping (item 2)
   actually works and you don't have to win a correlated `{compute AND FSx in same AZ}` conjunction.
   The spore.host pattern (`lagotto` watch → `spawn` pull-from-S3) is exactly this.

---

## 11. Bottom line

A real M/M/c cluster gives you **bounded, knowable** contention: you know `c`, you can compute
Erlang-C waits, you can capacity-plan. The cloud trades that for **higher mean availability but
unbounded, *unobservable* contention** — you can't compute your own blocking probability from
first principles because you can never see the pool or the global load.

And keep the §6 result in perspective: **30 minutes is the cloud losing, and still beating
on-prem.** That half-hour of failed retries was our *worst* case — and on a contended on-prem
shared resource, the *same* job routinely waits **days to weeks** in the fairshare queue. The
cloud's bad day is the on-prem queue's good day. The reason it doesn't *feel* that way is the
cost asymmetry (§7): the on-prem wait is nearly free at the margin and can't be abandoned, so you
absorb it silently; the cloud wait is metered and abandonable, so 30 minutes feels like an
outrage. Both framings are true and not contradictory — it's **unbounded-but-usually-seconds**
(on-demand, body of the distribution) vs **bounded-but-often-enormous** (on-prem fairshare). We
walked away at 30 min *because we could*; the on-prem user is position #47 and cannot.

For interactive and bursty work, that trade is a clear win. For tightly-coupled HPC that needs
*k* co-located nodes *now*, you've arguably surrendered the one property — predictability — that
made capacity planning possible, **unless you pay to reserve**, at which point you've
reconstructed the on-prem cost model inside the cloud — **the sunk-cost amortization clock and
all** (§7c), minus the eventual asset.

And the resolution to the visibility paradox: you don't recover predictability by estimating the
unknowable `c`. You recover it by measuring the **availability process you actually experience**
(`B` and the recovery rate `β`) — quantities that fully absorb the hidden pool size and turn
"how big is `c`?" into the answerable "how often, and for how long, am I shut out?" The
worked example (§6) shows both faces in one dataset: `B ≈ 0.07`, wait ≈ 21 s for single
instances; `B ≈ 1`, wait ≳ 30 min for the 4-node placement group — same hour, same region.
And the scarcity was driven by **demand and co-location, not supply or newness**: the
brand-new Graviton5 was freely available while the established, popular c8a was the part we
couldn't get. The model is reliable right up to the tail — and the tail (in-demand parts,
atomic batches, shocks, launches) is both where it strains *and* where, for a resource you can
own, on-prem quietly wins.

And don't forget the second resource you must win: **data has to be there too.** The loss model
governs *any* AZ-pinned on-demand resource — FSx Lustre and provisioned storage block in hot AZs
just like compute (§9c) — so data-heavy HPC must win a *correlated conjunction* of draws, not one.
The discipline that keeps that from compounding: **authoritative copy in regional S3, disposable
per-AZ cache (lazy FSx or instance-local NVMe) hydrated from it** — so "where's my data" becomes
an AZ-agnostic, idle-free, single-draw problem instead of a second loss-system bet stacked on the
first (§9).

ParallelCluster's "elastic SLURM cluster" abstraction is genuinely useful — right up until you
hit that tail. Then it cannot paper over the fact that **it never controlled the capacity in the
first place** — nor the data's gravity, nor that the storage layer is the same loss system wearing
a different hat.
