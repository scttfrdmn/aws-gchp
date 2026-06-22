# GCHP Monitoring Dashboard — Implementation Plan

Final plan (supersedes `swift-swinging-reef.md`). Decisions locked 2026-06-21.

## Goal
A live dashboard for a GCHP run — progress, throughput, ETA, memory, success/fail —
that is **private to the researcher running that experiment** and works with **many
researchers running simultaneously**.

## Design model: per-user, fully private

- **Per-user bucket (multi-tenant).** The exporter writes `status.json` to **the
  researcher's OWN S3 bucket** (parameterized), never a shared one. User A's status
  lives in user A's bucket; isolation is automatic via normal bucket ownership/IAM.
  Scales to N concurrent users with zero shared state.
- **No public S3 surface.** The bucket/prefix stays private. We do NOT enable static
  website hosting or relax any public-access block. ("Only this computer" is satisfied
  by *possession of the user's AWS creds on their machine*, not by IP-filtering a
  public page — which would be weaker and riskier.)
- **Local HTML dashboard.** `gchp-monitor-ui.html` lives on the researcher's machine,
  opened from disk. It does not hit S3 directly (browsers can't sign requests); instead
  a tiny local poller (`gchp-dash.sh`) pulls `status.json` with the user's AWS creds and
  serves it to the page from `localhost`. Access requires creds on this computer.
- **Optional hardening:** add an `aws:SourceIp` Deny-unless condition (this machine:
  `47.150.84.16`, likely dynamic) to the monitor prefix. Belt-and-suspenders only;
  creds-gating already restricts to this computer.

## Verified infrastructure facts (checked 2026-06-21)
1. Run-cluster head node has `AmazonS3FullAccess` → can write `status.json` to any
   user bucket. (For least-privilege, a user can scope it to just their bucket.)
2. `gchp-shared-storage-us-east-1` has full Public Access Block on — confirming we
   should NOT try to serve a public page from project infra. Per-user private buckets
   sidestep this entirely.
3. GCHP per-step log telemetry (observed in this session's runs), parseable:
   ```
   GCHP Date: 2019/01/01  Time: 23:50:00  Throughput(days/day)[Avg Tot Run]: 1549.5  7202.7  7605.9  TimeRemaining(Est) 000:00:00  40.0% : 22.4% Mem Comm:Used  Wallclock: ...
   ```
   Plus `cap_restart` (start vs current date) and `Restarts/gcchem_internal_checkpoint`
   (the validated success signal — NOT exit code, due to the benign teardown abort).
4. Runs live at a known path: `scripts/gchp-setup-rundir.sh` →
   `/fsx/scratch/gchp_merra2_TransportTracers`, log `gchp.<startdate>z.log`.

## Build scope THIS session (core; setup/teardown deferred)

```
scripts/monitoring/
  gchp-monitor-exporter.sh   # head node: parse run -> status.json -> user's S3 bucket
  gchp-dash.sh               # local: poll status.json from S3, serve to the page on localhost
  gchp-monitor-ui.html       # local dashboard; polls localhost, auto-refresh ~10s
docs/MONITORING.md           # usage, the per-user bucket model, cost, troubleshooting
```
Deferred until validated on a real run: `deploy-exporter.sh` (systemd install),
`teardown-monitoring.sh`, optional SourceIp policy helper. (Lifecycle is already
covered by `gchp-setup-rundir.sh` + pcluster commands.)

## Exporter design — `gchp-monitor-exporter.sh`
Args: `--bucket s3://<user-bucket>/<prefix>` (or `$GCHP_MONITOR_S3`), `--rundir`
(default the helper's path), `--interval` (default 10s), `--cluster <name>`.
Loop every interval:
1. `squeue` → job id / state / elapsed / node.
2. Tail latest `gchp.*.log`; parse last `GCHP Date`, `Throughput(...)[Avg Tot Run]`,
   `TimeRemaining(Est)`, percent + mem fields.
3. `cap_restart` start→current and checkpoint presence → progress % and
   status RUNNING / SUCCESS / FAILED (FAILED only if job ended AND cap_restart did not
   advance / no checkpoint — so the benign teardown SIGABRT reads as SUCCESS).
4. Emit `status.json`; `aws s3 cp` to the user's bucket.

Draft `status.json`:
```json
{ "cluster":"gchp-run-x86","updated":"<iso>",
  "job":{"id":1,"state":"RUNNING","node":"compute-dy-c7a-nodes-1","elapsed":"00:02:13"},
  "sim":{"start":"20190101","current":"20190101_2350","percent":98,
         "throughput_days_day":1549.5,"eta":"000:00:00"},
  "status":"RUNNING","mem_used_pct":22.4,"checkpoint":false }
```

## Dashboard design — `gchp-monitor-ui.html` + `gchp-dash.sh`
- `gchp-dash.sh <s3-uri>`: loops `aws s3 cp <uri> ./status.json` every ~5s and serves
  the dir via `python3 -m http.server` on `localhost`; prints the local URL. Keeps S3
  fully private (signing happens via the user's CLI creds, not the browser).
- `gchp-monitor-ui.html`: vanilla JS, Atkinson Hyperlegible font, fetches `status.json`
  from localhost every ~10s. Shows: status badge, progress bar (start→end sim date),
  throughput (days/day), ETA, memory %, job/node, last-updated. `?run=<name>` param so
  one page can point at different status files.

## Verification (without a cluster)
- Unit-test the parser: feed `gchp-monitor-exporter.sh` a saved GCHP log + a `cap_restart`
  fixture locally (I have the exact log format), assert correct `status.json`. This is
  the bulk of the logic and is fully testable offline.
- `gchp-dash.sh` + UI: serve a hand-written `status.json` locally, open the page, confirm
  it renders/refreshes. No AWS needed.
- End-to-end (S3 round-trip + live GCHP): piggyback on the next real run rather than
  spinning a cluster up just for this.
