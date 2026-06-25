#!/bin/bash
#
# teardown-monitoring.sh — remove the GCHP monitor exporter systemd service.
#
# Run this ON A CLUSTER HEAD NODE (the counterpart to deploy-exporter.sh).
# Stops + disables + removes the service and installed exporter. By default it writes a
# final status.json (status=STOPPED) so the dashboard shows monitoring ended cleanly;
# pass --no-final to skip that.
#
# Usage (on the head node):
#   sudo ./teardown-monitoring.sh [--no-final]

set -uo pipefail

INSTALL_DIR="/opt/gchp-monitor"
UNIT="/etc/systemd/system/gchp-monitor.service"
WRITE_FINAL=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-final) WRITE_FINAL=0; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)." >&2
  exit 1
fi

if [[ ! -f "$UNIT" ]]; then
  echo "gchp-monitor.service not installed — nothing to do."
  exit 0
fi

# Recover the bucket from the unit so we can post a final STOPPED status.
BUCKET="$(sed -nE 's/.*--bucket ([^ ]+).*/\1/p' "$UNIT" | head -1)"

echo "Stopping gchp-monitor.service..."
systemctl disable --now gchp-monitor.service 2>/dev/null || true

if [[ "$WRITE_FINAL" -eq 1 && -n "$BUCKET" ]]; then
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  tmp="$(mktemp)"
  printf '{ "status": "STOPPED", "updated": "%s", "note": "monitoring exporter torn down" }\n' "$now" > "$tmp"
  # Use the service user's creds if running under sudo; root may lack AWS config.
  if command -v aws >/dev/null 2>&1; then
    aws s3 cp "$tmp" "$BUCKET/status.json" --only-show-errors 2>/dev/null \
      && echo "Wrote final STOPPED status to $BUCKET/status.json" \
      || echo "(could not write final status — bucket may need user creds; skipping)"
  fi
  rm -f "$tmp"
fi

rm -f "$UNIT"
rm -rf "$INSTALL_DIR"
systemctl daemon-reload

echo "✅ gchp-monitor.service removed."
echo "   (Your status.json in S3 is left in place${WRITE_FINAL:+ with a final STOPPED marker}.)"
