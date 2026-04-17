# Backup and Recovery

This document covers the two recovery layers in the blueprint:

- the portable control-plane recovery bundle used to rebuild the local operator workspace
- service-data backups handled through Restic and dual S3-compatible backends

In the product model, this is not optional hardening. Backup and recovery are part of the default operating contract: restore confidence should exist before the first incident.

## Portable recovery bundle

When `backup_enabled: true` and two backup backends are configured, each successful `full`, `gateway`, or `control` deploy refreshes a portable control-plane recovery bundle.

The bundle contains the environment files and local state needed to rebuild the operator workspace for a single environment.

The bundle also records the environment data-model version. During deploy and restore, the blueprint migrates older `environments/<env>/` layouts forward to the current supported schema.

The recovery line is the stable break-glass secret for reaching that bundle. Normal deploys keep updating the bundle in S3; they do not keep rotating the line.

### What to store offline

Store exactly one thing from the deployment summary:

1. the opaque `bp1...` recovery line

The current line is also written locally to `environments/<env>/.recovery/latest-recovery-line`, but the intended workflow is to keep the printed recovery line in an offline password manager, secure note, or physical recovery card.

Treat it like a seed phrase for the operator workspace:

- save it when the deploy summary first prints it
- keep using the same saved line for normal deploys and fresh-machine recovery
- only replace it if the deploy summary explicitly tells you the recovery line changed

### Restore on a fresh machine

From a macOS or Linux machine with this repo checked out:

```bash
./scripts/restore.sh --recovery-line '<opaque-line>'
```

The restore flow:

1. decodes the recovery line
2. uses the embedded backup-storage credentials to try the primary backend and then the secondary backend
3. downloads and decrypts the latest bundle
4. recreates the environment files and local state
5. applies pending environment data-model migrations
6. prints the recommended next `deploy.sh` command without running it automatically

Use this flow to recover the operator workspace. Service-data recovery is handled separately through Restic.

Automatic migrations cover blueprint-managed environment files such as `secrets.env`, `terraform.tfvars`, `group_vars/`, and `inventory/`. They do not migrate service-internal application data.

## Service-data backups

The blueprint includes encrypted Restic-based backups with dual S3-compatible backends for redundancy.

### How it works

- nightly at `02:00 UTC` by default, with randomized jitter
- encrypted with the Restic password
- deduplicated after the first full backup
- replicated to both configured backends
- used automatically for restore-aware redeploys when a fresh VM has empty data directories

### What is backed up

| Service | Data | VM |
|---------|------|----|
| Headscale | SQLite database, config, Headplane config | control |
| Gateway | Caddy certificates and config | gateway |
| Monitoring | Prometheus data and Grafana dashboards | monitoring |
| Tailscale | Node identity and keys in `/var/lib/tailscale` | all VMs |

## S3 backend setup

Two backends are required when `backup_enabled: true`.

### Primary backend — AWS S3

1. create an S3 bucket
2. create an IAM user with minimal bucket permissions
3. create an access key for that user
4. place the key pair into `secrets.env`

Example secrets:

```bash
BACKUP_S3_PRIMARY_ACCESS_KEY=AKIA...
BACKUP_S3_PRIMARY_SECRET_KEY=wJal...
```

### Secondary backend — Hetzner Object Storage

1. create an Object Storage bucket
2. generate S3 credentials
3. place the key pair into `secrets.env`

Example secrets:

```bash
BACKUP_S3_SECONDARY_ACCESS_KEY=...
BACKUP_S3_SECONDARY_SECRET_KEY=...
```

The deploy fails when backups are enabled but the secondary backend is missing or cannot be initialized.

### Custom endpoints and bucket names

Endpoints and bucket names live in `group_vars/all.yml`.

```yaml
backup_backends:
  - name: "primary"
    type: "s3"
    endpoint: "https://s3.eu-central-1.amazonaws.com"
    bucket: "myproject-backups"
    access_key: "{{ lookup('env', 'BACKUP_S3_PRIMARY_ACCESS_KEY') }}"
    secret_key: "{{ lookup('env', 'BACKUP_S3_PRIMARY_SECRET_KEY') }}"
  - name: "secondary"
    type: "s3"
    endpoint: "https://hel1.your-objectstorage.com"
    bucket: "myproject-backups-dr"
    access_key: "{{ lookup('env', 'BACKUP_S3_SECONDARY_ACCESS_KEY') }}"
    secret_key: "{{ lookup('env', 'BACKUP_S3_SECONDARY_SECRET_KEY') }}"
```

## Enable backups

After both backends are configured in `secrets.env`, enable backups in `group_vars/all.yml`:

```yaml
backup_enabled: true
```

Then converge or deploy:

```bash
./scripts/deploy.sh full --env prod --no-destroy
```

If Backrest opens but repository cards stay at `0 B` or the trees spin forever, re-run the deploy and verify that `/opt/backrest/config/config.json` contains a non-empty `instance` field and repository entries with either `guid` or `autoInitialize`.

## Restic password

`RESTIC_PASSWORD` in `secrets.env` is the master encryption key for the service-data backups.

Lost password means lost backups. Store it separately in a password manager and in the owner recovery material.

## Retention and schedule

Default retention:

| Period | Kept |
|--------|------|
| Hourly | 24 |
| Daily | 7 |
| Weekly | 4 |
| Monthly | 12 |
| Yearly | 2 |

Example overrides:

```yaml
backup_retention_keep_daily: 14
backup_retention_keep_monthly: 6
backup_schedule: "*-*-* 03:00:00"
```

## Monitoring backup health

Use one or more of the following:

- Grafana dashboard: `Backup Overview`
- Backrest UI on the monitoring path
- Prometheus alerts such as `BackupFailed`, `BackupStale`, `BackupSizeAnomaly`, and `BackupDrillFailed`

## Auto-restore on deploy

When a VM is rebuilt and its data directories are empty, services automatically restore from the latest backup snapshot. That makes destroy-and-recreate a viable recovery path.

Skip automatic restore with:

```bash
./scripts/deploy.sh full --env prod --no-restore
```

## Owner recovery card

Keep these items securely outside the live workspace:

1. the current `bp1...` recovery line
2. the Restic master password
3. primary S3 endpoint, bucket, access key, and secret key
4. secondary S3 endpoint, bucket, access key, and secret key

Use the recovery line for workspace recovery and the Restic credentials for direct service-data recovery.

See [Backup architecture](../technical/BACKUP.md) for the technical backup implementation details.

## Verification

```bash
./scripts/tests/run.sh backup-verify
./scripts/tests/run.sh portable-recovery
```

These checks verify backup tooling, scheduling, metrics, dashboards, and portable recovery behavior.