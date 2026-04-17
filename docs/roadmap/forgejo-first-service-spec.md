# Roadmap: Forgejo First-Service Specification

**Historical design spec - April 2026**

This document defines the first-service onboarding model using Forgejo on a separate server, and formalizes how every service should be selected in config with explicit internal/external visibility.

Status note: the first implementation of this spec has shipped. Keep this page as design context and decision history; treat user and technical docs as the source of truth for current behavior.

This is a design document only. Shipped behavior remains documented in the main docs:

- [Architecture](../technical/ARCHITECTURE.md)
- [Operations](../technical/OPERATIONS.md)
- [User Guide](../user/GUIDE.md)

---

## Summary

Deliver two outcomes together:

1. Add Forgejo as the first dedicated application service VM (`forgejo-vm`).
2. Introduce a generic service configuration contract so each service is easy to enable/disable and can be marked as internal-only or externally published.

The service model must stay reproducible, idempotent, and aligned with current DNS/TLS and backup patterns.

---

## Why this spec exists

Current topology supports gateway/control/monitoring and already allows generic workload VMs, but service publishing still relies on a mix of hardcoded behavior and role-specific wiring.

To make future services operationally cheap to add, the blueprint needs one shared contract for:

- service selection (enabled/disabled)
- service visibility (internal vs external)
- service routing and TLS behavior
- service summary and test discovery

Forgejo is the first consumer of that contract.

---

## Goals

- Deploy Forgejo on its own workload VM with no public IPv4.
- Keep Forgejo opt-in by configuration.
- Let operators declare per-service visibility using a single, explicit field.
- Support different service implementation styles under one contract:
  - Docker/containerized services
  - Ansible-managed multi-step application setups
  - plain package/binary installs on the VM
- Reuse existing visibility and TLS architecture:
  - public hostnames terminate on gateway
  - internal hostnames use existing internal TLS paths
- Keep access predictable for users by deriving hostnames from service config.
- Keep implementation generic enough that the next service uses the same pattern.

## Non-goals

- Publicly exposing service VMs directly (no direct public service-node ingress).
- Introducing a second gateway or replacing current network topology.
- Shipping HA Forgejo in phase 1.
- Reworking unrelated core components (Headscale, monitoring internals) beyond integration points.

---

## Decision: service visibility contract

Every service must declare visibility using one field:

- `internal`: reachable only over tailnet/MagicDNS.
- `external`: reachable on public DNS via gateway ingress.
- `both`: published on both internal and external paths.

This field drives routing, DNS, TLS, deployment summary output, and tests.

## Decision: runtime-agnostic service contract

Every service must also declare one runtime profile:

- `docker`: containerized runtime (single or multi-container).
- `ansible`: role-driven app setup with explicit tasks/templates/handlers.
- `plain`: direct VM install (packages, binaries, or systemd units without container orchestration).

Runtime profile controls install/start/health orchestration, but does not change the shared service visibility, DNS, TLS, backup, or observability contract.

---

## Target topology for Forgejo

| Item | Value |
|------|-------|
| Workload key | `forgejo` |
| VM host | `forgejo-vm` |
| Public IPv4 | none |
| App bind | `forgejo-vm` tailscale IP only |
| Default service port | `3000` (HTTP upstream) |
| SSH access | tailnet-only |

Public exposure, when selected, is always through gateway reverse proxy. Forgejo VM itself remains private.

---

## User-facing config model

### 1. Terraform workload remains the service VM switch

If `workloads.forgejo` is present in `terraform.tfvars`, the VM exists.

If absent, Forgejo is not deployed.

### 2. Service registry in environment vars

Add one service catalog map in `environments/<env>/group_vars/all.yml`:

```yaml
service_catalog:
  forgejo:
    enabled: true
    runtime: docker            # docker | ansible | plain
    visibility: internal        # internal | external | both
    internal_alias: git
    external_subdomain: git
    upstream_port: 3000
```

Contract notes:

- `enabled: false` means role/tasks are skipped even if VM exists.
- `runtime` selects how the service lifecycle is executed on the VM.
- `visibility` controls publication behavior.
- `internal_alias` produces `git.<headscale_magic_dns_base_domain>` when internal path is active.
- `external_subdomain` produces `git.<base_domain>` when external path is active.
- `upstream_port` allows role defaults to remain overrideable.

### 2a. Runtime examples for future services

```yaml
service_catalog:
  forgejo:
    enabled: true
    runtime: docker
    visibility: internal
    internal_alias: git
    external_subdomain: git
    upstream_port: 3000

  matrix:
    enabled: true
    runtime: ansible
    visibility: external
    internal_alias: matrix
    external_subdomain: matrix
    upstream_port: 8008

  ntfy:
    enabled: true
    runtime: plain
    visibility: both
    internal_alias: notify
    external_subdomain: notify
    upstream_port: 8080
```

### 3. Visibility behavior

When `visibility: internal`:

- publish only `internal_alias` over internal DNS/TLS path
- do not render external gateway route

When `visibility: external`:

- publish only external gateway route
- do not render internal alias

When `visibility: both`:

- publish both routes
- keep one upstream service target

---

## Integration model (generic, all services)

### 1. Per-role service manifest

Each service role provides `defaults/service_integration.yml`:

```yaml
service_integration:
  service_name: forgejo
  display_name: Forgejo
  host_groups: [forgejo]
  supported_runtime_profiles: [docker, ansible, plain]
  default_upstream_scheme: http
  default_upstream_port: 3000
  default_internal_alias: git
  default_external_subdomain: git
  lifecycle:
    install_role: forgejo
    service_unit: forgejo
    health_endpoint: /api/healthz
  summary:
    category: Source Hosting
    default_path: /
  tests:
    smoke_path: /api/healthz
```

### 2. Compiled service catalog artifact

During Ansible converge, compile service integration manifests plus environment overrides into:

- `environments/<env>/inventory/service-catalog.json`

This single artifact drives:

- internal alias rendering
- gateway public routes
- deployment summary endpoints
- test target discovery

### 3. Existing routing systems remain in use

No replacement of current routing model is required.

- External publication compiles to `gateway_services`-equivalent routes.
- Internal publication compiles to current internal DNS/TLS mechanisms (`internal_service_tls_mode` and `headscale_magic_dns_base_domain`).

### 4. Runtime adapter execution model

Compiled catalog entries are executed through one adapter interface with profile-specific internals.

Required lifecycle stages:

- `install`
- `configure`
- `start_or_restart`
- `verify_local_health`

Runtime adapter behavior:

- `docker`: use container runtime tasks and health checks against exposed app endpoint.
- `ansible`: run role tasks/handlers as the source of truth; verify declared health checks.
- `plain`: install packages/binaries, manage systemd service, verify local endpoint/process.

All adapters must be idempotent and safe to rerun.

---

## Forgejo role expectations

Role: `ansible/roles/forgejo`

Minimum phase-1 behavior:

- install and run Forgejo (containerized)
- bind only on service host tailscale IP
- persist data under `/opt/forgejo/data`
- include secrets via environment file (no hardcoded credentials)
- include observability and backup manifests

Forgejo uses runtime profile `docker` in phase 1, while the platform contract remains compatible with `ansible` and `plain` services.

Recommended defaults:

- disable open registration by default
- require explicit admin bootstrap values in env secrets

---

## DNS and TLS behavior

### Internal path

Uses existing internal TLS mode behavior:

- `internal_service_tls_mode: internal`: private CA path
- `internal_service_tls_mode: namecheap`: gateway tailnet listener wildcard path

Internal Forgejo alias is rendered only when visibility includes internal and `headscale_magic_dns_base_domain` is set.

### External path

Uses existing gateway TLS mode behavior:

- `public_service_tls_mode: letsencrypt`
- `public_service_tls_mode: namecheap`

External Forgejo hostname is rendered only when visibility includes external.

---

## Backup and observability requirements

Forgejo must integrate into existing manifests and pipelines:

- backup manifest with repositories, attachments/LFS, and DB dump strategy
- observability manifest with logs and health probes
- deployment summary entries for active endpoints
- tests for internal/external visibility behavior

No service should be considered complete without all four integrations.

---

## Test strategy (design)

Automated checks to add:

- config validation for `service_catalog.*.runtime` enum
- config validation for `service_catalog.*.visibility` enum
- template tests proving route generation for internal/external/both
- adapter tests proving runtime dispatch for `docker`, `ansible`, and `plain`
- smoke check for Forgejo health endpoint over selected exposure path
- negative check ensuring non-selected path is not published

Manual checks:

- verify browser/API reachability on declared path(s)
- verify non-reachability on undeclared path(s)

---

## Rollout plan

### Phase 1: config contract + catalog compile

- introduce service catalog schema
- compile service-catalog artifact
- wire validators

### Phase 2: routing and summary consumption

- consume compiled catalog in internal and external route generation
- update deployment summary generation
- add routing tests

### Phase 3: Forgejo service role

- add Forgejo role and secrets contract
- add backup/observability manifests
- add Forgejo smoke tests

### Phase 4: docs and stabilization

- update user deployment docs with service selection examples
- update architecture docs with generic visibility contract
- complete regression tests for mixed-service scenarios

---

## Risks and mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Drift between service manifests and runtime config | Wrong routes or missing endpoints | compile one canonical catalog and validate before apply |
| Accidental public exposure | Security posture regression | strict visibility enum + negative tests |
| Runtime-specific drift across services | Deploy fragility and one-off fixes | enforce adapter interface and runtime enum validation |
| Per-service one-off logic creeping back | Maintainability loss | enforce catalog-driven generation in templates/scripts |
| Namecheap wildcard preconditions not met | Delayed TLS readiness | keep current two-pass guidance and explicit deploy warnings |

---

## Acceptance criteria

- Forgejo can be enabled by config without manual code edits.
- Service runtime can be set as `docker`, `ansible`, or `plain` without changing platform wiring.
- Operators can set `internal`, `external`, or `both` per service.
- Non-selected visibility paths are not published.
- Deployment summary reflects selected visibility correctly.
- Backup and observability integration exists for Forgejo.
- Automated tests cover visibility routing and Forgejo smoke checks.

---

## Approval note

Implementing this spec is an architectural extension (new service role + generic service-catalog path). Implementation should proceed only after explicit approval of this design.