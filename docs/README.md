# Privalon

## Documentation Index

Current release: see [../VERSION](../VERSION) (history in [../CHANGELOG.md](../CHANGELOG.md)).

## Product framing

Privalon is a framework for people who want digital sovereignty without accepting the usual self-hosting tradeoff of "the app runs, but the operating layer is fragile."

Running one open-source service is usually the easy part. Running several private services with real restore confidence, sane DNS and TLS, minimal public exposure, observability, alerts, and repeatable operations is the hard part.

The blueprint is meant to make that operating layer reusable: private by default, recoverable by design, and structured so additional services plug into the same model instead of creating new operational chaos.

That includes a lower-friction local web UI path for people who do not want to drive every routine workflow from the terminal, while keeping the underlying Terraform + Ansible model available when direct control is needed.

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
- Self-hosted tailnet control-plane (Headscale) for private access, with Headplane kept tailnet-only
- Embedded DERP relay on the control VM as standard fallback for non-direct client paths
- Private internal workloads (no public IPv4 by default)
- Tailscale-first administration with post-bootstrap public SSH lockdown
- Automated encrypted backups to dual S3-compatible backends
- Portable control-plane recovery with a stable recovery line and continuously refreshed bundle in backup storage
- Built-in observability: Prometheus, Grafana, Loki, health checks, and packaged dashboards
- Post-deploy verification scripts under `scripts/tests/`
- **Local web UI** (`make ui`) — deployment dashboard, live log streaming, and config editor

## Operational expectations

- After Ansible finishes, plan to administer hosts from a tailnet-connected machine.
- ThreeFold “no console” reality: if you lose access, recovery is usually **replace/redeploy**.
- When backup storage is configured, each successful deploy refreshes a portable control-plane recovery bundle in backup storage. The recovery line is designed to be saved offline once and reused for fresh-machine restore, rather than reissued on every normal deploy.
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
- Forgejo first-service spec (service selection + visibility contract): [roadmap/forgejo-first-service-spec.md](roadmap/forgejo-first-service-spec.md)
- Portable recovery bundle and restore: [technical/ARCHITECTURE.md#control-plane-recovery-bundle](technical/ARCHITECTURE.md#control-plane-recovery-bundle) + [technical/OPERATIONS.md#portable-recovery-bundle-and-restore](technical/OPERATIONS.md#portable-recovery-bundle-and-restore)
- DNS routing and service visibility roadmap (remaining work): [roadmap/dns-and-visibility.md](roadmap/dns-and-visibility.md)
- Published delivery milestones: [roadmap/DELIVERY-MILESTONES.md](roadmap/DELIVERY-MILESTONES.md)
- Internal service template + Vaultwarden design spec: [roadmap/service-template-and-vaultwarden.md](roadmap/service-template-and-vaultwarden.md)
- Logging and service observability: [technical/ARCHITECTURE.md#observability-architecture](technical/ARCHITECTURE.md#observability-architecture) + [technical/OPERATIONS.md#service-observability](technical/OPERATIONS.md#service-observability)
- Blueprint improvement roadmap: [roadmap/blueprint-improvement.md](roadmap/blueprint-improvement.md)
- AI-layer roadmap: [roadmap/ai-layer-roadmap.md](roadmap/ai-layer-roadmap.md)
- Web UI — deployment dashboard & config interface: [technical/ARCHITECTURE.md#web-ui](technical/ARCHITECTURE.md#web-ui) + [technical/OPERATIONS.md#web-ui-local-deployment-dashboard](technical/OPERATIONS.md#web-ui-local-deployment-dashboard)

## AI-assisted contributions

Repo-wide Copilot workflow and guardrails: [../.github/copilot-instructions.md](../.github/copilot-instructions.md)

Contributing:
- [../CONTRIBUTING.md](../CONTRIBUTING.md)
- [../SECURITY.md](../SECURITY.md)
