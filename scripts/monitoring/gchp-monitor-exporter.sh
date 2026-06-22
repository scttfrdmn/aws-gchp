#!/bin/bash
#
# gchp-monitor-exporter.sh — runs on a cluster HEAD NODE.
#
# Parses a GCHP run's state (SLURM queue + GCHP log + cap_restart + checkpoint) and
# publishes a small status.json to the RESEARCHER'S OWN S3 bucket every interval.
# Each user points this at a bucket they own → private, multi-tenant, no shared state.
#
# Usage:
#   gchp-monitor-exporter.sh --bucket s3://my-bucket/gchp-monitor/run1 \
#       [--rundir DIR] [--cluster NAME] [--interval SECONDS] [--once]
#
# Env alternative: GCHP_MONITOR_S3=s3://my-bucket/gchp-monitor/run1
#
# Success is judged by cap_restart advancing + checkpoint presence — NOT the job exit
# code (GCHP 14.7.1 has a benign teardown SIGABRT after a successful run; see
# docs/RUNNING-GCHP.md / geoschem/GCHP#556).

set -uo pipefail

S3_DEST="${GCHP_MONITOR_S3:-}"
RUNDIR="/fsx/scratch/gchp_merra2_TransportTracers"
CLUSTER="$(hostname 2>/dev/null | sed 's/-[0-9]*$//' || echo gchp)"
INTERVAL=10
ONCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)   S3_DEST="$2"; shift 2 ;;
    --rundir)   RUNDIR="$2"; shift 2 ;;
    --cluster)  CLUSTER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# build_status_json <rundir> <cluster> — prints status.json to stdout.
# Pure function of the run dir contents + squeue; no S3. Unit-testable offline by
# pointing it at a fixture dir (it tolerates a missing squeue).
# ---------------------------------------------------------------------------
build_status_json() {
  local rundir="$1" cluster="$2"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

  # --- SLURM queue (best-effort; absent in offline tests) ---
  local jobid="" jobstate="" elapsed="" node="" inqueue=0
  if command -v squeue >/dev/null 2>&1; then
    local line; line="$(squeue -h -o '%i|%T|%M|%N' 2>/dev/null | head -1)"
    if [[ -n "$line" ]]; then
      inqueue=1
      jobid="${line%%|*}";   line="${line#*|}"
      jobstate="${line%%|*}"; line="${line#*|}"
      elapsed="${line%%|*}"; node="${line#*|}"
    fi
  fi

  # --- cap_restart: start vs current sim date ---
  local cap_start="" cap_now=""
  if [[ -f "$rundir/.cap_start" ]]; then cap_start="$(awk '{print $1}' "$rundir/.cap_start" 2>/dev/null)"; fi
  if [[ -f "$rundir/cap_restart" ]]; then cap_now="$(awk '{print $1}' "$rundir/cap_restart" 2>/dev/null)"; fi

  # --- checkpoint present + non-empty? (the validated success signal) ---
  local checkpoint=false
  [[ -s "$rundir/Restarts/gcchem_internal_checkpoint" ]] && checkpoint=true

  # --- parse latest GCHP log for telemetry ---
  local log="" gchp_date="" gchp_time="" tput="" eta="" pct="" mem=""
  log="$(ls -t "$rundir"/gchp.*.log 2>/dev/null | head -1)"
  if [[ -n "$log" && -f "$log" ]]; then
    # Last "GCHP Date: YYYY/MM/DD  Time: HH:MM:SS" line
    local dline; dline="$(grep -E 'GCHP Date:' "$log" 2>/dev/null | tail -1)"
    gchp_date="$(sed -nE 's/.*GCHP Date: ([0-9/]+).*/\1/p'  <<<"$dline")"
    gchp_time="$(sed -nE 's/.*Time: ([0-9:]+).*/\1/p'        <<<"$dline")"
    # Throughput: "Throughput(days/day)[Avg Tot Run]: 1549.5 7202.7 7605.9" -> first (Avg)
    tput="$(sed -nE 's/.*Throughput\(days\/day\)\[Avg Tot Run\]:[ ]*([0-9.]+).*/\1/p' <<<"$dline")"
    eta="$(sed -nE 's/.*TimeRemaining\(Est\) ([0-9:]+).*/\1/p' <<<"$dline")"
    # GCHP prints "<commit>% : <used>% Mem Comm:Used" — capture the 2nd (mem used %).
    mem="$(sed -nE 's/.*[[:space:]]([0-9.]+)% :[[:space:]]+([0-9.]+)% Mem.*/\2/p' <<<"$dline")"
  fi

  # Real sim-progress %: (live GCHP date - BEG_DATE) / (END_DATE - BEG_DATE), using the
  # segment bounds from CAP.rc. Works throughout the run (cap_restart only advances at the
  # end, so it can't drive an in-progress bar). Best-effort; blank if unparseable.
  local beg_date="" end_date=""
  if [[ -f "$rundir/CAP.rc" ]]; then
    beg_date="$(sed -nE 's/^BEG_DATE:[[:space:]]*([0-9]+).*/\1/p' "$rundir/CAP.rc" 2>/dev/null | head -1)"
    end_date="$(sed -nE 's/^END_DATE:[[:space:]]*([0-9]+).*/\1/p' "$rundir/CAP.rc" 2>/dev/null | head -1)"
  fi
  pct="$(GCHP_BEG="$beg_date" GCHP_END="$end_date" GCHP_NOW="${gchp_date//\//}" GCHP_NOW_T="$gchp_time" python3 - <<'PY' 2>/dev/null
import os,sys
from datetime import datetime
def ep(d,t="0:0:0"):
    if not d or len(d)<8: return None
    hh,mm,ss=(t.split(":")+["0","0","0"])[:3]
    try: return datetime(int(d[:4]),int(d[4:6]),int(d[6:8]),int(hh),int(mm),int(ss)).timestamp()
    except Exception: return None
beg=ep(os.environ.get("GCHP_BEG","")); end=ep(os.environ.get("GCHP_END",""))
now=ep(os.environ.get("GCHP_NOW",""),os.environ.get("GCHP_NOW_T","0:0:0"))
if beg is None or end is None or end<=beg or now is None: print(""); sys.exit()
print(max(0,min(100,round((now-beg)/(end-beg)*100))))
PY
)"

  # --- derive overall status ---
  # RUNNING while job is in queue; otherwise SUCCESS iff cap advanced + checkpoint, else
  # FAILED (covers a genuine crash) or PENDING (nothing started yet).
  local status="UNKNOWN"
  local advanced=false
  [[ -n "$cap_start" && -n "$cap_now" && "$cap_start" != "$cap_now" ]] && advanced=true
  if [[ "$inqueue" -eq 1 && "$jobstate" == "RUNNING" ]]; then
    status="RUNNING"
  elif [[ "$inqueue" -eq 1 ]]; then
    status="$jobstate"          # PENDING/CONFIGURING/etc
  elif [[ "$checkpoint" == true && "$advanced" == true ]]; then
    status="SUCCESS"            # benign teardown SIGABRT still counts as success
  elif [[ -n "$cap_now" ]]; then
    status="FAILED"             # ran (cap_restart exists) but did not complete
  else
    status="IDLE"               # no run yet
  fi

  # --- emit JSON (manual; keeps the head node free of jq) ---
  local q='"'
  cat <<JSON
{
  "cluster": ${q}${cluster}${q},
  "updated": ${q}${now}${q},
  "status": ${q}${status}${q},
  "job": {
    "id": ${q}${jobid}${q},
    "state": ${q}${jobstate}${q},
    "elapsed": ${q}${elapsed}${q},
    "node": ${q}${node}${q}
  },
  "sim": {
    "start": ${q}${cap_start}${q},
    "current_date": ${q}${gchp_date}${q},
    "current_time": ${q}${gchp_time}${q},
    "cap_restart": ${q}${cap_now}${q},
    "throughput_days_day": ${q}${tput}${q},
    "eta": ${q}${eta}${q},
    "percent": ${q}${pct}${q}
  },
  "mem_used_pct": ${q}${mem}${q},
  "checkpoint": ${checkpoint}
}
JSON
}

# If sourced (for unit tests), stop here — expose build_status_json only.
[[ "${BASH_SOURCE[0]:-$0}" != "$0" ]] && return 0 2>/dev/null

# ---- main loop ----
if [[ -z "$S3_DEST" ]]; then
  echo "ERROR: no destination. Pass --bucket s3://... or set GCHP_MONITOR_S3." >&2
  exit 1
fi

# Snapshot the run's start date once, so we can detect cap_restart advancing.
if [[ -f "$RUNDIR/cap_restart" && ! -f "$RUNDIR/.cap_start" ]]; then
  cp "$RUNDIR/cap_restart" "$RUNDIR/.cap_start" 2>/dev/null || true
fi

echo "Exporting GCHP status: rundir=$RUNDIR -> $S3_DEST/status.json every ${INTERVAL}s"
while true; do
  tmp="$(mktemp)"
  build_status_json "$RUNDIR" "$CLUSTER" > "$tmp"
  if aws s3 cp "$tmp" "$S3_DEST/status.json" --content-type application/json --only-show-errors 2>/dev/null; then
    :
  else
    echo "[$(date -u +%H:%M:%S)] warning: s3 cp failed" >&2
  fi
  rm -f "$tmp"
  [[ "$ONCE" -eq 1 ]] && break
  sleep "$INTERVAL"
done
