# Changelog

## [0.1.0] - 2026-02-18

### Added
- Initial release
- One-shot deploy script (`deploy.sh`) — creates VPC, subnet, firewall, SA, secrets, GCE instance
- Clean teardown script (`teardown.sh`) — label-based or output-file discovery
- Deployer setup script (`setup_deployer.sh`) — minimum-privilege service account
- Smoke test script (`smoke_test.sh`) — IAP-based health check
- 5 personality presets (default, sentinel, researcher, coder, companion)
- Agent default files (AGENTS.md, HEARTBEAT.md, USER.md, SOUL.md)
- Shielded VM support (Secure Boot, vTPM, Integrity Monitoring)
- IAP tunnel access (no SSH keys, no open ports)
- Secret Manager integration (secrets fetched at each service start)
- Vertex AI support (service account auth, no API key needed)
- ARM support via t2a machine types
- Auto-rollback on deploy failure
- Auto-pairing via `--pair-user` flag
- Design document (DESIGN.md)
- Troubleshooting guide (12 known issues)
