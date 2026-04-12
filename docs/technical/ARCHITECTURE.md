# Architecture: Personal / SMB Multi-VM Deployment with Headscale

This is **technical** documentation (architecture and design decisions).

For “how to deploy and use”, see:
- Docs index: [../README.md](../README.md)
- Main guide: [../user/GUIDE.md](../user/GUIDE.md)

## Overview

This architecture provides:

* One public gateway for web services (80/443)
* Private internal network using Headscale + Tailscale
* Standard DERP relay fallback on the control VM for private-only nodes and hard NAT cases
* No public IPs on workload VMs (default packaged workload: monitoring VM)
* Centralized observability via Prometheus, Grafana, Loki, and Grafana Alloy on the monitoring VM
* Centralized access control via ACLs
* Optional full-tunnel VPN (Exit Node) for public Wi-Fi protection
* Portable across ThreeFold and other clouds
* Minimal per-VM firewall management

---

# High-Level Diagram

```
                 Internet
                     |
             ┌────────────────┐
             │   Gateway VM   │
             │  Public IPv4   │
             │ Reverse Proxy  │
             │  Exit Node     │
             └────────────────┘
                     |
     ┌───────────────┴───────────────┐
     │                               │
┌────────────────┐            ┌────────────────┐
│ Monitoring VM  │            │  Headscale VM  │
│ Prom + Grafana │            │  Control Plane │
│ Internal only  │            │  Public 443    │
└────────────────┘            └────────────────┘
               \                 /
                \   Tailscale   /
                 └──────┬──────┘
                        |
         Mac / Android / Other Devices
```

---

# Components

## 1. Gateway VM

**Purpose:**
Public entry point for all web traffic and VPN exit node.

**Public Exposure:**

* TCP 80
* TCP 443

**Services:**

* Reverse proxy (Caddy recommended)
* TLS (Let’s Encrypt)
* Tailscale client
* Advertised as Tailscale exit node, with Headscale approval for `0.0.0.0/0` and `::/0` applied during converge

**Responsibilities:**

* Route public domains to internal services via Tailscale IPs
* Provide full-tunnel VPN option when users enable exit node
* No public SSH access

**Security:**

* SSH accessible only via Tailscale interface
* Host firewall default deny inbound except 80/443 + Tailscale
* IP forwarding enabled (for exit node)
* IPv4 and IPv6 forwarding enabled for exit-node traffic
* Headscale ACL grants `autogroup:internet:*` to managed clients that should use the exit node
* NAT/MASQUERADE configured for outbound VPN traffic, with explicit routed-firewall allowance from `tailscale0` to the public interface

---

## 2. Headscale Control VM

**Purpose:**
Private network control plane for Tailscale clients.

**Public Exposure:**

* TCP 443 (Headscale API + coordination)
* UDP 3478 (DERP STUN)
* DERP relay over TCP 443 at `/derp`

**Services:**

* Headscale
* Embedded DERP relay
* Headplane admin UI on a tailnet-only listener (`control-vm` port `3000`)
* Tailscale client (optional but recommended)

**Responsibilities:**

* Register devices
* Distribute WireGuard keys
* Enforce ACL policy
* Maintain device identity

**Notes:**

* Not in data path
* If temporarily down, existing tunnels continue working
* Back up database + keys

---

## 3. Workload VMs (Default: Monitoring)

**Public Exposure:**

* None

**Network:**

* Tailscale only
* No public IPv4
* Mycelium optional but not relied upon

**Services:**

* Bind to Tailscale interface IP only (100.x.y.z)
* Never bind to 0.0.0.0
* Default packaged stack: Prometheus + Grafana + Loki + Blackbox exporter on the monitoring VM
* Every managed node also runs Grafana Alloy for centralized log shipping and local service-health collection

**Security:**

* SSH allowed only via Tailscale
* Host firewall baseline applied
* No public listening services

---

# Observability Architecture

The blueprint now ships a single private observability stack for infrastructure health,
service health, and centralized logs.

## Control points

### Monitoring VM

The monitoring VM runs the central backend components:

* Grafana for dashboards and log access
* Prometheus for metrics, rule evaluation, and service-health queries
* Loki for centralized log storage
* Blackbox exporter for remote HTTP and TCP probes

All of these stay tailnet-only by default.

### Every managed VM

Each managed VM contributes three observability surfaces:

* `node_exporter` on the node's Tailscale IP for VM metrics
* Grafana Alloy for shipping declared logs to Loki and exposing agent metrics
* A local service-health runner that writes `blueprint_service_health` metrics into the node_exporter textfile collector

## Data flow

### Logs

```text
Declared container logs / declared files
    -> Grafana Alloy on each node
    -> Loki on the monitoring VM
    -> Grafana Explore / Logs Overview dashboard
```

### Service health

```text
Local command/docker checks on each node
    -> node_exporter textfile collector
    -> Prometheus
    -> Grafana Service Health dashboard / alerts

Remote HTTP/TCP probes from monitoring VM
    -> Blackbox exporter
    -> Prometheus
    -> Grafana Service Health dashboard / alerts
```

This keeps the model small:

* one central backend VM
* one per-node log and local-health agent path
* one UI for operators

## Observability manifest contract

Service roles declare their observability wiring through `defaults/observability.yml`.
The shared `observability` role consumes those manifests on each node, while the
`monitoring` role reads the same catalog to build Prometheus probe targets.

Current manifest shape:

```yaml
observability:
  services:
    - service_name: grafana
      role_label: monitoring
      host_groups: [monitoring]
      enabled_var: ""
      logs:
        docker_containers: [grafana]
        files: []
        journald_units: []
      health_checks:
        local:
          - name: container-running
            type: docker
            container: grafana
        remote:
          - name: http-ready
            type: http
            target: tailscale_self
            port: 3000
            path: /api/health
```

Current support is intentionally narrow:

* log sources consumed today: `docker_containers`, `files`
* local check types consumed today: `command`, `docker`
* remote probe types consumed today: `http`, `tcp`

The `journald_units` field is reserved in the manifest schema but is not yet consumed by Alloy.

## Built-in service coverage

Privalon already wires observability for these shipped services:

* gateway: `caddy`
* control plane: `headscale`, `headplane` when enabled, `caddy`
* monitoring: `grafana`, `prometheus`, `loki`, `blackbox-exporter`, `backrest` when backups are enabled
* backup workflow: `/var/log/backup-*.log`, `/var/log/backup-summary.log`, `/var/log/backup-drill.log`

Default exclusions remain deliberate:

* `tailscaled` is not treated as a first-class monitored service
* generic host log sweeps such as `/var/log/*.log` are not collected
* direct Loki exposure is not part of the access model; operators go through Grafana

## Labels and retention

Log and service-health data use a small shared label set:

* `env`
* `node`
* `role`
* `service`
* `source` for logs
* `check` and `scope` for service-health metrics

Default retention behavior:

* Loki searchable retention: `30d`
* archive retention: `90d` total when S3-compatible backup storage is configured
* cleanup: automatic compaction-based retention in Loki plus archive object deletion by the monitoring VM's export job

The relevant knobs live in `ansible/group_vars/all/main.yml` and can be overridden per environment:

* `logging_enabled`
* `logging_loki_retention_days`
* `logging_archive_enabled`
* `logging_archive_retention_days`
* `logging_archive_prefix`
* `service_observability_enabled`
* `service_health_checks_enabled`
* `service_log_collection_enabled`

---

# Networking Model

## Internal Network = Tailscale

All VMs and user devices join a private tailnet controlled by Headscale.

Traffic characteristics:

* End-to-end encrypted (WireGuard)
* Identity-based access control
* Direct peer-to-peer when possible
* DERP relay fallback is part of the standard deployment, not an optional extra

Mycelium may be enabled on ThreeFold nodes for underlying connectivity but is not used for security decisions.

---

# Traffic Flows

## Public Web Traffic

```
Internet → Gateway (443) → Tailscale IP of workload service
```

Gateway routes by domain (SNI) to backend Tailscale addresses.
In the default packaged topology, monitoring services are consumed over Tailscale rather than exposed publicly.

---

## Admin Access

```
Laptop → Tailscale → Internal VM
```

Humans can SSH directly over Tailscale; automation may also use the gateway as an SSH jump host to reach private VM addresses.
No public SSH.

---

## Full-Tunnel VPN (Optional)

```
Laptop → Tailscale → Gateway (Exit Node) → Internet
```

Used for public Wi-Fi protection.

Operational detail: the gateway advertises the exit-node default routes with Tailscale,
and the control plane converge also approves those routes in Headscale so clients can
select the gateway immediately without a separate manual route-approval step.

---

# DNS and Service Visibility

## Two-namespace model

This blueprint assigns names to services through two independent mechanisms that serve
different purposes and must not be confused:

| Namespace | Technology | Resolves for | Used for |
|-----------|-----------|-------------|----------|
| **Public DNS** | Authoritative DNS (any registrar) | Everyone on the internet | Services that accept unauthenticated public traffic |
| **Tailscale MagicDNS** | Headscale coordination protocol | Tailscale-connected devices only | Admin UIs, monitoring, and private services |

**Decision rule:** if a non-Tailscale device — a browser, a mobile app, a third-party
integration — needs to reach a service, use public DNS. Everything else belongs on
MagicDNS.

---

## Public DNS

Two infrastructure IPs require public DNS records:

| IP | Records pointing here | Purpose |
|----|-----------------------|---------|
| Control VM public IPv4 | `headscale.yourdomain.com` | Headscale coordination + DERP relay |
| Gateway VM public IPv4 | `app.yourdomain.com`, `matrix.yourdomain.com`, … | All public-facing user services |

**All public app subdomains point to the gateway — one IP for all services.** The gateway
Caddy instance distinguishes services by hostname (SNI) and routes to the correct backend VM
over the Tailscale overlay. Adding a new public service requires one new DNS A record and one
entry in the gateway config — no new IP to look up, no new firewall rule.

**IP volatility on ThreeFold:** ThreeFold assigns public IPv4 addresses dynamically. Every
full destroy-and-recreate cycle produces a new control IP and a new gateway IP. DNS A records
must be updated before Ansible runs (Let's Encrypt HTTP-01 requires DNS to already resolve to
the correct IP). On providers with reserved or floating IPs (Hetzner cloud IPs, DigitalOcean
floating IPs), this is a one-time setup.

---

## Tailscale MagicDNS (private names)

When MagicDNS is enabled in Headscale, every tailnet device receives a stable private hostname
in addition to its raw Tailscale IP:

```
<vm-hostname>.<base_domain>
```

The default convention is `in.yourdomain.com` as the MagicDNS base domain (configurable via
`headscale_magic_dns_base_domain`). Example with `base_domain = in.yourdomain.com`:

| Service | MagicDNS name | Port | Access |
|---------|--------------|------|--------|
| Grafana | `grafana.in.yourdomain.com` | 443 | Tailscale-connected devices only |
| Prometheus | `prometheus.in.yourdomain.com` | 443 | Tailscale-connected devices only |
| Any future VM | `<service>-vm.in.yourdomain.com` | — | Joins tailnet → immediately resolvable |

**Private services are still accessed over the WireGuard tunnel**, but this blueprint now has
two HTTPS modes for the packaged monitoring aliases:

- `internal_service_tls_mode: internal` — the monitoring VM serves `grafana.*` /
  `prometheus.*` / `backrest.*` directly with Caddy's private CA.
- `internal_service_tls_mode: namecheap` — the gateway VM serves those aliases on its
  Tailscale IP using a wildcard public certificate for `*.headscale_magic_dns_base_domain`
  obtained through Namecheap DNS-01, then reverse proxies back to the monitoring VM.
  Because Namecheap requires source IP allowlisting for API calls, the first wildcard
  activation is effectively a two-pass operator flow: let the initial deploy finish,
  whitelist the current gateway public IP in Namecheap, then run
  `./scripts/deploy.sh gateway --env <env>` once so the gateway can complete the first
  issuance. Other TLS modes/providers remain one-pass flows.

**Current browser-ingress split:** public browser traffic terminates on the gateway public
listener, while `internal_service_tls_mode: namecheap` moves the packaged internal monitoring
aliases to the gateway Tailscale listener. Direct machine access stays on canonical `-vm`
MagicDNS names such as `monitoring-vm.in.<domain>`. Headscale remains a deliberate exception:
it keeps its own exact-host certificate on the control VM, while Headplane now stays tailnet-only
on the control node instead of riding on that public hostname.

In Namecheap wildcard mode, the gateway is also the only VM that needs DNS-01 automation
credentials. Backend monitoring services do not perform their own ACME or Namecheap API calls.

Public gateway ingress now also supports one upstream per service via `gateway_services`.
Each entry derives `<name>.<base_domain>` and can point at a different backend VM and port.
Public TLS on the gateway has two modes:

- `public_service_tls_mode: letsencrypt` keeps the default per-host ACME flow.
- `public_service_tls_mode: namecheap` uses a wildcard certificate for `*.base_domain`
  on the gateway via the same Namecheap DNS-01 integration.

The monitoring stack also uses these hostnames for Grafana node legends and filters when
`headscale_magic_dns_base_domain` is set, so operators see `gateway-vm.<domain>` style names
instead of raw scrape targets.

Service aliases stay clean (`grafana.in.<domain>`, `prometheus.in.<domain>`), while direct
machine access always keeps the `-vm` suffix (`gateway-vm.in.<domain>`, `myapp-vm.in.<domain>`).

**MagicDNS is optional.** Without it, private services remain reachable at `http://100.64.x.y:<port>`.
MagicDNS adds ergonomic hostnames but does not change the security posture.

The `base_domain` must be a (sub)domain you control, but no public DNS records need to be
published for it. Headscale distributes MagicDNS names to clients via the coordination
protocol — they never appear in public DNS.

---

## Deploy sequence when IPs change

On ThreeFold (dynamic IPs), the required order after `terraform apply` produces new IPs is:

```
1. terraform apply               → new IPs assigned
         │
2. Update DNS A records          → headscale.* → control IP; service.* → gateway IP
         │
3. Wait for propagation          → Let's Encrypt HTTP-01 requires live DNS resolution
         │
4. ansible: control group        → Caddy issues headscale.* cert ✓
         │
5. join-local                    → workstation joins tailnet via new Headscale
         │
6. ansible: all                  → gateway Caddy issues certs for all public services ✓
```

DNS update (step 2) must happen before Ansible (step 4). If Caddy cannot resolve the domain
during the HTTP-01 ACME challenge, it cannot issue a certificate. The deploy still converges,
but with `tls internal` fallback until DNS is corrected.

If `public_service_tls_mode: namecheap` is enabled, the public gateway certificate no longer
depends on HTTP-01 reachability for each hostname. The initial wildcard issuance still depends
on the gateway public IP being allowlisted in Namecheap before the follow-up gateway converge.

---

## Configuration summary

| Variable | File | Controls |
|----------|------|----------|
| `headscale_url` | `environments/<env>/group_vars/all.yml` | Full URL Tailscale clients use to join; must match the TLS cert |
| `headscale_tls_mode` | `environments/<env>/group_vars/all.yml` | `internal` (Caddy self-signed) or `letsencrypt` |
| `headscale_acme_email` | `environments/<env>/group_vars/all.yml` | Email for Let's Encrypt registration |
| `headscale_magic_dns_base_domain` | `environments/<env>/group_vars/all.yml` | Base domain for MagicDNS (default: `in.<domain>`); empty string disables |
| `public_service_tls_mode` | `environments/<env>/group_vars/all.yml` | `letsencrypt` (per-host ACME) or `namecheap` (gateway wildcard DNS-01 for `*.base_domain`) |
| `internal_service_tls_mode` | `environments/<env>/group_vars/all.yml` | `internal` (private CA on monitoring VM) or `namecheap` (gateway wildcard DNS-01) |
| `gateway_services` | `environments/<env>/group_vars/gateway.yml` | Preferred list of public services; each item defines `name`, `upstream_host`, `upstream_port` |
| `gateway_domains` | `environments/<env>/group_vars/gateway.yml` | Legacy list of public domains sharing one upstream |
| `gateway_upstream_host` | `environments/<env>/group_vars/gateway.yml` | Legacy single upstream backend hostname |
| `gateway_upstream_port` | `environments/<env>/group_vars/gateway.yml` | Legacy single upstream backend port |

---

## What stays private (never a public DNS record)

| Service | Private access path | Notes |
|---------|--------------------|---------|
| Grafana | `https://grafana.in.yourdomain.com` | Ops-only; resolves only inside the tailnet |
| Prometheus | `https://prometheus.in.yourdomain.com` | Internal metrics store |
| SSH (all VMs) | `ssh root@<tailscale-ip>` | Always tailnet-only; no exception |
| Headplane UI | `http://control-vm.in.yourdomain.com:3000` | Tailnet-only admin surface on the control node |

---

# Firewall Baseline (All VMs)

Default policy: DROP inbound.

Allow:

* Established/related connections
* Loopback
* Tailscale interface
* 80/443 on Gateway only
* 443 on Headscale only

Disable:

* Password SSH
* Public SSH
* IP forwarding (except gateway)

This is deployed via Ansible role.

---

# Headscale ACL Model

Central ACL file (version controlled):

Example policy structure:

* group:admins
* tag:servers
* tag:db (optional future workload)
* tag:backup (optional future workload)

Allow:

* tailnet members → servers (SSH + monitoring ports)
* servers → optional db (DB port)
* servers → optional backup (backup port)

Default: deny.

---

# Terraform Responsibilities

Provision:

* gateway VM (public IPv4 enabled)
* control VM (public IPv4 enabled)
* workload VMs (no public IPv4)

Output:

* Public IPs
* Instance metadata
* Inventory for Ansible

---

# Ansible Responsibilities

## Common Role

* User creation
* SSH hardening
* Firewall baseline
* Package updates

## Tailscale Role

* Install Tailscale
* Configure login server (Headscale URL)
* Join tailnet
* Advertise tags
* Configure exit node on gateway

## Headscale Role

* Install Headscale
* Configure TLS
* Deploy ACL file
* Configure DERP

## Gateway Role

* Install reverse proxy
* Deploy domain routing config
* Enable IP forwarding + NAT

---

# Backup Requirements

The blueprint uses Restic with dual S3-compatible backends for encrypted, deduplicated backups. See [BACKUP.md](BACKUP.md) for the full specification.

Key host paths backed up per VM:

| VM | Paths |
|-----|-------|
| Control | `/opt/headscale/data/`, `/opt/headscale/config/`, `/opt/headplane/`, `/opt/caddy/data/` |
| Gateway | `/opt/caddy/data/`, `/opt/caddy/config/` |
| All VMs | `/var/lib/tailscale` (per-host repo) |

Store the Restic master password and S3 credentials offline; see the Owner Recovery Card template in [BACKUP.md](BACKUP.md#12-owner-recovery-card).

## Control-Plane Recovery Bundle

Service-data backups and operator workspace recovery are intentionally separate concerns in this blueprint.

- Service backups continue to use Restic repositories under the normal per-service S3 layout.
- Control-plane recovery uses a dedicated encrypted bundle stored under a separate `control-recovery/<env>/...` object path.
- The bundle contains the environment files and local Terraform-related state needed to reconstruct the operator workspace on another machine.
- The bundle metadata includes both the repo version and the environment `data_model_version`, so restore can migrate older environment layouts forward before the next deploy.
- Each successful deploy refreshes a lightweight `latest.json` pointer so restore can fetch the newest bundle without scanning object history.

The data-model migration layer is intentionally limited to blueprint-managed environment files under `environments/<env>/`. It is not a generic migration system for service-internal databases or application storage formats.

The printed recovery line is wrong-eye fool-protection, not a standalone cryptographic trust anchor. The line only helps the restore script locate and unlock the bundle; confidentiality still depends on the encrypted bundle stored in backup storage.

---

# Portability

This architecture:

* Works on ThreeFold
* Works on AWS / Hetzner / DigitalOcean
* Allows mixing nodes across providers
* Does not depend on Mycelium
* Requires only outbound internet access to join tailnet

---

# Operational Characteristics

* If gateway fails → web + exit node down, internal network intact.
* If headscale fails → new joins blocked, existing tunnels continue.
* If workload VM fails → no impact to control plane.
* Replacement (destroy + recreate) requires only restoring configs + headscale DB.

---

# Multi-Environment Model

## Problem

A single repo clone with a single Terraform state supports only one live deployment.
Running a second deployment (test, family, client) from the same directory would
overwrite the state, conflict on TFGrid resource names, and share Ansible secrets.

## Solution: named environment directories

Each deployment is a named **environment** under `environments/<name>/`. The blueprint code
(`terraform/*.tf`, `ansible/roles/`, `scripts/`) is shared; the environment directory holds
all the config and state specific to that deployment.

```
environments/
  prod/
    terraform.tfvars          ← TFGrid credentials, VM sizes, node IDs
    .data-model-version       ← current environment schema version
    terraform.tfstate         ← Terraform state (gitignored)
    .terraform/               ← provider cache (gitignored)
    group_vars/
      all.yml                 ← headscale_url, TLS mode, domain, passwords
      gateway.yml             ← public service routing
    inventory/                ← runtime outputs (gitignored)
      terraform-outputs.json
      tailscale-ips.json
      headscale-authkeys.json
      headscale-root-ca.crt
  test/
    … same structure …
  family/
    … same structure …
```

## Isolation guarantees

| What | How isolated |
|------|--------------|
| Terraform state | `environments/<env>/terraform.tfstate` — separate file per env |
| Environment schema version | `environments/<env>/.data-model-version` — one file per env |
| Terraform provider cache | `environments/<env>/.terraform/` via `TF_DATA_DIR` |
| Terraform variables | `environments/<env>/terraform.tfvars` — env-specific `name`, node IDs |
| TFGrid resource names | `name` variable in tfvars must be unique per env (TFGrid enforces this) |
| DNS subdomains | Configured per env in `group_vars/all.yml` (`headscale_url`) |
| Tailscale tailnet | Each env’s Headscale is an independent tailnet; IP spaces do not conflict |
| Runtime inventory | `environments/<env>/inventory/` — separate per env |

## What is shared (intentional)

All blueprint logic: `ansible/roles/`, `terraform/*.tf`, `scripts/`. Updates to the blueprint
(bug fixes, new roles) apply to all environments from a single `git pull`.

## Deploy command

```bash
./scripts/deploy.sh full --env prod
./scripts/deploy.sh full --env test --join-local
```

`--env <name>` is required. `deploy.sh` exits early if the environment directory or
`environments/<name>/terraform.tfvars` is missing.

## Packaged environments

The repo ships two environment scaffolds:

| Environment | TFGrid network | TLS mode | Purpose |
|-------------|---------------|----------|---------|
| `prod` | `main` | `letsencrypt` | Production deployment with real domain |
| `test` | `test` | `internal` | Testing and blueprint development; no real domain required |

Add more environments by copying the `environments/prod/` or `environments/test/` structure.

## See also

- [Operations — Working with Environments](../technical/OPERATIONS.md#working-with-environments)
- [User Guide](../user/GUIDE.md)

---

# Web UI

## Overview

A locally-hosted web application (`ui/`) that wraps `deploy.sh` and the config files with a browser-based interface. The UI runs on the **operator's workstation** — never on a deployed VM.

```
make ui-install    # install Python dependencies
make ui            # start on http://localhost:8090
```

## Architecture

```
Browser ─── HTTP/SSE ───► FastAPI (ui/server.py)
                                │
                    ┌───────────┴────────────┐
                    │                        │
              job_runner.py          config_reader.py
              (subprocess +          (terraform.tfvars,
               SSE streaming)         secrets.env,
                    │                 group_vars YAML)
                    │
            asyncio subprocess
                    │
            scripts/deploy.sh
```

| Layer | Technology | Role |
|-------|-----------|------|
| Backend | FastAPI + asyncio | Routes, SSE endpoint, subprocess management |
| Real-time streaming | Server-Sent Events with `Last-Event-ID` replay | Live log delivery, survives tab close/reopen; server emits structured section events so repeated/reordered Ansible plays remain distinct |
| Frontend | htmx navigation + vanilla JS `EventSource` | Log panes, ANSI rendering, phase detection |
| Job persistence | Per-job `.log` + `.json` under `environments/<env>/.ui-logs/` | Survives browser and server restarts |
| Config I/O | PyYAML + python-dotenv + python-hcl2 | Read/write `terraform.tfvars`, `secrets.env`, `group_vars` YAML |

## Security properties

- **Local only** — binds to `0.0.0.0:8090` on the workstation; no remote access by design.
- **No auth layer** — single-user local tool; not exposed outside the workstation.
- **Write-only secrets** — secret values (mnemonic, passwords, API keys) are written to `secrets.env` directly but never returned to the browser. The UI exposes only a boolean presence flag (`saved` / `not set`).
- **No credential storage** — the server holds no secrets in memory between requests. All credential writes go directly to the file via `python-dotenv set_key`.
- **Deploy.sh unchanged** — the UI is a wrapper; all deployment logic stays in `deploy.sh`.

## Job lifecycle and SSE replay

Each `deploy.sh` invocation is assigned a **job ID** (e.g. `test-20260319-152654`). Output is fanned to two sinks simultaneously:

1. An append-only log file: `environments/<env>/.ui-logs/<job-id>.log`
2. An in-memory line buffer (capped at 1000 lines) + per-subscriber `asyncio.Queue` for live tailing

The SSE endpoint at `GET /jobs/{job_id}/stream` honours the `Last-Event-ID` header, which the browser sends automatically on reconnect. On reconnect the server seeks to the requested line in the log file, reconstructs the structured section stream (`section-start`, `line`, `section-end`), then switches to live tailing. If the process has already finished, the full log is replayed from disk and a final `event: done` is sent.

The HTML shell is served with `Cache-Control: no-store`, and static asset URLs are
versioned from the repo `VERSION` file (`/static/app.js?v=<version>`). That keeps
browser caches from pinning an older UI after a release.

## Repo layout

```
ui/
  server.py              FastAPI app — routes, SSE endpoint
  requirements.txt       fastapi, uvicorn, pyyaml, python-dotenv, python-hcl2
  static/
    index.html           SPA shell (no build step)
    app.js               EventSource log panes, ANSI parser, phase detection
    style.css            Dark theme
  lib/
    job_runner.py        Subprocess launch, output fan-out, job registry
    config_reader.py     Read/write terraform.tfvars, secrets.env, group_vars YAML
    log_sections.py      Parse deploy.sh output into named sections for collapsible log panes
    job_cli.py           CLI bridge used by deploy.sh to register terminal runs in the UI history
  README.md              Usage and architecture reference
```

---

# Security Model Summary

Layer 1: Public exposure limited to gateway (80/443).
Layer 2: Private tailnet for all internal services.
Layer 3: Identity-based ACL enforcement.
Layer 4: Host firewall baseline.
Layer 5: Optional encrypted full-tunnel VPN.

---

# Design Philosophy

* Simple perimeter
* Minimal moving parts
* Centralized policy
* No public SSH
* Easy recovery
* Portable across infrastructure providers
* Appropriate for personal / SMB deployments
