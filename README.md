# Privalon

[![CI](https://github.com/clarionis-data/generic-blueprint/actions/workflows/ci.yml/badge.svg)](https://github.com/clarionis-data/generic-blueprint/actions/workflows/ci.yml)

Infrastructure blueprint (Terraform + Ansible) for a small multi-VM setup on the ThreeFold Grid, using Headscale/Tailscale for private access.

Current release: see [VERSION](VERSION) (history in [CHANGELOG.md](CHANGELOG.md)).

## Why this exists

Many people want digital sovereignty: fewer subscriptions, fewer opaque vendors touching their data, and far less dependence on platforms that move data through analytics, partner, and model-training pipelines they do not meaningfully control.

The problem is that "just self-host it" is usually only the easy first step. Getting an open-source app to run is one thing. Keeping it backed up, restorable, observable, secure, properly exposed, and realistic to operate under failure is the hard part.

That is the gap this project is trying to close.

Privalon is meant to be a reusable framework for a private digital ecosystem, not just a one-off deploy recipe. The goal is to let one operator or a small team add services over time without re-solving the same operational problems every time.

The baseline model is:

- stable daily backups with failure visibility and restore paths designed to work under real pressure
- observability from day one: metrics, logs, dashboards, and service health signals
- the smallest practical public attack surface, with clear separation between public ingress and private services
- built-in alerting, DNS, and TLS management as part of the platform instead of as manual follow-up work
- private networking by default, with tailnet-first administration and optional gateway exit-node use
- a repeatable service model so the next workload is easier to add than the previous one

Longer-term roadmap work extends that operating model further, including higher-level operator assistance, but the current direction is already clear: make self-hosting feel materially closer to the convenience, reliability, and security bar people expect from proprietary cloud products.

For the fuller product vision and operating model, start with [docs/user/GUIDE.md](docs/user/GUIDE.md).

## Who this is for

- You want a small “personal / SMB” style blueprint with a **public gateway** and **private internal services**.
- You want to grow from one private service to a small private ecosystem without re-solving backups, DNS, TLS, monitoring, and security boundaries each time.
- You may still use the CLI, but you do not need to be comfortable doing everything from the terminal; the local web UI already covers the lower-friction path and is expected to keep improving over time.

Non-goals:
- This is not a managed service.
- This does not (yet) aim to be a fully audited, multi-tenant platform.

## Prerequisites

- Terraform installed.
- A funded ThreeFold Grid account mnemonic.
- SSH public keys ready (used for initial bootstrap access).
- Optional but strongly recommended: a real DNS domain for the control plane and any service hostnames you want to expose cleanly. The `sslip.io` fallback is useful for bootstrap/dev Headscale access, but it is not a good long-term control-plane URL and does not replace proper DNS for public services or browser-trusted TLS.
- Optional: Namecheap API credentials only if you want the repo to manage DNS A-record updates automatically and/or if you choose Namecheap-backed wildcard TLS on the gateway for the public `*.yourdomain.com` namespace and/or the internal `*.in.<domain>` namespace. They are not required for manual DNS management or the default per-host Let's Encrypt flows.

If you enable `public_service_tls_mode: namecheap` or `internal_service_tls_mode: namecheap`, those modes require `NAMECHEAP_API_USER` and `NAMECHEAP_API_KEY` in `secrets.env`. The deploy can complete wildcard activation in a single pass when the current gateway public IP is already allowlisted in the Namecheap API settings before the deploy starts. If that IP was not allowlisted yet, finish the deploy, add the current gateway public IP to the Namecheap API allowlist, then run `./scripts/deploy.sh gateway --env <env>` once. Other TLS modes/providers remain one-pass flows.

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

- After bootstrap, **public SSH is blocked**; administration happens over the tailnet.
- Workload services bind to the Tailscale interface only.
- The control VM includes a standard DERP relay fallback so private-only nodes remain reachable when direct peer-to-peer paths fail.
- Headplane stays **tailnet-only** while Headscale itself remains public on the control VM.
- ThreeFold has “no console” realities; recovery may require **destroy + recreate** (see operations runbook).
- When backup storage is configured, each successful deploy refreshes a portable control-plane recovery bundle in backup storage. The recovery line is meant to be saved offline and reused to restore the latest bundle on a fresh machine; it is only reprinted when first created or when recovery-backend settings change.
- Deploy and restore now also auto-migrate the blueprint-managed environment data under `environments/<env>/` to the current supported schema. This covers environment files only, not service-internal databases or application data.

## Documentation

### User-facing (what it does, features, how to use it)
- Quick start / overview: [docs/README.md](docs/README.md)
- Main guide hub: [docs/user/GUIDE.md](docs/user/GUIDE.md)
- Product concept and vision: [docs/user/CONCEPT.md](docs/user/CONCEPT.md)
- Getting started: [docs/user/GETTING-STARTED.md](docs/user/GETTING-STARTED.md)
- Deployment and configuration: [docs/user/DEPLOYMENT.md](docs/user/DEPLOYMENT.md)
- Backup and recovery: [docs/user/BACKUP-RECOVERY.md](docs/user/BACKUP-RECOVERY.md)
- Troubleshooting: [docs/user/TROUBLESHOOTING.md](docs/user/TROUBLESHOOTING.md)

### Technical (architecture + operations)
- Architecture: [docs/technical/ARCHITECTURE.md](docs/technical/ARCHITECTURE.md)
- Operations runbook: [docs/technical/OPERATIONS.md](docs/technical/OPERATIONS.md)
- Backup architecture: [docs/technical/BACKUP.md](docs/technical/BACKUP.md)
- Roadmap / design notes: [docs/roadmap/blueprint-improvement.md](docs/roadmap/blueprint-improvement.md)
- Published delivery milestones: [docs/roadmap/DELIVERY-MILESTONES.md](docs/roadmap/DELIVERY-MILESTONES.md)
- Forgejo first-service spec (service selection + visibility contract): [docs/roadmap/forgejo-first-service-spec.md](docs/roadmap/forgejo-first-service-spec.md)
- Internal service template + Vaultwarden design spec: [docs/roadmap/service-template-and-vaultwarden.md](docs/roadmap/service-template-and-vaultwarden.md)
- Portable recovery bundle and restore: [docs/technical/ARCHITECTURE.md#control-plane-recovery-bundle](docs/technical/ARCHITECTURE.md#control-plane-recovery-bundle) + [docs/technical/OPERATIONS.md#portable-recovery-bundle-and-restore](docs/technical/OPERATIONS.md#portable-recovery-bundle-and-restore)
- Logging and service observability: [docs/technical/ARCHITECTURE.md#observability-architecture](docs/technical/ARCHITECTURE.md#observability-architecture) + [docs/technical/OPERATIONS.md#service-observability](docs/technical/OPERATIONS.md#service-observability)

## AI-assisted contributions

Repo-wide Copilot workflow and guardrails live in [.github/copilot-instructions.md](.github/copilot-instructions.md).

## Contributing

- Contribution guidelines: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security policy: [SECURITY.md](SECURITY.md)

