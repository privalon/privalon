# Troubleshooting

This document collects the most common user-facing failure cases and the fastest likely fixes. It follows the same operating philosophy as the rest of the docs: failures are expected, and recovery should be low-improvisation.

## Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| SSH stops working after deploy | Public SSH was locked down by design | Join the tailnet and SSH via the Tailscale IP |
| Clients cannot join Headscale | `headscale_url` does not match the login server in use | Verify the `--login-server` value matches `headscale_url` |
| Terraform apply times out | Multi-node network creation is flaky on the selected placement | Pin nodes with `use_scheduler = false` |
| Terraform reports a name conflict | Older infrastructure was not fully cleaned up | `deploy.sh` retries automatically, but inspect stale resources if it persists |
| Verification scripts fail | Wrong IPs, URLs, or stale inventory | Run `./scripts/helpers/deployment-summary.sh` and confirm the generated values |
| Deploy shows `monitoring-vm tailscale_ip is empty; cannot configure Alloy log shipping` | Control-only or partial Ansible scope ran before monitoring facts were available | Re-run full converge (`./scripts/deploy.sh full --env <env>`) or a scope that includes monitoring so Alloy log shipping can be configured |
| Backups do not run | Backups are disabled or S3 credentials are missing | Check `group_vars/all.yml` and `secrets.env` |
| `make ui` fails | Port `8090` is already in use | Start the UI on another port, for example `python3 -m uvicorn server:app --port 9000` from `ui/` |
| Web UI shows `Error loading environments` | UI was started from the wrong directory or the server is not running | Run `make ui` from the repo root |

## Recovery-oriented notes

- The deployment summary wraps long tokens such as API keys and recovery lines to terminal width for easier scanning and copy/paste.
- Default topology is intentionally minimal: gateway, control, and monitoring. Extend `workloads` in `terraform.tfvars` to add more private workload VMs.
- Headscale preauth key creation remains best-effort because CLI flags vary by Headscale version.
- Typical backup cost for a modest deployment of around `65 GB` remains roughly low-single-digit USD per month across both S3 providers.

For detailed recovery scenarios, use [Operations runbook](../technical/OPERATIONS.md).