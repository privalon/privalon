# Getting Started

This document covers what the blueprint deploys, what you get from it, how to perform a first deployment, how to access the resulting services, and how to validate that the system is working.

## What the blueprint deploys

This blueprint provisions VMs on the ThreeFold Grid with Terraform, then configures them with Ansible:

| VM | Public IP | Role |
|----|-----------|------|
| **Gateway** | Yes (80/443) | Caddy reverse proxy, optional Tailscale exit node |
| **Control** | Yes (443) | Headscale control plane; Headplane admin UI stays tailnet-only on port `3000` |
| **Monitoring** | No | Prometheus + Grafana — reachable over Tailscale only |

Additional workload VMs with no public IP can be added by extending the `workloads` map in `terraform.tfvars`.

## What you get

- **Tailscale-first access**: SSH, Grafana, and Prometheus are meant to be reached over the tailnet rather than public IPs.
- **Minimal public exposure**: the gateway exposes `80/443`, the control VM exposes `443`, and workload VMs stay private.
- **Standard relay fallback**: the control VM exposes an embedded DERP relay for paths where direct peer-to-peer connectivity fails.
- **Automated security defaults**: public SSH is locked down after bootstrap and internal services bind to Tailscale-facing paths.
- **Automated backups**: nightly encrypted backups to dual S3 backends with restore-aware redeploy flows.
- **Portable control-plane recovery**: successful deploys can refresh an encrypted recovery bundle and print a one-line restore token.
- **Observability**: Prometheus, Grafana, Loki, health checks, and packaged dashboards are included from the start.
- **Verification suites**: post-deploy checks are available under `scripts/tests/`.
- **Local web UI**: `make ui` provides form-based configuration, live deploy logs, and a progress/ETA view.

## Security model

- The **tailnet is the access boundary**. After deployment, administration should happen from a tailnet-connected machine.
- If you are not on the tailnet after bootstrap, SSH timing out is expected.
- If you lose the original deploy machine, use the portable recovery flow in [Backup and recovery](BACKUP-RECOVERY.md) to rebuild the operator workspace on a fresh machine.

## Quick start

### Option A — Web UI

The local web UI is the lowest-friction path for a first deployment.

```bash
make ui-install
make ui
```

Open `http://localhost:8090`, select an environment, fill in the Configure form, then deploy from the Deploy tab.

For `full`, `gateway`, and `control` deploys, the UI's **Existing Infrastructure** selector chooses whether the run should converge in place with `--no-destroy` or perform a destroy-and-recreate path with `--yes`.

The UI also shows a top-level progress bar and ETA based on the selected deploy scope, counted Ansible tasks, and timing learned from previous successful runs in the same environment.

### Option B — CLI workflow

#### 1. Prerequisites

- Terraform installed, for example `sudo snap install terraform --classic` on Ubuntu
- a funded TFChain wallet created at [dashboard.grid.tf](https://dashboard.grid.tf/)
- one or more SSH public keys
- ideally a real DNS name for Headscale rather than long-term use of the `sslip.io` bootstrap fallback

#### 2. Configure your environment

Each deployment lives in `environments/<name>/`. The `prod` and `test` directories provide example files.

```bash
cd environments/prod

cp secrets.env.example secrets.env
$EDITOR secrets.env

cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

$EDITOR group_vars/all.yml
```

What goes where:

| File | Contains | Git status |
|------|----------|------------|
| `secrets.env` | mnemonic, admin passwords, Restic password, S3 keys | Gitignored |
| `terraform.tfvars` | SSH keys, node selection, workloads, network settings | Gitignored |
| `group_vars/all.yml` | Headscale URL, TLS mode, backup enablement, other Ansible settings | Committed |

#### 3. Deploy

```bash
./scripts/deploy.sh full --env prod --join-local
```

This command:

1. sources `secrets.env`
2. runs Terraform
3. extracts outputs into inventory data
4. validates Namecheap-managed DNS convergence when that automation is enabled
5. runs the Ansible playbook
6. refreshes the portable recovery bundle when backup storage is configured
7. joins the local machine to the tailnet when `--join-local` is used
8. locks down public SSH

The control VM also exposes a DERP relay at `https://<headscale_url>/derp` for clients that cannot establish direct peer-to-peer paths.

After completion, the deployment summary prints IPs, URLs, next steps, and the latest recovery line when the environment is configured for portable recovery.

When Namecheap DNS automation is enabled, deploys fail if public records do not converge to the expected IPs within the configured timeout. That behavior is intentional.

## Access your services

Once your machine is on the tailnet:

```bash
# SSH
ssh ops@<tailscale-ip>

# Grafana
http://<monitoring-tailscale-ip>:3000

# Prometheus
http://<monitoring-tailscale-ip>:9090

# Grafana Explore
http://<monitoring-tailscale-ip>:3000/explore

# Optional MagicDNS aliases
https://grafana.<magic-dns-domain>
https://prometheus.<magic-dns-domain>
https://backrest.<magic-dns-domain>

# Headplane, tailnet only
http://control-vm.<magic-dns-domain>:3000
```

If the gateway is configured as an exit node, select `gateway-vm` in the Tailscale client Exit Nodes menu after the deploy or gateway converge completes.

If the exit node is missing after a gateway redeploy, re-run:

```bash
./scripts/deploy.sh gateway --env <env> --no-destroy
```

## Observability views

Once Grafana is reachable, the main paths are:

- **Infrastructure Health** for VM status, CPU, memory, and disk
- **Service Health** for local and remote service checks
- **Logs Overview** for service and backup log visibility
- **Explore** for direct Loki-backed log search

The default service catalog already includes the gateway proxy, control-plane services, monitoring services, and backup workflow.

Logs stay searchable in Grafana for `30d` by default. When backup storage is configured, older logs are archived for up to `90d` total before deletion.

In `internal_service_tls_mode: namecheap`, browser-trusted HTTPS for packaged monitoring aliases terminates on the gateway's Tailscale IP and then proxies to the monitoring VM over Tailscale.

By default, redeploys preserve tailnet identity by restoring the Headscale node database and each VM's `/var/lib/tailscale` state.

If you explicitly deploy with `--fresh-tailnet`, existing workstation registrations become stale by design. Re-run:

```bash
./scripts/deploy.sh join-local --env <env> --rejoin-local
```

If an unmanaged client still fails after a control-plane restore and you keep seeing `noise handshake failed: decrypting machine key`, run `tailscale logout` followed by `tailscale up --login-server ... --reset --force-reauth` on that device.

## Verify the deployment

```bash
./scripts/tests/run.sh bootstrap-smoke
PREFER_TAILSCALE=1 REQUIRE_TS_SSH=1 ./scripts/tests/run.sh tailnet-management
./scripts/tests/run.sh backup-verify
```

The `tailnet-management` suite verifies access to monitoring services over the tailnet. If you troubleshoot manually, test the actual service endpoints from your workstation rather than relying only on `tailscale ping`.

If you run Terraform, Ansible, or the verification scripts directly instead of using `deploy.sh`, source `environments/<env>/secrets.env` with `set -a` first so shared secrets are exported into the environment.