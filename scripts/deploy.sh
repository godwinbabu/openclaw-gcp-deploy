#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# deploy.sh — One-shot OpenClaw deployment to Google Cloud Platform
#
# Creates: VPC network, subnet, firewall rules, service account,
#          Secret Manager secrets, Compute Engine instance (e2-medium)
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - GCP project with billing enabled
#   - .env.<name> or .env.starfish (TELEGRAM_BOT_TOKEN)
#   - jq, openssl available
#
# Usage:
#   ./scripts/deploy.sh --name starfish --project my-project
#   ./scripts/deploy.sh --name starfish --project my-project --model google/gemini-2.0-flash
#   ./scripts/deploy.sh --name starfish --project my-project --pair-user 123456789
###############################################################################

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠️  $*" >&2; }

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --name <name>             Agent/project name (default: starfish)
  --project <id>            GCP project ID (default: from gcloud config)
  --region <region>         GCP region (default: us-central1)
  --zone <zone>             GCP zone (default: auto from region)
  --env-dir <path>          Directory containing .env files
  --machine-type <type>     GCE machine type (default: e2-medium)
  --disk-size <gb>          Boot disk size in GB (default: 20)
  --model <model>           AI model (default: google/gemini-2.0-flash)
  --personality <name|path> Agent personality (default, sentinel, researcher, coder, companion)
  --pair-user <id>          Telegram user ID to auto-approve pairing
  --no-monitoring           Skip uptime check creation
  --no-rollback             Don't auto-teardown on failure
  --cleanup-first           Tear down existing resources first
  --dry-run                 Show what would be created
  -h, --help                Show help

Examples:
  $0 --name starfish --project my-gcp-project
  $0 --name starfish --project my-gcp-project --model google/gemini-2.0-flash
  $0 --name starfish --project my-gcp-project --pair-user 123456789
  $0 --name starfish --project my-gcp-project --machine-type t2a-standard-1
USAGE
}

# Defaults
NAME="starfish"
PROJECT=""
REGION="us-central1"
ZONE=""
ENV_DIR=""
MACHINE_TYPE="e2-medium"
DISK_SIZE="20"
MODEL="google/gemini-2.0-flash"
PERSONALITY="default"
PAIR_USER=""
MONITORING=true
NO_ROLLBACK=false
CLEANUP_FIRST=false
DRY_RUN=false
OUTPUT_PATH="./deploy-output.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --zone) ZONE="${2:-}"; shift 2 ;;
    --env-dir) ENV_DIR="${2:-}"; shift 2 ;;
    --machine-type) MACHINE_TYPE="${2:-}"; shift 2 ;;
    --disk-size) DISK_SIZE="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --personality) PERSONALITY="${2:-}"; shift 2 ;;
    --pair-user) PAIR_USER="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    --no-monitoring) MONITORING=false; shift ;;
    --no-rollback) NO_ROLLBACK=true; shift ;;
    --cleanup-first) CLEANUP_FIRST=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# --- Input validation ---
if ! [[ "$NAME" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
  echo "ERROR: --name must be 1-31 lowercase alphanumeric/hyphen chars starting with a letter" >&2
  exit 1
fi

if [[ -n "$PAIR_USER" ]] && ! [[ "$PAIR_USER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --pair-user must be a numeric Telegram user ID" >&2
  exit 1
fi

if ! [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || [[ "$DISK_SIZE" -lt 10 ]]; then
  echo "ERROR: --disk-size must be >= 10 GB" >&2
  exit 1
fi

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

###############################################################################
# GCP Authentication & Project
###############################################################################

# Check gcloud is available
if ! command -v gcloud &>/dev/null; then
  echo "ERROR: gcloud CLI not found. Install from https://cloud.google.com/sdk/install" >&2
  exit 1
fi

# Check jq and openssl
for cmd in jq openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found. Install it first." >&2
    exit 1
  fi
done

# Resolve project
if [[ -z "$PROJECT" ]]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
    echo "ERROR: No GCP project set. Use --project or 'gcloud config set project <id>'" >&2
    exit 1
  fi
fi

log "GCP Project: $PROJECT"

# Verify gcloud auth
if ! gcloud auth print-access-token --project "$PROJECT" &>/dev/null; then
  echo "ERROR: gcloud not authenticated. Run 'gcloud auth login'" >&2
  exit 1
fi

# Auto-select zone if not provided
if [[ -z "$ZONE" ]]; then
  ZONE="${REGION}-a"
  log "Zone: $ZONE (auto-selected)"
fi

###############################################################################
# Find .env file (same pattern as AWS skill)
###############################################################################
ENV_FILE=".env.${NAME}"
ENV_FALLBACK=".env.starfish"

resolve_env_file() {
  local dir="$1"
  if [[ -f "$dir/$ENV_FILE" ]]; then
    echo "$dir/$ENV_FILE"
  elif [[ -f "$dir/$ENV_FALLBACK" ]]; then
    echo "$dir/$ENV_FALLBACK"
  else
    echo ""
  fi
}

RESOLVED_ENV=""
if [[ -z "$ENV_DIR" ]]; then
  RESOLVED_ENV=$(resolve_env_file "$SKILL_DIR/..")
  if [[ -n "$RESOLVED_ENV" ]]; then
    ENV_DIR="$(cd "$SKILL_DIR/.." && pwd)"
  else
    RESOLVED_ENV=$(resolve_env_file "$SKILL_DIR")
    if [[ -n "$RESOLVED_ENV" ]]; then
      ENV_DIR="$(cd "$SKILL_DIR" && pwd)"
    else
      echo "ERROR: Cannot find $ENV_FILE (or $ENV_FALLBACK). Provide --env-dir" >&2
      exit 1
    fi
  fi
else
  ENV_DIR="$(cd "$ENV_DIR" && pwd)"
  RESOLVED_ENV=$(resolve_env_file "$ENV_DIR")
  if [[ -z "$RESOLVED_ENV" ]]; then
    echo "ERROR: Neither $ENV_DIR/$ENV_FILE nor $ENV_DIR/$ENV_FALLBACK found" >&2
    exit 1
  fi
fi

log "Env file: $RESOLVED_ENV"

# Load env file
while IFS='=' read -r key value; do
  [[ -n "$key" ]] && export "$key=$value"
done < <(grep -E '^[A-Z0-9_]+=' "$RESOLVED_ENV")

# Validate required vars
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN is not set" >&2
  exit 1
fi

# Check optional keys
HAS_GEMINI_KEY=false
if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  HAS_GEMINI_KEY=true
fi

# Determine if model is Vertex AI
IS_VERTEX=false
if [[ "$MODEL" == google/* || "$MODEL" == vertex-ai/* ]]; then
  IS_VERTEX=true
  log "Vertex AI model detected: $MODEL"
fi

# Resolve personality
PERSONALITIES_DIR="$SKILL_DIR/assets/personalities"
if [[ -f "$PERSONALITY" ]]; then
  SOUL_CONTENT=$(cat "$PERSONALITY")
  log "Personality: custom ($PERSONALITY)"
elif [[ -f "$PERSONALITIES_DIR/${PERSONALITY}.md" ]]; then
  SOUL_CONTENT=$(cat "$PERSONALITIES_DIR/${PERSONALITY}.md")
  log "Personality: $PERSONALITY (built-in)"
else
  echo "ERROR: Unknown personality '$PERSONALITY'" >&2
  echo "Available: default, sentinel, researcher, coder, companion" >&2
  exit 1
fi

# Base64-encode files for transport
SOUL_B64=$(echo "$SOUL_CONTENT" | base64)
AGENT_DEFAULTS_DIR="$SKILL_DIR/assets/agent-defaults"
AGENTS_MD_B64=$(cat "$AGENT_DEFAULTS_DIR/AGENTS.md" | base64)
HEARTBEAT_MD_B64=$(cat "$AGENT_DEFAULTS_DIR/HEARTBEAT.md" | base64)
USER_MD_B64=$(cat "$AGENT_DEFAULTS_DIR/USER.md" | base64)

# Generate gateway token
GATEWAY_TOKEN=$(openssl rand -hex 32)

# Deploy ID for labeling
DEPLOY_ID="${NAME}-$(date -u +%Y%m%dT%H%M%SZ)"

# GCP resource names (must be lowercase, hyphens only)
NETWORK_NAME="${NAME}-network"
SUBNET_NAME="${NAME}-subnet"
FW_DENY_NAME="${NAME}-deny-ingress"
FW_IAP_NAME="${NAME}-allow-iap"
FW_EGRESS_NAME="${NAME}-allow-egress"
SA_NAME="${NAME}-sa"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
INSTANCE_NAME="${NAME}"
ROUTER_NAME="${NAME}-router"
NAT_NAME="${NAME}-nat"

# Subnet CIDR
SUBNET_CIDR="10.50.0.0/24"

log "Deploy ID: $DEPLOY_ID"

###############################################################################
# Failure trap — auto-rollback
###############################################################################
cleanup_on_failure() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "" >&2
    echo "=========================================" >&2
    echo "  ❌ Deploy failed (exit code $exit_code)" >&2
    echo "=========================================" >&2

    if [[ "$NO_ROLLBACK" == "true" ]]; then
      echo "  --no-rollback set. Resources left for debugging." >&2
      echo "  To clean up: $SCRIPT_DIR/teardown.sh --name $NAME --project $PROJECT --yes" >&2
    else
      echo "  Auto-rolling back..." >&2
      if [[ -x "$SCRIPT_DIR/teardown.sh" ]]; then
        "$SCRIPT_DIR/teardown.sh" --name "$NAME" --project "$PROJECT" \
          --region "$REGION" --yes 2>&1 || warn "Auto-rollback encountered errors"
        log "Auto-rollback complete."
      fi
    fi
    echo "=========================================" >&2
  fi
}
trap cleanup_on_failure EXIT

log "=========================================="
log "  OpenClaw GCP Deploy: $NAME"
log "  Project: $PROJECT | Region: $REGION"
log "  Zone: $ZONE | Machine: $MACHINE_TYPE"
log "  Model: $MODEL"
log "=========================================="

###############################################################################
# Preflight Checks
###############################################################################
log ""
log "--- Preflight Checks ---"

PREFLIGHT_FAIL=false

# Check project exists and billing
if ! gcloud projects describe "$PROJECT" &>/dev/null; then
  warn "Project $PROJECT not found or not accessible"
  PREFLIGHT_FAIL=true
else
  log "  ✅ Project $PROJECT accessible"
fi

# Check zone exists
if ! gcloud compute zones describe "$ZONE" --project "$PROJECT" &>/dev/null 2>&1; then
  warn "Zone $ZONE not available in project $PROJECT"
  PREFLIGHT_FAIL=true
else
  log "  ✅ Zone $ZONE available"
fi

# Check machine type availability
if ! gcloud compute machine-types describe "$MACHINE_TYPE" --zone "$ZONE" --project "$PROJECT" &>/dev/null 2>&1; then
  warn "Machine type $MACHINE_TYPE not available in $ZONE"
  PREFLIGHT_FAIL=true
else
  log "  ✅ Machine type $MACHINE_TYPE available in $ZONE"
fi

# Check for existing deployment
EXISTING=$(gcloud compute instances list --project "$PROJECT" \
  --filter="labels.project=$NAME" --format="value(name)" 2>/dev/null || true)
if [[ -n "$EXISTING" && "$CLEANUP_FIRST" != "true" ]]; then
  warn "Instance with label project=$NAME already exists: $EXISTING"
  warn "Use --cleanup-first to tear down first"
  PREFLIGHT_FAIL=true
fi

if [[ "$PREFLIGHT_FAIL" == "true" && "$DRY_RUN" != "true" ]]; then
  echo "ERROR: Preflight checks failed." >&2
  exit 1
fi

log "Preflight checks passed ✅"

if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Would create: VPC, subnet, firewall rules, SA, secrets, GCE instance"
  log "[DRY RUN] Machine type: $MACHINE_TYPE, Disk: ${DISK_SIZE}GB"
  exit 0
fi

###############################################################################
# Step 0: Cleanup if requested
###############################################################################
if [[ "$CLEANUP_FIRST" == "true" ]]; then
  log ""
  log "--- Step 0: Cleaning up existing $NAME resources ---"
  if [[ -x "$SCRIPT_DIR/teardown.sh" ]]; then
    "$SCRIPT_DIR/teardown.sh" --name "$NAME" --project "$PROJECT" \
      --region "$REGION" --yes || true
  fi
fi

###############################################################################
# Step 1: Enable required APIs
###############################################################################
log ""
log "--- Step 1: Enabling GCP APIs ---"

APIS=(
  "compute.googleapis.com"
  "secretmanager.googleapis.com"
  "iap.googleapis.com"
  "aiplatform.googleapis.com"
  "logging.googleapis.com"
  "monitoring.googleapis.com"
)

for api in "${APIS[@]}"; do
  if gcloud services enable "$api" --project "$PROJECT" 2>/dev/null; then
    log "  ✅ $api"
  else
    warn "  Failed to enable $api — may already be enabled"
  fi
done

###############################################################################
# Step 2: Create VPC Network
###############################################################################
log ""
log "--- Step 2: Creating VPC Network ---"

if gcloud compute networks describe "$NETWORK_NAME" --project "$PROJECT" &>/dev/null 2>&1; then
  log "Network $NETWORK_NAME already exists — using existing"
else
  gcloud compute networks create "$NETWORK_NAME" \
    --project "$PROJECT" \
    --subnet-mode=custom \
    --description="OpenClaw $NAME deployment network" \
    --quiet
  log "Network: $NETWORK_NAME"
fi

###############################################################################
# Step 3: Create Subnet
###############################################################################
log ""
log "--- Step 3: Creating Subnet ---"

if gcloud compute networks subnets describe "$SUBNET_NAME" \
  --project "$PROJECT" --region "$REGION" &>/dev/null 2>&1; then
  log "Subnet $SUBNET_NAME already exists — using existing"
else
  gcloud compute networks subnets create "$SUBNET_NAME" \
    --project "$PROJECT" \
    --network="$NETWORK_NAME" \
    --region="$REGION" \
    --range="$SUBNET_CIDR" \
    --enable-private-ip-google-access \
    --quiet
  log "Subnet: $SUBNET_NAME ($SUBNET_CIDR)"
fi

###############################################################################
# Step 4: Create Firewall Rules
###############################################################################
log ""
log "--- Step 4: Creating Firewall Rules ---"

# Deny all ingress (priority 1000)
if ! gcloud compute firewall-rules describe "$FW_DENY_NAME" --project "$PROJECT" &>/dev/null 2>&1; then
  gcloud compute firewall-rules create "$FW_DENY_NAME" \
    --project "$PROJECT" \
    --network="$NETWORK_NAME" \
    --direction=INGRESS \
    --action=DENY \
    --rules=all \
    --source-ranges="0.0.0.0/0" \
    --priority=1000 \
    --description="Deny all ingress for OpenClaw $NAME" \
    --quiet
  log "  ✅ Deny all ingress: $FW_DENY_NAME"
else
  log "  Firewall $FW_DENY_NAME already exists"
fi

# Allow IAP tunnel (priority 900 — higher than deny)
if ! gcloud compute firewall-rules describe "$FW_IAP_NAME" --project "$PROJECT" &>/dev/null 2>&1; then
  gcloud compute firewall-rules create "$FW_IAP_NAME" \
    --project "$PROJECT" \
    --network="$NETWORK_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --priority=900 \
    --target-tags="${NAME}-iap" \
    --description="Allow IAP tunnel SSH for OpenClaw $NAME" \
    --quiet
  log "  ✅ Allow IAP tunnel: $FW_IAP_NAME"
else
  log "  Firewall $FW_IAP_NAME already exists"
fi

###############################################################################
# Step 5: Create Cloud Router + NAT (for outbound without external IP)
# Actually, we'll use an ephemeral external IP for simplicity (same as AWS)
# NAT is more complex and costs more. Ephemeral IP is free while running.
###############################################################################
log ""
log "--- Step 5: Network egress (ephemeral external IP) ---"
log "  Using ephemeral external IP for outbound connectivity"

###############################################################################
# Step 6: Create Service Account
###############################################################################
log ""
log "--- Step 6: Creating Service Account ---"

if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" &>/dev/null 2>&1; then
  log "Service account $SA_EMAIL already exists — using existing"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --project "$PROJECT" \
    --display-name="OpenClaw $NAME" \
    --description="Service account for OpenClaw $NAME deployment" \
    --quiet
  log "Service Account: $SA_EMAIL"
fi

# Grant roles
ROLES=(
  "roles/secretmanager.secretAccessor"
  "roles/logging.logWriter"
  "roles/monitoring.metricWriter"
)

# Add Vertex AI role if using Vertex
if [[ "$IS_VERTEX" == "true" ]]; then
  ROLES+=("roles/aiplatform.user")
fi

for role in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$role" \
    --condition=None \
    --quiet &>/dev/null || true
  log "  ✅ Granted $role"
done

# Grant IAP tunnel access to the deployer (current user)
DEPLOYER_EMAIL=$(gcloud config get-value account 2>/dev/null || true)
if [[ -n "$DEPLOYER_EMAIL" && "$DEPLOYER_EMAIL" != "(unset)" ]]; then
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="user:$DEPLOYER_EMAIL" \
    --role="roles/iap.tunnelResourceAccessor" \
    --condition=None \
    --quiet &>/dev/null || true
  log "  ✅ IAP tunnel access for $DEPLOYER_EMAIL"
fi

###############################################################################
# Step 7: Store Secrets in Secret Manager
###############################################################################
log ""
log "--- Step 7: Storing Secrets ---"

store_secret() {
  local secret_id="$1" secret_value="$2"
  # Create secret if doesn't exist
  if ! gcloud secrets describe "$secret_id" --project "$PROJECT" &>/dev/null 2>&1; then
    gcloud secrets create "$secret_id" \
      --project "$PROJECT" \
      --replication-policy="automatic" \
      --labels="project=$NAME,deploy-id=${DEPLOY_ID,,}" \
      --quiet
  fi
  # Add new version
  echo -n "$secret_value" | gcloud secrets versions add "$secret_id" \
    --project "$PROJECT" \
    --data-file=- \
    --quiet
  log "  ✅ Stored: $secret_id"
}

store_secret "${NAME}-telegram-bot-token" "$TELEGRAM_BOT_TOKEN"
store_secret "${NAME}-gateway-token" "$GATEWAY_TOKEN"

if [[ "$HAS_GEMINI_KEY" == "true" ]]; then
  store_secret "${NAME}-gemini-api-key" "$GEMINI_API_KEY"
fi

###############################################################################
# Step 8: Get OS Image
###############################################################################
log ""
log "--- Step 8: Getting OS image ---"

# Detect if ARM machine type
IS_ARM=false
if [[ "$MACHINE_TYPE" == t2a-* || "$MACHINE_TYPE" == t2d-* ]]; then
  IS_ARM=true
fi

if [[ "$IS_ARM" == "true" ]]; then
  IMAGE_PROJECT="ubuntu-os-cloud"
  IMAGE_FAMILY="ubuntu-2204-lts-arm64"
  log "OS: Ubuntu 22.04 LTS ARM64 (for $MACHINE_TYPE)"
else
  IMAGE_PROJECT="debian-cloud"
  IMAGE_FAMILY="debian-12"
  log "OS: Debian 12 (for $MACHINE_TYPE)"
fi

###############################################################################
# Step 9: Generate Startup Script
###############################################################################
log ""
log "--- Step 9: Generating startup script ---"

NODE_VERSION="22.14.0"

# Determine Node.js architecture
if [[ "$IS_ARM" == "true" ]]; then
  NODE_ARCH="arm64"
else
  NODE_ARCH="x64"
fi

# Build models config block
if [[ "$IS_VERTEX" == "true" ]]; then
  MODELS_BLOCK='"models": {
    "providers": {
      "google": {
        "api": "vertex-ai",
        "auth": "gcp-identity",
        "projectId": "'"$PROJECT"'",
        "location": "'"$REGION"'"
      }
    }
  },'
else
  MODELS_BLOCK='"models": {},'
fi

# Create startup script
STARTUP_SCRIPT=$(cat <<'STARTUP'
#!/bin/bash
set -euo pipefail

exec > /var/log/openclaw-bootstrap.log 2>&1
echo "[$(date)] Starting OpenClaw bootstrap..."

# Variables (replaced by deploy script)
AGENT_NAME="__NAME__"
PROJECT_ID="__PROJECT__"
REGION="__REGION__"
NODE_VERSION="__NODE_VERSION__"
NODE_ARCH="__NODE_ARCH__"
MODEL="__MODEL__"
HAS_GEMINI_KEY="__HAS_GEMINI_KEY__"
IS_VERTEX="__IS_VERTEX__"

# Retry helper
retry_cmd() {
  local max_retries=3 delay=5 attempt=1
  while true; do
    if "$@"; then return 0; fi
    if [[ $attempt -ge $max_retries ]]; then
      echo "[$(date)] FATAL: Command failed after $max_retries attempts: $*" >&2
      return 1
    fi
    echo "[$(date)] Attempt $attempt failed, retrying in ${delay}s..."
    sleep $delay
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# Detect package manager
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
else
  echo "[$(date)] FATAL: No supported package manager found" >&2
  exit 1
fi

# Install dependencies
echo "[$(date)] Installing dependencies..."
if [[ "$PKG_MGR" == "apt" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  retry_cmd apt-get update -y
  retry_cmd apt-get install -y git jq curl xz-utils
else
  retry_cmd dnf install -y git jq curl tar gzip xz
fi

# Install Node.js from official tarball
echo "[$(date)] Installing Node.js ${NODE_VERSION} (${NODE_ARCH})..."
cd /tmp
NODE_TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
retry_cmd curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}" -o node.tar.xz
retry_cmd curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o SHASUMS256.txt

# Verify integrity
echo "[$(date)] Verifying Node.js SHA256..."
EXPECTED_SHA=$(grep "${NODE_TARBALL}" SHASUMS256.txt | awk '{print $1}')
ACTUAL_SHA=$(sha256sum node.tar.xz | awk '{print $1}')
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  echo "[$(date)] FATAL: SHA256 mismatch!" >&2
  exit 1
fi
echo "[$(date)] SHA256 verified OK"

tar -xf node.tar.xz -C /usr/local --strip-components=1
rm -f node.tar.xz SHASUMS256.txt
hash -r

echo "[$(date)] Node: $(node --version), npm: $(npm --version)"

# Install OpenClaw
echo "[$(date)] Installing OpenClaw..."
retry_cmd npm install -g openclaw@latest 2>&1 | tail -20
echo "[$(date)] OpenClaw: $(which openclaw)"

# Install gcloud CLI if not present (needed for Secret Manager)
if ! command -v gcloud &>/dev/null; then
  echo "[$(date)] Installing gcloud CLI..."
  curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${NODE_ARCH}.tar.gz -o /tmp/gcloud.tar.gz
  tar -xf /tmp/gcloud.tar.gz -C /opt
  /opt/google-cloud-sdk/install.sh --quiet --path-update=true
  ln -sf /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud
  rm -f /tmp/gcloud.tar.gz
fi

# Create openclaw user
echo "[$(date)] Creating openclaw user..."
useradd -r -m -s /bin/bash openclaw || true

# Create directories
mkdir -p /home/openclaw/.openclaw/agents/main/agent
mkdir -p /home/openclaw/.openclaw/workspace

# Create startup script
echo "[$(date)] Writing startup script..."
cat > /usr/local/bin/openclaw-startup.sh <<'STARTEOF'
#!/bin/bash
set -e

export HOME="/home/openclaw"
export PATH="/usr/local/bin:/usr/bin:/opt/google-cloud-sdk/bin:$PATH"
export NODE_OPTIONS="--max-old-space-size=1024"

AGENT_NAME="__NAME__"
PROJECT_ID="__PROJECT__"
REGION="__REGION__"
MODEL="__MODEL__"
HAS_GEMINI_KEY="__HAS_GEMINI_KEY__"

cd /home/openclaw/.openclaw

echo "[$(date)] Fetching secrets from Secret Manager..."

# Fetch secrets at runtime
TELEGRAM_TOKEN=$(gcloud secrets versions access latest --secret="${AGENT_NAME}-telegram-bot-token" --project="$PROJECT_ID" 2>/dev/null)
GW_TOKEN=$(gcloud secrets versions access latest --secret="${AGENT_NAME}-gateway-token" --project="$PROJECT_ID" 2>/dev/null)

GEMINI_KEY=""
if [[ "$HAS_GEMINI_KEY" == "true" ]]; then
  GEMINI_KEY=$(gcloud secrets versions access latest --secret="${AGENT_NAME}-gemini-api-key" --project="$PROJECT_ID" 2>/dev/null) || true
fi

echo "[$(date)] Writing ephemeral config files..."

# Write openclaw.json
cat > /home/openclaw/.openclaw/openclaw.json <<OCEOF
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "${GW_TOKEN}"
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "${MODEL}"
      },
      "workspace": "/home/openclaw/.openclaw/workspace",
      "heartbeat": {
        "every": "30m",
        "prompt": "Check HEARTBEAT.md if it exists. If nothing needs attention, reply HEARTBEAT_OK."
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist",
      "streamMode": "partial",
      "accounts": {
        "default": {
          "name": "${AGENT_NAME}",
          "dmPolicy": "pairing",
          "botToken": "${TELEGRAM_TOKEN}",
          "groupPolicy": "allowlist",
          "streamMode": "partial"
        }
      }
    }
  },
  "plugins": {
    "entries": {
      "telegram": {
        "enabled": true
      }
    }
  },
  __MODELS_BLOCK__
  "tools": {
    "agentToAgent": {
      "enabled": true
    }
  }
}
OCEOF

# Write auth-profiles.json
if [[ "$HAS_GEMINI_KEY" == "true" && -n "$GEMINI_KEY" ]]; then
  cat > /home/openclaw/.openclaw/agents/main/agent/auth-profiles.json <<APEOF
{
  "version": 1,
  "profiles": {
    "google:default": {
      "type": "token",
      "provider": "google",
      "token": "${GEMINI_KEY}"
    }
  }
}
APEOF
else
  cat > /home/openclaw/.openclaw/agents/main/agent/auth-profiles.json <<APEOF
{
  "version": 1,
  "profiles": {}
}
APEOF
fi

chown -R openclaw:openclaw /home/openclaw/.openclaw

echo "[$(date)] Starting gateway..."
exec /usr/local/bin/openclaw gateway run --allow-unconfigured
STARTEOF
chmod +x /usr/local/bin/openclaw-startup.sh

# Replace placeholders in startup script
sed -i "s|__NAME__|${AGENT_NAME}|g" /usr/local/bin/openclaw-startup.sh
sed -i "s|__PROJECT__|${PROJECT_ID}|g" /usr/local/bin/openclaw-startup.sh
sed -i "s|__REGION__|${REGION}|g" /usr/local/bin/openclaw-startup.sh
sed -i "s|__MODEL__|${MODEL}|g" /usr/local/bin/openclaw-startup.sh
sed -i "s|__HAS_GEMINI_KEY__|${HAS_GEMINI_KEY}|g" /usr/local/bin/openclaw-startup.sh

# Write systemd service
echo "[$(date)] Writing systemd service..."
cat > /etc/systemd/system/openclaw.service <<'SVCEOF'
[Unit]
Description=OpenClaw Gateway
Documentation=https://docs.openclaw.ai
After=network-online.target google-guest-agent.service
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw/.openclaw
ExecStart=/usr/local/bin/openclaw-startup.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw

[Install]
WantedBy=multi-user.target
SVCEOF

# Write SOUL.md
echo "[$(date)] Writing SOUL.md..."
echo "__SOUL_B64__" | base64 -d > /home/openclaw/.openclaw/workspace/SOUL.md
cp /home/openclaw/.openclaw/workspace/SOUL.md /home/openclaw/.openclaw/agents/main/agent/SOUL.md

# Write agent defaults
echo "[$(date)] Writing agent default files..."
echo "__AGENTS_MD_B64__" | base64 -d > /home/openclaw/.openclaw/workspace/AGENTS.md
echo "__HEARTBEAT_MD_B64__" | base64 -d > /home/openclaw/.openclaw/workspace/HEARTBEAT.md
echo "__USER_MD_B64__" | base64 -d > /home/openclaw/.openclaw/workspace/USER.md
mkdir -p /home/openclaw/.openclaw/workspace/memory

# Fix ownership
chown -R openclaw:openclaw /home/openclaw/.openclaw

# Enable and start
echo "[$(date)] Starting OpenClaw service..."
systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw

# Wait and check
sleep 15
if systemctl is-active openclaw; then
  echo "[$(date)] ✅ OpenClaw is running!"
  journalctl -u openclaw -n 10 --no-pager
else
  echo "[$(date)] ❌ OpenClaw failed to start"
  journalctl -u openclaw -n 30 --no-pager
  exit 1
fi

echo "[$(date)] Bootstrap complete!"
STARTUP
)

# Replace all placeholders in startup script
STARTUP_SCRIPT="${STARTUP_SCRIPT//__NAME__/$NAME}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__PROJECT__/$PROJECT}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__REGION__/$REGION}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__NODE_VERSION__/$NODE_VERSION}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__NODE_ARCH__/$NODE_ARCH}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__MODEL__/$MODEL}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__HAS_GEMINI_KEY__/$HAS_GEMINI_KEY}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__IS_VERTEX__/$IS_VERTEX}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__MODELS_BLOCK__/$MODELS_BLOCK}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__SOUL_B64__/$SOUL_B64}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__AGENTS_MD_B64__/$AGENTS_MD_B64}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__HEARTBEAT_MD_B64__/$HEARTBEAT_MD_B64}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//__USER_MD_B64__/$USER_MD_B64}"

# Write startup script to temp file
STARTUP_FILE=$(mktemp)
echo "$STARTUP_SCRIPT" > "$STARTUP_FILE"

###############################################################################
# Step 10: Create Compute Engine Instance
###############################################################################
log ""
log "--- Step 10: Creating Compute Engine Instance ---"

gcloud compute instances create "$INSTANCE_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --network-interface="network=$NETWORK_NAME,subnet=$SUBNET_NAME" \
  --service-account="$SA_EMAIL" \
  --scopes="cloud-platform" \
  --image-family="$IMAGE_FAMILY" \
  --image-project="$IMAGE_PROJECT" \
  --boot-disk-size="${DISK_SIZE}GB" \
  --boot-disk-type="pd-balanced" \
  --tags="${NAME}-iap" \
  --labels="project=$NAME,deploy-id=${DEPLOY_ID,,}" \
  --metadata-from-file="startup-script=$STARTUP_FILE" \
  --shielded-secure-boot \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --no-address \
  --quiet 2>&1 || {
    # Retry with external IP if no-address fails (NAT not configured)
    warn "No-address failed — retrying with ephemeral external IP"
    gcloud compute instances create "$INSTANCE_NAME" \
      --project="$PROJECT" \
      --zone="$ZONE" \
      --machine-type="$MACHINE_TYPE" \
      --network-interface="network=$NETWORK_NAME,subnet=$SUBNET_NAME" \
      --service-account="$SA_EMAIL" \
      --scopes="cloud-platform" \
      --image-family="$IMAGE_FAMILY" \
      --image-project="$IMAGE_PROJECT" \
      --boot-disk-size="${DISK_SIZE}GB" \
      --boot-disk-type="pd-balanced" \
      --tags="${NAME}-iap" \
      --labels="project=$NAME,deploy-id=${DEPLOY_ID,,}" \
      --metadata-from-file="startup-script=$STARTUP_FILE" \
      --shielded-secure-boot \
      --shielded-vtpm \
      --shielded-integrity-monitoring \
      --quiet
  }

rm -f "$STARTUP_FILE"

log "Instance: $INSTANCE_NAME"

# Get instance details
INSTANCE_ID=$(gcloud compute instances describe "$INSTANCE_NAME" \
  --project="$PROJECT" --zone="$ZONE" \
  --format="value(id)" 2>/dev/null || echo "unknown")

EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
  --project="$PROJECT" --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "none")

INTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
  --project="$PROJECT" --zone="$ZONE" \
  --format="value(networkInterfaces[0].networkIP)" 2>/dev/null || echo "unknown")

log "Instance ID: $INSTANCE_ID"
log "Internal IP: $INTERNAL_IP"
log "External IP: ${EXTERNAL_IP:-none}"

###############################################################################
# Step 11: Wait for Bootstrap
###############################################################################
log ""
log "--- Step 11: Waiting for bootstrap (4-6 minutes) ---"

for i in $(seq 1 48); do
  # Check serial console for bootstrap completion
  SERIAL_OUT=$(gcloud compute instances get-serial-port-output "$INSTANCE_NAME" \
    --project="$PROJECT" --zone="$ZONE" \
    --port=1 2>/dev/null | tail -5 || true)

  if echo "$SERIAL_OUT" | grep -q "Bootstrap complete"; then
    log "Bootstrap completed!"
    break
  fi

  if [[ $i -eq 48 ]]; then
    warn "Bootstrap may still be running after 8 min"
    warn "Check: gcloud compute ssh $INSTANCE_NAME --zone $ZONE --tunnel-through-iap"
  fi
  sleep 10
done

###############################################################################
# Step 12: Smoke Test
###############################################################################
log ""
log "--- Step 12: Smoke Test ---"

SMOKE_CMD="systemctl is-active openclaw && echo SERVICE_OK; journalctl -u openclaw -n 5 --no-pager"
SMOKE_OUT=$(gcloud compute ssh "$INSTANCE_NAME" \
  --project="$PROJECT" --zone="$ZONE" \
  --tunnel-through-iap \
  --command="$SMOKE_CMD" 2>/dev/null || echo "SSH via IAP not available yet")

log "Smoke test:"
echo "$SMOKE_OUT"

###############################################################################
# Step 13: Auto-pair (if --pair-user provided)
###############################################################################
if [[ -n "$PAIR_USER" ]]; then
  log ""
  log "--- Step 13: Auto-approving Telegram pairing for user $PAIR_USER ---"
  sleep 30

  PAIR_CMD="sudo -u openclaw bash -c 'cd /home/openclaw/.openclaw && /usr/local/bin/openclaw pairing approve telegram $PAIR_USER'"
  PAIR_OUT=$(gcloud compute ssh "$INSTANCE_NAME" \
    --project="$PROJECT" --zone="$ZONE" \
    --tunnel-through-iap \
    --command="$PAIR_CMD" 2>/dev/null || echo "Pairing command failed — try manually via IAP SSH")

  log "Pairing: $PAIR_OUT"
fi

###############################################################################
# Step 14: Save Outputs
###############################################################################
log ""
log "--- Step 14: Saving deployment outputs ---"

# Build secrets list
SECRETS_JSON="[\"${NAME}-telegram-bot-token\", \"${NAME}-gateway-token\""
if [[ "$HAS_GEMINI_KEY" == "true" ]]; then
  SECRETS_JSON+=", \"${NAME}-gemini-api-key\""
fi
SECRETS_JSON+="]"

cat > "$OUTPUT_PATH" <<OUTEOF
{
  "name": "$NAME",
  "cloud": "gcp",
  "project": "$PROJECT",
  "region": "$REGION",
  "zone": "$ZONE",
  "deployId": "$DEPLOY_ID",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "infrastructure": {
    "network": "$NETWORK_NAME",
    "subnet": "$SUBNET_NAME",
    "firewallRules": ["$FW_DENY_NAME", "$FW_IAP_NAME"],
    "serviceAccount": "$SA_EMAIL"
  },
  "instance": {
    "name": "$INSTANCE_NAME",
    "instanceId": "$INSTANCE_ID",
    "machineType": "$MACHINE_TYPE",
    "internalIp": "$INTERNAL_IP",
    "externalIp": "${EXTERNAL_IP:-none}",
    "zone": "$ZONE"
  },
  "secrets": $SECRETS_JSON,
  "config": {
    "model": "$MODEL",
    "channel": "telegram",
    "dmPolicy": "pairing",
    "gatewayPort": 18789,
    "personality": "$PERSONALITY"
  },
  "access": {
    "ssh": "gcloud compute ssh $INSTANCE_NAME --zone $ZONE --tunnel-through-iap --project $PROJECT",
    "logs": "gcloud compute ssh $INSTANCE_NAME --zone $ZONE --tunnel-through-iap --project $PROJECT --command 'journalctl -u openclaw -n 50 --no-pager'"
  }
}
OUTEOF

log ""
log "=========================================="
log "  ✅ Deployment Complete!"
log "=========================================="
log ""
log "  Instance:    $INSTANCE_NAME"
log "  Internal IP: $INTERNAL_IP"
log "  External IP: ${EXTERNAL_IP:-none}"
log "  Zone:        $ZONE"
log "  Model:       $MODEL"
log "  Channel:     Telegram"
log ""
log "  IAP SSH Access:"
log "    gcloud compute ssh $INSTANCE_NAME --zone $ZONE --tunnel-through-iap --project $PROJECT"
log ""
if [[ -n "$PAIR_USER" ]]; then
  log "  Pairing: auto-approved for Telegram user $PAIR_USER"
else
  log "  Next steps:"
  log "    1. Message the Telegram bot to get a pairing code"
  log "    2. SSH in via IAP and approve:"
  log "       sudo -u openclaw bash -c 'cd /home/openclaw/.openclaw && openclaw pairing approve telegram <CODE>'"
fi
log ""
log "  Output saved to: $OUTPUT_PATH"
log "=========================================="
