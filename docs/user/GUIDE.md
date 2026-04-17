# Privalon — User Guide

This is the main user-facing entry point for the blueprint. Read it as documentation for operating a private digital ecosystem rather than launching one isolated app: the infrastructure layer, operational guardrails, service model, and lower-friction local web UI path that let you add private services over time without re-solving backup, restore, DNS, TLS, monitoring, and security boundaries from scratch.

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

The repo separates product framing from setup steps and from recovery detail so readers can understand the operating contract first: not merely "self-host this service," but "operate a growing set of private services with a coherent recovery, security, and observability model." After that, setup and runbook material is easier to evaluate in the right context.
