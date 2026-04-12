# Privalon — User Guide

This is the main user-facing entry point for the blueprint. It now acts as a smaller hub that points to focused documents by topic instead of keeping all user guidance in one large file.

For technical implementation and operator workflows, see:
- [Docs index](../README.md)
- [Architecture](../technical/ARCHITECTURE.md)
- [Operations runbook](../technical/OPERATIONS.md)
- [Backup architecture](../technical/BACKUP.md)

## Read this in order

1. [Concept](CONCEPT.md) for the product idea, vision, security posture, operating model, and intended audience.
2. [Getting started](GETTING-STARTED.md) for what the blueprint deploys, what you get, quick-start flows, access patterns, and verification.
3. [Deployment and configuration](DEPLOYMENT.md) for environment setup, deploy scopes and flags, TLS choices, node selection, and tailnet joins.
4. [Backup and recovery](BACKUP-RECOVERY.md) for the portable recovery bundle, service backups, restore paths, and owner recovery material.
5. [Troubleshooting](TROUBLESHOOTING.md) for common failure cases and quick fixes.

## Suggested reader paths

- New evaluator: start with [Concept](CONCEPT.md), then [Getting started](GETTING-STARTED.md).
- First deployment: read [Getting started](GETTING-STARTED.md), then [Deployment and configuration](DEPLOYMENT.md).
- Day-2 operator: keep [Backup and recovery](BACKUP-RECOVERY.md) and [Troubleshooting](TROUBLESHOOTING.md) close.

## Why the split

The repo now separates product framing from setup steps and from recovery detail. That makes it easier for readers to understand what the blueprint is trying to achieve before they dive into configuration and operational specifics.
