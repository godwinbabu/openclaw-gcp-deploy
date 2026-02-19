# Troubleshooting — OpenClaw GCP Deploy

## Known Issues

### 1. Instance has no internet connectivity

**Symptom:** Startup script hangs, can't install packages.

**Cause:** Instance created with `--no-address` (no external IP) and no Cloud NAT configured.

**Fix:** The deploy script automatically retries with an ephemeral external IP if `--no-address` fails. If you need NAT-only (no external IP), create a Cloud Router + Cloud NAT gateway first:

```bash
gcloud compute routers create openclaw-router --network=<network> --region=<region>
gcloud compute routers nats create openclaw-nat --router=openclaw-router --region=<region> --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
```

### 2. "Permission denied" accessing Secret Manager

**Symptom:** Startup script fails to fetch secrets.

**Cause:** Service account missing `roles/secretmanager.secretAccessor`.

**Fix:** Grant the role:
```bash
gcloud projects add-iam-policy-binding <project> \
  --member="serviceAccount:<sa-email>" \
  --role="roles/secretmanager.secretAccessor"
```

### 3. Node.js install fails on ARM (t2a instances)

**Symptom:** Node.js tarball download or extraction fails.

**Cause:** Wrong architecture in download URL.

**Fix:** The deploy script auto-detects ARM vs x86 and uses the correct tarball. If manually installing:
```bash
# ARM64
curl -fsSL https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-arm64.tar.xz -o node.tar.xz
# x86_64
curl -fsSL https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz -o node.tar.xz
```

### 4. Shielded VM boot fails

**Symptom:** Instance doesn't boot with Secure Boot enabled.

**Cause:** Some custom images or older OS versions don't support Secure Boot.

**Fix:** Remove `--shielded-secure-boot` from the instance creation command, or use the default Debian 12 / Ubuntu 22.04 images which support it.

### 5. IAP tunnel SSH fails

**Symptom:** `gcloud compute ssh --tunnel-through-iap` times out.

**Causes:**
- Missing `roles/iap.tunnelResourceAccessor` on your user
- Firewall rule for IAP (35.235.240.0/20) not created
- Instance not running

**Fix:**
```bash
# Check IAP role
gcloud projects get-iam-policy <project> --filter="bindings.role:iap.tunnelResourceAccessor"

# Verify firewall
gcloud compute firewall-rules list --filter="name~allow-iap" --project <project>

# Check instance status
gcloud compute instances describe <name> --zone <zone> --format="value(status)"
```

### 6. OpenClaw gateway fails to start

**Symptom:** Service is "failed" in systemctl.

**Causes:**
- Node.js not installed (npm install failed)
- Config file invalid
- Port already in use

**Fix:** SSH in via IAP and check logs:
```bash
gcloud compute ssh <instance> --zone <zone> --tunnel-through-iap
sudo journalctl -u openclaw -n 50 --no-pager
cat /var/log/openclaw-bootstrap.log
```

### 7. Telegram bot doesn't respond

**Symptom:** Bot is online but ignores messages.

**Cause:** Pairing not approved.

**Fix:** Message the bot, then approve via IAP SSH:
```bash
gcloud compute ssh <instance> --zone <zone> --tunnel-through-iap
sudo -u openclaw bash -c 'cd /home/openclaw/.openclaw && openclaw pairing approve telegram <CODE>'
```

### 8. "API not enabled" errors

**Symptom:** `googleapi: Error 403: ... has not been used in project ... before or it is disabled`

**Fix:** The deploy script enables required APIs automatically. If it failed:
```bash
gcloud services enable compute.googleapis.com secretmanager.googleapis.com \
  iap.googleapis.com aiplatform.googleapis.com --project <project>
```

### 9. Vertex AI model errors

**Symptom:** Model returns errors or "permission denied".

**Cause:** Service account missing `roles/aiplatform.user`, or Vertex AI API not enabled.

**Fix:**
```bash
gcloud services enable aiplatform.googleapis.com --project <project>
gcloud projects add-iam-policy-binding <project> \
  --member="serviceAccount:<sa-email>" \
  --role="roles/aiplatform.user"
```

### 10. Teardown fails — resources still exist

**Symptom:** Some resources can't be deleted.

**Causes:**
- Dependencies (instance still using network)
- IAM bindings not cleaned up

**Fix:** Delete in order: instance → secrets → firewall rules → subnet → network → service account. Or use `--from-output` which has exact resource names.

### 11. gcloud CLI not found on instance

**Symptom:** Startup script can't run `gcloud secrets versions access`.

**Cause:** gcloud not pre-installed on the VM image.

**Fix:** The startup script installs gcloud CLI if not present. Debian 12 images usually have it pre-installed via google-cloud-sdk package. If not, the script downloads it.

### 12. Disk space full during install

**Symptom:** npm install or Node.js download fails with ENOSPC.

**Fix:** Use `--disk-size 30` (or larger) when deploying. Default is 20GB which is sufficient for most cases.
