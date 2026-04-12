# Privalon

Infrastructure blueprint (Terraform + Ansible) for a small multi-VM setup on the ThreeFold Grid, using Headscale/Tailscale for private access.

Current release: see [VERSION](VERSION) (history in [CHANGELOG.md](CHANGELOG.md)).

## Why this exists

This project is meant to make digital sovereignty practical by default for individuals and small organizations.

The goal is not just "self-hosting," but self-hosting that stays safe, recoverable, and realistic to operate over time.

- Security should be built in, not added later.
- Backups should be automatic, not something operators remember when it is already too late.
- Observability should be present from the start, not bolted on after incidents.
- Recovery should be a standard workflow, not an improvisation.
- Adding another service should reuse the same model instead of introducing chaos.

The blueprint therefore keeps only the minimum required public surface, pushes administration onto the tailnet, and treats predictability, recovery, and repeatability as first-class product goals.

For the fuller product vision and operating model, start with [docs/user/GUIDE.md](docs/user/GUIDE.md).

## Who this is for

- You want a small “personal / SMB” style blueprint with a **public gateway** and **private internal services**.
- You’re comfortable operating infrastructure from a terminal and running Terraform/Ansible.

Non-goals:
- This is not a managed service.
- This does not (yet) aim to be a fully audited, multi-tenant platform.

## Prerequisites

- Terraform installed.
- A funded ThreeFold Grid account mnemonic.
- SSH public keys ready (used for initial bootstrap access).
- Optional but strongly recommended: a real DNS name for Headscale. The `sslip.io` fallback is useful for bootstrap/dev, but not as a long-term control-plane URL.
- Optional: Namecheap API credentials if you want automatic A-record updates or browser-trusted wildcard TLS on the gateway for the public `*.yourdomain.com` namespace and/or the internal `*.in.<domain>` namespace.

If you enable `public_service_tls_mode: namecheap` or `internal_service_tls_mode: namecheap`, the deploy can complete wildcard activation in a single pass when the current gateway public IP is already allowlisted in the Namecheap API settings before the deploy starts. If that IP was not allowlisted yet, finish the deploy, add the current gateway public IP to the Namecheap API allowlist, then run `./scripts/deploy.sh gateway --env <env>` once. Other TLS modes/providers remain one-pass flows.

## Certificate Automation

- Public HTTPS hostnames have two gateway modes:
	- `public_service_tls_mode: letsencrypt` uses Caddy's normal ACME / Let's Encrypt flow. Certificates are issued and renewed automatically per hostname once DNS points at the correct VM and the ACME path remains reachable.
	- `public_service_tls_mode: namecheap` uses one wildcard public certificate for `*.base_domain` on the gateway via Namecheap DNS-01.
- Headscale stays on its own exact-host certificate path on the control VM.
- Tailnet-only monitoring aliases have two modes:
	- `internal_service_tls_mode: internal` uses the monitoring VM's private Caddy CA. There is no public ACME renewal path in this mode because clients trust the private CA instead.
	- `internal_service_tls_mode: namecheap` uses a wildcard public certificate for `*.headscale_magic_dns_base_domain` on the gateway via Namecheap DNS-01.
- In Namecheap mode, the first gateway-side wildcard issuance is a two-pass flow. After that, renewals are automatic through Caddy as long as the gateway public IP is still allowlisted in Namecheap and the API credentials remain valid.

## Security model (high level)

- After bootstrap, **public SSH is intended to be blocked**; administration happens over the tailnet.
- Workload services are intended to bind to the Tailscale interface only.
- The control VM includes a standard DERP relay fallback so private-only nodes remain reachable when direct peer-to-peer paths fail.
- Headplane is intended to stay **tailnet-only** even though Headscale itself remains public on the control VM.
- ThreeFold has “no console” realities; recovery may require **destroy + recreate** (see operations runbook).
- When backup storage is configured, each successful deploy also refreshes a portable control-plane recovery bundle and prints a one-line restore token for fresh-machine recovery.
- Deploy and restore now also auto-migrate the blueprint-managed environment data under `environments/<env>/` to the current supported schema. This covers environment files only, not service-internal databases or application data.

## Documentation

### User-facing (what it does, features, how to use it)
- Quick start / overview: [docs/README.md](docs/README.md)
- Main guide hub: [docs/user/GUIDE.md](docs/user/GUIDE.md)
- Product concept and vision: [docs/user/CONCEPT.md](docs/user/CONCEPT.md)
- Getting started: [docs/user/GETTING-STARTED.md](docs/user/GETTING-STARTED.md)
- Deployment and configuration: [docs/user/DEPLOYMENT.md](docs/user/DEPLOYMENT.md)
- Backup and recovery: [docs/user/BACKUP-RECOVERY.md](docs/user/BACKUP-RECOVERY.md)

### Technical (architecture + operations)
- Architecture: [docs/technical/ARCHITECTURE.md](docs/technical/ARCHITECTURE.md)
- Operations runbook: [docs/technical/OPERATIONS.md](docs/technical/OPERATIONS.md)
- Roadmap / design notes: [docs/roadmap/blueprint-improvement.md](docs/roadmap/blueprint-improvement.md)
- Published delivery milestones: [docs/roadmap/DELIVERY-MILESTONES.md](docs/roadmap/DELIVERY-MILESTONES.md)
- Internal service template + Vaultwarden design spec: [docs/roadmap/service-template-and-vaultwarden.md](docs/roadmap/service-template-and-vaultwarden.md)
- Portable recovery bundle and restore spec: [docs/roadmap/portable-recovery-bundle-and-restore.md](docs/roadmap/portable-recovery-bundle-and-restore.md)
- Logging and service observability: [docs/technical/ARCHITECTURE.md](docs/technical/ARCHITECTURE.md) + [docs/technical/OPERATIONS.md](docs/technical/OPERATIONS.md)

Terminal-driven deploys launched through `./scripts/deploy.sh ...` are recorded automatically into `environments/<env>/.ui-logs/` so the local Web UI History tab can replay them later. UI-triggered deploys now also store an immutable per-job snapshot of `scripts/deploy.sh` in that same log directory before launch, preserve the original repo root when executing that snapshot, and therefore avoid both mid-run script edits and path-resolution regressions while the job is still running. The Web UI Deploy tab now combines the emitted deploy plan, correctly counted `ansible-playbook --list-tasks` output, live Ansible task markers, and an environment-local timing profile rebuilt from successful prior jobs. That lets the top-level progress bar and ETA learn real step durations over time, remain resilient as the blueprint expands, and adapt mid-run when a step is overrunning its historical average. Real-domain environments also auto-enable Let's Encrypt for Headscale again by default, while `join-local` now installs the persisted internal Headscale CA into the macOS System keychain when internal TLS is intentionally used.

Job logs now also contain machine-readable progress diagnostics for post-run estimation analysis: deploy-side `[bp-progress]` markers include timestamps and elapsed timing, and UI-triggered runs append throttled `[bp-progress-ui]` estimator snapshots with the visible percent/ETA/label state back into the same persisted log.

Tailnet identity is preserved by default on redeploys: Headscale restores its node database and each VM restores `/var/lib/tailscale` so existing node registrations survive routine rebuilds. Use `./scripts/deploy.sh ... --fresh-tailnet` only when you explicitly want a destructive tailnet reset.

When `--fresh-tailnet` is used, the deployment summary now includes client reset instructions that prefer `./scripts/deploy.sh join-local --env <env> --rejoin-local`, so laptops and other user devices rejoin through the hostname-sanitizing helper before falling back to a manual `tailscale logout` plus `tailscale up --force-reauth --hostname ...` flow.

When `backup_enabled: true` and two backup backends are configured, the deployment summary also prints a single opaque break-glass recovery line and stores the latest generated copy locally in `environments/<env>/.recovery/latest-recovery-line`. Restore from a fresh macOS or Linux machine with `./scripts/restore.sh --recovery-line '<opaque-line>'`.

## AI-assisted contributions

Repo-wide Copilot workflow and guardrails live in [.github/copilot-instructions.md](.github/copilot-instructions.md).

## Contributing

- Contribution guidelines: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security policy: [SECURITY.md](SECURITY.md)

