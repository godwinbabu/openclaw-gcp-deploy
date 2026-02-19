#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# smoke_test.sh — Post-deploy health check via IAP tunnel
###############################################################################

usage() {
  cat <<USAGE
Usage: $0 --name <instance> --zone <zone> --project <project> [--output <path>]
USAGE
}

NAME=""
ZONE=""
PROJECT=""
OUTPUT="./smoke-test-report.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --zone) ZONE="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$NAME" ]] || { echo "--name required" >&2; exit 1; }
[[ -n "$ZONE" ]] || { echo "--zone required" >&2; exit 1; }
[[ -n "$PROJECT" ]] || { echo "--project required" >&2; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Smoke testing $NAME in $ZONE..."

# Check instance is running
INSTANCE_STATUS=$(gcloud compute instances describe "$NAME" \
  --project="$PROJECT" --zone="$ZONE" \
  --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

# Check OpenClaw service via IAP
SERVICE_STATUS="unknown"
OPENCLAW_VERSION="unknown"
if [[ "$INSTANCE_STATUS" == "RUNNING" ]]; then
  SMOKE_OUTPUT=$(gcloud compute ssh "$NAME" \
    --project="$PROJECT" --zone="$ZONE" \
    --tunnel-through-iap \
    --command="systemctl is-active openclaw 2>/dev/null; openclaw --version 2>/dev/null || echo unknown" \
    2>/dev/null || echo "SSH_FAILED")

  if echo "$SMOKE_OUTPUT" | grep -q "active"; then
    SERVICE_STATUS="active"
  elif echo "$SMOKE_OUTPUT" | grep -q "SSH_FAILED"; then
    SERVICE_STATUS="ssh_failed"
  else
    SERVICE_STATUS="inactive"
  fi
fi

OVERALL="pass"
if [[ "$INSTANCE_STATUS" != "RUNNING" || "$SERVICE_STATUS" != "active" ]]; then
  OVERALL="fail"
fi

mkdir -p "$(dirname "$OUTPUT")"
cat > "$OUTPUT" <<EOF
{
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "overall": "$OVERALL",
  "instance": "$NAME",
  "zone": "$ZONE",
  "project": "$PROJECT",
  "checks": {
    "instanceStatus": "$INSTANCE_STATUS",
    "serviceStatus": "$SERVICE_STATUS"
  }
}
EOF

log "Result: $OVERALL"
log "Report: $OUTPUT"

[[ "$OVERALL" == "pass" ]]
