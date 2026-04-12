# Privalon

## ThreeFold Grid blueprint (Terraform + Ansible)

Current release: see [../VERSION](../VERSION) (history in [../CHANGELOG.md](../CHANGELOG.md)).

## Product framing

This repository is not only a Terraform + Ansible deployable. It is a blueprint for making digital sovereignty practical by default: private-by-default access, minimal public exposure, built-in backups, built-in observability, and a repeatable way to add more services without increasing operational chaos.

If you are new to the repo, read it in this order:

- [user/CONCEPT.md](user/CONCEPT.md) for the product idea, vision, operating principles, and intended audience.
- [user/GETTING-STARTED.md](user/GETTING-STARTED.md) for what gets deployed, quick-start flows, access patterns, and validation.
- [user/DEPLOYMENT.md](user/DEPLOYMENT.md) for environment configuration, deploy scopes, node selection, TLS, and joining devices.
- [user/BACKUP-RECOVERY.md](user/BACKUP-RECOVERY.md) for recovery workflows and service-data backup guidance.
- [user/GUIDE.md](user/GUIDE.md) for the compact user-guide hub that ties those topics together.
- [technical/ARCHITECTURE.md](technical/ARCHITECTURE.md) for the implementation model and system boundaries.
- [technical/OPERATIONS.md](technical/OPERATIONS.md) for recovery, day-2 operations, and runbook detail.
- [roadmap/blueprint-improvement.md](roadmap/blueprint-improvement.md) for the larger evolution plan.

## What you get

- Public gateway for HTTPS ingress (80/443)
- Self-hosted tailnet control-plane (Headscale) for private access
- Embedded DERP relay on the control VM as standard fallback for non-direct client paths
- Private internal workloads (no public IPv4 by default)
- Post-deploy verification scripts under `scripts/tests/`
- **Local web UI** (`make ui`) — deployment dashboard, live log streaming, and config editor

## Operational expectations

- After Ansible finishes, plan to administer hosts from a tailnet-connected machine.
- ThreeFold “no console” reality: if you lose access, recovery is usually **replace/redeploy**.
- When backup storage is configured, each successful deploy also refreshes a portable control-plane recovery bundle and prints a one-line restore token for fresh-machine recovery.
- Deploy and restore automatically migrate the blueprint-managed environment data model when older environment files are restored or reused. This is separate from service-data backup/restore.
- The gateway exit-node path is part of the shipped tailnet workflow: the blueprint now installs the required Headscale internet ACL, gateway forwarding/firewall settings, and an end-to-end regression check in `./scripts/tests/run.sh tailnet-management`.

## Documentation map

### User-facing (what it does, features, how to use it)
- Guide hub: [user/GUIDE.md](user/GUIDE.md)
- Product concept and vision: [user/CONCEPT.md](user/CONCEPT.md)
- Getting started: [user/GETTING-STARTED.md](user/GETTING-STARTED.md)
- Deployment and configuration: [user/DEPLOYMENT.md](user/DEPLOYMENT.md)
- Backup and recovery: [user/BACKUP-RECOVERY.md](user/BACKUP-RECOVERY.md)
- Troubleshooting: [user/TROUBLESHOOTING.md](user/TROUBLESHOOTING.md)
- This page (quick start / overview): [README.md](README.md)

### Technical (architecture + operations)
- Architecture: [technical/ARCHITECTURE.md](technical/ARCHITECTURE.md)
- Operations runbook: [technical/OPERATIONS.md](technical/OPERATIONS.md)
- Backup architecture: [technical/BACKUP.md](technical/BACKUP.md)
- DNS and service visibility: [technical/ARCHITECTURE.md#dns-and-service-visibility](technical/ARCHITECTURE.md#dns-and-service-visibility) + [technical/OPERATIONS.md#domain-configuration](technical/OPERATIONS.md#domain-configuration)

### Roadmap / design notes
- Multi-environment model: [technical/ARCHITECTURE.md#multi-environment-model](technical/ARCHITECTURE.md#multi-environment-model)
- Environment operations: [technical/OPERATIONS.md#working-with-environments](technical/OPERATIONS.md#working-with-environments)
- Portable recovery bundle and restore: [technical/ARCHITECTURE.md#control-plane-recovery-bundle](technical/ARCHITECTURE.md#control-plane-recovery-bundle) + [technical/OPERATIONS.md#portable-recovery-bundle-and-restore](technical/OPERATIONS.md#portable-recovery-bundle-and-restore)
- DNS routing and service visibility roadmap (remaining work): [roadmap/dns-and-visibility.md](roadmap/dns-and-visibility.md)
- Internal service template + Vaultwarden design spec: [roadmap/service-template-and-vaultwarden.md](roadmap/service-template-and-vaultwarden.md)
- Logging and service observability: [technical/ARCHITECTURE.md](technical/ARCHITECTURE.md) + [technical/OPERATIONS.md](technical/OPERATIONS.md)
- Blueprint improvement roadmap: [roadmap/blueprint-improvement.md](roadmap/blueprint-improvement.md)
- AI-layer roadmap: [roadmap/ai-layer-roadmap.md](roadmap/ai-layer-roadmap.md)
- Web UI — deployment dashboard & config interface: [technical/ARCHITECTURE.md#web-ui](technical/ARCHITECTURE.md#web-ui) + [technical/OPERATIONS.md#web-ui-local-deployment-dashboard](technical/OPERATIONS.md#web-ui-local-deployment-dashboard)

## AI-assisted contributions

Repo-wide Copilot workflow and guardrails: [../.github/copilot-instructions.md](../.github/copilot-instructions.md)

Contributing:
- [../CONTRIBUTING.md](../CONTRIBUTING.md)
- [../SECURITY.md](../SECURITY.md)

This repo contains a starter blueprint to deploy a small multi-VM setup on the ThreeFold Grid using Terraform, then configure it with Ansible.

- **Gateway VM** with **public IPv4** (public edge: 80/443, reverse proxy, optional exit node with Headscale default-route approval handled during converge)
- **Control VM** with **public IPv4** (runs **Headscale** on 443; **Headplane** stays tailnet-only on the control node)
- **Workload VMs** with **no public IPv4** (default: monitoring VM with Prometheus + Grafana)

- Architecture: [technical/ARCHITECTURE.md](technical/ARCHITECTURE.md)
- Main guide: [user/GUIDE.md](user/GUIDE.md)
- Operations runbook: [technical/OPERATIONS.md](technical/OPERATIONS.md)

## Quick start

### Install local dependencies first

The repo assumes a few local tools are already present. On a fresh Ubuntu or Debian machine, install them before using either the Web UI or the CLI:

```bash
sudo apt update
sudo apt install -y ca-certificates curl git jq lsof make openssh-client python3 python3-pip python3-venv rsync
sudo apt install -y ansible
sudo snap install terraform --classic
```

What these are used for:

- `make`, `python3`, `python3-pip`, `lsof`: local Web UI (`make ui-install`, `make ui`, `make ui-stop`)
- `terraform`, `ansible-playbook`: actual infrastructure deploys
- `ssh`, `rsync`, `jq`, `curl`, `git`: deploy/restore helper scripts and normal operator workflow

If `apt install make` reports `no installation candidate`, your package metadata is incomplete. Run `sudo apt update` first. On stripped-down Ubuntu images, also ensure the standard Ubuntu repositories are enabled:

```bash
sudo apt install -y software-properties-common
sudo add-apt-repository universe
sudo apt update
```

After that, re-run the install command above.

### Option A — Web UI (recommended)

No terminal editing required. A locally-hosted dashboard handles configuration, deployment, and live log streaming.

```bash
# Install the UI's Python packages (fastapi, uvicorn, pyyaml, python-dotenv,
# aiofiles, python-hcl2) once the OS-level dependencies above are present.
make ui-install

# Start the UI
make ui
```

Open **http://localhost:8090**, select your environment in the **Configure** tab, fill in the form (credentials, SSH keys, DNS), then click **Deploy** in the **Deploy** tab. See [user/GUIDE.md](user/GUIDE.md) and [../ui/README.md](../ui/README.md) for a full walkthrough.

For `full`, `gateway`, and `control` deploys, the Deploy tab's **Existing Infrastructure** dropdown preselects whether the UI should converge in place (`--no-destroy`) or force a destroy-and-recreate cycle (`--yes`).

### Option B — CLI (one-command deploy)

Once the local dependencies above are installed, configure your environment:

```bash
cd environments/prod
cp secrets.env.example secrets.env  && $EDITOR secrets.env
cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars
```

Deploy everything in one command:

```bash
# From the repo root:
./scripts/deploy.sh full --env prod --join-local
```

This runs Terraform + Ansible in sequence, extracts outputs, and optionally joins your workstation to the tailnet.

If you enable `public_service_tls_mode: namecheap` or `internal_service_tls_mode: namecheap`, treat the first activation as a Namecheap-specific two-pass flow: let the initial deploy finish, whitelist the current gateway public IP in Namecheap's API settings, then run `./scripts/deploy.sh gateway --env <env>` once. Other TLS modes/providers continue in one pass.

Certificate lifecycle summary:

- Public hostnames: either Caddy issues and renews per-host Let's Encrypt certificates automatically, or the gateway serves one wildcard certificate for `*.base_domain` when `public_service_tls_mode: namecheap` is enabled.
- Internal monitoring aliases in `internal` mode: private CA on the monitoring VM, no public ACME path.
- Internal monitoring aliases in `namecheap` mode: gateway-side wildcard certificate with automatic renewal through Namecheap DNS-01, but the gateway public IP must remain allowlisted in Namecheap for renewal to keep working.

After completion, access is **Tailscale-only**:

- SSH: `ssh root@<tailscale-ip>`
- Grafana: `http://<monitoring-tailscale-ip>:3000`
- Prometheus: `http://<monitoring-tailscale-ip>:9090`
- Headplane: `http://control-vm.<magic-dns-domain>:3000` or `http://<control-tailscale-ip>:3000`

Important:

- The `firewall` role locks down **public SSH**. After the playbook completes, manage hosts via **Tailscale SSH**.
- Assume there is **no VM console** to recover access. If you need a temporary safety net during bootstrap, set `firewall_allow_public_ssh_from_cidrs` (see [technical/OPERATIONS.md](technical/OPERATIONS.md)).

## One-command deploy helpers

```bash
./scripts/deploy.sh full    --env prod --join-local
./scripts/deploy.sh gateway --env prod
./scripts/deploy.sh control --env prod
```

Notes:

- These commands detect existing Terraform state and will ask before destroying anything.
- A backup hook runs first (currently a stub): `scripts/hooks/backup.sh`.
- If the control VM is corrupted/destroyed, you can recreate it and restore Headscale from backup. See the control recovery section in [technical/OPERATIONS.md](technical/OPERATIONS.md).

### Joining your deploy machine to the tailnet

```bash
./scripts/deploy.sh full --join-local
```

Force re-auth if already connected to another tailnet: add `--rejoin-local`.

### Temporary public SSH allowlist (bootstrap safety net)

```bash
./scripts/deploy.sh full --allow-ssh-from-my-ip
```

Or specify a CIDR: `--allow-ssh-from "203.0.113.10/32"`.

With `--join-local`, the allowlist is removed automatically at the end. Otherwise, follow the manual firewall-lockdown steps in [technical/OPERATIONS.md](technical/OPERATIONS.md).

## Run the verification tests

After a deploy, you can run the repo’s end-to-end checks from the repo root:

```bash
PREFER_TAILSCALE=1 ./scripts/tests/run.sh bootstrap-smoke
PREFER_TAILSCALE=1 REQUIRE_TS_SSH=1 ./scripts/tests/run.sh tailnet-management
```

## Versioning and releases

This repo now uses a single repo-wide Semantic Versioning source of truth:

- `VERSION`: current release number
- `CHANGELOG.md`: human-readable history in Keep a Changelog format
- `scripts/release.sh`: helper to inspect or bump versions

Useful commands:

```bash
make version
make changelog
make release-patch
make release-minor
make release-major
```

Release rule of thumb:

- Patch: fixes, small doc/test updates, no intended workflow change
- Minor: new repo features, new services, materially improved workflows
- Major: breaking layout, compatibility, or operational model changes
