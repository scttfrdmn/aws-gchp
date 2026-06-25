#!/bin/bash
#
# deploy-exporter.sh — install the GCHP monitor exporter as a systemd service.
#
# Run this ON A CLUSTER HEAD NODE. It installs gchp-monitor-exporter.sh as a system
# service so monitoring starts automatically, survives head-node reboots, and restarts
# on failure (vs. a manual `nohup ... &` that dies on logout/reboot).
#
# Usage (on the head node):
#   sudo ./deploy-exporter.sh --bucket s3://my-bucket/gchp-monitor/run1 \
#       [--rundir DIR] [--cluster NAME] [--interval SECONDS]
#
# Pairs with teardown-monitoring.sh to remove it.

set -euo pipefail

BUCKET=""
RUNDIR="/fsx/scratch/gchp_merra2_TransportTracers"
CLUSTER="$(hostname 2>/dev/null | sed 's/-[0-9]*$//' || echo gchp)"
INTERVAL=10
RUN_USER="ec2-user"
INSTALL_DIR="/opt/gchp-monitor"
UNIT="/etc/systemd/system/gchp-monitor.service"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)   BUCKET="$2"; shift 2 ;;
    --rundir)   RUNDIR="$2"; shift 2 ;;
    --cluster)  CLUSTER="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --user)     RUN_USER="$2"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BUCKET" ]] && { echo "ERROR: --bucket s3://... is required" >&2; exit 1; }
[[ "$BUCKET" == s3://* ]] || { echo "ERROR: --bucket must be an s3:// URI" >&2; exit 1; }
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo) to install a systemd service." >&2
  exit 1
fi

# Locate the exporter next to this script, or in the mounted stack.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORTER_SRC=""
for cand in "$HERE/gchp-monitor-exporter.sh" \
            /fsx/stacks/*/gchp14.7.1-validated/gchp-monitor-exporter.sh; do
  [[ -f "$cand" ]] && { EXPORTER_SRC="$cand"; break; }
done
[[ -z "$EXPORTER_SRC" ]] && { echo "ERROR: gchp-monitor-exporter.sh not found next to this script or in /fsx stacks." >&2; exit 1; }

echo "Installing exporter from: $EXPORTER_SRC"
install -d "$INSTALL_DIR"
install -m 0755 "$EXPORTER_SRC" "$INSTALL_DIR/gchp-monitor-exporter.sh"

cat > "$UNIT" <<UNITEOF
[Unit]
Description=GCHP run monitor exporter (status.json -> ${BUCKET})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
# SLURM bins are needed by the exporter; ensure they're on PATH for the service.
Environment=PATH=/opt/slurm/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash ${INSTALL_DIR}/gchp-monitor-exporter.sh --bucket ${BUCKET} --rundir ${RUNDIR} --cluster ${CLUSTER} --interval ${INTERVAL}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now gchp-monitor.service

echo ""
echo "✅ gchp-monitor.service installed and started."
echo "   bucket:   ${BUCKET}"
echo "   rundir:   ${RUNDIR}"
echo "   interval: ${INTERVAL}s   user: ${RUN_USER}"
echo ""
echo "Manage it:"
echo "   systemctl status gchp-monitor      # health"
echo "   journalctl -u gchp-monitor -f      # logs"
echo "   sudo ./teardown-monitoring.sh      # remove"
