# Backup Architecture — Deep Brainstorming

March 2026 · Research Document v1.0

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Design Principles](#2-design-principles)
3. [Backup Tool Evaluation](#3-backup-tool-evaluation)
4. [Storage Backend Evaluation](#4-storage-backend-evaluation)
5. [Encryption & Key Management](#5-encryption--key-management)
6. [Modular Service Integration](#6-modular-service-integration)
7. [Multi-Environment Isolation](#7-multi-environment-isolation)
8. [Scheduling & Retention](#8-scheduling--retention)
9. [Restore-on-Deploy (Auto-Restore)](#9-restore-on-deploy-auto-restore)
10. [Restore Drills & Automated Testing](#10-restore-drills--automated-testing)
11. [Notification & Alerting](#11-notification--alerting)
12. [Backup Monitoring UI](#12-backup-monitoring-ui)
13. [Data Type Considerations](#13-data-type-considerations)
14. [Recommended Architecture](#14-recommended-architecture)
15. [Implementation Roadmap](#15-implementation-roadmap)

---

## 1. Executive Summary

This document evaluates backup architectures for the sovereign cloud blueprint. The requirements are:

- **Multi-target**: Backups replicated to 2+ independent S3-compatible stores
- **Owner-accessible**: One master password unlocks everything, even if the entire grid is down
- **Modular**: Adding a new service = adding a backup manifest, not re-engineering the pipeline
- **Auto-restore**: New deployments attempt restore from backup by default
- **Multi-environment**: Full isolation between prod/test/company-a/company-b
- **Flexible scheduling**: Nightly default, configurable per-service
- **Flexible data types**: Certificates, databases, media archives, source code, vaults
- **Failure notification**: Email on backup or restore-drill failure
- **Restore drills**: Automated verification that backups are actually restorable
- **Monitoring UI**: Visual dashboard for backup status, size, and history

---

## 2. Design Principles

| Principle | Rationale |
|---|---|
| **Encryption before leaving the host** | Data is encrypted with a repository password before upload; no trust required in the storage provider |
| **One master password** | A single Restic repository password (or age master key) unlocks all backup repos; owner stores this offline |
| **Modular manifests** | Each service declares what to back up via a standard YAML interface in its Ansible role |
| **Idempotent & safe to re-run** | Backup and restore operations converge; running twice produces the same result |
| **Multi-target by default** | Every backup automatically uploads to all configured backends |
| **Environment-scoped** | Backup paths are prefixed with `<env>/` to make collisions impossible |
| **Restore before configure** | On fresh deploy, attempt restore from backup *before* running service-specific configuration |

---

## 3. Backup Tool Evaluation

### Option A: Restic (Recommended)

**Description**: Open-source, encrypted, deduplicated backup tool. Supports S3, B2, SFTP, local, REST server, and more backends natively.

**Pros**:
- Encryption built-in (AES-256 in CTR mode + Poly1305 MAC)
- Content-addressable deduplication across snapshots — very space-efficient
- Fast incremental backups (only changed blocks uploaded)
- Native S3, B2, SFTP, REST server, local backend support
- Single static binary — no dependencies, easy to install
- Active maintenance, large community
- Tags and hostnames for organizing snapshots — natural fit for multi-env
- `restic mount` — browse snapshots as a FUSE filesystem for easy partial restores
- Built-in `check` command for integrity verification
- `restic forget --keep-*` for retention policy enforcement
- Works well with pre/post backup hooks (database dumps, service stops)

**Cons**:
- No native multi-target replication (must run backup twice or use `restic copy`)
- Repository format v2 is newer, some older docs reference v1
- No built-in scheduling (relies on cron/systemd timers)
- `restic copy` between repos is functional but adds backup time
- No built-in web UI (needs external monitoring)

**Verdict**: Best overall choice. Industry standard for self-hosted encrypted backups.

### Option B: BorgBackup + Borgmatic

**Description**: Mature, encrypted, deduplicated backup tool with excellent compression. Borgmatic adds YAML-based configuration.

**Pros**:
- Excellent compression (better than Restic in most cases)
- Very mature and battle-tested
- Borgmatic provides clean YAML config and cron integration
- Supports pre/post hooks natively in borgmatic
- Append-only mode for immutable backups

**Cons**:
- **No native S3/B2 support** — requires a local filesystem or SSH target
- To use S3: must pair with rclone mount (FUSE) — fragile, slower, adds complexity
- Repository format tied to host architecture (harder to cross-restore)
- Requires Python — heavier dependency than Restic's static binary
- Multi-target requires multiple repo configurations
- Less natural fit for cloud-native S3 workflows

**Verdict**: Excellent tool, but lack of native S3 support is a dealbreaker for multi-target cloud storage. Would require rclone as a shim, adding fragility.

### Option C: Kopia

**Description**: Modern backup tool, written in Go, with built-in web UI and S3 support.

**Pros**:
- Native S3, B2, GCS, Azure, SFTP, Rclone support
- Built-in web UI for browsing and managing snapshots
- Policy-based scheduling and retention built-in
- Snapshot-level encryption similar to Restic
- Content-addressable deduplication
- Active development, gaining community traction
- Supports repository syncing across backends natively
- Built-in server mode for centralized management

**Cons**:
- Younger project than Restic or Borg — less battle-tested
- Smaller community, fewer integration examples
- Repository format less established (migration risk if project stalls)
- Web UI adds attack surface if exposed
- Some edge cases in large repository handling reported
- Less Docker/container ecosystem support than Restic

**Verdict**: Very promising, especially the built-in UI and multi-backend sync. However, maturity gap vs Restic is a real risk for production sovereign infrastructure. Worth monitoring.

### Option D: Duplicacy

**Description**: Cloud-native backup tool with lock-free deduplication.

**Pros**:
- Lock-free deduplication (multiple clients can back up simultaneously)
- Native S3, B2, GCS support
- Erasure coding support for extra durability

**Cons**:
- **Partial open-source** — CLI is open, but web UI is commercial
- Less community adoption
- Fewer Ansible/automation integrations available
- Commercial licensing complexity

**Verdict**: Lock-free dedup is interesting, but commercial UI and smaller community make it a poor fit for an open-source blueprint.

### Tool Comparison Matrix

| Feature | Restic | BorgBackup | Kopia | Duplicacy |
|---|---|---|---|---|
| Encryption | Built-in AES-256 | Built-in AES-256 | Built-in AES-256 | Built-in |
| Deduplication | Content-addressed | Chunk-based | Content-addressed | Lock-free |
| S3 Native | Yes | No (rclone shim) | Yes | Yes |
| B2 Native | Yes | No | Yes | Yes |
| Web UI | No | No | Yes (built-in) | Commercial only |
| Static binary | Yes (Go) | No (Python) | Yes (Go) | Yes (Go) |
| Maturity | High | Very High | Medium | Medium |
| Multi-backend sync | `restic copy` | Manual | Built-in | Built-in |
| Scheduling | External (cron) | Borgmatic | Built-in | Built-in |
| Community size | Large | Large | Growing | Small |
| License | BSD-2 | BSD-3 | Apache-2 | Dual (CLI: open) |

**Top Recommendation**: **Restic** — best balance of maturity, S3 support, encryption, and community. Kopia is a strong runner-up if built-in UI and scheduling are highly valued.

---

## 4. Storage Backend Evaluation

The requirement is 2+ independent storage backends for resilience. All should be S3-compatible for uniform tooling.

### Option A: Hetzner Storage Box / Object Storage

**Pros**:
- Cheapest EU option (~€0.006/GB/month for Storage Box, €0.005/GB for Object Storage)
- S3-compatible API (Object Storage) or SFTP/BorgBackup-native (Storage Box)
- GDPR-compliant, German jurisdiction
- Same provider as potential compute — low egress latency
- Object Storage: no egress fees within Hetzner network

**Cons**:
- Object Storage is relatively new (less mature than AWS/B2)
- Storage Box is SFTP/CIFS only — no S3 API (would require rclone bridge)
- Single jurisdiction (DE) — may want geographic diversity

**Verdict**: Object Storage for S3-compatible target. Excellent primary backend.

### Option B: Backblaze B2

**Pros**:
- Very cheap ($0.006/GB/month storage)
- S3-compatible API
- Free egress to Cloudflare (if integrated)
- US jurisdiction — geographic diversity
- Mature, reliable platform
- First 10 GB free
- Restic has native B2 support (both S3-compat and native API)

**Cons**:
- Egress fees outside Cloudflare bandwidth alliance ($0.01/GB)
- US jurisdiction (not ideal if GDPR-only preference)
- Occasionally slower cross-Atlantic transfers from EU

**Verdict**: Excellent secondary backend for geographic/provider diversity.

### Option C: Wasabi

**Pros**:
- Fixed pricing ($6.99/TB/month) — no egress fees
- S3-compatible API
- Multiple regions (US, EU, APAC)
- Predictable cost

**Cons**:
- 90-day minimum storage policy (deleted data still billed for 90 days)
- Have had occasional availability issues
- Less established than B2 or AWS

**Verdict**: Good for large media archives with predictable sizing. 90-day minimum is problematic for rapidly rotating snapshots.

### Option D: AWS S3 (or S3 Glacier)

**Pros**:
- Most mature, most durable (11 nines)
- Glacier tiers extremely cheap for long-term
- Global regions
- S3 API is the de facto standard

**Cons**:
- Expensive egress ($0.09/GB in most regions)
- Complex pricing tiers
- IAM complexity
- Overkill for small/medium sovereign setups

**Verdict**: Best durability, but cost/complexity overhead makes it a poor default for the blueprint. Users can opt-in.

### Option E: Minio Self-Hosted (on dedicated backup VM)

**Pros**:
- Fully self-hosted, zero external dependency
- S3-compatible API
- Can run on a cheap Hetzner VPS or ThreeFold VM
- Full control over data location and durability
- Useful as local/fast backup target alongside remote ones

**Cons**:
- Not a DR solution alone — same provider risk
- Requires management of the Minio host
- Disk durability depends on the VM provider
- Additional infrastructure cost and complexity

**Verdict**: Useful as a fast, local third target. Should NOT be the only target.

### Option F: Scaleway Object Storage

**Pros**:
- EU-based, GDPR-compliant (French jurisdiction)
- S3-compatible API
- 75 GB free tier
- Competitive pricing
- Geographic diversity from Hetzner (France vs Germany)

**Cons**:
- Smaller community presence
- Less tooling documentation specifically for Restic
- egress pricing can surprise at scale

**Verdict**: Good EU alternative to Hetzner for geographic distribution within EU.

### Recommended Backend Combination

| Target | Role | Provider | Why |
|---|---|---|---|
| **Primary** | Main backup target | Hetzner Object Storage | Cheapest, closest, GDPR, S3 API |
| **Secondary** | Disaster recovery | Backblaze B2 | Different provider, different continent, cheap |
| **Optional Tertiary** | Local fast restore | Self-hosted Minio (on backup VM) | Fast restores, no egress cost |

This gives: **2 providers, 2 jurisdictions, 2 continents** — any single failure (provider outage, legal seizure, region disaster) leaves at least one backup accessible.

---

## 5. Encryption & Key Management

### The "One Master Password" Design

The requirement is: the owner stores one master password (and the S3 bucket endpoints). With these two pieces of information, all backups for all environments and services can be unlocked even if the entire grid is down.

#### Option A: Single Restic Repository Password (Recommended for simplicity)

**Design**: One Restic repository password used across all repositories. Environments and services are separated by repository path, not by key.

```
Bucket structure:
  s3://backups/<env>/<service>/        ← one Restic repo per service per env
  s3://backups/prod/headscale/
  s3://backups/prod/vaultwarden/
  s3://backups/prod/matrix/
  s3://backups/test/headscale/
```

**What the owner stores offline**:
1. Master Restic repository password
2. S3 endpoint URLs (2 backends)
3. S3 access key + secret key (per backend)

That's 5 pieces of information total — fits on a single index card.

**Pros**:
- Truly single-password design
- Simple mental model
- Easy to script and automate
- If you have the password + bucket URL, you can restore anything

**Cons**:
- Compromise of the master password exposes ALL environments
- No compartmentalization between environments
- If the password is lost, ALL backups are lost

**Mitigation**: Print the password, store in a physical safe + a sealed envelope with a trusted person.

#### Option B: Per-Environment Restic Passwords Derived from Master Key

**Design**: A master passphrase is used with a KDF (HKDF or Argon2id) to derive per-environment passwords deterministically.

```
master_password = "my-sovereign-cloud-master-2026"
prod_password   = HKDF(master_password, salt="prod")
test_password   = HKDF(master_password, salt="test")
```

**What the owner stores offline**:
1. Master passphrase
2. The KDF salt scheme (documented in README: `env name`)
3. S3 credentials (same as Option A)

**Pros**:
- Single master password still
- Per-environment isolation — compromising one env's password doesn't expose others
- Deterministic — can regenerate derived passwords from master alone
- Better security posture for multi-tenant (company-a, company-b)

**Cons**:
- Slightly more complex to implement (needs a password derivation script)
- Must document the derivation scheme clearly — if the scheme is lost, passwords can't be regenerated
- Custom tooling needed (small script wrapping `openssl` or `python3`)

**Verdict**: Best for multi-tenant deployments (company-a, company-b). For single-owner with prod+test only, Option A is sufficient.

#### Option C: age-based Key Hierarchy

**Design**: Use [age](https://github.com/FiloSottile/age) to create a master identity. Per-environment keys are encrypted with the master key.

```
master-identity.age        ← owner keeps this offline
prod-restic-password.age   ← encrypted with master identity
test-restic-password.age   ← encrypted with master identity
s3-credentials.age         ← encrypted with master identity
```

**What the owner stores offline**:
1. `master-identity.age` file (or the key string)
2. The encrypted key files (can be stored in the repo safely!)

**Pros**:
- Encrypted key files can live in the git repo (fully safe)
- Master key is a single file/string
- age is a modern, audited, simple encryption tool
- Can add additional recipients (share backup access with a co-admin)
- File-based — naturally integrates with version control

**Cons**:
- More moving parts (age binary, key files, decrypt-before-use workflow)
- Must install age on restore machine
- Slightly higher cognitive load for non-technical operators

**Verdict**: Best for teams/co-admin scenarios. Overkill for solo operator but very clean design.

### Recommendation

**Default (solo operator, 1-3 envs)**: Option A — single Restic password.
**Multi-tenant / multi-company**: Option B — derived passwords from master.
**Teams with co-admins**: Option C — age key hierarchy.

The blueprint should implement Option A as default with a clear upgrade path to B or C documented.

---

## 6. Modular Service Integration

### The "Backup Manifest" Pattern

Each Ansible role declares its backup requirements via a standardized YAML structure. The backup system reads these manifests and executes accordingly.

#### Manifest Structure (proposed)

Each service role includes a `backup.yml` in its `defaults/` or `meta/` directory:

```yaml
# ansible/roles/<service>/defaults/backup.yml
backup:
  service_name: "headscale"
  
  # What to back up
  targets:
    - name: "state"
      type: "directory"
      path: "/var/lib/headscale"
      description: "Headscale database and state"
    
    - name: "config"
      type: "directory"
      path: "/etc/headscale"
      description: "Headscale configuration files"
    
    - name: "certs"
      type: "directory"
      path: "/opt/caddy/data"
      description: "TLS certificates and Caddy state"

  # Pre-backup hooks (e.g., database dump)
  pre_backup:
    - name: "dump-sqlite"
      command: "docker exec headscale sqlite3 /var/lib/headscale/db.sqlite3 '.backup /var/lib/headscale/db-backup.sqlite3'"
      description: "Create consistent SQLite dump"

  # Post-backup hooks (e.g., cleanup)
  post_backup:
    - name: "cleanup-dump"
      command: "rm -f /var/lib/headscale/db-backup.sqlite3"

  # Schedule override (optional, defaults to nightly)
  schedule: "daily"       # daily|hourly|weekly|custom cron expression
  
  # Retention override (optional, uses global defaults if omitted)
  retention:
    keep_daily: 7
    keep_weekly: 4
    keep_monthly: 12

  # Restore verification command
  restore_verify:
    command: "docker exec headscale headscale version"
    description: "Verify Headscale container starts with restored data"
    timeout: 60
```

#### How It Works

1. **Discovery**: A backup Ansible role scans all installed service roles for `backup.yml` manifests
2. **Registration**: Each discovered manifest is compiled into a global backup configuration on the host
3. **Execution**: A systemd timer (or cron) runs the backup wrapper script, which:
   - Iterates over registered services
   - Runs pre-backup hooks
   - Calls `restic backup` with the declared paths
   - Runs post-backup hooks
   - Reports success/failure
4. **Multi-target**: The wrapper runs `restic backup` once per configured backend (or uses `restic copy` after primary)

#### Adding a New Service

To add backup for a new service, the developer only needs to:

1. Create `ansible/roles/<service>/defaults/backup.yml` with the manifest
2. The backup system auto-discovers it on next Ansible run

No changes needed to the backup role itself. **Zero-touch integration.**

### Example Manifests for Various Data Types

#### Certificates & Private Keys
```yaml
backup:
  service_name: "tls-certs"
  targets:
    - name: "caddy-certs"
      type: "directory"
      path: "/opt/caddy/data"
    - name: "tailscale-keys"
      type: "directory"
      path: "/var/lib/tailscale"
  schedule: "daily"
```

#### PostgreSQL Database
```yaml
backup:
  service_name: "nextcloud-db"
  targets:
    - name: "pg-dump"
      type: "file"
      path: "/var/backups/nextcloud-db.sql.gz"
  pre_backup:
    - name: "pg-dump"
      command: "docker exec nextcloud-db pg_dumpall -U nextcloud | gzip > /var/backups/nextcloud-db.sql.gz"
  post_backup:
    - name: "cleanup"
      command: "rm -f /var/backups/nextcloud-db.sql.gz"
  schedule: "daily"
```

#### Large Media Storage (Immich / Photoserver)
```yaml
backup:
  service_name: "immich"
  targets:
    - name: "media"
      type: "directory"
      path: "/opt/immich/upload"
      exclude:
        - "thumbs/**"
        - "encoded-video/**"   # can be regenerated
    - name: "database"
      type: "file"
      path: "/var/backups/immich-db.sql.gz"
  pre_backup:
    - name: "pg-dump"
      command: "docker exec immich-db pg_dumpall -U immich | gzip > /var/backups/immich-db.sql.gz"
  schedule: "daily"
  retention:
    keep_daily: 7
    keep_weekly: 4
    keep_monthly: 6
```

#### Password Vault (Vaultwarden)
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
  schedule: "hourly"     # critical data → more frequent
  retention:
    keep_hourly: 24
    keep_daily: 30
    keep_weekly: 12
    keep_monthly: 24
```

#### Matrix (Synapse) with Media Store
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
  schedule: "daily"
```

#### Source Code (Forgejo/Gitea)
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
  schedule: "daily"
```

---

## 7. Multi-Environment Isolation

### Repository Path Strategy

Each environment gets its own Restic repository path within the same S3 bucket:

```
s3://sovereign-backups/
  ├── prod/
  │   ├── headscale/          ← Restic repo
  │   ├── vaultwarden/        ← Restic repo
  │   ├── matrix/             ← Restic repo
  │   └── ...
  ├── test/
  │   ├── headscale/
  │   └── ...
  ├── company-a/
  │   ├── headscale/
  │   └── ...
  └── company-b/
      ├── headscale/
      └── ...
```

### Isolation Levels

| Level | Description | Implementation |
|---|---|---|
| **Path isolation** | Different Restic repos per env | S3 prefix per env (`<env>/<service>/`) |
| **Credential isolation** | Per-env S3 credentials (optional) | Separate IAM users per env |
| **Bucket isolation** | Separate S3 buckets per env (optional) | Separate bucket per env |
| **Password isolation** | Per-env Restic password | Derived from master (Option B above) |

**Default**: Path isolation + single password (simplest).
**Multi-tenant**: Path isolation + per-env derived password + per-env S3 credentials.

### Ansible Integration

The environment name is already available as `--env <name>` in the deploy workflow. The backup role uses this to set the repository path:

```yaml
# Set at backup role level
backup_env: "{{ lookup('env', 'BLUEPRINT_ENV') | default('default') }}"
backup_s3_path: "{{ backup_s3_bucket }}/{{ backup_env }}/{{ backup_service_name }}"
```

---

## 8. Scheduling & Retention

### Scheduling Options

#### Option A: Systemd Timers (Recommended)

**Design**: Each backup job is a systemd timer + service unit, deployed by Ansible.

```ini
# /etc/systemd/system/backup-headscale.timer
[Unit]
Description=Nightly backup for Headscale

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
```

**Pros**:
- Native systemd logging (journald)
- Persistent=true catches missed runs (VM was down at scheduled time)
- RandomizedDelaySec avoids all services backing up simultaneously
- `systemctl list-timers` shows next/last run
- Integrates with monitoring (node_exporter systemd collector)

**Cons**:
- More files to template (timer + service per backup job)
- systemd-specific (won't work on non-systemd distros — not a real concern here)

#### Option B: Cron Jobs

**Pros**: Simple, universal, well-understood.
**Cons**: No persistent/catch-up, no native logging, no stagger support, harder to monitor.

#### Option C: Central Scheduler (dedicated container)

**Pros**: Single place to see all schedules, web UI possible.
**Cons**: Additional infrastructure, single point of failure, over-engineering.

**Recommendation**: Systemd timers — native, reliable, monitorable.

### Retention Policy

Default retention (configurable per-service via manifest):

| Tier | Keep | Rationale |
|---|---|---|
| Hourly | 24 | Only for critical services (Vaultwarden, mail) |
| Daily | 7 | One week of daily granularity |
| Weekly | 4 | One month of weekly granularity |
| Monthly | 12 | One year of monthly snapshots |
| Yearly | 2 | Two-year deep archive |

Executed via:
```bash
restic forget \
  --keep-hourly 24 \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 12 \
  --keep-yearly 2 \
  --prune
```

### Backup Execution Flow

```
Systemd timer fires
  └→ backup-<service>.sh
       ├→ Run pre_backup hooks (DB dumps, etc.)
       ├→ restic backup --tag <env> --tag <service> <paths...>  → Primary backend
       ├→ restic copy --from-repo <primary> --to-repo <secondary>  → Secondary backend
       ├→ restic forget --prune (both repos)
       ├→ Run post_backup hooks (cleanup)
       ├→ Write status to /var/lib/backup-status/<service>.json
       └→ On failure: send notification
```

---

## 9. Restore-on-Deploy (Auto-Restore)

### Design

When deploying a service (fresh VM or service re-add), the Ansible role should check for existing backups and offer/perform restore automatically.

#### Flow

```
Service role begins
  └→ Check: does a Restic snapshot exist for this env+service?
       ├→ YES: restore latest snapshot to service data directories
       │    └→ Run service-specific post-restore hooks
       │    └→ Continue with normal Ansible configuration (idempotent)
       └→ NO: fresh install (normal flow)
```

#### Ansible Implementation

```yaml
# In each service role's tasks/main.yml, prepend:
- name: "Check for existing backup"
  include_role:
    name: backup
    tasks_from: check_snapshot
  vars:
    backup_service_name: "headscale"

- name: "Restore from backup if snapshot exists"
  include_role:
    name: backup
    tasks_from: restore
  vars:
    backup_service_name: "headscale"
    backup_restore_paths:
      - { src: "/var/lib/headscale", dest: "/var/lib/headscale" }
      - { src: "/etc/headscale", dest: "/etc/headscale" }
  when: backup_snapshot_exists | default(false)
```

#### Safety Controls

- Restore only happens if the service data directory is empty (prevents clobbering running services)
- A `--no-restore` flag skips auto-restore (for intentional fresh starts)
- Restore is logged and reported in the deployment summary

---

## 10. Restore Drills & Automated Testing

### Design

Periodic automated drills that verify backups can actually be restored. Results are monitored and alertable.

#### Drill Types

| Type | Frequency | What It Tests |
|---|---|---|
| **Integrity check** | Weekly | `restic check` — verifies repo consistency |
| **File restore** | Weekly | Restore latest snapshot to temp dir, verify file count/checksums |
| **Full service restore** | Monthly | Spin up ephemeral container, restore data, verify service starts |

#### Integration with Test Suite

New test script: `scripts/tests/80_verify_backup_restore.sh`

```bash
#!/usr/bin/env bash
# Test: Backup & Restore Drill
# For each backed-up service:
#   1. Verify Restic repo is accessible
#   2. Verify latest snapshot exists and is recent (< 25 hours)
#   3. Restore to temp directory
#   4. Verify restored files are non-empty and match expected structure
#   5. Run service-specific verify command if defined
```

#### Restore Drill Scheduling

- Repository integrity check: weekly systemd timer
- File restore drill: weekly (different day than integrity check)
- Full service drill: monthly or on-demand via `./scripts/deploy.sh restore-drill --env prod`

#### Alerting on Drill Failure

If any drill fails → email notification (same mechanism as backup failure alerts).

---

## 11. Notification & Alerting

### Option A: Direct SMTP Email (Recommended as primary)

**Design**: Backup scripts send email directly via `msmtp` or `sendmail` on failure.

**Pros**:
- Works even if monitoring stack is down
- Simple to configure (SMTP credentials in Ansible vars)
- No dependency on other services

**Cons**:
- Requires SMTP credentials configured
- Email deliverability can be an issue (SPF, DKIM)

**Implementation**:
- Install `msmtp` via common role
- Configure with SMTP credentials (e.g., Mailgun, Fastmail, or self-hosted Stalwart)
- Backup script sends email on non-zero exit

### Option B: Prometheus Alertmanager (Recommended as secondary)

**Design**: Backup scripts expose metrics; Prometheus alerts on stale/failed backups.

**Pros**:
- Integrates with existing monitoring stack (already deployed)
- Rich alerting rules (backup age, size anomalies, etc.)
- Can route to email, Matrix, Slack, etc.

**Cons**:
- If monitoring VM is down, alerts don't fire
- More complex setup

**Implementation**:
- Backup wrapper writes a `node_exporter` textfile metric:
  ```
  backup_last_success_timestamp{service="headscale",env="prod"} 1710288000
  backup_last_size_bytes{service="headscale",env="prod"} 52428800
  backup_last_duration_seconds{service="headscale",env="prod"} 42
  backup_last_status{service="headscale",env="prod"} 1
  ```
- Prometheus alert rule: `backup_last_success_timestamp < (time() - 90000)` → fire alert
- Alertmanager routes to email

### Option C: Matrix/Webhook Notification

**Design**: Send backup status to a Matrix room or generic webhook.

**Pros**:
- Real-time notifications
- Can use self-hosted Matrix (eat your own dog food)

**Cons**:
- Depends on Matrix being up
- Circular: Matrix backup failure notification sent via... Matrix?

**Recommendation**: 
- **Primary**: Direct SMTP email (works independently)
- **Secondary**: Prometheus + Alertmanager metrics (richer monitoring)
- **Optional**: Matrix webhook for real-time visibility (non-critical path)

---

## 12. Backup Monitoring UI

### Option A: Backrest (Recommended)

**Description**: Purpose-built web UI for Restic repositories. Open source (GPL-3.0).

**Features**:
- Browse Restic snapshots visually
- See backup sizes, timestamps, retention status
- Trigger manual backups and restores from the UI
- View backup logs and errors
- Multiple repository support
- Docker deployment

**Pros**:
- Purpose-built for Restic — perfect integration
- Active development (started 2023, growing community)
- Light resource footprint
- Docker-native — fits existing deployment pattern
- Shows exactly what the user wants: what's backed up, size, status

**Cons**:
- Relatively new project
- Must be exposed only on Tailnet (security)
- Read-write access to Restic repos (must be secured)

**Deployment**: Run on monitoring VM, accessible only via Tailscale IP.

```yaml
# Docker compose snippet
backrest:
  image: garethgeorge/backrest:latest
  volumes:
    - /opt/backrest/config:/config
    - /opt/backrest/data:/data
    - /opt/backrest/cache:/cache
  ports:
    - "<tailscale_ip>:9898:9898"
  restart: unless-stopped
```

### Option B: Custom Grafana Dashboard

**Design**: Add backup metrics to the existing Grafana instance via Prometheus.

**Pros**:
- No additional software — uses existing monitoring stack
- Customizable dashboards
- Alerting built-in
- Already on the Tailnet

**Cons**:
- Only shows metrics (timestamps, sizes), not snapshot contents
- Can't browse/restore from the UI
- Requires custom dashboard creation

**Implementation**: Export textfile metrics from backup scripts → Prometheus scrapes → Grafana dashboard.

### Option C: Kopia Server (if using Kopia as backup tool)

**Pros**: Built-in web UI with full snapshot management, native to the tool.
**Cons**: Ties UI to backup tool choice. If using Restic, this is not available.

### Option D: MinIO Console (if using self-hosted MinIO)

**Pros**: Shows raw bucket contents, storage usage.
**Cons**: Shows raw S3 objects, not Restic snapshots — useless for understanding backup status.

### Recommendation

**Deploy both**:
1. **Backrest** — for interactive snapshot browsing, manual backup/restore (on monitoring VM, Tailnet-only)
2. **Grafana dashboard** — for at-a-glance metrics, alerting, historical trends (already deployed)

This gives the owner:
- Grafana: "At a glance — is everything OK? Any alerts?"
- Backrest: "Let me browse the snapshots, check sizes, trigger a restore"

---

## 13. Data Type Considerations

Different data types have different backup characteristics:

| Data Type | Examples | Size | Change Rate | Backup Strategy |
|---|---|---|---|---|
| **Configuration** | Headscale config, Caddy config, Ansible vars | Small (KB) | Low | Daily, keep many versions |
| **Certificates & Keys** | TLS certs, Tailscale keys, SSH keys | Small (KB) | Very low | Daily, critical to restore |
| **SQLite Databases** | Headscale DB, Vaultwarden | Small-Medium (MB) | Medium | Pre-hook `.backup`, daily/hourly |
| **PostgreSQL Databases** | Nextcloud, Matrix, Forgejo, Immich | Medium (MB-GB) | Medium-High | Pre-hook `pg_dumpall`, daily |
| **Media Files** | Immich photos, Matrix media, avatars | Large (GB-TB) | Append-mostly | Daily, exclude regenerable thumbnails |
| **Source Code Repos** | Forgejo repositories (bare git) | Medium-Large (GB) | Medium | Daily, git bundles or direct |
| **Password Vaults** | Vaultwarden data | Small (MB) | Medium | Hourly, highest criticality |
| **Email** | Stalwart mail storage | Medium-Large (GB) | High | Daily, consider IMAP-level backup |
| **Documents** | Paperless-ngx, Nextcloud files | Medium-Large (GB) | Medium | Daily, standard file backup |

### Restic Handles All of These

Restic's content-addressable deduplication naturally handles all types:
- Small config files: minimal incremental cost
- Databases: daily dumps deduplicate well (most data unchanged between dumps)
- Large media: only new/changed files uploaded on incremental backup
- Append-only data (git repos, mail): excellent dedup efficiency

### Special Cases

1. **Large media stores (Immich, photos)**: Consider `--exclude` for regenerable content (thumbnails, transcoded video). Document estimated storage ratios.

2. **PostgreSQL with WAL archiving**: For large, heavily-written databases, consider enabling WAL archiving to an S3 bucket for point-in-time recovery. This is an advanced feature, not default.

3. **Git repositories**: Restic handles bare repos well. Alternative: `git bundle` per repo for compact transport. Restic is simpler and sufficient.

4. **Encrypted vaults (Vaultwarden)**: Already encrypted at application level. Restic adds a second encryption layer. This is fine — belt and suspenders.

---

## 14. Recommended Architecture

### High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      ANSIBLE BACKUP ROLE                    │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  Headscale   │  │ Vaultwarden  │  │    Matrix     │ ... │
│  │ backup.yml   │  │ backup.yml   │  │ backup.yml   │      │
│  │  manifest    │  │  manifest    │  │  manifest    │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         └──────────────────┼──────────────────┘             │
│                            ▼                                │
│              ┌──────────────────────┐                       │
│              │   Backup Wrapper     │                       │
│              │   (shell script)     │                       │
│              │                      │                       │
│              │  1. Pre-hooks        │                       │
│              │  2. restic backup    │──────→ Metrics file   │
│              │  3. restic copy      │        (node_exporter)│
│              │  4. restic forget    │                       │
│              │  5. Post-hooks       │                       │
│              │  6. Status/notify    │                       │
│              └──────────┬───────────┘                       │
│                         │                                   │
│              ┌──────────┴───────────┐                       │
│              │   Systemd Timers     │                       │
│              │  (per-service)       │                       │
│              └──────────────────────┘                       │
└─────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
┌──────────────────┐          ┌──────────────────┐
│ Hetzner Object   │          │  Backblaze B2    │
│ Storage (S3)     │          │  (S3-compat)     │
│                  │          │                  │
│ /<env>/<service> │          │ /<env>/<service> │
│  Restic repos    │          │  Restic repos    │
└──────────────────┘          └──────────────────┘

    PRIMARY target              SECONDARY target
    (EU, fast)                  (US, disaster recovery)


┌─────────────────────────────────────────────────────────────┐
│                    MONITORING & UI                           │
│                                                             │
│  ┌──────────────┐     ┌──────────────┐    ┌──────────────┐ │
│  │  Grafana     │     │  Prometheus  │    │   Backrest   │ │
│  │  Dashboard   │◀────│  Metrics     │    │   Web UI     │ │
│  │  (overview)  │     │              │    │  (snapshots) │ │
│  └──────────────┘     └──────────────┘    └──────────────┘ │
│         │                                                   │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │ Alertmanager │──→ Email notification on failure          │
│  └──────────────┘                                          │
└─────────────────────────────────────────────────────────────┘
    All on monitoring VM, accessible only via Tailscale
```

### Component Summary

| Component | Choice | Rationale |
|---|---|---|
| **Backup tool** | Restic | Mature, encrypted, S3-native, deduplicated, static binary |
| **Primary storage** | Hetzner Object Storage | Cheapest, EU, GDPR, S3 API |
| **Secondary storage** | Backblaze B2 | Different provider + continent |
| **Encryption** | Restic built-in (single master password) | Simple, owner stores one password |
| **Scheduling** | Systemd timers | Reliable, monitorable, catch-up on missed runs |
| **Service integration** | YAML backup manifests in roles | Modular, zero-touch for new services |
| **Multi-environment** | S3 path prefix per env | Simple isolation, shared infrastructure |
| **Auto-restore** | Check-and-restore in Ansible roles | New deploys recover from backup by default |
| **Notification** | msmtp email + Prometheus alertmanager | Independent primary + rich secondary |
| **Monitoring UI** | Grafana dashboard + Backrest | At-a-glance + deep inspection |
| **Restore drills** | Automated test scripts + systemd timers | Weekly integrity + monthly full drill |

### What the Owner Stores Offline

An index card or sealed envelope containing:

```
SOVEREIGN CLOUD BACKUP ACCESS
==============================
Restic master password: <password>

Primary backup:
  Endpoint: https://hel1.your-objectstorage.com
  Bucket:   sovereign-backups
  Access:   <key>
  Secret:   <secret>

Secondary backup:
  Endpoint: https://s3.us-west-002.backblazeb2.com
  Bucket:   sovereign-backups-dr
  Access:   <key>  
  Secret:   <secret>

Environments: prod, test
Path format:  <bucket>/<env>/<service>/

To restore:
  restic -r s3:https://hel1.your-objectstorage.com/sovereign-backups/prod/headscale snapshots
  restic -r s3:https://hel1.your-objectstorage.com/sovereign-backups/prod/headscale restore latest --target /
```

**That's it.** One password, two S3 endpoints, two credential pairs. Everything else is recoverable.

---

## 15. Implementation Roadmap

### Phase 1: Foundation (Week 1)

- [ ] Create `ansible/roles/backup/` role
- [ ] Implement Restic installation task
- [ ] Implement S3 backend configuration (from Ansible vars)
- [ ] Implement single-service backup wrapper script
- [ ] Create backup manifests for existing services (headscale, monitoring, gateway)
- [ ] Add global backup variables to `group_vars/all/main.yml`
- [ ] Test: backup and restore of Headscale state

### Phase 2: Multi-Target & Scheduling (Week 2)

- [ ] Add `restic copy` to secondary backend
- [ ] Implement systemd timer generation from manifests
- [ ] Implement retention policy enforcement
- [ ] Add backup status metrics (node_exporter textfile)
- [ ] Test: verify both backends receive data

### Phase 3: Auto-Restore & Notifications (Week 3)

- [ ] Implement `check_snapshot` and `restore` tasks in backup role
- [ ] Integrate auto-restore into headscale and monitoring roles
- [ ] Implement msmtp notification on backup failure
- [ ] Add Prometheus alert rules for stale backups
- [ ] Test: destroy and redeploy with auto-restore

### Phase 4: Restore Drills & UI (Week 4)

- [ ] Create `scripts/tests/80_verify_backup_restore.sh`
- [ ] Implement weekly integrity check timer
- [ ] Deploy Backrest on monitoring VM
- [ ] Create Grafana backup dashboard
- [ ] Add restore drill to deployment checklist
- [ ] Test: end-to-end restore drill passes

### Phase 5: Documentation & Hardening (Week 5)

- [ ] Write operator backup runbook section
- [ ] Document "offline index card" contents
- [ ] Document per-service restore procedures
- [ ] Security review of backup credentials handling
- [ ] Add backup section to deployment summary output

---

## Appendix A: Alternative Architectures Considered

### A1: Pull-Based Backup (Dedicated Backup VM)

**Design**: A dedicated backup VM pulls data from all service VMs via SSH/rsync over Tailscale, then pushes to S3.

**Pros**: Centralized scheduling, compromised service VM can't delete backups.
**Cons**: Requires additional VM, SSH credentials distribution, more complex Ansible, higher cost.
**Verdict**: Good for larger deployments (10+ VMs). Over-engineering for the blueprint's current scale.

### A2: Agent-Based Backup (Velero/K8s-style)

**Design**: Each VM runs a backup agent that reports to a central controller.

**Pros**: Modern, fits microservices patterns.
**Cons**: Requires controller infrastructure, more complex, assumes Kubernetes (which this blueprint does not use).
**Verdict**: Wrong paradigm for VM-based deployments.

### A3: Filesystem-Level Snapshots (ZFS/Btrfs)

**Design**: Use ZFS or Btrfs snapshots for instant, consistent backups, then replicate snapshots to remote.

**Pros**: Instant snapshots, filesystem-level consistency, no application hooks needed.
**Cons**: Requires specific filesystem (not available on all providers), replication to S3 requires additional tooling, ThreeFold VMs use ext4.
**Verdict**: Excellent if available, but not portable across providers. Could be an optional enhancement.

---

## Appendix B: Cost Estimates

### Storage Costs (per environment)

Assuming a moderate deployment: Headscale (50 MB) + monitoring configs (100 MB) + Vaultwarden (200 MB) + Nextcloud (10 GB) + Matrix (5 GB) + Immich photos (50 GB) = ~65 GB raw data.

With Restic deduplication, incremental growth is ~5-10% of raw per month.

| Backend | Monthly Storage (65 GB) | Monthly Storage (200 GB) | Notes |
|---|---|---|---|
| Hetzner Object Storage | ~€0.39 | ~€1.20 | €0.006/GB |
| Backblaze B2 | ~$0.39 | ~$1.20 | $0.006/GB |
| **Total (2 backends)** | **~€0.78** | **~€2.40** | |

Egress costs (restore events only):
- Hetzner: Free within Hetzner network, €0.01/GB external
- B2: $0.01/GB (free via Cloudflare)

**Bottom line**: Backup storage for a full sovereign setup costs less than €3/month.
