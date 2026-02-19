---
name: openclaw-gcp-deploy
description: Deploy OpenClaw securely on GCP with a single command. Creates VPC, Compute Engine, Telegram channel, and configurable AI model (Vertex AI, Gemini, or any provider) — IAP-only access, no SSH keys. Use when setting up OpenClaw on GCP, deploying a new agent instance to Compute Engine, or tearing down an existing GCP deployment.
metadata:
  {
    "openclaw":
      {
        "emoji": "☁️",
        "requires": { "bins": ["gcloud", "jq", "openssl"] },
      },
  }
---

# OpenClaw GCP Deploy Skill

## Quick Start (~$27/mo)

### Prerequisites
- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- GCP project with billing enabled
- `.env.starfish` in workspace root:
  ```
  TELEGRAM_BOT_TOKEN=...     # from @BotFather (required)
  GEMINI_API_KEY=...         # optional (for API-key Gemini, vs Vertex AI)
  ```
- `jq`, `openssl` available

### One-Shot Deploy

```bash
./scripts/deploy.sh --name starfish --project my-gcp-project

# With specific model:
./scripts/deploy.sh --name starfish --project my-gcp-project \
  --model google/gemini-2.0-flash

# With auto-pairing:
./scripts/deploy.sh --name starfish --project my-gcp-project \
  --pair-user 123456789
```

This single command:
1. Enables required GCP APIs (Compute, Secret Manager, IAP, Vertex AI)
2. Creates VPC network + subnet (custom mode)
3. Creates firewall rules (deny-all ingress, allow IAP tunnel only)
4. Creates service account with minimal permissions
5. Stores secrets in Secret Manager
6. Launches e2-medium instance with startup script
7. Installs Node.js 22 + OpenClaw + configures everything
8. Runs smoke test via IAP tunnel
9. Saves all resource info to `deploy-output.json`

### After Deploy

1. **Message the Telegram bot** — you'll get a pairing code
2. **Approve pairing** via IAP SSH:
   ```bash
   gcloud compute ssh starfish --zone us-central1-a --tunnel-through-iap --project my-project
   sudo -u openclaw bash -c 'cd /home/openclaw/.openclaw && openclaw pairing approve telegram <CODE>'
   ```
3. Bot is live! ✅

### Teardown

```bash
# Using saved output:
./scripts/teardown.sh --from-output ./deploy-output.json --yes

# Or by name:
./scripts/teardown.sh --name starfish --project my-gcp-project --yes
```

## Model Support

### `--model` flag

```bash
# Gemini Flash via Vertex AI (default — uses service account, no API key)
--model google/gemini-2.0-flash

# Any model via API key
--model openrouter/anthropic/claude-sonnet-4
```

### Vertex AI
Service account gets `roles/aiplatform.user` automatically. No API key needed — uses GCP identity.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│              VPC Network (custom mode)              │
│  ┌───────────────────────────────────────────────┐  │
│  │        Subnet (10.50.0.0/24)                  │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │   Compute Engine e2-medium (4GB)        │  │  │
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

## Security

| Feature | Detail |
|---------|--------|
| **No SSH keys** | IAP tunnel only — zero inbound ports |
| **Secrets at runtime** | Fetched from Secret Manager at each service start |
| **Minimal SA** | Only secretmanager.secretAccessor + aiplatform.user |
| **Disk encryption** | Google-managed encryption (default) |
| **Shielded VM** | Secure Boot + vTPM + Integrity Monitoring |
| **Labels** | All resources labeled `project=<name>`, `deploy-id=<id>` |
| **Firewall** | Deny-all ingress, allow IAP range only |

## Cost Breakdown (~$27/mo)

| Resource | Cost |
|----------|------|
| e2-medium (2 vCPU, 4GB) | ~$24.27/mo |
| Balanced PD 20GB | ~$2.00/mo |
| Secret Manager (3 secrets) | ~$0.18/mo |
| Vertex AI (Gemini Flash) | Free tier / pay per token |
| Cloud Logging | Free (500MB/mo) |
| **Total** | **~$26.45/mo** |

## Personalities

| Personality | Description |
|-------------|-------------|
| `default` | Helpful, direct, efficient assistant |
| `sentinel` | Vigilant monitor — alerts, status reports |
| `researcher` | Deep-thinking research assistant |
| `coder` | Pragmatic software engineer |
| `companion` | Warm, empathetic companion |
| *custom path* | Path to your own SOUL.md file |

## Troubleshooting

See `references/TROUBLESHOOTING.md` for known issues and solutions.
