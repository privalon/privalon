# Roadmap: Internal Service Template and Vaultwarden

**Planned design spec — April 2026**

This document describes how to add a Bitwarden-compatible password manager to the blueprint as a first-class internal service, and how to turn that work into a reusable template for future tailnet-only services and operator tools.

This is a design document only. Shipped behavior remains documented in the main docs:

- [Architecture](../technical/ARCHITECTURE.md)
- [Operations](../technical/OPERATIONS.md)
- [User Guide](../user/GUIDE.md)

---

## Summary

Add a dedicated small workload VM named `vaultwarden` and run a self-hosted Bitwarden-compatible server on it.

The service must:

- stay reachable only from inside Tailscale / Headscale
- use no public IPv4 and no public ingress
- integrate with the blueprint's existing DNS, internal TLS, backup, log shipping, service-health, deployment-summary, and verification flows
- avoid one-off hardcoding so future internal services can follow the same pattern

The implementation should therefore deliver two things together:

1. a **generic internal-service integration template** for future service VMs
2. a **Vaultwarden role** as the first consumer of that template

---

## Decision

### Chosen server: Vaultwarden

Phase 1 should use **Vaultwarden**, not the official multi-component Bitwarden self-hosted stack.

| Option | Operational fit for this blueprint | Complexity | Small-VM fit | Decision |
|--------|-----------------------------------|------------|--------------|----------|
| Official Bitwarden self-hosted | Heavy stack, larger operational and upgrade surface | High | Poor | Do not use for phase 1 |
| Vaultwarden (Bitwarden-compatible) | Small single-service deployment, already aligned with repo roadmap and backup examples | Low | Good | Use this |

Why this choice fits the blueprint:

- the repo already assumes small, single-purpose VMs
- backup docs already reference Vaultwarden as a target service
- SQLite backup/restore fits the existing Restic model cleanly
- a dedicated small VM keeps blast radius low while remaining cheap to run

If a later requirement specifically needs the official Bitwarden stack, the generic template below should still apply, but that would be a separate higher-cost service profile and should not block Vaultwarden now.

---

## Goals

- Deploy Vaultwarden on its own workload VM with no public IPv4.
- Keep the feature opt-in so environments that do not need a password vault do not pay for another VM.
- Keep all access tailnet-only.
- Integrate the service into MagicDNS and internal HTTPS routing when `headscale_magic_dns_base_domain` is configured.
- Include service data in the existing encrypted dual-backend backup flow.
- Include service logs and service-health checks in the existing observability stack.
- Surface the service in the deployment summary and normal operator guidance.
- Add end-to-end verification coverage under `scripts/tests/`.
- Leave behind a repeatable onboarding pattern for future internal services.

## Non-goals

- Exposing Vaultwarden publicly on the internet.
- HA / clustering / multi-node database design.
- SMTP, push relay, SSO, or enterprise Bitwarden features in phase 1.
- Making Vaultwarden part of the mandatory default topology for every environment.
- Replacing the current gateway/control/monitoring topology.
- Creating a second unrelated TLS trust model for internal services.

---

## Target topology

### New workload VM

| Workload key | Inventory host | Public IP | Default size | Purpose |
|--------------|----------------|-----------|--------------|---------|
| `vaultwarden` | `vaultwarden-vm` | No | 1 vCPU, 2 GiB RAM, 16 GiB rootfs | Bitwarden-compatible password vault |

Sizing should stay intentionally conservative but not fragile. `1 vCPU / 2 GiB / 16 GiB` is still a small VM in this blueprint, while leaving room for:

- Vaultwarden itself
- container runtime overhead
- log shipping and local health checks
- backups and restore verification

### Access model

Primary access paths:

- direct tailnet fallback: `http://<vaultwarden-tailscale-ip>:8080`
- MagicDNS alias when configured: `https://bitwarden.<headscale_magic_dns_base_domain>`

Important distinction:

- the **service/workload/role** name stays `vaultwarden`
- the **operator-facing DNS alias** should default to `bitwarden`

That keeps implementation names aligned with the upstream project while presenting a familiar endpoint to users.

### Enablement model

Vaultwarden should be an **optional service VM**, not an always-on default for every environment.

Expected enablement contract:

- add a `vaultwarden` entry to the environment's Terraform `workloads` map when the service is wanted
- provide `VAULTWARDEN_ADMIN_TOKEN` in `environments/<env>/secrets.env`
- expose service docs, summary output, and tests only when the workload actually exists

If an environment does not define the workload, the blueprint should behave exactly as it does today.

---

## Core design choice: keep one internal TLS model

The blueprint already has two internal service TLS modes:

- `internal`: the monitoring VM's Caddy instance owns the private internal CA and terminates tailnet-only HTTPS
- `namecheap`: the gateway VM owns the wildcard public certificate and terminates tailnet-only HTTPS for internal aliases

Future services should reuse those same proxy tiers instead of introducing one private CA per service VM.

That means Vaultwarden itself should expose only its application port on its own Tailscale address, while the existing proxy tier provides user-facing HTTPS when DNS aliases are enabled.

### Why this matters

- `join-local` and current trust instructions already assume one internal CA flow
- operators should not have to install a different CA for every service VM
- the gateway and monitoring tiers are already the places where hostname-based routing exists
- the hardcoded monitoring-only alias logic needs to become generic anyway

---

## Generic future-service template

The template should standardize how a new internal service enters the blueprint.

Template scope for phase 1:

- first-class support for internal HTTP/HTTPS services
- reusable workload, backup, observability, summary, and test patterns for other operator tools
- raw TCP-only tools can still reuse most of the template, but hostname-based proxy/TLS fields may need a later extension

### 1. Workload convention

Each service VM should use the same identifier in all core places:

- Terraform workload key: `vaultwarden`
- Ansible role name: `vaultwarden`
- backup manifest `service_name`: `vaultwarden`
- observability manifest `service_name`: `vaultwarden`
- inventory hostname: `vaultwarden-vm`

The user-facing DNS alias may differ. For Vaultwarden, that alias should be `bitwarden`.

### 2. New manifest: service integration metadata

Backup and observability are already manifest-driven. DNS, proxy routing, deployment-summary output, and service verification are still partly hardcoded.

Add a new per-role manifest file:

- `ansible/roles/<service>/defaults/service_integration.yml`

Suggested shape:

```yaml
service_integration:
  service_name: vaultwarden
  display_name: Bitwarden-compatible vault
  host_groups: [vaultwarden]
  dns_aliases: [bitwarden]
  proxy:
    enabled: true
    upstream_scheme: http
    upstream_port: 8080
    health_path: /alive
  summary:
    category: Password Vault
    default_path: /
  tests:
    smoke_path: /alive
```

This manifest should become the source of truth for cross-cutting integration that is currently duplicated or hardcoded.

### 3. Compiled service catalog

During Ansible runs, all `service_integration.yml` manifests should be merged into one catalog and persisted into the environment inventory directory, for example:

- `environments/<env>/inventory/service-catalog.json`

That catalog should be consumed by:

- the Headscale DNS reconcile play
- the monitoring Caddy template in `internal` mode
- the gateway Caddy template in `namecheap` mode
- `scripts/helpers/deployment-summary.sh`
- shared test helpers under `scripts/tests/`

This is the key template outcome. Without it, every new service would still require manual edits in multiple unrelated places.

### 4. Inventory grouping for workload roles

Today the inventory gives a special `monitoring` group, but future services need the same behavior.

Required change:

- automatically create one Ansible group per workload key

Example:

- workload `vaultwarden` produces group `vaultwarden` with host `vaultwarden-vm`

This enables role targeting, observability manifests, and tests without additional special cases.

### 5. Generic workload-role execution

Future service roles should not require a brand-new hardcoded play every time.

Preferred design:

- add a generic play for `workloads`
- include the role whose name matches `tf_name` when that role exists and the service is enabled
- leave hosts with no matching service role untouched

That keeps the blueprint extensible while preserving explicit roles for core infrastructure components such as `headscale`, `gateway`, and `monitoring`.

### 6. Backup role filtering must become generic

The current backup role only knows how to map a fixed set of host groups to backup service names.

Required change:

- include discovered backup manifests whose `service_name` matches any current workload group on the host
- keep the existing `control -> headscale`, `gateway -> gateway`, and `monitoring -> monitoring` compatibility mapping

Otherwise a future `vaultwarden` manifest would be discovered but never actually applied on `vaultwarden-vm`.

---

## Vaultwarden service design

### Service defaults

Secure defaults for phase 1:

- `SIGNUPS_ALLOWED=false`
- `ADMIN_TOKEN` sourced from `VAULTWARDEN_ADMIN_TOKEN`
- `WEBSOCKET_ENABLED=true`
- no public registration flow
- no public exposure
- app bound only to the node's Tailscale IP

Optional integrations such as SMTP should stay disabled unless explicitly configured.

### Process model

Run Vaultwarden as a container on `vaultwarden-vm`.

The role should follow the same Docker-on-ThreeFold precautions already used by other containerized roles, including the existing storage-driver handling needed on VirtioFS-backed hosts.

### Network binding

Vaultwarden should bind to:

- `{{ tailscale_ip }}:8080`

It should not bind to `0.0.0.0`.

That keeps the service directly reachable from other tailnet nodes and from the internal proxy tier, while remaining off the public network.

### Data location

Store service data under:

- `/opt/vaultwarden/data`

That keeps the role aligned with the repo's existing backup examples and makes restore behavior predictable.

---

## DNS and internal HTTPS integration

### Current limitation

The existing DNS reconcile and proxy templates are hardcoded around the monitoring aliases:

- `grafana`
- `prometheus`
- `backrest`

Vaultwarden should not be bolted on as one more special case.

### Required design

When `headscale_magic_dns_base_domain` is configured, the service catalog should drive alias generation.

#### In `internal_service_tls_mode: internal`

- Headscale DNS should resolve `bitwarden.<magic_dns_base>` to the **monitoring VM Tailscale IP**
- monitoring Caddy should reverse proxy that hostname to `http://<vaultwarden-tailscale-ip>:8080`
- the same monitoring Caddy private CA continues to be the trust anchor for all internal aliases

#### In `internal_service_tls_mode: namecheap`

- Headscale DNS should resolve `bitwarden.<magic_dns_base>` to the **gateway VM Tailscale IP**
- gateway Caddy should terminate wildcard TLS and reverse proxy that hostname to `http://<vaultwarden-tailscale-ip>:8080`

#### When no MagicDNS base is configured

- deployment summary and tests should fall back to direct Tailscale IP access
- no hostname-based TLS path is required

This preserves the current TLS model while making the alias list data-driven.

---

## Backup and restore integration

Vaultwarden is a high-value, low-size service. It should use a more frequent backup cadence than the default daily baseline.

### Backup manifest

Role file:

- `ansible/roles/vaultwarden/defaults/backup.yml`

Proposed manifest:

```yaml
backup:
  service_name: vaultwarden
  targets:
    - name: data
      type: directory
      path: /opt/vaultwarden/data
      description: Vaultwarden SQLite database and attachments
  pre_backup:
    - name: sqlite-backup
      command: "sqlite3 /opt/vaultwarden/data/db.sqlite3 '.backup /opt/vaultwarden/data/db-backup.sqlite3'"
      description: Create a consistent SQLite backup copy
  post_backup:
    - name: cleanup-dump
      command: "rm -f /opt/vaultwarden/data/db-backup.sqlite3"
  schedule_cron:
    minute: '17'
    hour: '*'
  retention:
    keep_hourly: 24
    keep_daily: 30
    keep_weekly: 12
    keep_monthly: 24
  restore_verify:
    command: "curl -fsS http://127.0.0.1:8080/alive"
    description: Verify Vaultwarden responds after restore
    timeout: 30
```

### Restore expectations

- fresh deploys should auto-restore Vaultwarden data when backup state exists and service data is empty
- restore verification should check the app's `/alive` endpoint locally on the VM
- the deployment summary should include enough information to confirm the service repo exists and is healthy

---

## Logs and monitoring integration

Vaultwarden should use the same generic observability model as existing services.

### Observability manifest

Role file:

- `ansible/roles/vaultwarden/defaults/observability.yml`

Proposed minimum coverage:

```yaml
observability:
  services:
    - service_name: vaultwarden
      role_label: vaultwarden
      host_groups: [vaultwarden]
      logs:
        docker_containers: [vaultwarden]
        files: []
        journald_units: []
      health_checks:
        local:
          - name: container-running
            type: docker
            container: vaultwarden
          - name: alive-local
            type: command
            command: curl -fsS http://127.0.0.1:8080/alive >/dev/null 2>&1
        remote:
          - name: alive-tailnet
            type: http
            target: tailscale_self
            port: 8080
            path: /alive
            expected_status: 200
```

### Observability expectations

- logs should flow to Loki under the normal per-service labels
- service-health signals should appear in the existing Service Health dashboard
- the generic Logs Overview dashboard should show Vaultwarden errors if the container starts failing
- no dedicated dashboard is required for phase 1 unless the generic views prove insufficient

### Logging sensitivity

Observability must remain operationally useful without becoming a vault-data leak path.

Default logging posture:

- collect container stderr/stdout only
- do not add verbose access-log harvesting unless it is needed and reviewed
- never log secrets such as admin tokens from templates or summaries

---

## Security requirements

Vaultwarden must respect the blueprint's existing security model.

Required controls:

- no public IPv4 on the service VM
- SSH only over the tailnet after bootstrap
- application bound only to the Tailscale interface
- secure default config with signups disabled
- admin access protected by a dedicated secret, not by the shared service password
- backup encryption remains the existing Restic boundary; the service does not invent a separate backup system

Security notes:

- `VAULTWARDEN_ADMIN_TOKEN` belongs in `environments/<env>/secrets.env`
- this service should not reuse `SERVICES_ADMIN_PASSWORD` for privileged admin access
- if SMTP or push-relay support is added later, those secrets stay optional and separate

---

## Deployment summary and operator UX

The deployment summary should gain a Password Vault section when the service is present.

Expected fields:

- service name: Bitwarden-compatible vault
- host: `vaultwarden-vm`
- tailnet IP
- direct URL: `http://<tailscale-ip>:8080`
- MagicDNS URL when configured: `https://bitwarden.<magic_dns_base>`
- access note: tailnet-only
- backup note when `backup_enabled=true`

This summary output should be driven from the compiled service catalog plus live host facts, not by another hardcoded block.

---

## Verification plan

Add a new end-to-end verification script, for example:

- `scripts/tests/66_verify_vaultwarden.sh`

Minimum checks:

1. `vaultwarden-vm` exists in Terraform outputs and inventory.
2. The Vaultwarden container is running on the service VM.
3. `http://<vaultwarden-tailscale-ip>:8080/alive` returns success.
4. When MagicDNS is configured:
   - `bitwarden.<magic_dns_base>` resolves inside the tailnet
   - HTTPS responds through the configured proxy tier
5. When `backup_enabled=true`:
   - the backup manifest is deployed on `vaultwarden-vm`
   - backup health/metrics show the service repo
6. Observability confirms:
   - a local service-health metric exists for `vaultwarden`
   - a remote probe target exists for `vaultwarden`
   - container logs are queryable through Loki/Grafana labels

The normal suite runner should include this test in the appropriate profile once the role is implemented.

---

## Implementation touchpoints

Expected code areas for the eventual implementation:

| Area | Likely files |
|------|--------------|
| Terraform workload docs/examples | `terraform/terraform.tfvars.example`, `environments/example/terraform.tfvars.example` |
| Secret docs/examples | `environments/example/secrets.env.example` |
| Inventory grouping | `ansible/inventory/tfgrid.py` |
| Generic workload-role execution | `ansible/playbooks/site.yml` |
| Service catalog generation | `ansible/playbooks/site.yml` plus new role defaults manifests |
| Internal proxy routing | `ansible/roles/monitoring/templates/monitoring-Caddyfile.j2`, `ansible/roles/gateway/templates/Caddyfile.j2` |
| Vaultwarden role | `ansible/roles/vaultwarden/**` |
| Backup generic filter | `ansible/roles/backup/tasks/deploy.yml` |
| Summary output | `scripts/helpers/deployment-summary.sh` |
| Verification | `scripts/tests/common.sh`, new `scripts/tests/66_verify_vaultwarden.sh`, `scripts/tests/run.sh` |
| User-facing docs | `README.md`, `docs/README.md`, `docs/user/GUIDE.md`, `docs/technical/OPERATIONS.md`, `docs/technical/ARCHITECTURE.md` |

---

## Acceptance criteria

This roadmap item is complete when all of the following are true:

- Vaultwarden runs on a dedicated small VM with no public ingress.
- The service is reachable from tailnet-connected clients and not from the public internet.
- MagicDNS plus internal HTTPS works when the environment enables it.
- Backup, restore verification, logs, service-health, and deployment-summary output include the service.
- The new service did not require adding another one-off hardcoded alias block.
- A second future service can follow the same onboarding pattern using the same manifest and role conventions.

---

## Template checklist for future services

When adding the next internal service/tool, the expected checklist should be:

1. Add a workload entry in Terraform using the service name as the workload key.
2. Add an Ansible role with the same name.
3. Add `defaults/main.yml` for service variables and secrets.
4. Add `defaults/backup.yml` if the service owns durable data.
5. Add `defaults/observability.yml` for logs and health checks.
6. Add `defaults/service_integration.yml` for DNS, proxy routing, summary, and tests.
7. Ensure the application binds only to the Tailscale interface.
8. Add one verification script under `scripts/tests/`.
9. Update main docs only after the feature is implemented and tested.

Vaultwarden should be the first implementation that proves this template works.