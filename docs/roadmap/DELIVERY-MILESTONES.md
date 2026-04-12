# Delivery Milestones (Published Plan)

This document is the public milestones and deliverables plan for roadmap
execution and progress tracking.

It is intentionally separated from private funding strategy notes and focuses on
what will be delivered, how it will be verified, and which artifacts will be
published in the open-source repository.

## Scope and Delivery Window

- Target window: 3 to 4 months
- Target scope band: baseline reliability, security, and operator usability
- Focus: reproducibility, security hardening, and operator usability for
  sovereign self-hosted infrastructure

## Milestone 1: Reproducible Quality Gates (Weeks 1-3)

### Deliverables

- Public CI workflows for Terraform validation, UI tests, and local static
  integration suites
- Stable verification entry points documented for contributors
- Public verification matrix in docs

### Acceptance Criteria

- CI runs on pull requests and pushes to main
- CI passes with no cloud credentials and no deployed infrastructure
- The same checks can be reproduced locally from a clean checkout

### Verification

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
python3 -m unittest discover -s ui/tests
./scripts/tests/run.sh static-gateway
./scripts/tests/run.sh dashboard-json
./scripts/tests/run.sh dns-helper-local
```

### Public Artifacts

- `.github/workflows/ci.yml`
- Updated contributor and docs references

## Milestone 2: Security and Recovery Baseline Proof (Weeks 4-7)

### Deliverables

- Machine-runnable security baseline checks (public exposure expectations,
  secret-handling guardrails, and policy sanity checks)
- Recovery and backup verification improvements with clear pass/fail output
- Updated operations runbook mapping checks to expected outputs

### Acceptance Criteria

- Security baseline command reports deterministic PASS/FAIL results
- Recovery verification suite runs without manual edits to scripts
- Security/recovery checks are referenced in operations docs and CI where
  feasible

### Verification

```bash
./scripts/tests/run.sh backup-verify
./scripts/tests/run.sh portable-recovery
```

### Public Artifacts

- New or extended verification scripts under `scripts/tests/`
- Documentation updates under `docs/technical/OPERATIONS.md`

## Milestone 3: Public Documentation Coherence and Evaluator Path (Weeks 8-10)

### Deliverables

- Single evaluator path from README to architecture, operations, and tests
- Removal of stale "stub/placeholder" wording for shipped features
- Explicit "how to validate" section for external reviewers

### Acceptance Criteria

- Public docs consistently describe shipped behavior
- No contradiction between docs and implementation for core deploy/recovery
  paths
- A new evaluator can follow docs and run non-destructive validation without
  private context

### Verification

```bash
./scripts/tests/run.sh static-gateway
./scripts/tests/run.sh dashboard-json
python3 -m unittest discover -s ui/tests
```

### Public Artifacts

- README and docs map updates
- Changelog entries for all user-visible documentation and workflow changes

## Milestone 4: Release-Ready Baseline (Weeks 11-14)

### Deliverables

- Release candidate tag with validated checks and updated changelog
- Operator runbook for repeatable deploy, verify, and restore workflows
- Risk and rollback notes for major operational changes

### Acceptance Criteria

- Release checklist completed with evidence for each verification item
- Version and changelog aligned with delivered scope
- No critical open issue in the milestone scope

### Verification

```bash
./scripts/tests/run.sh bootstrap-smoke
./scripts/tests/run.sh tailnet-management
```

### Public Artifacts

- Tagged release notes
- Updated `CHANGELOG.md` and `VERSION`

## Reporting Cadence

- Biweekly public progress update in changelog-style format
- End-of-milestone summary with:
  - completed deliverables
  - verification output summary
  - known limitations and next steps
