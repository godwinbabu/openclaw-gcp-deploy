#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup_deployer.sh — Create a GCP service account with minimum permissions
#                     to run the OpenClaw deploy + teardown scripts.
#
# Usage:
#   ./scripts/setup_deployer.sh --project my-project
#   ./scripts/setup_deployer.sh --project my-project --name openclaw-deployer
#   ./scripts/setup_deployer.sh --dry-run
###############################################################################

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --project <id>          GCP project ID (required)
  --name <name>           Service account name (default: openclaw-deployer)
  --dry-run               Print required roles without creating anything
  -h, --help              Show help
USAGE
}

PROJECT=""
SA_NAME="openclaw-deployer"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --name) SA_NAME="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1"; usage; exit 2 ;;
  esac
done

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [[ -z "$PROJECT" ]]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
    echo "ERROR: --project required" >&2
    exit 1
  fi
fi

SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

# Roles needed by the deployer
DEPLOYER_ROLES=(
  "roles/compute.admin"                   # Create/delete VPC, subnets, firewall, instances
  "roles/iam.serviceAccountAdmin"         # Create/delete service accounts
  "roles/iam.serviceAccountUser"          # Attach SA to instances
  "roles/secretmanager.admin"             # Create/delete secrets
  "roles/iap.tunnelResourceAccessor"      # IAP tunnel for SSH
  "roles/serviceusage.serviceUsageAdmin"  # Enable APIs
  "roles/resourcemanager.projectIamAdmin" # Grant roles to instance SA
)

if [[ "$DRY_RUN" == "true" ]]; then
  log ""
  log "=== Deployer Roles Needed (dry run) ==="
  log ""
  for role in "${DEPLOYER_ROLES[@]}"; do
    log "  - $role"
  done
  log ""
  log "Create a service account '$SA_NAME' and grant these roles."
  log "Or grant them to your user account for interactive use."
  exit 0
fi

log "Project: $PROJECT"
log "Service Account: $SA_EMAIL"
log ""

# Create service account
if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" &>/dev/null 2>&1; then
  log "Service account already exists"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --project "$PROJECT" \
    --display-name "OpenClaw Deployer" \
    --description "Minimum-privilege deployer for OpenClaw GCP deployments" \
    --quiet
  log "✅ Service account created: $SA_EMAIL"
fi

# Grant roles
for role in "${DEPLOYER_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$role" \
    --condition=None \
    --quiet &>/dev/null || true
  log "  ✅ Granted: $role"
done

# Create key file
KEY_FILE="./${SA_NAME}-key.json"
gcloud iam service-accounts keys create "$KEY_FILE" \
  --iam-account "$SA_EMAIL" \
  --project "$PROJECT" \
  --quiet 2>/dev/null && {
  log ""
  log "=========================================="
  log "  ✅ Deployer ready: $SA_NAME"
  log "=========================================="
  log ""
  log "  Key file: $KEY_FILE"
  log "  ⚠️  Keep this secure — it grants deploy permissions!"
  log ""
  log "  To use:"
  log "    export GOOGLE_APPLICATION_CREDENTIALS=$KEY_FILE"
  log "    gcloud auth activate-service-account --key-file=$KEY_FILE"
  log "    ./scripts/deploy.sh --name starfish --project $PROJECT"
  log ""
} || {
  log ""
  log "=========================================="
  log "  ✅ Deployer roles granted to: $SA_EMAIL"
  log "=========================================="
  log ""
  log "  Could not create key (may have 10 keys already)."
  log "  Use Workload Identity or create key manually."
  log ""
}
