#!/bin/bash
#
# lock-monitor-ip.sh — OPTIONAL belt-and-suspenders: restrict the gchp-monitor/* prefix
# of YOUR S3 bucket to a single source IP (this computer's egress IP by default).
#
# Runs on your LOCAL machine. The monitoring design is already private (the dashboard
# reads with your AWS creds; nothing is public). This adds an extra Deny-unless-SourceIp
# condition so even a leaked credential can't read the status from another network.
#
# Usage:
#   ./lock-monitor-ip.sh --bucket my-bucket [--ip 1.2.3.4] [--prefix gchp-monitor/*] [--profile aws]
#   ./lock-monitor-ip.sh --bucket my-bucket --remove        # remove the statement
#
# SAFETY: merges into (does not clobber) any existing bucket policy. Prints the
# resulting policy and asks for confirmation before applying. Home/ISP IPs are often
# dynamic — re-run when your IP changes.

set -uo pipefail

BUCKET="" ; IP="" ; PREFIX="gchp-monitor/*" ; PROFILE="${AWS_PROFILE:-}" ; REMOVE=0
SID="GCHPMonitorIPLock"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)  BUCKET="$2"; shift 2 ;;
    --ip)      IP="$2"; shift 2 ;;
    --prefix)  PREFIX="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --remove)  REMOVE=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$BUCKET" ]] && { echo "ERROR: --bucket is required" >&2; exit 1; }
AWS=(aws); [[ -n "$PROFILE" ]] && AWS=(aws --profile "$PROFILE")

if [[ "$REMOVE" -eq 0 && -z "$IP" ]]; then
  IP="$(curl -s https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
  [[ -z "$IP" ]] && { echo "ERROR: could not detect public IP; pass --ip" >&2; exit 1; }
  echo "Detected this computer's public IP: $IP"
fi

# Fetch existing policy (empty doc if none).
EXISTING="$("${AWS[@]}" s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text 2>/dev/null || true)"
[[ -z "$EXISTING" || "$EXISTING" == "None" ]] && EXISTING='{"Version":"2012-10-17","Statement":[]}'

# Merge with python: drop any prior statement with our Sid, then add the new one
# (unless --remove). Deny all principals on the prefix UNLESS source IP matches.
# The existing policy is passed via env (EXISTING_POLICY), NOT stdin — stdin is taken
# by the heredoc that carries the python script itself.
NEW_POLICY="$(EXISTING_POLICY="$EXISTING" BUCKET="$BUCKET" IP="$IP" PREFIX="$PREFIX" SID="$SID" REMOVE="$REMOVE" python3 - <<'PY'
import json,os
pol=json.loads(os.environ["EXISTING_POLICY"])
sid=os.environ["SID"]; bucket=os.environ["BUCKET"]; prefix=os.environ["PREFIX"]
pol.setdefault("Version","2012-10-17"); pol.setdefault("Statement",[])
# remove any prior copy of our statement (idempotent)
pol["Statement"]=[s for s in pol["Statement"] if s.get("Sid")!=sid]
if os.environ["REMOVE"]!="1":
    pol["Statement"].append({
        "Sid": sid,
        "Effect": "Deny",
        "Principal": "*",
        "Action": "s3:GetObject",
        "Resource": f"arn:aws:s3:::{bucket}/{prefix}",
        "Condition": {"NotIpAddress": {"aws:SourceIp": os.environ["IP"]}}
    })
# if removing left zero statements, emit empty marker so caller deletes the policy
print(json.dumps(pol,indent=2) if pol["Statement"] else "__EMPTY__")
PY
)"

if [[ "$NEW_POLICY" == "__EMPTY__" ]]; then
  echo "Removing bucket policy (no statements left)..."
  "${AWS[@]}" s3api delete-bucket-policy --bucket "$BUCKET" && echo "✅ policy removed"
  exit 0
fi

echo ""
echo "=== Proposed bucket policy for $BUCKET ==="
echo "$NEW_POLICY"
echo ""
read -rp "Apply this policy? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted; no change."; exit 0; }

tmp="$(mktemp)"; echo "$NEW_POLICY" > "$tmp"
"${AWS[@]}" s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$tmp"
rm -f "$tmp"
if [[ "$REMOVE" -eq 1 ]]; then
  echo "✅ Removed the $SID statement (other statements preserved)."
else
  echo "✅ Locked $BUCKET/$PREFIX reads to $IP (statement $SID)."
  echo "   Re-run with a new --ip if your address changes; --remove to undo."
fi
