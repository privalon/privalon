# Backup Architecture

March 2026 · v1.5

**Status**: Implemented and verified

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Decisions](#2-architecture-decisions)
3. [System Design](#3-system-design)
4. [Modular Service Integration](#4-modular-service-integration)
5. [Multi-Environment Isolation](#5-multi-environment-isolation)
6. [Scheduling & Retention](#6-scheduling--retention)
7. [Auto-Restore on Deploy](#7-auto-restore-on-deploy)
8. [Notification & Alerting](#8-notification--alerting)
9. [Monitoring UI](#9-monitoring-ui)
10. [Restore Drills](#10-restore-drills)
11. [Backup Configuration](#11-backup-configuration)
12. [Owner Recovery Card](#12-owner-recovery-card)
13. [Data Type Reference](#13-data-type-reference)
14. [Implementation Roadmap](#14-implementation-roadmap)
15. [Cost Estimates](#15-cost-estimates)

---

## 1. Overview

Every service deployed by this blueprint is backed up nightly (configurable) to two independent S3-compatible storage backends. Backups are encrypted before leaving the host using a single master password. New deployments auto-restore from the most recent backup if one exists.

**Key properties**:
- Encrypted, deduplicated, incremental backups via Restic
- Dual-target: two S3 backends on different providers
- One master password unlocks all environments and services
- Modular: each service role declares its own backup manifest
- Auto-restore on fresh deploy (unless `--no-restore` is passed)
- Tailnet identity preserved by default: Headscale restores its node DB and each VM restores `/var/lib/tailscale`
- Alertmanager notifications on failure + weekly health summary email
- Backrest web UI + Grafana dashboard for monitoring (Tailnet-only)

---

## 2. Architecture Decisions

All decisions were evaluated in [docs/research/backup-architecture.md](../research/backup-architecture.md) and confirmed during design review.

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Backup tool | **Restic** | Mature, encrypted, S3-native, deduplicated, static Go binary |
| 2 | Storage backends | **AWS S3** (primary) + **Hetzner Object Storage** (secondary) | Two providers, configurable — any S3-compatible backend works |
| 3 | Encryption | **Single Restic master password** | Simple; owner stores one password offline. Upgrade path to per-env derived passwords documented |
| 4 | Service integration | **Backup manifest in each role** (auto-discover) | Zero-touch: add `backup.yml` to a role and it's backed up |
| 5 | Auto-restore | **ON by default** if data dir is empty + same env | `--no-restore` skips all service restores; `--fresh-tailnet` resets only Headscale and per-VM Tailscale identity state |
| 6 | Monitoring UI location | **Monitoring VM** (Tailnet-only) | Already hosts Grafana/Prometheus; not publicly accessible |
| 7 | Notifications | **Prometheus alert rules** + **weekly health summary** | Prometheus evaluates backup alerts; weekly summary confirms ecosystem is alive |
| 8 | Deduplication | **Restic block-level dedup** (default) | Content-addressed chunks; large media archives don't multiply storage |
| 9 | Restore drills | **Integrity check + file restore** (weekly) | Full-service drills deferred to later phase |
| 10 | Repo granularity | **One Restic repo per service per env** | Independent retention, independent restore, granular monitoring |
| 11 | Config location | **Global `group_vars/all/main.yml`** | Same S3 credentials for all envs; env name differentiates the path |
| 12 | First backup trigger | **Immediately after deploy** | Ensures a snapshot exists from minute one; auto-restore available if VM dies day one |

---

## 3. System Design

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                     PER-VM: ANSIBLE BACKUP ROLE                  │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │  Headscale   │  │ Vaultwarden  │  │    Matrix     │  ...     │
│  │ backup.yml   │  │ backup.yml   │  │ backup.yml   │           │
│  │  manifest    │  │  manifest    │  │  manifest    │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         └──────────────────┼──────────────────┘                  │
│                            ▼                                     │
│              ┌───────────────────────┐                           │
│              │   backup-wrapper.sh   │                           │
│              │                       │                           │
│              │  1. Pre-hooks         │                           │
│              │  2. restic backup →   │───→ node_exporter metrics │
│              │     PRIMARY backend   │                           │
│              │  3. restic backup →   │                           │
│              │     SECONDARY backend │                           │
│              │  4. restic forget     │                           │
│              │  5. Post-hooks        │                           │
│              └──────────┬────────────┘                           │
│                         │                                        │
│              ┌──────────┴────────────┐                           │
│              │   Cron jobs (zinit)   │                           │
│              │  (per-service)        │                           │
│              └───────────────────────┘                           │
└──────────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
┌──────────────────┐          ┌──────────────────┐
│   AWS S3         │          │ Hetzner Object   │
│   (S3)           │          │ Storage (S3)     │
│                  │          │                  │
│ /<env>/<service> │          │ /<env>/<service> │
│  Restic repos    │          │  Restic repos    │
└──────────────────┘          └──────────────────┘
    PRIMARY target              SECONDARY target


┌──────────────────────────────────────────────────────────────────┐
│              MONITORING VM (Tailnet-only)                         │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   Grafana    │  │  Prometheus  │  │   Backrest   │           │
│  │  dashboard   │◀─│   metrics    │  │   Web UI     │           │
│  │  (overview)  │  │  + alerts    │  │  (snapshots) │           │
│  └──────────────┘  └──────┬───────┘  └──────────────┘           │
│                           │                                      │
│                    ┌──────┴───────┐                               │
│                    │ Alert Rules  │──→ Prometheus alerts           │
│                    └──────────────┘                               │
└──────────────────────────────────────────────────────────────────┘

Weekly health summary email (Mon 08:00 UTC) ──→ Owner inbox
  If this email stops arriving → investigate manually
```

### Component Responsibilities

| Component | Where | Responsibility |
|---|---|---|
| **Restic** | Every VM with backed-up services | Encrypt, deduplicate, upload snapshots to S3 |
| **backup-wrapper.sh** | Every VM with backed-up services | Orchestrate pre-hooks → backup (primary) → backup (secondary) → prune → post-hooks → metrics |
| **Cron jobs** | Every VM with backed-up services | Schedule backup runs (nightly default, per-service override via cron) |
| **Backup manifests** | Each service Ansible role | Declare what to back up, hooks, schedule, retention |
| **Backup Ansible role** | Runs on all VMs | Install Restic, discover manifests, deploy wrapper + cron jobs, run initial backup |
| **Prometheus** | Monitoring VM | Scrape backup metrics, evaluate alert rules |
| **Grafana** | Monitoring VM | Dashboard: backup status, sizes, trends |
| **Backrest** | Monitoring VM | Web UI: browse snapshots, trigger manual backup/restore |
| **Weekly summary** | Monitoring VM | Weekly email with backup health + storage stats. If it stops arriving → investigate |

---

## 4. Modular Service Integration

### Backup Manifest Specification

Each Ansible role that manages a service declares its backup requirements via `defaults/backup.yml`:

```yaml
# ansible/roles/<service>/defaults/backup.yml
backup:
  service_name: "<service>"       # Unique name, used as Restic repo path segment

  # What to back up
  targets:
    - name: "<target-name>"       # Human-readable target name
      type: "directory"           # "directory" or "file"
      path: "/path/to/data"       # Absolute path on the VM
      description: "..."          # What this target contains
      exclude:                    # Optional: restic --exclude patterns
        - "thumbs/**"

  # Pre-backup hooks (run before restic backup)
  pre_backup:                     # Optional
    - name: "<hook-name>"
      command: "<shell command>"
      description: "..."

  # Post-backup hooks (run after restic backup + copy + prune)
  post_backup:                    # Optional
    - name: "<hook-name>"
      command: "<shell command>"

  # Schedule override (optional — defaults to global backup_schedule_cron)
  schedule_cron:
    minute: "0"
    hour: "2"               # cron fields; defaults to daily at 02:00 UTC

  # Retention override (optional — defaults to global backup_retention_*)
  retention:
    keep_hourly: 24
    keep_daily: 7
    keep_weekly: 4
    keep_monthly: 12
    keep_yearly: 2

  # Restore verification (optional — used by restore drills)
  restore_verify:
    command: "<shell command>"     # Must exit 0 if restored data is valid
    description: "..."
    timeout: 60                   # Seconds
```

### Discovery Mechanism

1. The `backup` Ansible role runs on each VM
2. It scans all roles applied to that host for `defaults/backup.yml`
3. For each discovered manifest, it:
   - Initializes a Restic repo at `s3://<bucket>/<env>/<service>/` (idempotent)
   - Deploys `/opt/backup/configs/<service>.yml` on the host
   - Deploys `backup-<service>.sh` wrapper script
   - Deploys a cron job for the service (via `ansible.builtin.cron`)
   - Runs the first backup immediately

### Adding a New Service

To add backup for a new service:

1. Create `ansible/roles/<service>/defaults/backup.yml` with the manifest
2. Run Ansible — the backup role auto-discovers and configures everything

**No changes to the backup role. No changes to any central config. Zero-touch.**

### Existing Service Manifests

These manifests will be created for services already in the blueprint:

#### Headscale (control VM)

```yaml
backup:
  service_name: "headscale"
  targets:
    - name: "state"
      type: "directory"
      path: "/var/lib/headscale"
      description: "Headscale database and state"
    - name: "config"
      type: "directory"
      path: "/etc/headscale"
      description: "Headscale configuration"
    - name: "caddy-data"
      type: "directory"
      path: "/opt/caddy/data"
      description: "TLS certificates and Caddy state"
    - name: "headplane-config"
      type: "directory"
      path: "/opt/headplane"
      description: "Headplane configuration and secrets"
  pre_backup:
    - name: "sqlite-backup"
      command: "docker exec headscale sqlite3 /var/lib/headscale/db.sqlite3 '.backup /var/lib/headscale/db-backup.sqlite3'"
      description: "Create consistent SQLite dump"
  post_backup:
    - name: "cleanup-dump"
      command: "rm -f /var/lib/headscale/db-backup.sqlite3"
  restore_verify:
    command: "docker exec headscale headscale version"
    description: "Verify Headscale starts with restored data"
    timeout: 60
```

#### Gateway (gateway VM)

```yaml
backup:
  service_name: "gateway"
  targets:
    - name: "caddy-data"
      type: "directory"
      path: "/opt/caddy/data"
      description: "Caddy TLS certificates and state"
    - name: "caddy-config"
      type: "directory"
      path: "/opt/caddy/config"
      description: "Caddy configuration"
```

#### Monitoring (monitoring VM)

```yaml
backup:
  service_name: "monitoring"
  targets:
    - name: "prometheus-data"
      type: "directory"
      path: "/opt/prometheus/data"
      description: "Prometheus time-series database"
    - name: "grafana-data"
      type: "directory"
      path: "/opt/grafana/data"
      description: "Grafana dashboards and settings"
  retention:
    keep_daily: 7
    keep_weekly: 4
    keep_monthly: 3
```

#### Tailscale State (all VMs)

```yaml
backup:
  service_name: "tailscale"
  targets:
    - name: "tailscale-state"
      type: "directory"
      path: "/var/lib/tailscale"
      description: "Tailscale node identity and keys"
```

    `tailscale` does not use one shared repository anymore. Each host stores its state
    in a per-host repo such as `tailscale-control-vm`, `tailscale-gateway-vm`, or
    `tailscale-monitoring-vm` so restores cannot clone node identity across VMs.

  By default, fresh VM rebuilds restore this per-host state so the node keeps its prior
  tailnet identity. Use `./scripts/deploy.sh ... --fresh-tailnet` only when you explicitly
  want rebuilt VMs to come back as brand-new Tailscale nodes.

### Future Service Manifest Examples

Reference manifests for planned Tier-1 services:

<details>
<summary>Vaultwarden (password vault)</summary>

```yaml
backup:
  service_name: "vaultwarden"
  targets:
    - name: "data"
      type: "directory"
      path: "/opt/vaultwarden/data"
  pre_backup:
    - name: "sqlite-backup"
      command: "sqlite3 /opt/vaultwarden/data/db.sqlite3 '.backup /opt/vaultwarden/data/db-backup.sqlite3'"
  post_backup:
    - name: "cleanup"
      command: "rm -f /opt/vaultwarden/data/db-backup.sqlite3"
  schedule: "hourly"
  retention:
    keep_hourly: 24
    keep_daily: 30
    keep_weekly: 12
    keep_monthly: 24
  restore_verify:
    command: "curl -sf http://localhost:8080/alive || exit 1"
    timeout: 30
```

</details>

<details>
<summary>Matrix Synapse (messaging)</summary>

```yaml
backup:
  service_name: "matrix-synapse"
  targets:
    - name: "database"
      type: "file"
      path: "/var/backups/synapse-db.sql.gz"
    - name: "media"
      type: "directory"
      path: "/opt/matrix/media_store"
    - name: "config"
      type: "directory"
      path: "/opt/matrix/config"
  pre_backup:
    - name: "pg-dump"
      command: "docker exec matrix-db pg_dumpall -U synapse | gzip > /var/backups/synapse-db.sql.gz"
  post_backup:
    - name: "cleanup"
      command: "rm -f /var/backups/synapse-db.sql.gz"
  restore_verify:
    command: "curl -sf http://localhost:8008/_matrix/client/versions || exit 1"
    timeout: 60
```

</details>

<details>
<summary>Forgejo (source code hosting)</summary>

```yaml
backup:
  service_name: "forgejo"
  targets:
    - name: "repositories"
      type: "directory"
      path: "/opt/forgejo/data/gitea/repositories"
    - name: "database"
      type: "file"
      path: "/var/backups/forgejo-db.sql.gz"
    - name: "config"
      type: "directory"
      path: "/opt/forgejo/config"
    - name: "lfs"
      type: "directory"
      path: "/opt/forgejo/data/gitea/lfs"
  pre_backup:
    - name: "dump-db"
      command: "docker exec forgejo-db pg_dumpall -U forgejo | gzip > /var/backups/forgejo-db.sql.gz"
  post_backup:
    - name: "cleanup"
      command: "rm -f /var/backups/forgejo-db.sql.gz"
```

</details>

<details>
<summary>Immich (photo archive)</summary>

```yaml
backup:
  service_name: "immich"
  targets:
    - name: "media"
      type: "directory"
      path: "/opt/immich/upload"
      exclude:
        - "thumbs/**"
        - "encoded-video/**"
    - name: "database"
      type: "file"
      path: "/var/backups/immich-db.sql.gz"
  pre_backup:
    - name: "pg-dump"
      command: "docker exec immich-db pg_dumpall -U immich | gzip > /var/backups/immich-db.sql.gz"
  post_backup:
    - name: "cleanup"
      command: "rm -f /var/backups/immich-db.sql.gz"
  retention:
    keep_daily: 7
    keep_weekly: 4
    keep_monthly: 6
```

</details>

<details>
<summary>Nextcloud (files + collaboration)</summary>

```yaml
backup:
  service_name: "nextcloud"
  targets:
    - name: "data"
      type: "directory"
      path: "/opt/nextcloud/data"
    - name: "database"
      type: "file"
      path: "/var/backups/nextcloud-db.sql.gz"
    - name: "config"
      type: "directory"
      path: "/opt/nextcloud/config"
  pre_backup:
    - name: "maintenance-on"
      command: "docker exec nextcloud php occ maintenance:mode --on"
    - name: "pg-dump"
      command: "docker exec nextcloud-db pg_dumpall -U nextcloud | gzip > /var/backups/nextcloud-db.sql.gz"
  post_backup:
    - name: "maintenance-off"
      command: "docker exec nextcloud php occ maintenance:mode --off"
    - name: "cleanup"
      command: "rm -f /var/backups/nextcloud-db.sql.gz"
```

</details>

<details>
<summary>Stalwart Mail</summary>

```yaml
backup:
  service_name: "stalwart-mail"
  targets:
    - name: "data"
      type: "directory"
      path: "/opt/stalwart/data"
    - name: "config"
      type: "directory"
      path: "/opt/stalwart/etc"
  schedule: "daily"
```

</details>

---

## 5. Multi-Environment Isolation

### S3 Path Structure

Each environment gets its own path prefix. All envs share the same S3 bucket and Restic master password.

```
s3://<bucket>/
  ├── prod/
  │   ├── headscale/          ← independent Restic repo
  │   ├── gateway/
  │   ├── monitoring/
  │   ├── tailscale-control-vm/
  │   ├── tailscale-gateway-vm/
  │   ├── tailscale-monitoring-vm/
  │   ├── vaultwarden/
  │   └── ...
  ├── test/
  │   ├── headscale/
  │   └── ...
  └── company-a/
      ├── headscale/
      └── ...
```

### How Environment Name Flows

```
deploy.sh --env prod
  → sets BLUEPRINT_ENV=prod
    → Ansible backup role reads BLUEPRINT_ENV
      → Restic repo path = s3://<bucket>/prod/<service>/
        → Cron job wrapper exports RESTIC_REPOSITORY with env prefix
```

Auto-restore only restores from the **same environment** — deploying `--env prod` restores from `prod/` snapshots, never from `test/`.

### Isolation Level

| Aspect | Default | Optional upgrade |
|---|---|---|
| Path isolation | Yes — different S3 prefix per env | N/A |
| Password isolation | No — shared master password | Per-env derived passwords (HKDF) |
| Credential isolation | No — shared S3 keys | Per-env IAM users |
| Bucket isolation | No — shared bucket | Separate buckets per env |

The default (path isolation + shared password) is sufficient for solo operator with multiple envs. Per-env passwords and credentials are documented as upgrade options in [backup-architecture.md](../research/backup-architecture.md#option-b-per-environment-restic-passwords-derived-from-master-key) for multi-tenant scenarios.

---

## 6. Scheduling & Retention

### Scheduling

Cron jobs manage backup scheduling. Each service gets its own cron entry deployed via Ansible's `cron` module. The cron daemon runs under **zinit** on ThreeFold Grid VMs (which use zinit instead of systemd).

**Default schedule**: daily at 02:00 UTC.

```cron
# Deployed via ansible.builtin.cron
0 2 * * *  /opt/backup/bin/backup-<service>.sh >> /var/log/backup-<service>.log 2>&1
```

Services can override the schedule in their manifest via `schedule_cron` dict.

**Cron integration notes**:
- File locking (`flock`) in each wrapper script prevents overlapping runs
- Logs written to `/var/log/backup-<service>.log` for debugging
- Metrics written to `/var/lib/node_exporter/textfile/backup_<service>.prom` after each run
- `crontab -l` to view all configured backup schedules

### First Backup

Ansible runs the first backup **immediately** after deploying the backup configuration for a service. This ensures a snapshot exists from minute one.

### Retention Policy

Default retention (overridable per-service in manifest):

| Tier | Keep | Rationale |
|---|---|---|
| Hourly | 24 | Only for critical services (Vaultwarden, mail) |
| Daily | 7 | One week of daily granularity |
| Weekly | 4 | One month of weekly points |
| Monthly | 12 | One year of monthly points |
| Yearly | 2 | Two-year deep archive |

Retention is applied via `restic forget --prune` after each backup run, on both primary and secondary backends. Secondary failures are fatal because dual-backend redundancy is part of the backup contract, not a best-effort option.

### Deduplication Behavior

Restic splits every file into variable-size content-addressed chunks (~1 MB average). Only unique chunks are stored.

**Impact on storage**:
- 50 GB photo archive: initial upload = ~50 GB. Daily backup with 200 MB new photos = ~200 MB incremental. Existing 50 GB costs zero additional storage.
- 7 daily + 4 weekly + 12 monthly snapshots of a 50 GB archive ≠ 23 × 50 GB. Real cost ≈ 50 GB + cumulative new data.
- File renames, moves, and small edits are automatically deduplicated.

### Backup Execution Flow

```
Cron job fires (or first-run by Ansible)
  └→ /opt/backup/bin/backup-<service>.sh
       ├─ Source /opt/backup/.env (credentials)
       ├─ Run pre_backup hooks (DB dumps, maintenance mode, etc.)
       ├─ restic backup --tag <env> --tag <service> <paths...>   → PRIMARY backend
       ├─ restic backup --tag <env> --tag <service> <paths...>   → SECONDARY backend
       ├─ restic forget --prune (both repos, per retention policy)
       ├─ Run post_backup hooks (cleanup temp files, maintenance off)
       ├─ Write metrics to /var/lib/node_exporter/textfile/backup_<service>.prom
       └─ On failure: cleanup trap writes status=0 metrics
                      → Prometheus scrapes failed status
                      → alert rules evaluate
```

---

## 7. Auto-Restore on Deploy

### Behavior

When a service is deployed on a fresh or rebuilt VM, the backup role checks for an existing Restic snapshot for that service + environment. If found and the data directory is empty, it restores automatically.

### Flow

```
Ansible deploys service role
  └─ backup role: check_snapshot task
       └─ restic snapshots --json --tag <service> --latest 1
            ├─ Snapshot EXISTS + data dir EMPTY + same env:
            │    └─ restic restore latest --target /
            │    └─ Run post-restore hooks
            │    └─ Log: "Restored <service> from backup (snapshot <id>)"
            │    └─ Continue with normal Ansible config (idempotent)
            ├─ Snapshot EXISTS + data dir NOT EMPTY:
            │    └─ Skip restore (service already running)
            │    └─ Log: "Skipped restore — data directory not empty"
            └─ NO snapshot:
                 └─ Fresh install (normal flow)
```

### Flags

| Flag | Behavior |
|---|---|
| (default) | Auto-restore ON if snapshot exists + data dir empty + same env |
| `--no-restore` | Skip auto-restore entirely — force fresh install |

### Integration Point

Each service role includes the backup check at the top of its task list:

```yaml
# ansible/roles/<service>/tasks/main.yml (prepended)
- name: "Attempt restore from backup"
  include_role:
    name: backup
    tasks_from: restore
  vars:
    backup_service_name: "{{ backup.service_name }}"
  when: backup_restore_enabled | default(true)
```

The `backup_restore_enabled` var is set to `false` when `--no-restore` is passed via deploy.sh → Ansible extra vars.

---

## 8. Notification & Alerting

### Two-layer alerting

| Layer | What it catches | How it works |
|---|---|---|
| **Prometheus alert rules** (real-time) | Backup failed or stale | Prometheus scrapes backup metrics → alert rule fires → visible in Grafana |
| **Weekly health summary** (confirmation) | Silent monitoring death | Weekly cron job generates a report summarizing all backup statuses. If the report stops appearing in logs, the owner knows to investigate |

### Per-Service Backup Metrics

Each backup wrapper writes node_exporter textfile metrics after every run:

```
# /var/lib/node_exporter/textfile/backup_headscale.prom
backup_last_success_timestamp{service="headscale",env="prod"} 1710288000
backup_last_size_bytes{service="headscale",env="prod"} 52428800
backup_last_duration_seconds{service="headscale",env="prod"} 42
backup_last_status{service="headscale",env="prod"} 1
```

Prometheus scrapes these via node_exporter's textfile collector.

### Prometheus Alert Rules (real-time failure detection)

```yaml
groups:
  - name: backup
    rules:
      - alert: BackupFailed
        expr: backup_last_status == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Backup failed for {{ $labels.service }} ({{ $labels.env }})"

      - alert: BackupStale
        expr: time() - backup_last_success_timestamp > 90000  # 25 hours
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "No successful backup in 25h for {{ $labels.service }} ({{ $labels.env }})"

      - alert: BackupSizeAnomaly
        expr: |
          backup_last_size_bytes / backup_last_size_bytes offset 1d > 3
          or backup_last_size_bytes / backup_last_size_bytes offset 1d < 0.3
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Backup size changed >3x for {{ $labels.service }} ({{ $labels.env }})"
```

Prometheus evaluates these rules and fires alerts visible in the Grafana dashboard. Alertmanager can be added later for email/webhook/Matrix routing.

### Weekly Health Summary

A weekly cron job on the monitoring VM runs a script that:

1. Queries Prometheus for all `backup_last_*` metrics
2. Compiles a summary: per-service last backup time, size, status
3. Writes report to `/tmp/backup-summary-<date>.txt` and log
4. Optionally sends an email if `mail` or `msmtp` is configured

```cron
# Weekly backup summary: Monday 08:00 UTC
0 8 * * 1  /opt/backup/bin/backup-summary.sh >> /var/log/backup-summary.log 2>&1
```

Example summary email:

```
Subject: [prod] Weekly Backup Health — All OK

Backup Health Report — prod — 2026-03-16
═══════════════════════════════════════════

Service          Last Backup    Size     Status
─────────────────────────────────────────────
headscale        2h ago         48 MB    ✓ OK
gateway          2h ago         12 MB    ✓ OK
monitoring       2h ago         1.2 GB   ✓ OK
tailscale        2h ago         3 MB     ✓ OK
vaultwarden      35m ago        180 MB   ✓ OK

Storage Usage:
  AWS S3:     2.1 GB (primary)
  Hetzner:    2.1 GB (secondary)

Restore Drill: Last run 2 days ago — PASSED

Next summary: 2026-03-23 08:00 UTC
```

**Dead man's switch**: If the weekly summary stops appearing in `/var/log/backup-summary.log`, the monitoring VM (or cron) is down and the owner should investigate manually. When email is configured, the absence of the expected email is the signal.

---

## 9. Monitoring UI

### Backrest (Snapshot Browser)

[Backrest](https://github.com/garethgeorge/backrest) runs on the monitoring VM, accessible only via Tailscale.

**Capabilities**:
- Browse all Restic repos and snapshots visually
- See backup sizes, timestamps, file counts
- Trigger manual backups or restores from the UI
- View backup logs and errors
- Multi-repo support — one view for all services and envs

**Deployment** (via Ansible monitoring role):

```yaml
# Docker container on monitoring VM
backrest:
  image: garethgeorge/backrest:latest
  volumes:
    - /opt/backrest/config:/config
    - /opt/backrest/data:/data
    - /opt/backrest/cache:/cache
  environment:
    - BACKREST_PORT=9898
  ports:
    - "<tailscale_ip>:9898:9898"
  restart: unless-stopped
```

**Access**: `http://<monitoring-tailscale-ip>:9898` — Tailnet-only, not exposed publicly.

**Login**: `admin` / `SERVICES_ADMIN_PASSWORD` from `environments/<env>/secrets.env`. Backrest stores that password as a base64-encoded bcrypt hash in `config.json`, which differs from Prometheus's raw bcrypt format.

### Grafana Dashboard

A backup overview dashboard on the existing Grafana instance showing:

- Last successful backup time per service
- Backup size per service (with historical trend)
- Backup duration
- Alert status (green/red per service)
- Restore drill results

Data source: Prometheus, scraped from node_exporter textfile metrics written by the backup wrapper.

### Usage Split

| Question | Where to look |
|---|---|
| "Is everything OK?" | Grafana dashboard — green/red per service |
| "How much space am I using?" | Grafana dashboard — size trend chart |
| "Let me browse the snapshots" | Backrest UI |
| "I need to restore a specific file" | Backrest UI → select snapshot → browse → restore |
| "Backup failed — what happened?" | Grafana alert → `/var/log/backup-<service>.log` on VM |

---

## 10. Restore Drills

### Automated Drill Types

| Type | Frequency | What It Tests | How |
|---|---|---|---|
| **Integrity check** | Weekly | Restic repo consistency | `restic check` on both backends |
| **File restore** | Weekly | Data is actually readable | Restore latest snapshot to `/tmp/backup-drill/<service>/`, verify files are non-empty and match expected structure |

Full-service restore drills (spin up container, restore, verify health) are a future enhancement.

### Cron Job for Drills

```cron
# Weekly backup drill: Sunday 04:00 UTC
0 4 * * 0  /opt/backup/bin/backup-drill.sh >> /var/log/backup-drill.log 2>&1
```

### Test Suite Integration

New test script: `scripts/tests/80_verify_backup_restore.sh`

For each backed-up service on the current host:
1. Verify Restic repo is accessible on both backends
2. Verify latest snapshot exists and is recent (< 25 hours old)
3. Restore latest snapshot to temp directory
4. Verify restored files are non-empty and match expected paths from the manifest
5. Run `restore_verify` command if defined in the manifest
6. Clean up temp directory

### Drill Failure Alerting

Drill results flow through the same notification pipeline:
- Writes `backup_drill_last_status` metric → Prometheus → Alertmanager
- Drill status is included in the weekly health summary email

---

## 11. Backup Configuration

### Ansible Variables

All backup configuration lives in `group_vars/all/main.yml`:

```yaml
# ── Backup configuration ──

# Enable/disable backup system globally
backup_enabled: true

# Restic master password (should be set via env var or vault, not plaintext)
# export RESTIC_PASSWORD="your-master-password"
# Or set in environments/<env>/group_vars/all.yml
backup_restic_password: "{{ lookup('env', 'RESTIC_PASSWORD') }}"

# S3 backends (minimum 2)
backup_backends:
  - name: "primary"
    type: "s3"
    endpoint: "https://s3.amazonaws.com"
    bucket: "<your-primary-bucket>"
    access_key: "{{ lookup('env', 'BACKUP_S3_PRIMARY_ACCESS_KEY') }}"
    secret_key: "{{ lookup('env', 'BACKUP_S3_PRIMARY_SECRET_KEY') }}"
  - name: "secondary"
    type: "s3"
    endpoint: "https://hel1.your-objectstorage.com"
    bucket: "<your-secondary-bucket>"
    access_key: "{{ lookup('env', 'BACKUP_S3_SECONDARY_ACCESS_KEY') }}"
    secret_key: "{{ lookup('env', 'BACKUP_S3_SECONDARY_SECRET_KEY') }}"

# Default schedule (overridable per-service)
backup_schedule_cron:
  minute: "0"
  hour: "2"      # 02:00 UTC daily

# Default retention (overridable per-service in manifest)
backup_retention_keep_hourly: 24
backup_retention_keep_daily: 7
backup_retention_keep_weekly: 4
backup_retention_keep_monthly: 12
backup_retention_keep_yearly: 2

# Weekly health summary
backup_summary_enabled: true
backup_summary_cron: "0 8 * * 1"  # Monday 08:00 UTC

# Restore behavior
backup_restore_enabled: true  # Set to false via --no-restore flag

# Alert email (used by Alertmanager, not backup scripts directly)
backup_alert_email: ""
```

### Credentials Flow

Credentials are **never stored in the repo**. They live in a per-environment `secrets.env` file (gitignored) that `deploy.sh` auto-sources:

```bash
# One-time setup per environment:
cp environments/prod/secrets.env.example environments/prod/secrets.env
$EDITOR environments/prod/secrets.env

# The file contains ALL secrets for the deployment:
#   TF_VAR_tfgrid_mnemonic=...          # TFChain wallet (used by Terraform)
#   SERVICES_ADMIN_PASSWORD=...         # Admin login for Grafana, Prometheus, Backrest
#   RESTIC_PASSWORD=...                 # Backup encryption master password
#   BACKUP_S3_PRIMARY_ACCESS_KEY=...    # AWS S3 (primary backup backend)
#   BACKUP_S3_PRIMARY_SECRET_KEY=...
#   BACKUP_S3_SECONDARY_ACCESS_KEY=...  # Hetzner Object Storage (secondary)
#   BACKUP_S3_SECONDARY_SECRET_KEY=...

# Deploy (secrets.env is auto-sourced by deploy.sh):
./scripts/deploy.sh full --env prod
```

Variables prefixed with `TF_VAR_` are automatically picked up by Terraform. Other variables are consumed by Ansible via `lookup('env', ...)`.

Alternatively, you can `export` variables in your shell or use any secrets manager / CI secrets injection — `deploy.sh` checks environment variables regardless of how they were set.

On the VMs, credentials are written to `/opt/backup/.env` (mode 0600, root-only) by the Ansible backup role and sourced by the wrapper script.

On the monitoring VM, the Backrest config is also rendered with a stable per-environment `instance` value (`privalon-<env>`), and each imported repo is marked `autoInitialize: true`. Backrest 1.12.x requires the instance field for repository operations and now rejects imported repos that have neither `guid` nor `autoInitialize`; when either requirement is missing, the UI may fail to start or repository trees and usage stats stay blank.

---

## 12. Owner Recovery Card

The owner stores a single card (physically or in a separate password manager) with everything needed to restore from scratch:

```
╔══════════════════════════════════════════════════════════╗
║          SOVEREIGN CLOUD BACKUP ACCESS                   ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║  Restic password: <master-password>                      ║
║                                                          ║
║  Primary (AWS S3):                                       ║
║    Endpoint: https://s3.amazonaws.com                    ║
║    Bucket:   <your-primary-bucket>                       ║
║    Access:   <key>                                       ║
║    Secret:   <secret>                                    ║
║                                                          ║
║  Secondary (Hetzner):                                    ║
║    Endpoint: https://hel1.your-objectstorage.com         ║
║    Bucket:   <your-secondary-bucket>                     ║
║    Access:   <key>                                       ║
║    Secret:   <secret>                                    ║
║                                                          ║
║  Path: s3://<bucket>/<env>/<service>/                    ║
║  Envs: prod, test                                        ║
║                                                          ║
║  RESTORE: (from any machine with restic installed)       ║
║                                                          ║
║  export RESTIC_PASSWORD="<master-password>"              ║
║  export AWS_ACCESS_KEY_ID="<key>"                        ║
║  export AWS_SECRET_ACCESS_KEY="<secret>"                 ║
║                                                          ║
║  # List snapshots:                                       ║
║  restic -r s3:s3.amazonaws.com/<bucket>/\                ║
║    prod/headscale snapshots                              ║
║                                                          ║
║  # Restore latest:                                       ║
║  restic -r s3:s3.amazonaws.com/<bucket>/\                ║
║    prod/headscale restore latest --target /              ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

**5 pieces of information** (1 password + 2 endpoints + 2 credential pairs) unlock **all** environments, **all** services, **all** snapshots.

---

## 13. Data Type Reference

How Restic handles each data type in the blueprint:

| Data Type | Examples | Size | Backup Strategy | Dedup Efficiency |
|---|---|---|---|---|
| Configuration | Headscale config, Caddyfile | KB | Daily, direct file backup | Excellent (tiny) |
| Certificates & Keys | TLS certs, Tailscale keys | KB | Daily, critical for restore | Excellent (tiny) |
| SQLite DBs | Headscale, Vaultwarden | MB | Pre-hook: `.backup` command | Good (binary changes) |
| PostgreSQL DBs | Nextcloud, Matrix, Forgejo, Immich | MB–GB | Pre-hook: `pg_dumpall \| gzip` | Good (text dumps dedup well) |
| Media files | Photos (Immich), Matrix media | GB–TB | Direct, exclude regenerable (thumbs, transcodes) | Excellent (append-mostly) |
| Git repos | Forgejo bare repositories | GB | Direct backup of bare repos | Good (packfiles change) |
| Password vaults | Vaultwarden data | MB | Hourly schedule | Excellent (small) |
| Email | Stalwart mail storage | GB | Daily | Good (append-mostly) |
| Documents | Nextcloud files, Paperless | GB | Daily | Good (mixed) |

### Storage Impact Example

50 GB photo archive + 7 daily + 4 weekly + 12 monthly retention:
- Actual S3 usage ≈ 50 GB + cumulative new photos added over retention window
- **Not** 23 × 50 GB (dedup eliminates shared blocks across snapshots)

---

## 14. Implementation Roadmap

### Phase 1: Core Backup (single backend)

- [x] Create `ansible/roles/backup/` role structure
  - `tasks/main.yml` — install Restic, discover manifests, deploy configs
  - `tasks/check_snapshot.yml` — check if snapshot exists for service
  - `tasks/restore.yml` — restore from latest snapshot
  - `templates/backup-wrapper.sh.j2` — per-service backup script
  - `templates/backup-env.j2` — credentials environment file
  - `templates/backup-config.yml.j2` — per-service config
  - `defaults/main.yml` — global backup defaults
- [x] Implement Restic binary installation (download + verify checksum)
- [x] Implement single-backend backup wrapper script
  - Pre-hooks → `restic backup` → `restic forget --prune` → post-hooks → metrics
- [x] Create backup manifests for existing services:
  - `ansible/roles/headscale/defaults/backup.yml`
  - `ansible/roles/gateway/defaults/backup.yml`
  - `ansible/roles/monitoring/defaults/backup.yml`
  - `ansible/roles/tailscale/defaults/backup.yml`
- [x] Add global backup variables to `ansible/group_vars/all/main.yml`
- [x] Wire backup role into `ansible/playbooks/site.yml` (runs after service roles)
- [x] Implement first-backup-on-deploy (Ansible triggers initial run)
- [x] Test: backup and restore of Headscale state on test env

### Phase 2: Dual Backend + Scheduling

- [x] Add direct `restic backup` to secondary backend in wrapper script
- [x] Implement cron job generation from manifest schedule field
- [x] Implement retention policy enforcement (global defaults + per-service override)
- [x] Add backup metrics export (node_exporter textfile)
  - `backup_last_success_timestamp`
  - `backup_last_size_bytes`
  - `backup_last_duration_seconds`
  - `backup_last_status`
- [x] Test: verify both backends receive data and `restic snapshots` works on both

### Phase 3: Auto-Restore + Notifications

- [x] Implement `check_snapshot` task — `restic snapshots --json --latest 1`
- [x] Implement `restore` task — restore latest, guard on empty data dir + same env
- [x] Add `--no-restore` flag to `deploy.sh` → passes `backup_restore_enabled=false`
- [x] Integrate auto-restore into headscale role (first service with restore)
- [x] Implement weekly health summary script + cron job
- [x] Add Prometheus alert rules for backup (failed, stale, size anomaly, drill failed)
- [ ] Add backup hooks integration to `scripts/hooks/backup.sh` (replace TODO stub)
- [ ] Test: destroy control VM → redeploy → verify auto-restore works

### Phase 4: Monitoring UI + Drills

- [x] Deploy Backrest container on monitoring VM (Ansible monitoring role)
  - Docker container, Tailscale IP binding, host networking
- [x] Create Grafana backup dashboard (provisioned via Ansible)
  - Last backup time, size, duration, status per service
  - Alert status indicators
- [ ] Create `scripts/tests/80_verify_backup_restore.sh`
  - Verify repo accessible on both backends
  - Verify snapshot recency
  - Restore to temp dir + verify files
- [x] Implement weekly drill cron job
- [x] Add drill metrics to node_exporter textfile
- [ ] Integrate drill test into `scripts/tests/run.sh`

### Phase 5: Documentation + Hardening

- [x] Add backup section to `docs/technical/OPERATIONS.md`
  - Backup verification commands
  - Manual restore procedure
  - Credential rotation procedure
- [ ] Add "Owner Recovery Card" template to `docs/user/GUIDE.md`
- [ ] Add per-service restore steps to operations docs
- [ ] Add backup status to deployment summary output (`scripts/helpers/deployment-summary.sh`)
- [ ] Security review: credential storage, file permissions, S3 bucket policies
- [x] Update `CHANGELOG.md` and bump `VERSION`

---

## 15. Cost Estimates

### Storage Costs (per environment, dual-backend)

Assuming moderate deployment: Headscale (50 MB) + Tailscale (10 MB) + Gateway certs (50 MB) + Monitoring (500 MB) + Vaultwarden (200 MB) + Nextcloud (10 GB) + Matrix (5 GB) + Immich (50 GB) ≈ **65 GB** raw data.

With Restic deduplication, monthly incremental growth ≈ 5–10% of raw.

| Backend | 65 GB | 200 GB | Notes |
|---|---|---|---|
| AWS S3 Standard | ~$1.50 | ~$4.60 | $0.023/GB (US East) |
| Hetzner Object Storage | ~€0.39 | ~€1.20 | €0.006/GB |
| **Total (2 backends)** | **~$1.89** | **~$5.80** | |

Egress costs (restore events only — rare):
- AWS: $0.09/GB (first 100 GB/month free tier)
- Hetzner: €0.01/GB external

**Bottom line**: Dual-backend backup for a full sovereign setup costs $2–6/month depending on data volume.

---

*This architecture is approved and ready for implementation. The research and evaluation that led to these decisions is preserved in [docs/research/backup-architecture.md](../research/backup-architecture.md).*
