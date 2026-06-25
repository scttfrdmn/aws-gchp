# GCHP Run Monitoring

A lightweight, **private, per-user** live dashboard for a GCHP run: simulation
progress, throughput, ETA, memory, and success/fail — without exposing anything
publicly and without interfering with other researchers running at the same time.

## Model

```
  [head node]  gchp-monitor-exporter.sh  --->  s3://YOUR-bucket/gchp-monitor/<run>/status.json   (PRIVATE)
                                                          |
  [your laptop]  gchp-dash.sh  <--- pulls with YOUR aws creds, serves on localhost
                      |
                  browser: http://localhost:8787/   (gchp-monitor-ui.html)
```

- Output goes to **a bucket you own** (parameterized) — so concurrent users never
  collide and never see each other's runs.
- Nothing is made public. The dashboard runs **on your computer** and reads S3 with
  **your** AWS credentials, so it is reachable only from a machine that has those creds.
- Success is judged by `cap_restart` advancing + a checkpoint being written — **not**
  the job exit code (GCHP 14.7.1 has a benign teardown abort; see
  [RUNNING-GCHP.md](RUNNING-GCHP.md)). So a completed run shows **SUCCESS** even though
  SLURM may mark the job failed.

## Quick start

**1. On the cluster head node**, install the exporter as a systemd service pointed at
your own bucket (recommended — survives head-node reboots, restarts on failure):

```bash
# exporter is bundled in the stack at /fsx/stacks/<arch>/gchp14.7.1-validated/ if the
# stack was rebuilt since this was added; otherwise copy scripts/monitoring/ up.
sudo ./deploy-exporter.sh \
  --bucket s3://my-bucket/gchp-monitor/run1 \
  --rundir /fsx/scratch/gchp_merra2_TransportTracers \
  --cluster gchp-run-x86 --interval 10

systemctl status gchp-monitor      # health
journalctl -u gchp-monitor -f      # logs
```

Or, for a quick one-off without installing a service:
```bash
nohup gchp-monitor-exporter.sh --bucket s3://my-bucket/gchp-monitor/run1 \
  --rundir /fsx/scratch/gchp_merra2_TransportTracers --cluster gchp-run-x86 \
  > /tmp/gchp-exporter.log 2>&1 &
```
(Note: a bare `nohup` does NOT survive a head-node reboot; the service does.)

**2. On your own computer**, launch the dashboard:

```bash
scripts/monitoring/gchp-dash.sh s3://my-bucket/gchp-monitor/run1 --profile aws
# open the printed http://localhost:8787/
```

The page auto-refreshes every 10s.

**3. (Optional) Restrict reads to this computer's IP** — belt-and-suspenders on top of
the credential gating:

```bash
scripts/monitoring/lock-monitor-ip.sh --bucket my-bucket --profile aws
# uses this machine's detected public IP; re-run with --ip if it changes,
# or --remove to undo. Merges into (never clobbers) any existing bucket policy.
```

**4. Tear down** when the run is done (on the head node):

```bash
sudo ./teardown-monitoring.sh        # stops + removes the service, posts a final STOPPED status
```

## status.json fields

| field | meaning |
|-------|---------|
| `status` | RUNNING / SUCCESS / FAILED / PENDING / IDLE |
| `sim.percent` | sim progress %, computed from BEG_DATE→END_DATE (CAP.rc) vs live GCHP date |
| `sim.current_date/time` | latest `GCHP Date:`/`Time:` from the log |
| `sim.throughput_days_day` | latest avg throughput (sim days per wall day) |
| `sim.eta` | GCHP's `TimeRemaining(Est)` |
| `mem_used_pct` | memory used % from the GCHP step line |
| `checkpoint` | whether `Restarts/gcchem_internal_checkpoint` exists & is non-empty |
| `job.*` | SLURM id / state / elapsed / node |

## Permissions

- **Head node → your bucket:** the run-cluster head node has `AmazonS3FullAccess`, so it
  can write to any bucket your account owns. For least privilege, attach a policy
  allowing `s3:PutObject` only on `arn:aws:s3:::my-bucket/gchp-monitor/*`.
- **Your laptop → your bucket:** uses your normal AWS CLI creds (`--profile`).
- No bucket is ever made public; no public-access-block changes are needed.

### Optional: lock reads to one machine's IP
If you want to also restrict by source IP (belt-and-suspenders), add a bucket policy
condition `aws:SourceIp` for your egress IP on the `gchp-monitor/*` prefix. Note home/ISP
IPs are often dynamic, so this needs re-applying when your IP changes; the credential
gating already limits access to machines holding your creds.

## Cost

Negligible — a few KB `status.json` overwritten every 10s. S3 PUT/GET on a handful of
small objects is well under a cent per run.

## Status values

- **RUNNING** — job in queue and executing.
- **PENDING / CONFIGURING** — job queued, compute node provisioning.
- **SUCCESS** — `cap_restart` advanced past the start date AND a checkpoint exists
  (true even with the benign teardown SIGABRT).
- **FAILED** — a run started (`cap_restart` exists) but did not complete.
- **IDLE** — no run present in the run directory yet.

## Files

- `scripts/monitoring/gchp-monitor-exporter.sh` — head-node exporter (parse → S3).
- `scripts/monitoring/deploy-exporter.sh` — install the exporter as a systemd service
  (auto-start, reboot-survival, restart-on-failure). Run with `sudo` on the head node.
- `scripts/monitoring/teardown-monitoring.sh` — stop/remove the service (head node).
- `scripts/monitoring/gchp-dash.sh` — local launcher (poll S3 → serve localhost).
- `scripts/monitoring/gchp-monitor-ui.html` — the dashboard page.
- `scripts/monitoring/lock-monitor-ip.sh` — optional: restrict the `gchp-monitor/*`
  prefix of your bucket to one source IP (local; merges into any existing policy).

## Validation status

- **End-to-end validated** on a live 3-day C24 run (2026-06): CONFIGURING → RUNNING
  (progress 0→100% tracking the sim date, live throughput/ETA/mem) → SUCCESS through
  the benign teardown SIGABRT. Per-user private bucket + local dashboard confirmed.
- The systemd `deploy-exporter.sh` / `teardown-monitoring.sh` and `lock-monitor-ip.sh`
  are syntax- and logic-tested offline (policy merge verified across add/re-run/remove);
  the systemd install path itself runs on the next head node where they're used.
