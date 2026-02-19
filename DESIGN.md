# OpenClaw GCP Deploy — Design Document

_Author: Bean | Date: 2026-02-18_

## Overview

One-shot OpenClaw deployment to Google Cloud Platform (GCP), mirroring the architecture and UX of `openclaw-aws-deploy`. A single shell command creates all infrastructure, installs OpenClaw, configures Telegram, and connects to an AI model — all with zero inbound ports.

## Goals

1. **Parity with AWS skill** — same UX, flags, safety features, teardown flow
2. **GCP-native security** — OS Login disabled, IAP tunnel for access (no SSH keys), firewall deny-all ingress
3. **Cost-competitive** — target ~$25-30/mo using e2-medium or t2a-standard-1 (ARM)
4. **Model flexibility** — Vertex AI (Gemini) as default, any provider via API key

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  VPC Network (custom)               │
│  ┌───────────────────────────────────────────────┐  │
│  │        Subnet (single region/zone)            │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │  Compute Engine e2-medium (2 vCPU, 4GB) │  │  │
│  │  │  ┌───────────────────────────────────┐  │  │  │
│  │  │  │       OpenClaw Gateway             │  │  │  │
│  │  │  │  • Node.js 22                      │  │  │  │
│  │  │  │  • Vertex AI / Gemini / any model  │  │  │  │
│  │  │  │  • Telegram channel                │  │  │  │
│  │  │  │  • 20GB Balanced PD (encrypted)    │  │  │  │
│  │  │  └───────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
         ↑                              ↓
  IAP Tunnel (no SSH keys)    Outbound HTTPS only
```

## GCP vs AWS Mapping

| Concept | AWS | GCP |
|---------|-----|-----|
| Network | VPC + Subnet + IGW + Route Table | VPC Network + Subnet + Cloud Router (optional) |
| Compute | EC2 t4g.medium (ARM64) | e2-medium (x86, 4GB) or t2a-standard-1 (ARM, 4GB) |
| Firewall | Security Group (no inbound) | VPC Firewall Rule (deny all ingress, allow IAP) |
| Remote access | SSM Session Manager | IAP TCP Tunneling (`gcloud compute ssh`) |
| Secrets | SSM Parameter Store (SecureString) | Secret Manager |
| IAM | IAM Role + Instance Profile | Service Account + IAM bindings |
| Monitoring | CloudWatch Alarms + Log Groups | Cloud Monitoring + Cloud Logging (automatic) |
| Boot script | EC2 User Data | Compute Engine Startup Script |
| Disk encryption | EBS encrypted (default) | PD encrypted by default (Google-managed keys) |
| OS | Amazon Linux 2023 (ARM64) | Debian 12 (Bookworm) or Ubuntu 22.04 LTS |
| Instance metadata | IMDSv2 (required) | Metadata server (default, hardened via attributes) |

## Key Design Decisions

### 1. Compute: e2-medium (x86) as default, t2a-standard-1 (ARM) as option
- **e2-medium**: $24.27/mo, 2 vCPU, 4GB, widely available in all regions
- **t2a-standard-1**: $22.12/mo, ARM (Ampere Altra), 4GB, limited regions (us-central1, europe-west4, asia-southeast1)
- Default to e2-medium for reliability; `--machine-type t2a-standard-1` for ARM
- ARM uses different OS image (Ubuntu 22.04 for ARM vs Debian 12 for x86)

### 2. Remote Access: IAP Tunnel (no SSH keys)
- **No external SSH** — firewall blocks all ingress
- Access via `gcloud compute ssh <instance> --tunnel-through-iap`
- IAP tunnel uses Google's identity-aware proxy (authenticated via gcloud)
- Requires `roles/iap.tunnelResourceAccessor` on the deployer
- Equivalent to AWS SSM — zero open ports

### 3. Secrets: Secret Manager
- Telegram bot token, gateway token, API keys stored in Secret Manager
- Instance service account has `roles/secretmanager.secretAccessor`
- Startup script fetches secrets at each boot (same pattern as AWS)
- Secrets versioned and auditable

### 4. Model Support: Vertex AI as primary
- **Default model**: `google/gemini-2.0-flash` via Vertex AI (uses service account, no API key)
- Vertex AI enabled automatically via `gcloud services enable aiplatform.googleapis.com`
- Alternative: Any model via API key (OpenRouter, Anthropic, etc.)
- `--model` flag works identically to AWS skill

### 5. OS: Debian 12 (x86) / Ubuntu 22.04 (ARM)
- Debian 12 for x86 instances (GCP's default, well-supported)
- Ubuntu 22.04 for ARM instances (better ARM support than Debian on GCP)
- Both use systemd, apt package manager

### 6. Firewall: Deny-all ingress + IAP
- Default VPC firewall rules deleted/overridden
- Single allow rule: IAP IP range (35.235.240.0/20) → TCP 22 (for tunnel only)
- All egress allowed (outbound HTTPS for Telegram, model APIs)

### 7. Monitoring: Cloud Logging + Monitoring (built-in)
- GCP automatically ships serial console + syslog to Cloud Logging
- Cloud Monitoring provides CPU, disk, network metrics out of the box
- Optional: uptime check for OpenClaw process via custom metric
- No additional agent needed (unlike AWS CloudWatch agent)

## Cost Breakdown (~$27/mo)

| Resource | Cost |
|----------|------|
| e2-medium (2 vCPU, 4GB) | ~$24.27/mo |
| Balanced PD 20GB | ~$2.00/mo |
| External IP (ephemeral) | ~$0/mo (ephemeral, only while running) |
| Secret Manager (3 secrets) | ~$0.18/mo |
| Vertex AI (Gemini Flash) | Free tier / ~$0.075/1M tokens |
| Cloud Logging (500MB free) | $0 |
| **Total** | **~$26.45/mo** |

_Note: Static external IP costs $0.004/hr (~$2.92/mo) if reserved. Ephemeral IPs are free._

## File Layout

```
openclaw-gcp-deploy/
├── DESIGN.md                    # This document
├── README.md                    # User-facing documentation
├── SKILL.md                     # OpenClaw skill definition
├── LICENSE                      # MIT
├── .gitignore
├── scripts/
│   ├── deploy.sh                # One-shot deploy (VPC + GCE + OpenClaw)
│   ├── teardown.sh              # Clean teardown of all resources
│   ├── setup_deployer.sh        # Create service account with min permissions
│   └── smoke_test.sh            # Post-deploy health verification
├── assets/
│   ├── personalities/           # SOUL.md presets (same as AWS)
│   │   ├── default.md
│   │   ├── sentinel.md
│   │   ├── researcher.md
│   │   ├── coder.md
│   │   └── companion.md
│   └── agent-defaults/          # Default agent files
│       ├── AGENTS.md
│       ├── HEARTBEAT.md
│       ├── USER.md
│       └── SOUL.md
├── references/
│   ├── TROUBLESHOOTING.md       # Known issues + solutions
│   └── config-templates/
│       ├── openclaw.json        # OpenClaw config template
│       ├── openclaw.service     # systemd unit file
│       └── startup.sh           # Startup script template
└── CHANGELOG.md
```

## Script Interface (CLI Flags)

### deploy.sh

```bash
./scripts/deploy.sh \
  --name starfish \
  --project my-gcp-project \
  --region us-central1 \
  --zone us-central1-a \
  --env-dir /path/to/workspace \
  --machine-type e2-medium \
  --model google/gemini-2.0-flash \
  --personality default \
  --pair-user 123456789 \
  --no-monitoring \
  --dry-run
```

| Flag | Default | Description |
|------|---------|-------------|
| `--name` | starfish | Agent/deployment name |
| `--project` | (from gcloud config) | GCP project ID |
| `--region` | us-central1 | GCP region |
| `--zone` | (auto from region) | GCP zone |
| `--env-dir` | workspace root | Directory with .env files |
| `--machine-type` | e2-medium | GCE machine type |
| `--model` | google/gemini-2.0-flash | AI model string |
| `--personality` | default | Agent personality preset |
| `--pair-user` | (none) | Auto-approve Telegram pairing |
| `--disk-size` | 20 | Boot disk size in GB |
| `--network` | (auto-created) | Existing VPC network name |
| `--subnet` | (auto-created) | Existing subnet name |
| `--no-monitoring` | false | Skip uptime checks |
| `--no-rollback` | false | Don't auto-teardown on failure |
| `--cleanup-first` | false | Tear down existing first |
| `--dry-run` | false | Preview only |

### teardown.sh

```bash
./scripts/teardown.sh \
  --name starfish \
  --project my-gcp-project \
  --from-output ./deploy-output.json \
  --dry-run \
  --yes
```

## Deploy Flow (Step by Step)

1. **Validate prerequisites** — gcloud CLI, project, APIs enabled
2. **Enable APIs** — compute, secretmanager, iap, aiplatform, logging
3. **Create VPC network** — custom mode, no default firewall rules
4. **Create subnet** — single region, private Google access enabled
5. **Create firewall rules** — deny-all ingress, allow IAP (35.235.240.0/20:22), allow egress
6. **Create Cloud Router + NAT** — for outbound connectivity without external IP (optional, or use ephemeral IP)
7. **Create service account** — minimal permissions (Secret Manager, Vertex AI, Logging)
8. **Store secrets** — Telegram token, gateway token, API keys in Secret Manager
9. **Get OS image** — latest Debian 12 or Ubuntu 22.04
10. **Generate startup script** — inline, fetches secrets, installs Node.js + OpenClaw
11. **Create instance** — with startup script, service account, labels
12. **Wait for startup** — poll serial console for "Bootstrap complete"
13. **Smoke test** — verify OpenClaw is running via IAP tunnel
14. **Auto-pair** — if --pair-user provided
15. **Save outputs** — deploy-output.json with all resource IDs

## Teardown Flow

1. **Delete instance** (releases ephemeral IP, disk auto-deleted)
2. **Delete secrets** from Secret Manager
3. **Delete firewall rules**
4. **Delete subnet**
5. **Delete VPC network**
6. **Delete service account**
7. **Delete Cloud Router + NAT** (if created)

## Security Model

| Feature | Implementation |
|---------|---------------|
| No SSH keys | OS Login disabled, no project/instance SSH keys |
| No open ports | Firewall deny-all ingress |
| IAP tunnel only | `gcloud compute ssh --tunnel-through-iap` |
| Secrets at runtime | Fetched from Secret Manager at each service start |
| Minimal SA | Only secretmanager.secretAccessor + aiplatform.user |
| Disk encryption | Google-managed encryption (default) |
| Labels | All resources labeled `project=<name>`, `deploy-id=<id>` |
| Shielded VM | Secure Boot + vTPM + Integrity Monitoring |

## Prerequisites

- `gcloud` CLI installed and authenticated
- A GCP project with billing enabled
- `jq`, `openssl` available
- `.env.<name>` file with `TELEGRAM_BOT_TOKEN`
- Optional: `GEMINI_API_KEY` (for API-key Gemini, vs Vertex AI)

## Differences from AWS Skill

1. **No explicit networking for internet** — GCP VPCs with external IPs have internet by default (no IGW/route table needed, unless using NAT-only)
2. **Built-in logging** — no CloudWatch agent needed
3. **IAP vs SSM** — different tunnel mechanism, same zero-port result
4. **Vertex AI vs Bedrock** — Vertex uses service account auth, Bedrock uses IAM role
5. **Labels vs Tags** — GCP uses labels (key-value on resources) instead of tags
6. **Shielded VM** — GCP has native Shielded VM support (Secure Boot, vTPM)
7. **Simpler IAM** — GCP binds roles to service accounts directly (no instance profiles)

## Future Enhancements

- [ ] Cloud Run deployment option (serverless, scale-to-zero)
- [ ] Artifact Registry for custom OpenClaw images
- [ ] Cloud Scheduler integration for cron
- [ ] Terraform/Pulumi IaC alternative
- [ ] Multi-region with Cloud Load Balancing
