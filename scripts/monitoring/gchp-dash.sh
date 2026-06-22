#!/bin/bash
#
# gchp-dash.sh — LOCAL dashboard launcher (runs on the researcher's own computer).
#
# Pulls status.json from the user's PRIVATE S3 location using their own AWS creds and
# serves it + the dashboard page on localhost. The browser never talks to S3 directly,
# so S3 stays fully private — access is gated by having creds on THIS machine.
#
# Usage:
#   gchp-dash.sh s3://my-bucket/gchp-monitor/run1   [--port 8787] [--interval 5] [--profile aws]
#
# Then open the printed http://localhost:PORT/ URL.

set -uo pipefail

S3_SRC=""
PORT=8787
INTERVAL=5
PROFILE="${AWS_PROFILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)     PORT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --profile)  PROFILE="$2"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    s3://*)     S3_SRC="$1"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$S3_SRC" ]] && { echo "ERROR: pass the status.json S3 location, e.g. s3://my-bucket/gchp-monitor/run1" >&2; exit 1; }
# Accept either the prefix or the full object path
[[ "$S3_SRC" == *.json ]] || S3_SRC="${S3_SRC%/}/status.json"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVE_DIR="$(mktemp -d)"
cp "$HERE/gchp-monitor-ui.html" "$SERVE_DIR/index.html"
trap 'kill $POLL_PID $HTTP_PID 2>/dev/null; rm -rf "$SERVE_DIR"' EXIT

AWS_ARGS=()
[[ -n "$PROFILE" ]] && AWS_ARGS=(--profile "$PROFILE")

echo "Polling $S3_SRC every ${INTERVAL}s -> $SERVE_DIR/status.json"
( while true; do
    aws "${AWS_ARGS[@]}" s3 cp "$S3_SRC" "$SERVE_DIR/status.json" --only-show-errors 2>/dev/null \
      || echo '{"status":"NO_DATA","updated":"","note":"status.json not found yet"}' > "$SERVE_DIR/status.json"
    sleep "$INTERVAL"
  done ) &
POLL_PID=$!

cd "$SERVE_DIR"
python3 -m http.server "$PORT" >/dev/null 2>&1 &
HTTP_PID=$!

sleep 1
echo ""
echo "  GCHP dashboard:  http://localhost:${PORT}/"
echo "  (Ctrl-C to stop. S3 stays private — served locally via your AWS creds.)"
echo ""
wait $HTTP_PID
