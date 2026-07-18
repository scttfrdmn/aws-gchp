# GCHP → AWS Calculator

Given a GCHP simulation intent, this tool estimates the AWS provisioning answer:
per-node memory, valid grid layouts, which instances fit, throughput (sim-days/day)
and **$/sim-day**, and the derived config guardrails (stack arch, NX/NY,
`domains_stack_size`, `/dev/shm`). It is the forward counterpart to
`scripts/validate_gchp_config.py` (which validates an existing run dir).

## Why it exists

Almost every wall in this benchmarking project was not knowing, up front, what a
GCHP config *demands* of AWS: C180 fullchem needs ~556 GB/node → OOMs every 128 GB
box → forces m9g's 768 GB; grid layouts must satisfy `NX·NY=cores, NY%6==0,
CS/NX≥4`; `/dev/shm` too small → SIGBUS; `domains_stack_size` too small → FMS
overflow. Each wall produced a **measured data point**. This tool turns that data
into an answer you can get *before* spending money.

## The honesty contract

Every number is tagged with its provenance:

| tag | meaning |
|-----|---------|
| **MEASURED** | read directly from a benchmark run (cited file:line+date) |
| **INTERPOLATED** | between measured points, or a small multi-point fit |
| **EXTRAPOLATED** | outside the measured range — directional only |
| **UNKNOWN** | no basis; the tool prints UNKNOWN and **refuses to rank** |

The tool will not present a guess as a measurement. When asked to rank "fastest" or
"cheapest" for a config with no measured throughput (e.g. C24 fullchem — the dataset
has exactly **one** fullchem throughput point, C180/m9g/48r/1N = 7.4 d/d), it refuses
and tells you to run the benchmark. A MEASURED result is never out-ranked by a merely
EXTRAPOLATED one on a small margin.

The data behind it is auditable JSON: `scripts/gchp_aws/data/benchmarks.json`
(measured points + per-row source) and `data/instances.json` (catalog + prices,
verified 2026-07-15). **This table is the deliverable** — add rows as new benchmarks land.

## Usage

```
cd scripts
python3 -m gchp_aws.calculator --cs-res 180 --mechanism fullchem --mode cheapest
python3 -m gchp_aws.calculator --cs-res 24  --mechanism fullchem --mode fastest --json
```

Options: `--cs-res` (24/48/90/180/360), `--mechanism fullchem|transporttracers`,
`--sim-days`, `--history full|minimal|none`, `--mode cheapest|fastest|fits-in-nodes`,
`--nodes N`, `--met standard|massflux`, `--json`.

## Worked example (C180 fullchem, cheapest)

```
#1 m9g.48xlarge  1N x 48r = 48 cores  768GB aarch64 EFA  $9.39/hr
     memory/node : 556 GB [MEASURED]
     throughput  : 7.4 sim-d/day [MEASURED]
     $/sim-day   : 30.46 USD/sim-day [MEASURED]
     WARNING: capacity AZ-specific + scarce
     CONFIG GUARDRAILS: aarch64 stack · NX=2 NY=24 · domains_stack_size 64000000 · /dev/shm 550 GB
#2 m9g.48xlarge  2N x 48r  ...  $26.32/sim-day [EXTRAPOLATED via TT ratio]
```

## Known-weak spots (the tool states these itself)

1. **Fullchem throughput now measured at 10 points across C24/C48/C90/C180** (Phase 3+4:
   m9g ladder + c8g/c7a cross-arch). Cells without a measured point EXTRAPOLATE via the
   **per-resolution** TT/fullchem ratio (1.9× C24 → 113× C180; the old flat 34× is a fallback
   that can mis-predict ~10× and says so). C360 = UNKNOWN (no restart; loud extrapolation only).
2. **Chem memory model validated** against C180 anchors: 48r=556 GB exact, 192r pred 801 vs
   measured 715 GB high-water (+12%, conservative → correctly predicts >768 GB OOM). Off-C180
   fullchem memory is still EXTRAPOLATED via resolution² but now anchored at both ends.
3. **Node-scaling has 2 points** (1N, 2N) → trusted for ÷nodes, not beyond 4N.
4. **Prices** verified live 2026-07-15/16 but drift; each carries a date + confidence.
5. **Decoupling speedup measured** (C90 fullchem, 2.23× at K=4, byte-identical) — the calculator
   does not yet model M>N speedup; it reports the baseline (inline) throughput. See
   `gchp-aws-scaling-campaign-results.md` §4.

## Reuse / architecture

`scripts/gchp_aws/`: `constraints.py` (grid layouts — shared with the validator),
`memory.py` (per-node model), `instances.py`, `throughput.py`, `provenance.py`
(the tagging core), `calculator.py` (CLI). Tests: `gchp_aws/tests/`
(`uv run --with pytest pytest scripts/gchp_aws/tests -q`).

Out of v1 scope: config emission (pcluster yaml / setCommonRunSettings edits),
live pricing/capacity API calls, spot pricing.
