#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# teardown.sh — Clean up all GCP resources for an OpenClaw deployment
#
# Discovery modes:
#   1. --from-output <deploy-output.json>  (exact resource names)
#   2. --name <name>                        (label-based discovery)
#
# Usage:
#   ./scripts/teardown.sh --name starfish --project my-project --dry-run
#   ./scripts/teardown.sh --from-output ./deploy-output.json --yes
#   ./scripts/teardown.sh --name starfish --project my-project --yes
###############################################################################

usage() {
  cat <<USAGE
Usage: $0 [options]

Discovery (at least one required):
  --name <name>           Find resources by label project=<name>
  --from-output <path>    Read resource names from deploy-output.json

Options:
  --project <id>          GCP project ID (default: from gcloud config)
  --region <region>       GCP region (default: us-central1)
  --zone <zone>           GCP zone (default: <region>-a)
  --dry-run               Show what would be deleted
  --yes                   Skip confirmation prompt
  -h, --help              Show help
USAGE
}

NAME=""
PROJECT=""
REGION="us-central1"
ZONE=""
FROM_OUTPUT=""
DRY_RUN=false
YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --zone) ZONE="${2:-}"; shift 2 ;;
    --from-output) FROM_OUTPUT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$NAME" && -z "$FROM_OUTPUT" ]]; then
  echo "ERROR: Provide --name or --from-output" >&2
  usage
  exit 2
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠️  $*" >&2; }

###############################################################################
# Resolve project
###############################################################################
if [[ -z "$PROJECT" ]]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
    echo "ERROR: No GCP project. Use --project" >&2
    exit 1
  fi
fi

if [[ -z "$ZONE" ]]; then
  ZONE="${REGION}-a"
fi

###############################################################################
# Resource Discovery
###############################################################################
INSTANCE_NAME=""
NETWORK_NAME=""
SUBNET_NAME=""
FW_RULES=()
SA_EMAIL=""
SECRETS=()

if [[ -n "$FROM_OUTPUT" ]]; then
  if [[ ! -f "$FROM_OUTPUT" ]]; then
    echo "ERROR: File not found: $FROM_OUTPUT" >&2
    exit 1
  fi
  log "Reading resources from: $FROM_OUTPUT"

  NAME=$(jq -r '.name // empty' "$FROM_OUTPUT")
  PROJECT=$(jq -r '.project // empty' "$FROM_OUTPUT" 2>/dev/null || echo "$PROJECT")
  REGION=$(jq -r '.region // empty' "$FROM_OUTPUT" 2>/dev/null || echo "$REGION")
  ZONE=$(jq -r '.zone // empty' "$FROM_OUTPUT" 2>/dev/null || echo "$ZONE")
  INSTANCE_NAME=$(jq -r '.instance.name // empty' "$FROM_OUTPUT")
  NETWORK_NAME=$(jq -r '.infrastructure.network // empty' "$FROM_OUTPUT")
  SUBNET_NAME=$(jq -r '.infrastructure.subnet // empty' "$FROM_OUTPUT")
  SA_EMAIL=$(jq -r '.infrastructure.serviceAccount // empty' "$FROM_OUTPUT")

  while IFS= read -r rule; do
    [[ -n "$rule" ]] && FW_RULES+=("$rule")
  done < <(jq -r '.infrastructure.firewallRules[]? // empty' "$FROM_OUTPUT")

  while IFS= read -r secret; do
    [[ -n "$secret" ]] && SECRETS+=("$secret")
  done < <(jq -r '.secrets[]? // empty' "$FROM_OUTPUT")

else
  log "Discovering resources by label project=$NAME"

  # Instance
  INSTANCE_NAME=$(gcloud compute instances list --project "$PROJECT" \
    --filter="labels.project=$NAME AND zone:$ZONE" \
    --format="value(name)" 2>/dev/null | head -1 || true)

  # If not found in specific zone, search all zones in region
  if [[ -z "$INSTANCE_NAME" ]]; then
    INSTANCE_LINE=$(gcloud compute instances list --project "$PROJECT" \
      --filter="labels.project=$NAME" \
      --format="value(name,zone)" 2>/dev/null | head -1 || true)
    if [[ -n "$INSTANCE_LINE" ]]; then
      INSTANCE_NAME=$(echo "$INSTANCE_LINE" | awk '{print $1}')
      ZONE=$(echo "$INSTANCE_LINE" | awk '{print $2}')
      # Extract just zone name from full path
      ZONE=$(basename "$ZONE")
      log "Found instance in zone: $ZONE"
    fi
  fi

  NETWORK_NAME="${NAME}-network"
  SUBNET_NAME="${NAME}-subnet"
  SA_EMAIL="${NAME}-sa@${PROJECT}.iam.gserviceaccount.com"

  FW_RULES=("${NAME}-deny-ingress" "${NAME}-allow-iap")
  SECRETS=("${NAME}-telegram-bot-token" "${NAME}-gateway-token" "${NAME}-gemini-api-key")
fi

###############################################################################
# Display Plan
###############################################################################
log ""
log "=========================================="
if [[ "$DRY_RUN" == "true" ]]; then
  log "  🔍 TEARDOWN DRY RUN: ${NAME:-unknown}"
else
  log "  🗑️  TEARDOWN: ${NAME:-unknown}"
fi
log "  Project: $PROJECT"
log "=========================================="

RESOURCE_COUNT=0

print_resource() {
  local type="$1" id="$2" billable="${3:-no}"
  if [[ -n "$id" ]]; then
    local marker=""
    [[ "$billable" == "yes" ]] && marker=" 💰"
    log "    $type: $id$marker"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
  fi
}

print_resource "Instance" "$INSTANCE_NAME" "yes"
for rule in "${FW_RULES[@]}"; do
  print_resource "Firewall" "$rule"
done
print_resource "Subnet" "$SUBNET_NAME"
print_resource "Network" "$NETWORK_NAME"
print_resource "Service Acct" "$SA_EMAIL"
for secret in "${SECRETS[@]}"; do
  print_resource "Secret" "$secret"
done

log ""
log "  Total: $RESOURCE_COUNT resources"

if [[ $RESOURCE_COUNT -eq 0 ]]; then
  log "  No resources found."
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "  [DRY RUN] No resources deleted."
  exit 0
fi

###############################################################################
# Confirmation
###############################################################################
if [[ "$YES" != "true" ]]; then
  echo ""
  read -p "  Delete all $RESOURCE_COUNT resources? Type 'yes': " confirm
  if [[ "$confirm" != "yes" ]]; then
    log "Aborted."
    exit 0
  fi
fi

###############################################################################
# Execute Teardown
###############################################################################
ERRORS=0

delete_resource() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    log "  ✅ $desc"
  else
    warn "  Failed: $desc"
    ERRORS=$((ERRORS + 1))
  fi
}

# 1. Delete instance
if [[ -n "$INSTANCE_NAME" ]]; then
  log ""
  log "--- Step 1: Delete instance ---"
  delete_resource "Instance: $INSTANCE_NAME" \
    gcloud compute instances delete "$INSTANCE_NAME" \
    --project="$PROJECT" --zone="$ZONE" --quiet
fi

# 2. Delete secrets
if [[ ${#SECRETS[@]} -gt 0 ]]; then
  log ""
  log "--- Step 2: Delete secrets ---"
  for secret in "${SECRETS[@]}"; do
    delete_resource "Secret: $secret" \
      gcloud secrets delete "$secret" --project="$PROJECT" --quiet
  done
fi

# 3. Delete firewall rules
if [[ ${#FW_RULES[@]} -gt 0 ]]; then
  log ""
  log "--- Step 3: Delete firewall rules ---"
  for rule in "${FW_RULES[@]}"; do
    delete_resource "Firewall: $rule" \
      gcloud compute firewall-rules delete "$rule" --project="$PROJECT" --quiet
  done
fi

# 4. Delete subnet
if [[ -n "$SUBNET_NAME" ]]; then
  log ""
  log "--- Step 4: Delete subnet ---"
  delete_resource "Subnet: $SUBNET_NAME" \
    gcloud compute networks subnets delete "$SUBNET_NAME" \
    --project="$PROJECT" --region="$REGION" --quiet
fi

# 5. Delete network
if [[ -n "$NETWORK_NAME" ]]; then
  log ""
  log "--- Step 5: Delete network ---"
  delete_resource "Network: $NETWORK_NAME" \
    gcloud compute networks delete "$NETWORK_NAME" \
    --project="$PROJECT" --quiet
fi

# 6. Delete service account
if [[ -n "$SA_EMAIL" ]]; then
  log ""
  log "--- Step 6: Delete service account ---"

  # Remove IAM bindings first
  for role in "roles/secretmanager.secretAccessor" "roles/logging.logWriter" \
              "roles/monitoring.metricWriter" "roles/aiplatform.user"; do
    gcloud projects remove-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:$SA_EMAIL" \
      --role="$role" --quiet &>/dev/null || true
  done

  delete_resource "Service Account: $SA_EMAIL" \
    gcloud iam service-accounts delete "$SA_EMAIL" \
    --project="$PROJECT" --quiet
fi

###############################################################################
# Summary
###############################################################################
log ""
log "=========================================="
if [[ $ERRORS -eq 0 ]]; then
  log "  ✅ Teardown Complete!"
else
  log "  ⚠️  Teardown finished with $ERRORS error(s)."
fi
log "=========================================="

[[ $ERRORS -eq 0 ]] || exit 1
