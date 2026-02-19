#!/bin/bash
# OpenClaw GCP Startup Script
# Called by systemd to start the OpenClaw gateway

set -e

export HOME="/home/openclaw"
export PATH="/usr/local/bin:/usr/bin:/opt/google-cloud-sdk/bin:$PATH"
export NODE_OPTIONS="--max-old-space-size=1024"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2; }

log "Starting OpenClaw startup sequence..."

# Verify Node.js
NODE_VERSION=$(node --version)
log "Node.js version: $NODE_VERSION"

OPENCLAW_PATH=$(which openclaw)
log "OpenClaw path: $OPENCLAW_PATH"

cd /home/openclaw/.openclaw

# Start gateway in FOREGROUND mode
# CRITICAL: Use 'run' not 'start'
log "Starting OpenClaw gateway (foreground)..."
exec /usr/local/bin/openclaw gateway run --allow-unconfigured
