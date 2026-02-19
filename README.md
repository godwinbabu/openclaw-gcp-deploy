# openclaw-gcp-deploy

**One-shot OpenClaw deployment to Google Cloud Platform** — VPC, Compute Engine, Telegram, any AI model, all in one command.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## What It Does

Deploys a fully working OpenClaw agent to GCP with a single command:

```
┌─────────────────────────────────────────────────────┐
│              VPC Network (custom mode)              │
│  ┌───────────────────────────────────────────────┐  │
│  │   Compute Engine e2-medium (2 vCPU, 4GB)      │  │
│  │  ┌───────────────────────────────────────────┐│  │
│  │  │         OpenClaw Gateway                  ││  │
│  │  │  • Vertex AI / Gemini / any model         ││  │
│  │  │  • Telegram channel                       ││  │
│  │  │  • Node.js 22 + systemd                   ││  │
│  │  │  • Shielded VM (Secure Boot + vTPM)       ││  │
│  │  └───────────────────────────────────────────┘│  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
         ↑                              ↓
    IAP only (no SSH keys)    Outbound HTTPS only
```

**Cost:** ~$27/month (e2-medium + disk + secrets).

## Quick Start

### Step 1: Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/install) installed
- `gcloud auth login` completed
- GCP project with billing enabled
- `jq` and `openssl` available

### Step 2: Create Telegram Bot + API Keys

```bash
# .env.starfish (or .env.<agent-name>)
TELEGRAM_BOT_TOKEN=from-botfather          # Required
GEMINI_API_KEY=from-aistudio.google.com    # Optional (Vertex AI uses SA auth instead)
```

### Step 3: Deploy

```bash
# Basic deploy
./scripts/deploy.sh --name starfish --project my-gcp-project

# With Vertex AI Gemini (default — no API key needed)
./scripts/deploy.sh --name starfish --project my-gcp-project \
  --model google/gemini-2.0-flash

# With auto-pairing
./scripts/deploy.sh --name starfish --project my-gcp-project \
  --pair-user 123456789

# ARM instance (cheaper, limited regions)
./scripts/deploy.sh --name starfish --project my-gcp-project \
  --machine-type t2a-standard-1 --region us-central1
```

### Step 4: Pair Telegram

If you didn't use `--pair-user`:

```bash
gcloud compute ssh starfish --zone us-central1-a --tunnel-through-iap --project my-project
sudo -u openclaw bash -c 'cd /home/openclaw/.openclaw && openclaw pairing approve telegram <CODE>'
```

### Step 5: Teardown

```bash
./scripts/teardown.sh --from-output ./deploy-output.json --yes

# Or by name:
./scripts/teardown.sh --name starfish --project my-gcp-project --yes
```

## Model Support

Pass any model string via `--model`:

```bash
# Vertex AI Gemini (default, uses service account — no API key)
--model google/gemini-2.0-flash

# Gemini via API key (needs GEMINI_API_KEY in .env)
--model google/gemini-2.0-flash

# Any provider
--model openrouter/anthropic/claude-sonnet-4
```

## Personalities

| Personality | Description |
|-------------|-------------|
| `default` | Helpful, direct, efficient assistant |
| `sentinel` | Vigilant monitor — alerts, status reports |
| `researcher` | Deep-thinking research assistant |
| `coder` | Pragmatic software engineer |
| `companion` | Warm, empathetic companion |
| *custom path* | Path to your own SOUL.md file |

```bash
./scripts/deploy.sh --name watchdog --personality sentinel ...
./scripts/deploy.sh --name my-agent --personality ./my-soul.md ...
```

## Security

| Feature | Detail |
|---------|--------|
| **No SSH keys** | IAP TCP tunnel only — zero inbound ports |
| **Secrets at runtime** | Fetched from Secret Manager on each service start |
| **Minimal service account** | Only secretmanager + vertex AI roles |
| **Disk encryption** | Google-managed encryption (default) |
| **Shielded VM** | Secure Boot + vTPM + Integrity Monitoring |
| **Labels** | All resources labeled for deterministic cleanup |
| **Firewall** | Deny-all ingress, allow IAP (35.235.240.0/20:22) only |

## What Gets Created

| Resource | Purpose | Cost |
|----------|---------|------|
| VPC Network + Subnet | Isolated network | Free |
| Firewall rules (2) | Deny ingress + allow IAP | Free |
| Service account | Minimal IAM permissions | Free |
| Secret Manager secrets | Encrypted secret storage | ~$0.18/mo |
| Compute Engine e2-medium | OpenClaw host (2 vCPU, 4GB) | ~$24.27/mo |
| Balanced PD 20GB | Boot disk (encrypted) | ~$2.00/mo |
| Cloud Logging | Automatic log collection | Free (500MB) |
| **Total** | | **~$27/mo** |

## GCP Deployer Permissions

```bash
# Create a deployer service account with minimum permissions
./scripts/setup_deployer.sh --project my-gcp-project

# Or just list the required roles
./scripts/setup_deployer.sh --dry-run
```

Required roles for the deployer:
- `roles/compute.admin`
- `roles/iam.serviceAccountAdmin`
- `roles/iam.serviceAccountUser`
- `roles/secretmanager.admin`
- `roles/iap.tunnelResourceAccessor`
- `roles/serviceusage.serviceUsageAdmin`
- `roles/resourcemanager.projectIamAdmin`

## Files

```
scripts/
  deploy.sh              ← One-shot deploy (start here)
  teardown.sh            ← Clean removal of all resources
  setup_deployer.sh      ← Create deployer SA with minimum permissions
  smoke_test.sh          ← Post-deploy health verification

assets/personalities/    ← Agent personality presets (SOUL.md files)
assets/agent-defaults/   ← Default agent config files

references/
  TROUBLESHOOTING.md     ← Known issues + solutions
  config-templates/      ← OpenClaw config, systemd, startup templates
```

## Compared to AWS Deploy

| Feature | AWS | GCP |
|---------|-----|-----|
| Compute | EC2 t4g.medium (ARM) | e2-medium (x86) or t2a (ARM) |
| Remote access | SSM Session Manager | IAP TCP Tunnel |
| Secrets | SSM Parameter Store | Secret Manager |
| AI models | Bedrock (IAM auth) | Vertex AI (SA auth) |
| Monitoring | CloudWatch (agent needed) | Cloud Logging (built-in) |
| Cost | ~$30/mo | ~$27/mo |

## Requirements

- Google Cloud SDK (`gcloud`) installed and authenticated
- `jq`, `openssl` available
- GCP project with billing enabled
- Telegram bot token ([create one](https://t.me/BotFather))

## License

MIT
