# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this repository now follows Semantic Versioning at the repo level.

## [Unreleased]

## [1.13.52] — 2026-04-17

### Fixed
- **`scripts/deploy.sh`**: Exported `DEPLOY_SCOPE` from `main` before helper execution so `wait_for_ssh` can reliably detect `full|control` scope and wait for control SSH in converge (non-destructive) runs. This fixes cases where deploy logs showed only gateway wait and then failed immediately on `control-vm` with port 22 `Connection refused`.

## [1.13.51] — 2026-04-17

### Documentation
- **`docs/user/DEPLOYMENT.md`** + **`docs/user/BACKUP-RECOVERY.md`**: Normalized heading style for clearer, consistent document titles.
- **`docs/user/TROUBLESHOOTING.md`**: Tightened the opening description for readability while preserving the same recovery-first meaning.
- **`docs/technical/OPERATIONS.md`**: Standardized product naming in service-extension guidance (`Vaultwarden`).
- **`docs/roadmap/forgejo-first-service-spec.md`**: Clarified status as a historical design spec and added an explicit note to use user/technical docs as the source of truth for current shipped behavior.

## [1.13.50] — 2026-04-17

### Fixed
- **`scripts/deploy.sh`**: Public SSH preflight now fails fast after a bounded timeout (`SSH_WAIT_TIMEOUT_SECONDS`, default `180`) instead of warning and continuing into Ansible with unreachable hosts.
- **`scripts/deploy.sh`**: Destructive pre-destroy backup now skips immediately when hosts are unreachable, so destroy/recreate proceeds without spending extra time on impossible backup attempts.
- **`scripts/deploy.sh`**: Added a bounded Ansible reachability probe timeout (`ANSIBLE_PING_TIMEOUT_SECONDS`, default `30`) so pre-destroy connectivity checks cannot stall.

### Documentation
- **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/user/GETTING-STARTED.md`** + **`docs/user/DEPLOYMENT.md`** + **`docs/user/BACKUP-RECOVERY.md`** + **`docs/user/TROUBLESHOOTING.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`** + **`docs/technical/BACKUP.md`** + **`ui/README.md`**: Cleaned and aligned framing language around the concept model: private-by-default operations, minimal public exposure, built-in observability, restore confidence, and repeatable low-improvisation day-2 workflows.

## [1.13.49] — 2026-04-17

### Fixed
- **`scripts/deploy.sh`**: Full and control deploy scopes now wait for control VM public SSH readiness (in addition to gateway) before starting Ansible when Tailscale transport is not active yet. This prevents early `UNREACHABLE` failures like `control-vm ... port 22: Connection refused` right after Terraform apply.

## [1.13.48] — 2026-04-17

### Fixed
- **`ansible/roles/observability/tasks/main.yml`**: Reworked Loki log-shipping derivation to tolerate control-only/partial Ansible runs. Missing `monitoring-vm` Tailscale IP now emits a warning and skips Alloy log-shipping tasks for that run instead of hard-failing the entire deployment during bootstrap.

### Added
- **`scripts/tests/17_verify_observability_guard_static.sh`** + **`scripts/tests/run.sh`**: Added a static regression check (`static-observability` suite) to ensure the observability role keeps the log-shipping guard and does not reintroduce a hard failure on missing `monitoring-vm` Tailscale IP.

### Documentation
- **`docs/user/TROUBLESHOOTING.md`** + **`docs/technical/OPERATIONS.md`**: Documented expected behavior and recovery guidance for temporary log-shipping skips during control-only or partial deploy passes.

## [1.13.47] — 2026-04-16

### Changed
- **`ansible/roles/backup/tasks/deploy.yml`**: Fixed backup manifest-to-host matching so workload service groups such as `forgejo` are treated as backup-bearing host services. This allows Forgejo backup configs, wrapper scripts, cron jobs, and initial snapshots to deploy on workload VMs instead of being silently skipped.

## [1.13.46] — 2026-04-15

### Added
- **Forgejo first-service implementation**: Added a new `forgejo` workload role with tailnet-only defaults, containerized runtime, optional admin bootstrap from environment secrets, and explicit bind behavior that keeps the service VM private.
- **Service runtime/visibility contract**: Added `service_catalog` as a shared config map for per-service `enabled`, `runtime` (`docker|ansible|plain`), and `visibility` (`internal|external|both`) selection.
- **Service integration manifests**: Added Forgejo `defaults/service_integration.yml`, `defaults/backup.yml`, and `defaults/observability.yml` so the service is wired into backup and observability pipelines from day one.

### Changed
- **`ansible/playbooks/site.yml`**: Added service-catalog schema validation, optional workload-role execution based on service catalog entries, dynamic internal DNS alias generation, and persisted compiled service catalog metadata under `environments/<env>/inventory/service-catalog.json`.
- **`ansible/inventory/tfgrid.py`**: Dynamic inventory now creates one host group per workload key, enabling generic host-group targeting for future service roles.
- **`ansible/roles/gateway`** + **`ansible/roles/monitoring`**: Internal and external routing now derive effective service routes from `service_catalog` in addition to existing static/legacy inputs, while preserving existing TLS-mode behavior.
- **`scripts/helpers/deployment-summary.sh`**: Deployment summary now surfaces configured workload services (runtime, visibility, and derived internal/external URLs) from the compiled service catalog artifact.

### Documentation
- **`docs/user/DEPLOYMENT.md`** + **`environments/example/group_vars/all.yml`** + **`environments/example/terraform.tfvars.example`**: Added operator-facing examples for service selection, runtime choice, visibility mode, and optional Forgejo workload definition.

### Testing
- **`scripts/tests/test_gateway_caddy_template.py`**: Added and updated coverage for dynamic internal route rendering and preserved public-routing behavior under the new derived route model.

## [1.13.45] — 2026-04-13

### Documentation
- **`docs/README.md`**: Removed the stale duplicated legacy quick-start/reference block that had drifted past the docs index section, fixed the "Digital Sovereignty" heading typo, and expanded the "What you get" overview so the docs landing page matches the currently shipped platform capabilities more accurately.

## [1.13.44] — 2026-04-13

### Changed
- **`scripts/helpers/recovery_bundle.py`** + **`scripts/helpers/deployment-summary.sh`** + **`scripts/restore.sh`**: Changed the portable recovery model from a rotating per-deploy recovery line to a stable recovery line that reuses the same offline secret across normal deploys while still refreshing the encrypted control-plane bundle on every successful deploy. The bundle-specific decrypt password now lives in the per-backend `latest.json` recovery pointer in backup storage, and the deployment summary only reprints the recovery line when it is first created or when recovery-backend settings change.

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/GETTING-STARTED.md`** + **`docs/user/BACKUP-RECOVERY.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Updated the portable recovery docs to describe the seed-like workflow accurately: store the recovery line offline once, keep refreshing bundles in backup storage after each deploy, and replace the line only when the recovery configuration changes.

### Testing
- **`scripts/tests/90_verify_portable_recovery_bundle.sh`** + **`ui/tests/test_deploy_cli.py`**: Added regression coverage for stable recovery-line reuse across normal refreshes, bundle passwords stored in `latest.json`, and deployment summary output that suppresses reprinting an unchanged recovery line.

## [1.13.43] — 2026-04-12

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/CONCEPT.md`** + **`docs/user/GUIDE.md`** + **`ui/README.md`**: Clarified that the local web UI is the lower-friction path for operators who are not comfortable with terminal-heavy workflows, while the CLI remains available and the UI is expected to keep improving over time.
- **`README.md`** + **`docs/user/GETTING-STARTED.md`** + **`docs/user/DEPLOYMENT.md`**: Clarified that a real domain is recommended for the broader control-plane and service DNS/TLS model, not only for Headscale, and that Namecheap API credentials are optional unless you choose Namecheap-managed DNS automation or the Namecheap-backed wildcard TLS modes.

## [1.13.42] — 2026-04-12

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/CONCEPT.md`** + **`docs/user/GUIDE.md`** + **`ui/README.md`**: Reframed the product narrative around the real self-hosting gap the blueprint is trying to close: not just getting services online, but operating a growing private service ecosystem with credible backup/restore, observability, DNS/TLS automation, minimal public exposure, and a repeatable security model.

### Added
- **`.github/workflows/ci.yml`**: Added public CI quality gates for Terraform validation, UI unit tests, and deterministic local static verification suites (`static-gateway`, `dashboard-json`, `dns-helper-local`) on push and pull requests.
- **`docs/roadmap/DELIVERY-MILESTONES.md`**: Added a published delivery plan with milestone scope, acceptance criteria, verification commands, and public artifacts, separate from private funding strategy notes.

### Changed
- **`Makefile`** + **`ui/requirements.txt`**: Switched the UI install flow to an isolated `.venv-ui` virtualenv and pinned UI Python dependencies to exact versions for more reproducible local and CI behavior.
- **`scripts/deploy.sh`**: Reworded backup/service placeholder messaging to remove stale TODO/stub wording while preserving existing scope behavior.

### Documentation
- Added `docs/roadmap/service-template-and-vaultwarden.md`, a technical design spec for a dedicated tailnet-only Vaultwarden VM plus a reusable internal-service onboarding template covering DNS, internal TLS, backups, logs, monitoring, deployment summary integration, and verification expectations.
- **`README.md`** + **`docs/README.md`** + **`docs/roadmap/blueprint-improvement.md`** + **`docs/technical/BACKUP.md`**: Added the public delivery milestones link and cleaned stale maturity wording/checklist status so published docs better match shipped behavior.
- **`README.md`**: Removed five stale changelog-style paragraphs that duplicated content already covered in the Security model section and dedicated docs; fixed broken link to the deleted `docs/roadmap/portable-recovery-bundle-and-restore.md` to point at the live `ARCHITECTURE.md` and `OPERATIONS.md` anchors instead; added section anchors to the observability links.
- **`docs/technical/ARCHITECTURE.md`**: Updated the "Backup Requirements" section to replace stale bare paths (`/var/lib/headscale`, `/etc/headscale`, `/etc/caddy`) with a table of the actual deployed host paths matching the Ansible backup manifests, and added a reference to `BACKUP.md` for the full specification.
- **`docs/technical/BACKUP.md`**: Removed the stale `March 2026 · v1.5` version header; corrected the Headscale "Existing Service Manifest" example to match the actual role (`/opt/headscale/data`, `/opt/headscale/config`, host `sqlite3` instead of `docker exec headscale sqlite3`).
- **`docs/technical/OPERATIONS.md`**: Fixed typo `print_vaultden()` → `print_vaultwarden()` in the deployment-summary extension guidance.
- **`README.md`**: Replaced three stale "intended to" phrases in the Security model section with present-tense descriptions matching shipped behavior; added missing `TROUBLESHOOTING.md` and `BACKUP.md` links to the docs map; corrected anchor-link display text so section links show the target anchor rather than the bare filename.
- **`docs/README.md`**: Added explicit anchors to the "Logging and service observability" entry, which was the only docs-map entry without section-level anchors.
- **`docs/technical/ARCHITECTURE.md`**: Added observability to the Overview bullet list; it is a core architectural component but was absent from the summary.
- **`docs/technical/BACKUP.md`**: Clarified "planned Tier-1 services" heading to "future Tier-1 services (not yet implemented)" to remove ambiguity about implementation status.

## [1.13.39] — 2026-04-11

### Changed
- **`ansible/playbooks/site.yml`** + **`ansible/roles/headscale/tasks/main.yml`** + **`ansible/roles/headscale/defaults/main.yml`** + **`ansible/roles/headscale/templates/headplane-config.yaml.j2`** + **`ansible/roles/headscale/templates/Caddyfile.j2`**: Finalized the Headplane move off the public Headscale hostname by starting it on localhost during bootstrap, rebinding it to the control node's Tailscale IPv4 after the tailnet is up, and returning `404` for the old public `/admin` path.
- **`ansible/roles/firewall/tasks/main.yml`** + **`ansible/roles/headscale/defaults/observability.yml`** + **`scripts/tests/65_verify_headplane.sh`** + **`scripts/tests/run.sh`**: Tightened the control-plane exposure and verification model so the public control VM no longer opens TCP `80` for Headplane access, observability probes the tailnet-only listener directly, and the verification suite asserts both public shutdown and private reachability.
- **`scripts/helpers/deployment-summary.sh`** + **`scripts/deploy.sh`** + **`ui/server.py`** + **`ui/tests/test_status_outputs.py`**: Updated operator-facing output to point Headplane at `control-vm` on port `3000`, warn when Headscale still uses the `sslip.io` bootstrap fallback, and expose the same tailnet-only admin URL in the local UI status API.

### Documentation
- **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`** + **`docs/roadmap/dns-and-visibility.md`**: Marked the Headplane visibility change as shipped, documented the new tailnet-only access path, and clarified the control-plane backup scope and first-join workflow without a public admin surface.

## [1.13.38] — 2026-04-11

### Documentation
- **`ui/README.md`**: Added the same user-facing product framing used in the main docs so the local Web UI documentation explains that the UI is part of the same secure-by-default, recoverable, low-friction operating model rather than a separate workflow with a different philosophy.

## [1.13.37] — 2026-04-11

### Documentation
- **`docs/user/GUIDE.md`** + **`docs/user/CONCEPT.md`** + **`docs/user/GETTING-STARTED.md`** + **`docs/user/DEPLOYMENT.md`** + **`docs/user/BACKUP-RECOVERY.md`** + **`docs/user/TROUBLESHOOTING.md`**: Split the large user guide into smaller focused documents and expanded the product concept into its own detailed user-facing explanation covering the blueprint's purpose, security philosophy, operational model, service-layer intent, non-goals, and long-term direction.
- **`README.md`** + **`docs/README.md`**: Updated the documentation map to point readers at the new user-doc structure instead of a single large guide.

## [1.13.36] — 2026-04-11

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/GUIDE.md`**: Added a clearer user-facing product narrative so first-time readers see the blueprint's purpose, security philosophy, operational model, intended audience, and service-layer direction before diving into technical implementation details. The docs map now explicitly points readers from vision to architecture, operations, and roadmap material.

## [1.13.35] — 2026-04-11

### Changed
- **Control plane hardening**: Headscale now keeps only the public coordination / DERP surface on the control VM, while Headplane no longer rides on the public `/admin` path and is instead exposed only over the tailnet on the control node's port `3000`.
- **`ansible/roles/firewall/tasks/main.yml`**: The control VM public firewall surface now exposes only TCP `443` plus UDP `3478` when embedded DERP is enabled.
- **Operator guidance**: Deployment summary, UI status output, and main documentation now point Headplane at the tailnet-only control-node endpoint and explicitly warn that the `sslip.io` Headscale URL is a bootstrap fallback rather than the recommended long-term control-plane identity.
- **Control-plane recovery guidance**: Documentation and the deployment summary now explicitly call out that the identity-critical backup scope includes the Headscale database, noise key, ACL/config, TLS state, and Headplane state.

## [1.13.34] — 2026-04-11

### Fixed
- **`ansible/playbooks/site.yml`**: Replaced the delegated localhost `wait_for` on `ansible_host:22` with `ansible.builtin.wait_for_connection` in the `Refresh tailnet sessions after Headscale updates` play. The earlier fix worked for direct hosts, but it broke workload nodes such as `monitoring-vm` because their `ansible_host` intentionally remains the private workload IP behind a ProxyCommand jump host. On converge runs after a Headscale restart, the localhost probe tried to reach `10.10.3.3:22` directly and timed out even though Ansible could reconnect normally through the configured jump path.

## [1.13.33] — 2026-04-10

### Fixed
- **`ansible/playbooks/site.yml`**: The `Refresh tailnet sessions after Headscale updates` play now waits for port 22 on `ansible_host` to reopen (delegated to localhost) before checking the remote Tailscale socket. Previously, the background tailscaled restart broke the SSH tunnel on control-vm (which is reached via its Tailscale IP), causing the immediate `wait_for` task to time out with UNREACHABLE.
- **`scripts/deploy.sh`** + **`ui/lib/deploy_progress.py`**: Converge-in-place deploys (full/gateway/control scopes) now run `join_local_tailnet` **after** Ansible completes, in addition to the existing pre-Ansible join. Ansible always restarts the Headscale container; on a fresh or rebuilt control VM this generates a new noise private key. Without a post-Ansible re-join, this machine's cached Tailscale connection silently breaks, causing persistent `noise handshake failed: decrypting machine key` errors for any client that connected before Ansible ran. The re-join is idempotent (skipped when the connection is still healthy) and heals the stale-key situation automatically. The progress plan emitter now models the pre-Ansible and post-Ansible join-local steps correctly for all three scopes.

## [1.13.32] — 2026-04-10

### Fixed
- **`scripts/deploy.sh`**: Expanded automatic local tailnet join coverage so converge-in-place runs can establish Tailscale transport before Ansible in `gateway` and `control` scopes (matching existing `full` behavior), and destructive `full`/`control` runs now auto-join after a control bootstrap refresh when feasible. This prevents non-destructive gateway/control converges from stalling on public SSH when hosts are intentionally tailnet-only.
- **`scripts/helpers/deployment-summary.sh`**: Internal Namecheap wildcard TLS activation failures are now surfaced as a hard action-required state in the Services section. Internal HTTPS aliases (`grafana/prometheus/backrest`) are explicitly marked as blocked until wildcard activation succeeds, with the required Namecheap allowlist + gateway rerun steps shown inline.

## [1.13.31] — 2026-04-10

### Fixed
- **`scripts/deploy.sh`**: `prefer_tailscale_for_ansible()` now skips the SSH probe when `PREFER_TAILSCALE=1` is explicitly set; previously the probe always ran and would fail right after joining (routes not yet propagated), causing Ansible to fall back to blocked public IPs. When the converge-in-place auto-join succeeds, `PREFER_TAILSCALE=1` is now set immediately so `ansible_run` uses Tailscale transport without re-probing.
- **`ui/tests/test_deploy_cli.py`**: Fixed remaining test assertions that broke when the deployment summary started wrapping long lines (`sudo killall -HUP mDNSResponder`, `--hostname ${SAFE_HOSTNAME}`) — now checked as independent tokens.

## [1.13.30] — 2026-04-10

### Added
- **`scripts/deploy.sh`** + **`ui/lib/deploy_progress.py`**: Converge-in-place (`full` scope, no destroy) now automatically joins this machine to the existing tailnet before Ansible runs. When `headscale-authkeys.json` and `tailscale-ips.json` are already present in the environment inventory, `join_local_tailnet` runs right after DNS setup — before `wait-ssh` — so Ansible can reach VMs over Tailscale even when public SSH is locked down from the prior deploy. If the machine is already connected to the correct tailnet the step is a no-op; if the auth key has expired the join fails gracefully and Ansible proceeds (and reports the SSH failure clearly). The progress plan emitter exposes this as a `join-local` step in the UI timeline.

### Fixed
- **`ui/tests/test_deploy_cli.py`**: Updated two test assertions that broke in 1.13.29 when `tailscale up` commands switched to backslash-continuation wrapping and the portable-restore command changed to show a generic placeholder rather than the literal recovery line.

## [1.13.29] — 2026-04-10

### Fixed
- **`scripts/helpers/deployment-summary.sh`**: `tailscale up` commands in the deployment summary now render with backslash line-continuation (`\`) when they wrap, so copy-pasting the multi-line output into a shell works correctly without the auth key being treated as a separate command. Added `--reset` to the non-fresh-tailnet join command so it succeeds even when the local Tailscale client was previously connected to a different server.

## [1.13.28] — 2026-04-10

### Fixed
- **`scripts/deploy.sh`** + **`ui/tests/test_deploy_cli.py`**: Restored the documented `--yes` behavior for existing Terraform-managed infrastructure. Non-interactive runs that explicitly pass `--yes` now take the destructive destroy-and-recreate path instead of silently downgrading to in-place converge and then failing later when no management path exists.
- **`scripts/hooks/backup.sh`** + **`ui/tests/test_deploy_cli.py`**: Bounded the pre-destroy backup hook with a timeout so destructive recovery deploys can continue even when the old VMs are unreachable and the best-effort backup Ansible run would otherwise hang in SSH/fact gathering.
- **`ui/lib/job_runner.py`**: Restored terminal History recording compatibility by letting `job_runner.py` import `timing.py` correctly both as a package module and as a script-local module from `ui/lib/job_cli.py`.

## [1.13.27] — 2026-04-10

### Fixed
- **`ansible/roles/monitoring/files/grafana-dashboards/logs-overview.json`** + **`scripts/tests/05_verify_grafana_dashboards.sh`**: Tightened the Logs Overview "Recent error count by service" and "Latest critical log lines" panels to keep their existing `error` match while explicitly excluding `level=info`, `level=debug`, and `level=trace` lines. This stops Loki's own info-level query logs from polluting the critical panels while still surfacing real service errors such as Headscale's noise-handshake failures.

### Documentation
- **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Clarified that managed blueprint VMs auto-heal after Headscale noise-key rotation, while unmanaged laptops and user devices still require a one-time `join-local --rejoin-local` or manual `tailscale up --reset --force-reauth` after control-plane restore/rebuild.

## [1.13.26] — 2026-04-10

### Fixed
- **`ui/lib/deploy_progress.py`** + **`ui/tests/test_deploy_progress.py`**: Fixed Ansible plan-time task counting to parse the real `ansible-playbook --list-tasks` output instead of defaulting `ansible-main` to weight `1`, so deploy progress starts with a realistic task total.
- **`ui/lib/timing.py`** + **`ui/lib/job_runner.py`** + **`ui/server.py`** + **`ui/static/app.js`** + **`ui/tests/test_timing.py`**: Added an environment-local timing profile rebuilt from successful persisted deploy logs and switched the Web UI progress/ETA estimator to duration-based calculations when history exists. The estimator now learns per-step timing with an EMA, survives different deploy shapes, includes terminal-recorded runs, and adjusts mid-run when the current step is slower than historical averages instead of pinning late-stage deploys at a stale `99%` / short ETA.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`** + **`ui/README.md`** + **`docs/roadmap/ui-deployment-eta.md`**: Documented the shipped timing-profile workflow, the new `GET /timing/{env}` API, and the duration-based ETA/progress model.

## [1.13.25] — 2026-04-09

### Fixed
- **`ansible/roles/headscale/tasks/main.yml`** + **`ansible/roles/tailscale/tasks/main.yml`**: Added Headscale noise-key fingerprint reconciliation for managed nodes. The control role now publishes a SHA-256 fingerprint of `noise_private.key`, and the tailscale role stores the last applied fingerprint per node under `/var/lib/tailscale/headscale-noise-key.sha256`. When the control-plane noise key changes (for example after restore/rebuild), managed nodes now automatically run `tailscale up --reset` during converge instead of silently keeping stale control-plane crypto state.
- **`ansible/roles/monitoring/templates/loki-config.yml.j2`** + **`ansible/group_vars/all/main.yml`**: Hardened Loki query path defaults to prevent scheduler overload and 429 storms under heavy dashboard queries. Added explicit `limits_config.split_queries_by_interval`, `frontend.max_outstanding_per_tenant`, `query_scheduler.max_outstanding_requests_per_tenant`, and `querier.max_concurrent` tuning for the deployed Loki version.
- **`ansible/playbooks/group_vars/all/main.yml`** + **`ansible/roles/monitoring/defaults/main.yml`**: Mirrored the Loki tuning defaults into the playbook-scoped group vars and monitoring role defaults so targeted `--tags monitoring` recovery runs render a valid Loki config instead of failing on undefined variables.
- **`ansible/roles/gateway/tasks/main.yml`**: Added the same local `tailscale ip -4` fallback used by the monitoring role so targeted gateway recovery runs do not fail when the `tailscale` play was not executed in the same Ansible invocation.
- **`scripts/tests/62_verify_service_observability.sh`**: Extended observability verification to assert the Loki overload-protection settings are rendered on the monitoring VM, verify always-on container log ingestion separately from backup-file ingestion, and keep Prometheus API checks aligned with the deployed basic-auth configuration.

## [1.13.24] — 2026-04-09

### Changed
- Deployment summary output now adapts to terminal width, wraps long values (API keys, auth keys, commands, recovery lines) cleanly, and adds visual spacing between subsections for easier scanning.
- Break-glass recovery line in the summary is now wrapped across lines rather than printed as one enormous token; the `--recovery-line` restore hint references the displayed line instead of repeating the full token.

## [1.13.23] — 2026-04-09

### Fixed
- **`ansible/roles/monitoring/tasks/main.yml`**: Added Docker vfs storage driver configuration (matching headscale and gateway roles). ThreeFold Grid VMs use VirtioFS as the root filesystem which does not support overlay2; without this fix, all monitoring containers (Loki, Prometheus, Grafana, Blackbox, Backrest) would fail to start after a fresh deploy. Also added the `zinit forget dockerd` + `zinit monitor dockerd` restart pattern so the storage driver change takes effect idempotently.
- **`ansible/roles/gateway/tasks/main.yml`** + **`ansible/roles/headscale/tasks/main.yml`**: Hardened the dockerd restart task with `zinit forget dockerd` before `zinit monitor dockerd` and added `exit 0` to prevent false task failures on fresh VMs where zinit does not yet know the `dockerd` service. Also reduced sleep between stop and kill from 2 s to 1 s.

## [1.13.22] — 2026-04-08

### Fixed
- **`ansible/playbooks/site.yml`**: `Pin Headscale FQDN in /etc/hosts` now always uses `tf_public_ip` (the VM's public IP) instead of `ansible_host`, which may be the Tailscale IP when Ansible runs over the tailnet. Using the Tailscale IP caused a bootstrapping deadlock: tailscaled could not reach Headscale to start because the only route to `headscale.babenko.live` was through `tailscale0`, which did not exist yet.
- **`ansible/roles/headscale/tasks/main.yml`** + **`ansible/roles/gateway/tasks/main.yml`**: Docker on ThreeFold Grid VMs uses VirtioFS as the root filesystem, which does not support the overlay `index=off` mount option used by the containerd snapshotter. Configured `{"storage-driver": "vfs"}` in `/etc/docker/daemon.json` by default (overridable via `docker_storage_driver` group var). Added an explicit dockerd restart task when the daemon config changes so the new storage driver takes effect before containers are launched.
- **`scripts/deploy.sh`**: `ask_destroy_recreate` no longer auto-approves destroy/recreate when `--yes` is passed. Previously `deploy.sh control --yes` silently destroyed and re-created the control VM (wiping Headscale state). Destructive operations now always require interactive confirmation regardless of `--yes`.
- **`scripts/tests/25_verify_gateway_exit_node.sh`**: Fixed hardcoded `100.64.0.1` gateway Tailscale IP — now resolved dynamically via `tailscale_ip_for_host "gateway-vm"` so the test is correct after gateway replacement.
- **`ansible/playbooks/site.yml`** (`Refresh tailnet sessions`): Wrapped `zinit stop/start tailscaled` in `nohup bash -c '...' </dev/null >/dev/null 2>&1 &` so the restart does not kill the SSH session it is running over, preventing VMs from being left with tailscaled stopped.

### Added
- **`ui/lib/deploy_progress.py`** + **`ansible/callback_plugins/blueprint_progress.py`** + **`ui/static/app.js`** + **`ui/static/style.css`** + **`scripts/deploy.sh`**: The local Web UI Deploy tab now shows a generic top-level progress percentage and ETA derived from the resolved deploy path, weighted non-Ansible steps, and live Ansible task-start markers instead of a hardcoded frontend phase map.

### Documentation
- **`docs/roadmap/dns-and-visibility.md`** + **`docs/README.md`**: Reduced the DNS roadmap to the one remaining unshipped phase (Headplane tailnet-only ingress) and moved the implemented DNS / ingress material to the main documentation map so shipped behavior is documented under architecture and operations instead of in the roadmap.

## [1.13.21] — 2026-04-08

### Added
- **`scripts/tests/25_verify_gateway_exit_node.sh`** + **`scripts/tests/run.sh`**: Added a guarded end-to-end gateway exit-node regression test that briefly enables the exit node on `control-vm`, verifies public egress through `gateway-vm`, and then immediately disables the exit node again.

### Fixed
- **`ansible/roles/headscale/templates/acl.hujson.j2`** + **`ansible/roles/gateway/tasks/main.yml`** + **`ansible/roles/firewall/tasks/main.yml`**: Fixed the gateway exit-node / personal-VPN path by allowing `autogroup:internet:*` in the Headscale ACL, enabling IPv6 forwarding on the gateway, and persisting explicit routed UFW rules for `tailscale0` to the public interface.

### Documentation
- **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Documented the required exit-node ACL, the gateway forwarding/firewall prerequisites, and the new guarded end-to-end verification flow.

## [1.13.20] — 2026-04-04

### Added
- **`scripts/deploy.sh`** + **`ansible/callback_plugins/blueprint_progress.py`** + **`ui/server.py`** + **`ui/static/app.js`**: Job logs now capture progress-debug timing data in the same persisted `.ui-logs/<job>.log` file, combining timestamped backend `[bp-progress]` markers with throttled UI `[bp-progress-ui]` snapshots of the visible percent, ETA, label, and triggering event so estimation errors can be analyzed after the run.

### Documentation
- **`README.md`** + **`docs/technical/OPERATIONS.md`**: Documented the new post-run progress-diagnostics markers that are written into per-job logs for estimation analysis.

## [1.13.19] — 2026-04-04

### Fixed
- **`ui/static/app.js`**: Replaying a successful deploy from History no longer lets old progress markers overwrite the already-complete 100% progress state, so completed jobs keep a stable final progress label instead of briefly showing intermediate steps.

## [1.13.18] — 2026-04-04

### Fixed
- **`scripts/helpers/dns-setup.sh`** + **`scripts/tests/14_verify_dns_helper_local.sh`**: The Namecheap DNS helper now replays the merged zone while authoritative `registrar-servers.com` nameservers remain stale, so deploys self-heal the reproduced "setHosts succeeded but live zone did not publish" state instead of only timing out.

### Documentation
- **`docs/technical/OPERATIONS.md`**: Documented that DNS automation now replays the merged Namecheap payload during authoritative publication lag before failing closed.

## [1.13.17] — 2026-04-04

### Fixed
- **`ansible/playbooks/site.yml`** + **`ansible/group_vars/all/main.yml`** + **`scripts/deploy.sh`** + **`ui/tests/test_deploy_cli.py`**: Real-domain environments now auto-switch Headscale back to Let's Encrypt by default as intended, and `join-local` now installs the persisted internal Headscale CA into the macOS System keychain when internal TLS is intentionally used.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`** + **`environments/example/group_vars/all.yml`**: Clarified the default Headscale TLS behavior for real domains, the `headscale_tls_mode_auto: false` opt-out, and the macOS internal-CA trust path.

## [1.13.16] — 2026-04-04

### Fixed
- **`ui/static/app.js`** + **`ui/lib/deploy_progress.py`** + **`ui/tests/test_deploy_progress.py`**: The Web UI progress bar now waits for the emitted plan before estimating completion, preserves any step markers that arrive before that plan so startup no longer spikes to near-complete and resets, and includes the DNS phase in control-scope progress to match the real deploy path.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`ui/README.md`**: Clarified how the Deploy tab progress bar now initializes cleanly from the emitted plan and reflects the control-scope DNS step.

## [1.13.15] — 2026-04-04

### Fixed
- **`ui/lib/job_runner.py`** + **`scripts/deploy.sh`** + **`ui/tests/test_job_runner.py`**: UI-triggered deploy snapshots now preserve the original repository root when they execute, so the Web UI no longer resolves environment paths under `.ui-logs/.../environments/<env>` and fail immediately on startup.

### Documentation
- **`README.md`** + **`docs/technical/OPERATIONS.md`**: Clarified that UI deploy snapshots preserve both immutable script contents and the original repository root during execution.

## [1.13.14] — 2026-04-03

### Fixed
- **`ui/lib/job_runner.py`** + **`ui/tests/test_job_runner.py`**: UI-triggered deploys now run from an immutable per-job snapshot of `scripts/deploy.sh`, log the exact snapshot used for the run, and reject unexpected progress-helper typos before launch so long-running deploys cannot fail later because the repo copy was edited mid-run.
- **`scripts/helpers/dns-setup.sh`** + **`scripts/deploy.sh`** + **`scripts/tests/14_verify_dns_helper_local.sh`** + **`scripts/tests/run.sh`**: Namecheap DNS automation now fails closed when public DNS stays stale, runs during control redeploys as well as full and gateway deploys, and has a local stubbed regression suite so stale public control-plane DNS no longer slips through as a successful deploy.
- **`scripts/tests/10_verify_headscale.sh`** + **`scripts/tests/60_verify_monitoring_stack.sh`**: Headscale verification now retries the control SSH probe before downgrading to a warning, and monitoring verification now parses `internal_service_tls_mode` robustly even when the environment YAML line includes an inline comment.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Documented both the persisted UI `deploy.sh` snapshot and the stricter DNS convergence requirement for Namecheap-managed deploys.

## [1.13.12] — 2026-04-02

### Fixed
- **`scripts/deploy.sh`** + **`ansible/roles/gateway/tasks/main.yml`** + **`scripts/helpers/deployment-summary.sh`**: Gateway converges now run Namecheap DNS setup before the gateway play, record whether wildcard TLS was actually activated, and only recommend a second gateway run when the current deploy did not activate wildcard TLS.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Clarified that Namecheap wildcard TLS is a one-pass deploy when the gateway IP is already allowlisted before deploy start, with a second gateway converge only as the fallback when that external allowlist step was still pending.

## [1.13.11] — 2026-04-02

### Fixed
- **`ansible/roles/tailscale/tasks/main.yml`** + **`ansible/roles/tailscale/defaults/main.yml`**: Gateway converges now wait longer for Headscale to surface the gateway's advertised exit-node routes before trying approval, avoiding false deploy failures on slow route propagation and emitting route-state diagnostics if the wait still times out.

## [1.13.10] — 2026-04-01

### Fixed
- **`Makefile`**: Fixed `make ui` so when the Blueprint UI is already running on port 8090 the target exits successfully instead of falling through and attempting to launch a second `uvicorn` process that fails with `address already in use`.

## [1.13.9] — 2026-04-01

### Fixed
- **`ansible/roles/headscale/tasks/main.yml`**: Headscale converges now skip the legacy invalid-node cron cleanup when `crontab` is not installed, so gateway/control deploys no longer fail on minimal hosts while still removing the old cron entry where cron exists.

## [1.13.8] — 2026-04-01

### Fixed
- **`ansible/roles/tailscale/tasks/main.yml`** + **`scripts/tests/10_verify_headscale.sh`**: Gateway converges now auto-approve the gateway's advertised `0.0.0.0/0` and `::/0` exit-node routes in Headscale, and the Headscale verification suite now fails if those routes are present but not approved.

### Documentation
- **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Documented that exit-node route approval is now part of converge, how clients should use the gateway as an exit node, and how to diagnose or manually recover route approval if needed.

## [1.13.7] — 2026-04-01

### Removed
- **`ansible/roles/headscale/tasks/main.yml`** + **`ansible/roles/headscale/files/headscale-reconcile-invalid-node-names.py`** + **`ui/tests/test_headscale_invalid_name_reconcile.py`**: Removed the unmanaged-client name reconciliation path entirely, including the control-plane cron job and helper, so direct client joins now keep Headscale's original fallback names unless the user sets a hostname explicitly or renames the node manually.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Removed the earlier documentation about automatic control-plane renaming for unmanaged clients and restored the simpler model where raw direct joins may keep `invalid-*` names.

## [1.13.6] — 2026-04-01

### Fixed
- **`ansible/roles/headscale/files/headscale-reconcile-invalid-node-names.py`** + **`ui/tests/test_headscale_invalid_name_reconcile.py`**: The control-plane rename job now treats generated fallback names such as `client-6` as temporary and extracts sanitized device names from nested Headscale hostinfo fields, so unmanaged macOS clients are renamed to real DNS-safe names instead of getting stuck on the numeric fallback.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Clarified that unmanaged client reconciliation now covers both `invalid-*` registrations and the temporary `client-<id>` fallback path.

## [1.13.5] — 2026-04-01

### Fixed
- **`ansible/roles/headscale/tasks/main.yml`** + **`ansible/roles/headscale/files/headscale-reconcile-invalid-node-names.py`** + **`ui/tests/test_headscale_invalid_name_reconcile.py`**: The control VM now renames unmanaged Headscale client nodes that registered as `invalid-*` by normalizing the stored hostname metadata, running once during deploy and then every minute from cron so direct macOS joins no longer stay on fallback names.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Documented that helper-side hostname normalization now has a control-plane follow-up path for unmanaged direct joins, including the on-demand reconciliation command on the control VM.

## [1.13.4] — 2026-04-01

### Fixed
- **`scripts/deploy.sh`** + **`ui/tests/test_deploy_cli.py`**: `join-local --rejoin-local` now matches stale Headscale nodes using both the sanitized local hostname and the current local Tailscale self-name, so old `invalid-*` workstation registrations are deleted before reauth instead of being left behind.
- **`scripts/helpers/deployment-summary.sh`** + **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: The fresh-tailnet manual fallback flow now tells clients to `tailscale logout` first and rejoin with `--force-reauth` plus an explicit safe hostname, instead of reusing the weaker raw `tailscale up ... --reset` command.

## [1.13.3] — 2026-04-01

### Fixed
- **`scripts/deploy.sh`** + **`ui/tests/test_deploy_cli.py`**: Fixed `--no-restore` and `--fresh-tailnet` so deploys now pass real boolean Ansible overrides after env `group_vars`, preventing string-valued `false` from being treated as truthy and preventing env defaults from overriding the CLI reset flags.
- **`scripts/helpers/deployment-summary.sh`** + **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Fresh-tailnet recovery guidance now prefers `./scripts/deploy.sh join-local --env <env> --rejoin-local` before the raw `tailscale up ... --reset` fallback, so workstation rejoin flows keep the hostname-sanitizing path that avoids `invalid-xxxx` client names.

## [1.13.2] — 2026-04-01

### Changed
- **`ansible/roles/tailscale/tasks/main.yml`**: Hardened Tailscale package bootstrap by replacing the one-shot GPG key download with a retried `get_url` fetch, so transient `502` responses from `pkgs.tailscale.com` no longer abort full converges.
- **`ansible/roles/backup/templates/backup-wrapper.sh.j2`**: Added `restic --retry-lock 60s` to backup and prune operations so short-lived repository locks on object storage backends do not cause otherwise successful gateway and tailscale backups to be reported as failed.

## [1.13.1] — 2026-03-31

### Documentation
- **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`** + **`docs/user/GUIDE.md`** + **`docs/roadmap/logging-and-service-observability.md`**: Moved the shipped observability stack details out of the roadmap and into the working docs, including the live Loki/Alloy/Blackbox/service-health architecture, the current built-in service coverage, documented Grafana Explore query presets, and the reduced list of genuinely unfinished observability work.

## [1.13.0] — 2026-03-31

### Added
- **`ansible/roles/observability/`** + **`ansible/playbooks/site.yml`**: Added the shared observability role that deploys Grafana Alloy on every managed VM, ships declared logs to Loki, and writes local `blueprint_service_health` metrics into the node_exporter textfile collector.
- **`ansible/roles/*/defaults/observability.yml`**: Introduced per-role observability manifests for gateway, headscale/control-plane services, monitoring services, and backup jobs so service logs and health checks are declared through a consistent contract instead of bespoke monitoring wiring.
- **`ansible/roles/monitoring/files/grafana-dashboards/service-health.json`** + **`ansible/roles/monitoring/files/grafana-dashboards/logs-overview.json`** + **`ansible/roles/monitoring/files/service-observability-alerts.yml`**: Added dedicated service-health and log-overview dashboards plus alert rules for local service failures, remote probe failures, and Alloy availability.
- **`scripts/tests/62_verify_service_observability.sh`** + **`scripts/tests/run.sh`**: Added end-to-end observability verification coverage for Loki readiness, Grafana datasource/dashboard provisioning, Prometheus service-health metrics, Blackbox probes, log ingestion, and retention/archive rendering.

### Changed
- **`ansible/roles/monitoring/tasks/main.yml`** + **`ansible/roles/monitoring/templates/prometheus.yml.j2`** + **`ansible/roles/monitoring/templates/grafana-datasource.yml.j2`**: Expanded the monitoring stack to provision Loki, Blackbox exporter, Prometheus observability scrape jobs, the Loki datasource, and retention/archive automation on the monitoring VM.
- **`ansible/group_vars/all/main.yml`** + **`ansible/playbooks/group_vars/all/main.yml`** + **`environments/example/group_vars/all.yml`**: Added the shared logging and service-observability configuration surface, including default 30-day Loki retention, 90-day archive retention, and archive enablement derived from configured backup backends.
- **`ansible/roles/backup/tasks/deploy.yml`** + **`ansible/roles/backup/templates/check-backup-health.sh.j2`** + **`scripts/helpers/deployment-summary.sh`**: Wired backup health into the generic service-observability path and updated deployment summaries to surface the new Grafana dashboards and log access flow.
- **`scripts/tests/05_verify_grafana_dashboards.sh`** + **`scripts/tests/60_verify_monitoring_stack.sh`**: Updated the existing dashboard and monitoring suites to validate the renamed Infrastructure Health dashboard and the expanded monitoring stack.

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Documented the shipped centralized logging and service-observability model, the new Grafana dashboards, the Loki/Alloy/Blackbox stack, and the default retention/archive behavior.

## [1.12.0] — 2026-03-31

### Added
- **`ansible/roles/gateway/templates/Caddyfile.j2`** + **`ansible/roles/gateway/tasks/main.yml`** + **`ansible/roles/gateway/defaults/main.yml`**: Implemented Phase 2 and Phase 4 of the DNS roadmap on the live gateway path. The gateway now supports `gateway_services` for per-service public upstream routing, while `public_service_tls_mode: namecheap` enables one wildcard certificate for `*.base_domain` on the gateway via the existing Namecheap DNS-01 integration.
- **`scripts/helpers/gateway_public_subdomains.py`** + **`scripts/tests/16_verify_gateway_static.sh`** + **`scripts/tests/test_gateway_public_subdomains.py`** + **`scripts/tests/test_gateway_caddy_template.py`**: Added local static coverage for gateway public-subdomain derivation and Caddy template rendering. This verifies legacy `gateway_domains` fallback, the new `gateway_services` schema, and the public Namecheap wildcard site generation.

### Changed
- **`scripts/deploy.sh`**: DNS automation now derives gateway A-record targets from `gateway_services` automatically when `gateway_subdomains` is omitted, so new environments do not need duplicate public-service lists just to keep Namecheap A-record updates in sync.
- **`scripts/helpers/deployment-summary.sh`**: Deployment summaries and warning blocks now surface both internal and public Namecheap wildcard follow-up steps, including the required gateway-IP allowlist reminder and the one-time `./scripts/deploy.sh gateway --env <env>` activation step.
- **`ansible/group_vars/all/main.yml`** + **`ansible/playbooks/group_vars/all/main.yml`** + **`ansible/roles/gateway/templates/Caddyfile.j2`**: Namecheap wildcard issuance now waits before checking DNS propagation and uses a longer propagation timeout by default, which avoids false ACME failures when `_acme-challenge` records appear on Namecheap DNS after recursive resolvers have briefly cached NXDOMAIN.
- **`ui/lib/config_reader.py`** + **`ui/server.py`** + **`ui/static/app.js`** + **`ui/tests/test_config_dns.py`**: The local Web UI DNS configuration view now exposes `public_service_tls_mode` alongside the existing internal wildcard mode and persists it through the config API.

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Updated the operator docs to describe the shipped `gateway_services` schema, the new `public_service_tls_mode` gateway wildcard flow, the shared Namecheap allowlist dependency, and the current certificate lifecycle for Headscale, public services, and internal monitoring aliases.
- **`docs/roadmap/dns-and-visibility.md`** + **`environments/example/group_vars/gateway.yml`** + **`environments/prod/group_vars/gateway.yml`** + **`environments/test/group_vars/gateway.yml`** + **`ansible/group_vars/gateway/main.yml`** + **`ansible/playbooks/group_vars/gateway/main.yml`**: Updated the roadmap and environment scaffolds to reflect that Phase 2 and Phase 4 are now shipped and that `gateway_services` is the preferred public ingress schema, with legacy `gateway_domains` retained as a compatibility fallback.

## [1.11.1] — 2026-03-31

### Documentation
- **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`** + **`docs/user/GUIDE.md`**: Folded the shipped gateway-ingress and Namecheap wildcard-TLS behavior into the main docs so the current runtime model is documented in production documentation rather than in a separate design note. The docs now state explicitly that the gateway terminates the packaged internal monitoring aliases in `internal_service_tls_mode: namecheap`, that direct host access stays on `-vm` MagicDNS names, and that Headscale remains on the control VM hostname.
- **`docs/README.md`** + **`docs/roadmap/dns-and-visibility.md`**: Reworked the DNS roadmap into a clean feature-proposal document that compares the current shipped model against three proposed changes: per-domain public upstream routing, public wildcard DNS-01, and moving Headplane to tailnet-only ingress.

### Removed
- **`docs/roadmap/internal-gateway-ingress-namecheap.md`**: Deleted the now-obsolete design doc because the shipped ingress and Namecheap wildcard-TLS model is already covered in the main docs.

## [1.11.0] — 2026-03-30

### Added
- **`scripts/helpers/data_model_version.py`** + **`scripts/helpers/data_migrations.py`**: Implemented the environment data-model versioning system. The blueprint now tracks `DATA_MODEL_VERSION`, records it in `environments/<env>/.data-model-version`, applies ordered forward-only migrations through a standalone CLI, and ships the first real migration from v1 to v2 that normalizes `inventory/terraform-outputs.json` by adding a top-level `provider` field.
- **`scripts/tests/92_verify_data_model_migrations.sh`**: Added automated coverage for fresh-environment initialization, dry-run planning, real migration execution with rollback tarball creation, and restore-time migration from an older v1 recovery bundle into the current checkout.

### Changed
- **`scripts/deploy.sh`** + **`scripts/restore.sh`** + **`scripts/helpers/recovery_bundle.py`**: Deploy and restore now run the data-model migration flow end to end. Recovery bundles embed `data_model_version`, restore defaults missing historical metadata to version `1`, portable bundles include `.data-model-version`, and restore automatically migrates older environment layouts before handing the workspace back to the operator.
- **`ansible/inventory/tfgrid.py`** + **`ui/server.py`**: Inventory readers now tolerate the normalized `terraform-outputs.json` shape where top-level metadata such as `provider` may coexist with raw Terraform output objects.
- **`environments/example/`** + **`scripts/deploy.sh`**: Seeded the tracked example scaffold with `.data-model-version`, while real local environments continue to initialize or migrate their schema automatically on first deploy or restore.

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Documented the shipped data-model migration system, clarified that automatic migrations cover blueprint-managed environment files only, and explicitly excluded service-internal application data migrations from this mechanism.

## [1.10.3] — 2026-03-24

### Changed
- **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Corrected the multi-environment documentation to match the current `deploy.sh` behavior. `--env <name>` is required; the old legacy no-`--env` mode is no longer documented.
- **`docs/README.md`**: Replaced stale roadmap links for implemented features with production-documentation links for the multi-environment model, portable recovery bundle, and Web UI.

### Removed
- **`docs/roadmap/multi-environment.md`**: Deleted the roadmap note because the shipped multi-environment model is already documented in production docs (`ARCHITECTURE.md`, `OPERATIONS.md`, `GUIDE.md`).

## [1.10.2] — 2026-03-24

### Changed
- **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Corrected restore flow documentation — the interactive edit step was removed from `restore.sh`; both docs now accurately describe that the operator edits restored files manually before running `deploy.sh`.

### Removed
- **`docs/roadmap/portable-recovery-bundle-and-restore.md`**: Deleted the implementation spec — the portable recovery bundle and `restore.sh` are fully implemented in v1.10.0 and covered in production documentation (`ARCHITECTURE.md`, `OPERATIONS.md`, `GUIDE.md`).

## [1.10.1] — 2026-03-24

### Changed
- **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Added missing `log_sections.py` and `job_cli.py` entries to the Web UI repo layout section; added `DELETE /jobs/{job_id}` and `POST /environments` to the API reference table.

### Removed
- **`docs/roadmap/web-ui.md`**: Deleted the Web UI roadmap document — all three phases are fully implemented in v1.8.0 and the design is now covered in production documentation (`ARCHITECTURE.md`, `OPERATIONS.md`, `GUIDE.md`, `ui/README.md`).

## [1.10.0] — 2026-03-24

### Added
- **`scripts/helpers/recovery_bundle.py`** + **`scripts/restore.sh`**: Implemented the portable control-plane recovery workflow. Successful deploys can now assemble an encrypted recovery bundle from the current environment files and local state, publish it to both configured S3-compatible backup storages, and restore that workspace later on a fresh macOS or Linux machine using a single opaque `bp1...` recovery line.
- **`scripts/tests/90_verify_portable_recovery_bundle.sh`** + **`scripts/tests/run.sh`**: Added automated local verification for recovery-line encode/decode, bundle manifest contents, required include/exclude rules, latest-pointer publication, primary-to-secondary restore failover, prepare-only restore behavior, and temporary-directory cleanup.

### Changed
- **`scripts/deploy.sh`** + **`scripts/helpers/deployment-summary.sh`**: Deploys now refresh the portable recovery bundle after successful `full`, `gateway`, and `control` runs, persist the latest local recovery line under `environments/<env>/.recovery/`, surface primary and secondary publication status in the deployment summary, and mark the deploy as failed when the primary recovery publication does not succeed.
- **`README.md`** + **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Documented the new portable recovery workflow, the `./scripts/restore.sh` entrypoint, the dedicated `control-recovery/<env>/...` storage path, and the explicit security boundary that the recovery line is obfuscation-first rather than a standalone trust anchor.

## [1.9.1] — 2026-03-24

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Added a dedicated certificate lifecycle and renewal explanation that clearly separates the three current TLS paths: public per-host ACME on Caddy, internal private-CA mode on the monitoring VM, and internal Namecheap-backed wildcard DNS-01 on the gateway. The docs now state explicitly that public certs renew automatically, that the internal Namecheap wildcard also renews automatically after first activation, and that those internal renewals still depend on the gateway IP remaining allowlisted in Namecheap.

## [1.9.0] — 2026-03-24

### Changed
- **Ingress and internal traffic model**: Internal browser traffic now has an explicit gateway-ingress architecture for packaged monitoring services. Public services still terminate on the gateway public interface, while tailnet-only service aliases such as `grafana.in.<domain>`, `prometheus.in.<domain>`, and `backrest.in.<domain>` terminate on the gateway Tailscale IP and proxy to the monitoring VM over Tailscale when `internal_service_tls_mode: namecheap` is enabled.
- **MagicDNS naming model**: Service aliases and machine names are now clearly separated. Service ingress stays on clean names like `grafana.in.<domain>`, while direct host access uses canonical `-vm` names such as `gateway-vm.in.<domain>` and `monitoring-vm.in.<domain>` across inventory, Tailscale registration, monitoring labels, deployment summaries, tests, and docs.
- **Operator workflow**: The Namecheap wildcard activation flow is now a documented and verified two-pass operator flow. Default deploys still run straight through, but Namecheap mode explicitly instructs the operator to let the first deploy finish, whitelist the gateway public IP in Namecheap, and then run `./scripts/deploy.sh gateway --env <env>` once. Other TLS modes/providers remain documented as one-pass flows.

### Fixed
- **Gateway wildcard TLS activation**: Fixed the runtime issues that blocked browser-trusted wildcard TLS for `*.in.<domain>` on the gateway, including invalid Caddy TLS syntax, malformed resolver rendering, incomplete host-limit context during the follow-up gateway converge, missing MagicDNS alias reconciliation when in-memory host facts were absent, and fallback routing that returned `404` instead of proxying valid service aliases.
- **Live Namecheap path verification**: The Namecheap-backed wildcard flow has now been validated end to end in the `test` environment. Service aliases resolve through Headscale MagicDNS to the gateway Tailscale IP, the gateway serves a public wildcard certificate for `*.in.babenko.live`, and the monitoring endpoints behind that certificate pass the repo's tailnet-management verification suite.

### Documentation
- **`README.md`** + **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`** + **`scripts/helpers/deployment-summary.sh`**: Consolidated the ingress, naming, and Namecheap wildcard-TLS workflow documentation so the runtime architecture, operator expectations, and follow-up deploy step are described consistently at the top level, in user docs, in technical docs, and in the post-deploy summary.

## [1.8.42] — 2026-03-24

### Documentation
- **`docs/roadmap/portable-recovery-bundle-and-restore.md`**: Removed the last controller-model wording from the recovery-bundle spec so the document reads as a clean standalone implementation contract focused only on bundle generation, restore, and separate follow-up deployment.

## [1.8.41] — 2026-03-24

### Documentation
- **`docs/roadmap/portable-recovery-bundle-and-restore.md`**: Tightened the recovery-bundle spec so restore stops after recreating the local workspace and printing next-step commands; deployment remains a separate operator action. The document was also cleaned up to stand on its own without historical references to earlier controller-placement models.

## [1.8.40] — 2026-03-24

### Fixed
- **`ansible/roles/gateway/templates/Caddyfile.j2`**: Fixed internal wildcard service routing after certificate activation. The gateway wildcard block now uses ordered `handle` routes for Grafana, Prometheus, and Backrest so Caddy's fallback `respond` handler does not override the reverse-proxy rules and return `404` for valid service aliases.

## [1.8.39] — 2026-03-24

### Documentation
- **`docs/roadmap/portable-recovery-bundle-and-restore.md`** + **`docs/README.md`** + **`README.md`**: Replaced the earlier in-perimeter deployment-source roadmap with a new implementation-oriented spec for portable break-glass recovery. The new document standardizes on post-deploy recovery-bundle backups, an opaque deployment-summary recovery one-liner, and a universal macOS/Linux restore flow that can rebuild an environment from backup storage without introducing a permanent controller VM.

### Removed
- **`docs/roadmap/in-perimeter-deployment-source.md`**: Removed the superseded in-perimeter controller roadmap in favor of the new portable recovery-bundle design.

## [1.8.38] — 2026-03-24

### Fixed
- **`ansible/playbooks/site.yml`**: Hardened the Headscale DNS reconcile for internal service aliases. The reconcile now falls back to the persisted `tailscale-ips.json` mapping when in-memory host facts are missing, so limited follow-up converges such as `./scripts/deploy.sh gateway --env <env>` keep `grafana.in.<domain>`, `prometheus.in.<domain>`, and `backrest.in.<domain>` in MagicDNS instead of silently dropping them.

## [1.8.37] — 2026-03-23

### Fixed
- **`ansible/roles/gateway/templates/Caddyfile.j2`**: Fixed the Namecheap wildcard TLS resolver rendering in the gateway Caddyfile. The previous template could render the closing `}` of the `tls` block onto the same line as the `resolvers` directive, causing ACME DNS propagation checks to fail with a bogus resolver entry like `}:53` even after the gateway IP had been allowlisted successfully.

## [1.8.36] — 2026-03-23

### Fixed
- **`scripts/deploy.sh`**: Fixed the Namecheap follow-up command `./scripts/deploy.sh gateway --env <env>` again so the limited converge includes `monitoring-vm` as well as the control plane. Without that extra host context, the gateway wildcard Caddy template could render without a monitoring upstream and leave the internal HTTPS aliases serving a `502` placeholder instead of the real monitoring services.

### Documentation
- **`docs/roadmap/in-perimeter-deployment-source.md`** + **`docs/README.md`** + **`README.md`**: Added a detailed roadmap proposal for moving the deployment source inside the tailnet perimeter. The new document compares controller-placement models, analyzes destructive redeploy risks, and explicitly covers detach / destroy / redeploy / reattach migration variants for a dedicated dev or ops machine.
- **`docs/roadmap/in-perimeter-deployment-source.md`**: Expanded the proposal into a stronger product-direction document for a self-managed private cloud. The roadmap now defines what digital independence should mean in practice, adds usability and resilience goals, and spells out expected degraded behavior when gateway, control, workload, controller, or client devices fail.

## [1.8.33] — 2026-03-23

### Fixed
- **`scripts/deploy.sh`**: Fixed the documented Namecheap follow-up command `./scripts/deploy.sh gateway --env <env>` so the gateway-only converge still includes the control-plane context needed by the Tailscale/Headscale preauth-key path. Without that, the second gateway run could fail before wildcard TLS activation even after the gateway IP had been allowlisted.

## [1.8.32] — 2026-03-23

### Changed
- **`README.md`** + **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`** + **`scripts/helpers/deployment-summary.sh`**: Clarified the Namecheap-only wildcard activation flow across the top-level docs, technical docs, user guide, and deploy summary. Deployments still run straight through by default, but when `internal_service_tls_mode: namecheap` is enabled the operator is now explicitly told to let the initial deploy finish, whitelist the gateway public IP in Namecheap, and then run `./scripts/deploy.sh gateway --env <env>` once to activate the wildcard certificate. Other TLS modes/providers are documented as one-pass flows.

## [1.8.31] — 2026-03-23

### Changed
- **`scripts/helpers/deployment-summary.sh`** + **`docs/technical/OPERATIONS.md`**: The deployment summary now always ends with an explicit `IMPORTANT` operator action when `internal_service_tls_mode: namecheap` is enabled. It tells the user to add the current gateway public IP to the Namecheap API allowlist and re-run the gateway converge step before expecting wildcard issuance or renewal to work.

## [1.8.30] — 2026-03-23

### Fixed
- **`ansible/roles/gateway/templates/Caddyfile.j2`** + **`ansible/roles/gateway/tasks/main.yml`**: Fixed the gateway wildcard Caddy configuration after live redeploy validation. The Namecheap-backed `*.in.<domain>` block now uses valid Caddy TLS/email syntax, and the gateway derives the Namecheap API client IP from its public IP facts instead of whichever `ansible_host` happened to be active.
- **`ansible/roles/tailscale/tasks/main.yml`** + **`scripts/tests/30_verify_tailscale_ssh_optional.sh`**: Added an idempotent Headscale node rename step so MagicDNS actually resolves canonical VM hostnames such as `monitoring-vm.in.<domain>` instead of silently keeping stripped `given_name` values. The Tailscale SSH fallback checks now match the same `-vm` hostnames.
- **`scripts/deploy.sh`** + **`scripts/helpers/deployment-summary.sh`**: Removed stale bare-hostname assumptions from deploy-time Tailscale peer probing and updated the deployment summary to show `monitoring-vm` as the direct node name plus an explicit Namecheap gateway-IP allowlist warning when `internal_service_tls_mode: namecheap` is enabled.

## [1.8.29] — 2026-03-23

### Changed
- **`ansible/inventory/tfgrid.py`** + **`ansible/roles/tailscale/tasks/main.yml`** + **`scripts/tests/common.sh`** + **`scripts/tests/60_verify_monitoring_stack.sh`** + **`ansible/roles/monitoring/templates/prometheus.yml.j2`**: Finalized the clean `*-vm` MagicDNS naming model. Tailscale registrations, dynamic inventory, monitoring labels, and test helpers now preserve VM hostnames with the `-vm` suffix instead of silently normalizing them away, so direct node access and future workload naming stay consistent with the gateway-ingress architecture.
- **`ansible/roles/gateway/defaults/main.yml`** + **`ansible/group_vars/gateway/main.yml`** + **`ansible/playbooks/group_vars/gateway/main.yml`** + **`environments/example/group_vars/gateway.yml`** + **`environments/prod/group_vars/gateway.yml`**: Updated gateway upstream examples/defaults to use VM inventory names such as `app-vm`, matching the canonical hostname model.

### Fixed
- **`ansible/group_vars/all/main.yml`** + **`ansible/roles/monitoring/tasks/main.yml`**: Fixed YAML indentation for Namecheap DNS resolver defaults and removed the duplicated `when` / over-broad CA export condition in the monitoring role so the internal-PKI path remains valid and only runs when enabled.

### Documentation
- **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`** + **`docs/user/GUIDE.md`**: Updated MagicDNS examples to distinguish service aliases such as `grafana.in.<domain>` from direct VM names such as `myapp-vm.in.<domain>`.

## [1.8.28] — 2026-03-23

### Changed
- **`ansible/group_vars/all/main.yml`** + **`ansible/playbooks/site.yml`** + **`ansible/roles/gateway/tasks/main.yml`** + **`ansible/roles/gateway/templates/Caddyfile.j2`** + **`ansible/roles/monitoring/tasks/main.yml`**: Added `internal_service_tls_mode` for tailnet-only MagicDNS service aliases. The new `namecheap` mode moves `grafana.*`, `prometheus.*`, and `backrest.*` HTTPS termination to the gateway Tailscale IP and issues a browser-trusted wildcard certificate for `*.headscale_magic_dns_base_domain` via `caddy-dns/namecheap` v1.0.0, while the existing `internal` mode remains the default fallback using the monitoring VM's private CA.
- **`ui/lib/config_reader.py`** + **`ui/server.py`** + **`ui/static/app.js`** + **`ui/tests/test_config_dns.py`**: The Web UI DNS section now exposes the MagicDNS base domain and internal service TLS mode, and persists those values into `group_vars/all.yml`.

### Fixed
- **`scripts/tests/60_verify_monitoring_stack.sh`**: Tailnet monitoring verification now distinguishes between private-CA MagicDNS mode and Namecheap-backed wildcard mode. In wildcard mode it asserts that the gateway Caddy image includes `dns.providers.namecheap` and verifies the internal HTTPS aliases without `-k`.

### Documentation
- **`README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`**: Documented the new internal service TLS modes, the gateway wildcard proxy path, and the extra Namecheap API allowlisting requirement for gateway-based wildcard renewals.

## [1.8.27] — 2026-03-23

### Fixed
- **`scripts/deploy.sh`** + **`ui/tests/test_deploy_cli.py`** + **`docs/user/GUIDE.md`**: `join-local` now normalizes the local machine hostname before passing it to `tailscale up`. This prevents fallback client names like `invalid-xxxx` when the OS hostname contains spaces, apostrophes, uppercase letters, or other invalid characters.

## [1.8.26] — 2026-03-23

### Changed
- **`scripts/helpers/deployment-summary.sh`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Fresh-tailnet recovery guidance now uses the correct order: reset and reconnect first, verify `tailscale status` and MagicDNS resolution second, and only then apply OS-specific DNS cache flushes as fallback. The summary now includes fallback guidance for macOS, Linux, Windows, and mobile clients.

## [1.8.25] — 2026-03-22

### Fixed
- **`scripts/deploy.sh`** + **`ui/lib/config_reader.py`** + **`ui/lib/job_runner.py`** + **`ui/server.py`** + **`ui/tests/test_deploy_recording.py`** + **`ui/tests/test_deploy_cli.py`**: UI and deploy regression tests no longer create temporary environment directories inside the real `environments/` tree. This prevents leaked test folders such as `ui-self-record-*` and `deploy-cli-fresh-*` from appearing in the Web UI environment selector after interrupted or local test runs.

## [1.8.24] — 2026-03-20

### Changed
- **`scripts/deploy.sh`** + **`ansible/roles/headscale/tasks/main.yml`** + **`ansible/roles/tailscale/tasks/main.yml`**: Tailnet identity is now preserved by default across redeploys. A new `--fresh-tailnet` deploy flag resets only Headscale node registrations and per-VM Tailscale state on destructive redeploys without disabling other service restores.
- **`ui/static/index.html`** + **`ui/static/app.js`** + **`ui/server.py`**: The Web UI now exposes the same `--fresh-tailnet` mode and blocks invalid combinations such as `--fresh-tailnet` with in-place converge.
- **`scripts/helpers/deployment-summary.sh`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`**: Fresh-tailnet deploy summaries now include explicit client reset steps (`tailscale up ... --reset` plus macOS DNS cache flush) so users can recover from stale local Tailscale or MagicDNS state after destructive redeploys.

## [1.8.22] — 2026-03-20

### Fixed
- **`ansible/roles/monitoring/templates/backrest-config.json.j2`** + **`scripts/tests/82_verify_backrest_auth.sh`**: Fixed Backrest 1.12.x compatibility by seeding a stable non-empty config `instance` and marking imported repos `autoInitialize: true`. Without those fields, the container either failed to start or the UI listed repos whose snapshot trees never loaded and whose dashboard usage stayed at `0 B`.

## [1.8.21] — 2026-03-20

### Changed
- **`scripts/deploy.sh`** + **`ui/lib/job_runner.py`**: Terminal-triggered deploys now record themselves into `environments/<env>/.ui-logs/` by default, while Web UI-launched deploys explicitly suppress that self-recording path to avoid duplicate History entries.

### Removed
- **`scripts/deploy-recorded.sh`**: Removed the separate terminal recording wrapper. `deploy.sh` is now the single deploy entrypoint for both normal terminal use and Web UI History import.

## [1.8.20] — 2026-03-20

### Fixed
- **`scripts/tests/20_verify_local_tailscale.sh`** + **`scripts/tests/60_verify_monitoring_stack.sh`**: Tailnet verification now checks transport-level reachability and direct monitoring HTTP access instead of relying on the default `tailscale ping` mode, which can time out even when Grafana and Prometheus are reachable over the tailnet. The monitoring check now also retries cold peer paths before failing and reports clean fallback HTTP status codes.
- **`ansible/playbooks/site.yml`**: Control-plane deploys now refresh `tailscaled` on all already-joined nodes after Headscale updates so stale peer state does not leave internal node pairs such as `monitoring-vm -> control` or `gateway -> control` disconnected after redeploy.

### Added
- **`docs/roadmap/logging-and-service-observability.md`** + **`docs/README.md`** + **`README.md`**: Added a roadmap/spec for lightweight centralized logging and service-level observability. The spec standardizes on Loki + Alloy, defines default retention as 30 days searchable plus 90 days archived total with automatic cleanup, excludes Tailscale from explicit default service monitoring, and spells out the required Grafana dashboards, saved queries, and log views for future service integrations.

## [1.8.19] — 2026-03-20

### Fixed
- **`scripts/deploy.sh`**: Fixed `join-local` / `--rejoin-local` to prefer the dedicated client preauth key from `headscale-authkeys.json` instead of incorrectly reusing the server-tag key. Workstations now rejoin Headscale as user-owned devices rather than being recreated as `tag:servers` nodes.

## [1.8.18] — 2026-03-20

### Fixed
- **`ansible/roles/headscale/templates/headscale-config.yaml.j2`**: Fixed the embedded DERP config rendering so the post-tailnet Headscale config re-render uses safe defaults outside the role context and emits valid YAML for public DERP IP fields. This unblocked live control-plane redeploys and restored the public `/derp` endpoint after the initial embedded-DERP rollout.

## [1.8.17] — 2026-03-20

### Added
- **`scripts/deploy-recorded.sh`** + **`ui/lib/job_cli.py`**: Added a terminal-first deploy wrapper that preserves normal stdout/stderr while writing the same combined output stream into `environments/<env>/.ui-logs/` for later replay in the Web UI History tab.

### Changed
- **`ui/lib/job_runner.py`** + **`ui/server.py`** + **`ui/static/app.js`**: The Web UI now imports terminal-recorded jobs from disk without needing a server restart, labels runs by source (`Web UI` vs `Terminal`), and tails recorded terminal logs while they are still running.

### Fixed
- **`ui/lib/job_runner.py`** + **`ui/tests/test_job_runner.py`**: Stale terminal jobs that never wrote final metadata are now recovered as `interrupted` instead of remaining stuck in `running`, so killed terminal deploys still appear correctly in UI history.

## [1.8.16] — 2026-03-20

### Changed
- **`ansible/roles/headscale/defaults/main.yml`** + **`ansible/roles/headscale/templates/headscale-config.yaml.j2`** + **`ansible/roles/headscale/templates/Caddyfile.j2`** + **`ansible/roles/headscale/tasks/main.yml`**: Switched the blueprint to Headscale's embedded DERP relay as the standard default for all deployments. The control VM now publishes a local DERP region on the same public hostname, retains the public Tailscale DERP map as extra fallback, and removes the legacy standalone `derper` container path.
- **`ansible/roles/firewall/tasks/main.yml`**: The control VM now opens UDP `3478` for DERP STUN as part of the default firewall baseline.
- **`scripts/helpers/deployment-summary.sh`** + **`docs/technical/ARCHITECTURE.md`** + **`docs/technical/OPERATIONS.md`** + **`docs/user/GUIDE.md`** + **`docs/README.md`** + **`README.md`**: Documented embedded DERP as a standard deployment element and surfaced the relay endpoint in the deployment summary and runbooks.

### Added
- **`scripts/tests/10_verify_headscale.sh`** + **`scripts/tests/12_verify_headscale_public_endpoint.sh`**: Added DERP verification to the Headscale test coverage. The suite now asserts that embedded DERP is enabled in the rendered config, the legacy standalone `derper` container is absent, and the public `/derp` endpoint is exposed.

## [1.8.14] — 2026-03-20

### Changed
- **`ansible/roles/monitoring/files/grafana-dashboards/backup-overview.json`**: Reworked the Backup Overview layout so `Backup Status` and `Restore Drill Status` share the top row at half-width each.
- **`ansible/roles/monitoring/files/grafana-dashboards/server-health.json`** + **`ansible/roles/monitoring/templates/prometheus.yml.j2`**: Reworked the Server Health layout into a 2x2 half-width grid, renamed `Node exporter up` to `Node status`, and switched dashboard legends and filters from raw scrape targets to MagicDNS-aware node display labels.

### Added
- **`scripts/tests/05_verify_grafana_dashboards.sh`** + **`scripts/tests/run.sh`**: Added a local dashboard JSON validation suite to catch layout or label regressions before deploy.

## [1.8.13] — 2026-03-20

### Fixed
- **`ansible/roles/monitoring/tasks/main.yml`** + **`ansible/roles/monitoring/templates/backrest-config.json.j2`**: Fixed Backrest login seeding from `SERVICES_ADMIN_PASSWORD`. Backrest expects `passwordBcrypt` to contain a base64-encoded bcrypt hash, while the previous deployment wrote the raw `$2b$...` hash string. The resulting config rendered successfully but caused every UI login attempt to fail.

### Added
- **`scripts/tests/82_verify_backrest_auth.sh`** + **`scripts/tests/run.sh`**: Added a backup-suite regression check that inspects the deployed Backrest config on the monitoring VM and fails when `passwordBcrypt` is not a valid base64-encoded bcrypt hash.

### Changed
- **`docs/user/GUIDE.md`** + **`docs/technical/BACKUP.md`**: Clarified that Backrest uses the shared `admin` account seeded from `SERVICES_ADMIN_PASSWORD` and documented the hash-format difference from Prometheus.

## [1.8.12] — 2026-03-20

### Changed
- **`ui/static/app.js`** + **`ui/static/style.css`**: Running deployment panes now mirror the active section title in the top header next to the job id, making it easier to see the current play without expanding the pane. The duplicated title is cleared as soon as the job finishes or when viewing completed jobs from history.

## [1.8.11] — 2026-03-20

### Fixed
- **`Makefile`**: `make ui` now detects when the Blueprint UI is already listening on port `8090` and exits cleanly with a helpful message instead of failing with an address-in-use traceback. `make ui-stop` now refuses to kill unrelated processes that happen to own the same port.
- **`ansible/roles/firewall/defaults/main.yml`** + **`ansible/roles/tailscale/defaults/main.yml`**: Added a local fallback for `tailscale_udp_port` in the firewall role and documented why it must mirror the tailscale role. This fixes destructive deploys failing in the firewall play with `'tailscale_udp_port' is undefined` when the firewall role runs independently of tailscale role defaults.

## [1.8.10] — 2026-03-19

### Fixed
- **`ui/lib/log_sections.py`** + **`ui/server.py`** + **`ui/static/app.js`**: Moved deploy-log sectioning to a structured server-side event stream. The UI now receives occurrence-based `section-start` / `line` / `section-end` events, so repeated or reordered Ansible plays no longer collide into a single section or disappear after the first occurrence.

### Added
- **`ui/tests/test_log_sections.py`**: Added parser coverage for repeated play titles and reconnect-style parser priming so section ids stay deterministic across replay.

### Changed
- **`ui/README.md`** + **`docs/technical/ARCHITECTURE.md`**: Documented the structured SSE section stream and why it fixes repeated/reordered Ansible play rendering.
- **`ui/static/index.html`** + **`ui/server.py`**: Added UI cache-busting. The HTML shell is now served with `Cache-Control: no-store`, and static asset URLs include the current repo version so browser caches pick up new JS/CSS after an update.

## [1.8.9] — 2026-03-19

### Changed
- **`ui/static/index.html`** + **`ui/static/app.js`** + **`ui/static/style.css`**: Replaced the Deploy tab's binary `--no-destroy` checkbox with an **Existing Infrastructure** dropdown. Web UI deploys are non-interactive, so the dropdown now preselects either in-place converge (`--no-destroy`) or destroy-and-recreate (`--yes`) for `full`, `gateway`, and `control` runs.

### Fixed
- **`ui/server.py`**: Added request validation that rejects conflicting deploy flags when both `--yes` and `--no-destroy` are supplied.
- **`docs/README.md`** + **`docs/user/GUIDE.md`** + **`docs/technical/OPERATIONS.md`** + **`ui/README.md`**: Updated the UI documentation to explain the new existing-infrastructure selection and its mapping to `deploy.sh` flags.

## [1.8.8] — 2026-03-19

### Fixed
- **`ansible/roles/tailscale/defaults/main.yml`** + **`ansible/roles/tailscale/tasks/main.yml`** + **`ansible/roles/firewall/tasks/main.yml`**: Pinned `tailscaled` to UDP `41641` and documented the firewall coupling. This prevents a regression where public nodes chose random UDP ports, appeared healthy in `tailscale status`, but dropped new client-initiated sessions because UFW blocked the ephemeral port.
- **`ansible/roles/headscale/templates/Caddyfile.j2`** + **`ansible/roles/headscale/templates/acl.hujson.j2`**: Documented the Headscale/Caddy streaming and peer-inclusion workarounds so future cleanup does not accidentally remove the behavior required by Headscale v0.28.
- **`ansible/roles/monitoring/tasks/main.yml`**: Documented why Prometheus `web.yml` must stay world-readable in the mounted container path to avoid restore-time crash loops.

## [1.8.7] — 2026-03-19

### Added
- **`ui/static/app.js`**: Live task counter in Ansible play section headers — counts `TASK [...]` lines as they stream in; shows `3 tasks` while running, `3 / 12 tasks` when the total from the previous run is known. Totals are persisted per environment/section in `localStorage` so the expected count is shown from the very first line of the next run.
- **`docs/roadmap/ui-deployment-eta.md`**: Roadmap document for the planned server-side ETA feature (per-section timing profile, EMA updates, `GET /timing/{env}` endpoint, live countdown).

## [1.8.6] — 2026-03-19

### Fixed
- **`ui/static/style.css`**: Log pane is now a fixed `height: 520px` instead of `max-height: 600px` — prevents the page from jumping when sections collapse and grow.
- **`ui/static/app.js`**: Section transitions (`getOrCreateSection`, `collapseAllSections`) now scroll within the log-wrap container instead of calling `scrollIntoView` on the page, so the viewport never moves.

## [1.8.5] — 2026-03-19

### Changed
- **`ui/static/app.js`** + **`ui/static/style.css`**: Cancel button is now gray (consistent with other buttons); requires a two-step confirm — first click shows "Confirm?" and arms a 3-second timeout, second click executes the cancel. Auto-resets if the user does not confirm within 3 s.


## [1.8.4] — 2026-03-19

### Added
- **`ansible/roles/headscale/tasks/main.yml`**: New task creates a user-owned (no-tags) preauth key for client devices (laptops/workstations) in addition to the existing `tag:servers/db/backup` keys. The key is stored under `authkeys.client` in `headscale-authkeys.json`.
- **`ui/static/app.js`** + **`ui/static/style.css`**: Collapsible log sections in the job pane — each major deployment phase (env, terraform, DNS, ansible plays, summary) gets its own collapsible section with a status dot; sections collapse when done, all collapse at job completion except the summary; clicking any header expands/collapses it.

### Fixed
- **`ansible/roles/headscale/templates/Caddyfile.j2`**: Added `transport http { versions 1.1 }` to the `reverse_proxy` block — prevents Caddy's HTTP/2 backend mode from stripping `Connection: upgrade`, which was breaking the Tailscale `/ts2021` noise-protocol handshake and causing `tailscale up` to hang.
- **`scripts/helpers/deployment-summary.sh`**: `get_preauth_key()` now returns the `client` key (user-owned, no server tags) instead of the `servers` tagged key. Server-tagged keys caused client devices to register with zero-expiry (a Headscale tagged-node limitation).

## [1.8.3] — 2026-03-19

### Added
- **`ui/`**: Cancel button on running job panes — sends SIGTERM to the deploy subprocess via `DELETE /jobs/{id}`; button hides automatically when the job finishes; shows "Cancelling…" while waiting for the process to exit.
- **`ui/lib/job_runner.py`**: `Job.cancel()` method and `_process` slot to hold the live subprocess handle.
- **`ui/server.py`**: `DELETE /jobs/{job_id}` endpoint (returns 409 if job is not running).
- **`ui/static/style.css`**: `.btn-danger` variant and `:disabled` style for the Cancel button.

## [1.8.2] — 2026-03-19

### Fixed
- **`Makefile`**: added `make ui-stop` target (sends SIGINT to the process on port 8090); added `--timeout-graceful-shutdown 1` to `make ui` so a single Ctrl-C exits within ~1 s even with active SSE connections; corrected help text port (8080 → 8090).
- **`ui/lib/job_runner.py`**: `rebuild_from_disk()` now detects jobs whose status is still `"running"` after a server restart (i.e. the server was killed mid-run), marks them `"interrupted"`, stamps `end_time`, and re-saves the metadata so they no longer appear as live on next startup.
- **`ui/static/app.js`**: history view and job-pane phase label now correctly reflect `"interrupted"` status.
- **`ui/static/style.css`**: added `.status-dot.interrupted` (amber, no animation) to visually distinguish crashed/interrupted jobs from running, done, and failed states.

## [1.8.1] — 2026-03-19

### Changed
- **`docs/README.md`**: replaced the manual step-by-step quick start with a UI-first flow (`make ui-install` / `make ui`); collapsed verbose CLI substeps; updated roadmap entry to mark web-ui as implemented (v1.8.0).
- **`docs/user/GUIDE.md`**: promoted web UI to Option A (recommended); fixed broken Option B sub-heading numbering; added web UI to "What you get" list; added two web-UI troubleshooting rows.
- **`docs/technical/ARCHITECTURE.md`**: added "Web UI" section covering architecture, security properties, SSE replay model, and repo layout.
- **`docs/technical/OPERATIONS.md`**: added "Web UI" operations section with screen reference, log persistence details, and API endpoint table.
- **`docs/roadmap/web-ui.md`**: marked as fully implemented; updated title, all phase headings (`✓ implemented`), and added implementation status notice.

## [1.8.0] — 2026-03-19

### Added
- **Web UI** (`ui/`): a locally-hosted deployment dashboard and configuration interface.
  - **Deploy tab** (Phase 1): trigger `deploy.sh` from the browser with scope/env selectors and option toggles; live log streaming via Server-Sent Events with ANSI colour rendering and automated phase detection (Terraform + Ansible phases); SSE `Last-Event-ID` replay — closing and re-opening the browser tab at any point resumes from the last received line; multiple parallel deploy panes.
  - **Configure tab** (Phase 2): form-based editing of `terraform.tfvars` (network, name, scheduler toggle, SSH keys), `secrets.env` (mnemonic, admin password, DNS API keys, backup credentials), and env-level `group_vars/all.yml` (DNS settings, backup toggle); sensitive fields are write-only — the display shows "saved" / "not set" without echoing values.
  - **Status tab** (Phase 3): public IPs for gateway and control VMs, clickable service URLs (Headscale, Headplane admin, Grafana, Prometheus) derived from `terraform-outputs.json` and `group_vars`.
  - **Environments tab**: environment listing with config completeness indicators and last-deploy status; "New environment" button creates a directory from the example template; quick-links to Configure and Status per environment.
  - **History tab**: all past and current jobs (from disk, survives server restart); click to replay any job log.
  - Job log files persisted under `environments/<env>/.ui-logs/` — survive browser and server restarts.
  - `make ui` target launches the server on `http://localhost:8090`.
  - `make ui-install` installs Python dependencies (`fastapi`, `uvicorn`, `pyyaml`, `python-dotenv`, `python-hcl2`).

## [1.7.2] — 2026-03-19

### Fixed
- **`20_verify_local_tailscale.sh`**: `wait_for_cluster_peer` hardcoded `control.in.babenko.live` and `gateway.in.babenko.live`, breaking the test in any non-babenko environment. Now resolves peer IPs from `tailscale_ip_for_host` (inventory JSON or live tailscale status).
- **`80_verify_backup_restore.sh`**: Prometheus `/api/v1/rules` was queried without credentials. Now that Prometheus has basic auth enabled, this returned 401 and the check silently failed. Fixed to pass `SERVICES_ADMIN_PASSWORD`.

### Added
- **`60_verify_monitoring_stack.sh`**: Added Prometheus unauthenticated-rejection check (warn if `/api/v1/targets` doesn't return 401 without credentials — catches misconfigured auth).
- **`60_verify_monitoring_stack.sh`**: Added Caddy internal CA cert presence check on the monitoring VM (warns if `/opt/monitoring-caddy/ca.crt` is missing).
- **`60_verify_monitoring_stack.sh`**: Added Backrest UI liveness check via raw Tailscale IP (HTTP 200/302/401 all pass; 000 warns that backup may be disabled).
- **`80_verify_backup_restore.sh`**: Added Backrest API HTTP status check when the Backrest container is running, verifying the web server is actually responding.

## [1.7.1] — 2026-03-19

### Added
- **HTTPS for service subdomains via Caddy internal PKI**: `grafana.*`, `prometheus.*`, and `backrest.*` MagicDNS URLs now serve HTTPS using Caddy's `tls internal` module. Caddy generates its own root CA and issues certs for all service subdomains automatically. The root CA cert is exported to `/opt/monitoring-caddy/ca.crt` on the monitoring VM after deployment — install it on your devices for browser-trusted HTTPS, or just accept the warning (connection is still encrypted).
- **Caddy data persistence**: the `monitoring-caddy` container now mounts `/opt/monitoring-caddy/data` so the internal CA survives container restarts and redeployments. Without this, each redeploy would generate a new CA and invaliate any previously trusted certs.
- **ACL port 443 for tailnet members**: Headscale ACL now allows `autogroup:member` access to `tag:servers:443` so the HTTPS service aliases are reachable from client devices.

### Fixed
- **Remaining `GRAFANA_ADMIN_PASSWORD` references**: renamed to `SERVICES_ADMIN_PASSWORD` in `docs/user/GUIDE.md`, `docs/technical/BACKUP.md`, `scripts/tests/80_verify_backup_restore.sh`, `scripts/tests/common.sh`, and `environments/prod/secrets.env`.

### Changed
- Deployment summary now shows `https://` for MagicDNS service URLs and includes CA cert trust instructions.
- Monitoring test (`60_verify_monitoring_stack.sh`) checks MagicDNS aliases over HTTPS with `-k` (cert not installed system-wide on control VM).

## [1.7.0] — 2026-03-18

### Added
- **Unified `SERVICES_ADMIN_PASSWORD` secret**: replaces `GRAFANA_ADMIN_PASSWORD`. One password covers Grafana, Prometheus, and Backrest initial login. Set it in `secrets.env`; change per-service after first login.
- **Prometheus HTTP basic auth**: Prometheus API and UI now require credentials (`admin / SERVICES_ADMIN_PASSWORD`). Auth is configured via a provisioned `web.yml` file and `--web.config.file`. The `/-/healthy` endpoint remains unauthenticated for health checks.
- **Backrest config provisioning**: Backrest now receives a generated `config.json` at deploy time containing auth (bcrypt-hashed password) and all S3 repos from `backup_backends` for each service in `backrest_watched_services` (default: headscale, gateway, monitoring). Repos are immediately visible in the UI without manual setup.
- **Grafana password sync**: the monitoring role now runs `grafana-cli admin reset-admin-password` after every deploy, ensuring the running Grafana instance always reflects the configured password even when the container was previously initialized with a different value.
- **Sanitized deployment summary file**: `deploy.sh` now saves a copy of the deployment summary (without API keys and Tailscale auth keys) to `environments/<env>/deployment-summary.txt` after each deploy. Sensitive keys are replaced with pointers to their source files.

### Fixed
- **Deployment summary showed wrong Grafana credentials**: the summary hardcoded `admin / admin` instead of reading the configured `SERVICES_ADMIN_PASSWORD`.

### Changed
- `GRAFANA_ADMIN_PASSWORD` is removed from `secrets.env.example`; use `SERVICES_ADMIN_PASSWORD` instead.
- `ansible/roles/monitoring/defaults/main.yml` now derives `grafana_admin_password` from `services_admin_password` (set in group_vars) rather than reading its own env var.
- Monitoring test (`60_verify_monitoring_stack.sh`) reads `SERVICES_ADMIN_PASSWORD` and passes credentials to the Prometheus API check.

## [1.6.20] — 2026-03-17

### Fixed
- **MagicDNS service alias access policy**: tailnet members can now reach private service aliases such as `grafana.in.*` and `prometheus.in.*` over port 80. The Headscale ACL template previously allowed only raw service ports (`3000` and `9090`), which left the hostname-based HTTP proxy reachable only from server-tagged nodes.
- **Monitoring verification coverage**: the monitoring test now verifies the MagicDNS service aliases through the control node in addition to the raw Prometheus and Grafana ports.

## [1.6.19] — 2026-03-17

### Fixed
- **MagicDNS recovery after fresh-start Headscale redeploys**: `join-local` now treats a stale local Tailscale session as unhealthy when it still has an old IP but can no longer synchronize with the rebuilt Headscale control plane. This prevents workstations from keeping ghost registrations after environments with `headscale_restore_database: false` are redeployed.
- **Environment-scoped deployment summary tailnet data**: the deployment summary now reads Tailscale IP mappings from the active environment inventory instead of falling back to the shared legacy inventory path.
- **Headscale DNS config completeness**: the rendered Headscale config now writes explicit empty `dns.nameservers` and `dns.search_domains` blocks, matching what Headplane expects when reading the config.

## [1.6.18] — 2026-03-17

### Fixed
- **Tailscale state restore collision**: `tailscale` backup repositories are now scoped per host instead of shared by service name. This prevents multiple VMs from restoring the same node identity and coming up with duplicate Tailscale IPs.
- **Secondary backup consistency**: the runtime backup wrapper no longer treats the secondary backend as optional or non-fatal. Secondary backup and prune failures now fail the backup job consistently, matching the deploy-time validation.
- **Backup drill alignment**: the restore drill now checks the correct per-host `tailscale` repositories.

### Changed
- Updated backup documentation and examples to describe mandatory dual-backend behavior and host-scoped `tailscale` repositories.

## [1.6.17] — 2026-03-16

### Fixed
- **TFGrid "global workload with the same name exists: conflict"**: ThreeFold Grid
  enforces globally unique network names and old names linger for several minutes
  after destroy, making immediate re-deploys fail. Each fresh full deploy now gets
  a unique network name by appending a `YYYYMMDD_HHMMSS` timestamp tag.
  - `terraform/variables.tf`: New `deployment_tag` variable (string, default `""`).
  - `terraform/main.tf`: `local.network_name` = `<name>_<tag>` when tag is set,
    plain `<name>` otherwise. `grid_network.net` uses `local.network_name`.
  - `scripts/deploy.sh`: `ensure_deployment_tag()` generates a tag on the first run
    and caches it to `environments/<env>/deployment-tag`. Subsequent applies (Ansible
    convergence, partial re-runs) read the cached tag — the TFGrid network name stays
    stable within a deployment lifecycle. On `scope_full` destroy, the cache file is
    deleted so a fresh tag is generated for the new deployment.
  - `environments/<env>/deployment-tag` added to `.gitignore`.

## [1.6.16] — 2026-03-16

### Added
- **Service subdomains** (`grafana.in.X`, `prometheus.in.X`, `backrest.in.X`): Private
  monitoring services are now reachable by service name (no port number) from any
  tailnet-connected device when `headscale_magic_dns_base_domain` is set.
  - `ansible/roles/monitoring/templates/monitoring-Caddyfile.j2`: New Caddy config
    that runs a port-80 HTTP reverse proxy on the monitoring VM's Tailscale interface,
    routing by hostname to local service ports (3000 / 9090 / 9898).
  - `ansible/roles/monitoring/tasks/main.yml`: Starts a `monitoring-caddy` Docker
    container with the above config when MagicDNS base domain is configured.
  - `ansible/playbooks/site.yml`: New "Headscale service DNS reconcile" play runs
    after all tailscale nodes have joined. It builds `extra_records` (A records for
    service names → monitoring VM Tailscale IP) from live `hostvars`, re-renders
    the headscale config, and restarts headscale so the DNS changes propagate to
    all tailnet clients immediately.
- **`headscale_restore_database` variable**: When set to `false`, headscale's node
  database (`db.sqlite`) is deleted after backup restore, giving a clean-slate
  headscale on every destructive redeploy. Caddy TLS certs, noise key, and ACL config
  are still restored. Set in `environments/<env>/group_vars/all.yml` to control per
  environment. Default: `true` (preserve existing behaviour — restore DB).

### Changed
- Deployment summary service URLs now show clean service subdomain URLs
  (`http://grafana.in.X`) with port-based fallback (`monitoring.in.X:3000`) shown
  as an alt URL. Backup section updated similarly.

## [1.6.15] — 2026-03-16

### Added
- **MagicDNS (internal DNS) support**: Headscale now enables MagicDNS automatically
  when `headscale_magic_dns_base_domain` is set in environment `group_vars/all.yml`
  (e.g. `headscale_magic_dns_base_domain: "in.example.com"`). Nodes become reachable
  by hostname — `control.in.example.com`, `gateway.in.example.com`, etc. — from any
  tailnet-connected device without raw IP addresses.
- **Headplane API key persisted during deploy**: The headscale Ansible role now generates
  a Headplane API key after every deploy and saves it to
  `environments/<env>/inventory/headplane-api-key.txt`. The deployment summary displays
  it under the Headplane section for immediate use at `<headscale_url>/admin`.
- **Deployment summary improvements**:
  - Internal DNS names (MagicDNS) displayed next to every tailnet node.
  - Service URLs (Grafana, Prometheus, Backrest) show MagicDNS hostnames when
    `headscale_magic_dns_base_domain` is set, falling back to Tailscale IPs.
  - Headplane API key shown inline under the Headplane block.
  - Pre-auth key auto-injected into the device join command.
  - SSH target uses MagicDNS hostname (`control.in.example.com`) when available.
  - Backrest UI URL now included in the Backup section with the resolved host.
  - Cleaner structure: Infrastructure, Services, Tailnet, Backup, Connecting, Reference.

### Fixed
- **Headscale initial user email**: `headscale_user` in the headscale role defaults now
  derives from `admin_email` (e.g. `babenko.nickolay@gmail.com` from env group_vars)
  instead of the hardcoded `main@example.com`. Set `admin_email` once and it propagates
  to the headscale user, ACME email, and Grafana notifications.
- **Headscale DNS page error**: The headscale config template set `base_domain: ""`
  unconditionally, causing an "Unexpected Server Error" on the DNS page in Headplane.
  The template now writes the correct `base_domain` when MagicDNS is configured and
  keeps a safe empty value otherwise.
- **Tailscale node names aligned with internal DNS**: Server VMs are now registered in
  the tailnet as `control`, `gateway`, `monitoring` (without the `-vm` suffix), so the
  MagicDNS names match the descriptive short names used throughout the documentation
  and roadmap (`control.in.example.com`, not `control-vm.in.example.com`).

## [1.6.14] — 2026-03-16

### Fixed
- `deploy.sh`: ThreeFold Grid provider `state.json` (subnet registry) is now isolated per environment. Previously all environments shared `terraform/state.json`, causing subnet allocation bleed between `prod` and `test`. Each environment now maintains its own `tf-grid-state.json` in `environments/<env>/`, which is restored before and saved after every Terraform run.

### Added
- No documented changes yet.

## [1.6.13] - 2026-03-15

### Fixed
- **Deployment summary incorrectly reported "Backup System: DISABLED"** even when
  `backup_enabled: true` was set in an environment-specific `group_vars/all.yml`.
  `scripts/helpers/deployment-summary.sh` now reads env-specific group_vars
  (derived from `INVENTORY_JSON` path) and lets them override the base default,
  matching Ansible variable precedence. Also fixed a multi-match bug where
  `grep -oP` returned multiple lines, causing the string comparison to fail.
- **Caddy TLS cert now persists across destructive redeploys (Option 1)**:
  `ansible/roles/headscale/defaults/backup.yml` already includes `/opt/caddy/data`
  as a backup target. The restore task in `site.yml` runs before the headscale role
  starts Caddy, so on every redeploy after the first the LE cert is restored from
  S3 and reused — no new certificate request, no rate limit exposure.
  Test env `headscale_tls_mode` switched back to `letsencrypt` to benefit from this.
  (If the LE rate limit is active, temporarily set `headscale_tls_mode: internal`.)

## [1.6.12] - 2026-03-15

### Fixed
- **Full destructive redeploy now completes in a single shot**: Two blocking issues were resolved:
  1. `scripts/deploy.sh` (`scope_full`) now calls `dns_setup` between `refresh_inventory` and
     `ansible_run`, so DNS is updated to the new control-vm IP before Ansible bootstraps Headscale
     and Tailscale. Previously, if the grid scheduler assigned a different IP on each redeploy,
     the Let's Encrypt ACME challenge would fail and `tailscale up` would time out.
  2. `ansible/playbooks/site.yml` auto-switch to `letsencrypt` now only fires when
     `headscale_tls_mode` is **not explicitly set** in group_vars/host_vars (uses
     `vars['headscale_tls_mode'] is not defined`). Previously it also overrode explicit
     `headscale_tls_mode: internal` settings.
- **Test environment uses internal TLS by default**: `environments/test/group_vars/all.yml` now
  explicitly sets `headscale_tls_mode: internal`, avoiding repeated Let's Encrypt certificate
  requests during destructive redeploys (which would quickly exhaust the 5-cert/7-day rate limit).
  Caddy's internal CA cert is automatically installed into the system trust store on all VMs.

## [1.6.11] - 2026-03-15

### Fixed
- **Backup summary script no longer fails with `tailscale_ip is undefined` on monitoring VM**: Added
  two fallback tasks in `ansible/roles/backup/tasks/deploy.yml` that run `tailscale ip -4` on the
  monitoring host when `tailscale_ip` is not already set. This mirrors the same pattern used in the
  monitoring role, and fires only for monitoring hosts when the backup summary is enabled.
  Verified end-to-end with a full destructive redeploy to the test environment.

## [1.6.10] - 2026-03-15

### Fixed
- **Test suite now auto-loads environment secrets**: `scripts/tests/common.sh`
  now sources `environments/<env>/secrets.env` at startup (same way `deploy.sh`
  does). This makes credentials like `GRAFANA_ADMIN_PASSWORD` and
  `BACKUP_S3_*` available to all tests without requiring the user to
  pre-export them. The `ENV` variable is also accepted as an alias for
  `TEST_ENV` for consistency with `deploy.sh`.
- **Monitoring test no longer requires local Tailscale ACL access**:
  Changed `require_tailscale` to `require_tailscale_or_gateway` in
  `60_verify_monitoring_stack.sh` — consistent with the other fixed tests.

## [1.6.9] - 2026-03-15

### Fixed
- **SSH known_hosts cleared automatically on deploy**: ThreeFold frequently
  reuses public IPs when VMs are destroyed and recreated, causing Ansible
  to fail with "REMOTE HOST IDENTIFICATION HAS CHANGED". Added
  `clear_stale_host_keys()` to `deploy.sh` — called automatically after
  `refresh_inventory` in every deploy scope (full, gateway, control). It
  extracts all IPv4 addresses from `terraform-outputs.json` and removes
  any matching entries from `~/.ssh/known_hosts` before Ansible runs.
- **Recovery test runs without local Tailscale ACL access**: Changed
  `require_tailscale` to `require_tailscale_or_gateway` in
  `40_break_and_recover_headscale_container.sh`. Also added
  `--allow-ssh-from-my-ip` to the internal `run_deploy` call so the
  firewall lockdown at the end of the converge keeps a recovery SSH path
  open for the final verification step.

## [1.6.8] - 2026-03-15

### Fixed
- **Pre-destroy backup hook now picks up environment credentials and config**:
  When `deploy.sh` runs a pre-destroy backup (the prompt "Destroy and recreate?
  [y/N]"), the backup hook (`scripts/hooks/backup.sh`) was invoking
  `ansible-playbook` without the environment-specific group_vars, causing
  Ansible to see only role defaults (`backup_backends: []`) and failing with
  "no backends are configured with credentials". Three issues fixed:
  1. `attempt_backup()` now exports `ENV_INVENTORY_DIR` and `ENV_NAME` so
     the hook subprocess can access them.
  2. The backup hook now sets `TF_OUTPUTS_JSON` / `TAILSCALE_IPS_JSON`
     unconditionally (not behind an `ENV_INVENTORY_DIR` guard).
  3. The backup hook now adds `--extra-vars @environments/<env>/group_vars/*.yml`
     so `backup_backends`, `backup_enabled`, and other env-specific variables
     are loaded — matching what the main `ansible_run()` does.

## [1.6.7] - 2026-03-15

### Fixed
- **Ansible deploy now works when Tailscale SSH is ACL-blocked from the controller**:
  `./scripts/deploy.sh full` was routing all VMs to their Tailscale IPs (due to
  local Tailscale being healthy), causing complete SSH failures when the controller
  machine is not an ACL-allowed SSH peer to the cluster. Fixed by:
  1. `prefer_tailscale_for_ansible()` in `deploy.sh` now probes actual SSH
     connectivity to the gateway's Tailscale IP (5s timeout) before deciding to
     set `PREFER_TAILSCALE=1`. Falls back to public-IP mode if the probe fails.
  2. `tfgrid.py` now routes `control-vm` through a gateway ProxyJump (using
     control's private IP) when not in Tailscale mode, since control's public
     SSH port may be firewalled by the firewall role. The private CIDR is always
     permitted by the firewall, so this path is reliable.

## [1.6.6] - 2026-03-15

### Fixed
- **Tests now work without local Tailscale connectivity**: Three tests that were
  previously skipped (`00_smoke.sh`, `60_verify_monitoring_stack.sh`,
  `80_verify_backup_restore.sh`) now run correctly on machines that are not
  ACL-allowed SSH peers to the control VM. Achieved by:
  1. Adding `tailscale_active()` to `common.sh` — checks the daemon actually
     has an IP, not just that the binary is installed.
  2. Adding `require_tailscale_or_gateway()` — passes if either local Tailscale
     is active or the gateway public SSH is reachable.
  3. Adding `ssh_via_gateway(ip, cmd...)` — uses `ProxyCommand` to jump via
     the gateway public IP and reach any private Tailscale IP inside the cluster.
  4. Adding `curl_via_gateway(url)` — tries a direct curl first, then routes
     through gateway SSH if that fails.
  5. Rewriting `ssh_root_control()` and `ssh_root_gateway()` with a 6-second
     direct-Tailscale probe that falls through silently to gateway-jump when
     the ACL blocks the direct path.
  6. Fixing `ssh_ts_host()` in `80_verify_backup_restore.sh` to use the same
     6-second probe + gateway-jump pattern instead of silently timing out.
  7. Making `control_public_ip()`, `gateway_public_ip()`, and
     `expected_vm_count()` read from `terraform-outputs.json` first so tests
     no longer need `terraform init`.

## [1.6.5] - 2026-03-15

### Fixed
- **Prometheus missing gateway target**: `gateway-vm` was not included in
  `tailscale-ips.json` (the tailscale role wrote it only during a full run with
  `--join-local`). Also, the Prometheus config template relied on `tailscale_ip`
  host facts that are only set when the tailscale role runs on each host — so a
  `--limit monitoring --tags monitoring` re-run produced a config with only
  monitoring-vm.  Fixed by:
  1. Adding `gateway-vm: 100.64.0.3` to `environments/test/inventory/tailscale-ips.json`.
  2. Adding a task to the monitoring role that reads `tailscale-ips.json` from
     the controller (via `TAILSCALE_IPS_JSON` env var) and stores it as
     `prometheus_tailscale_ip_map`.
  3. Updating `prometheus.yml.j2` to merge the JSON-map IPs alongside the
     `tailscale_ip` host facts so partial runs still generate a complete config.
- **node_exporter not installed on gateway**: The previous Ansible run did not
  complete on gateway-vm due to the tailscale bootstrap race (fixed in v1.6.3).
  Remediated by running the `node_exporter` and `backup` roles against gateway
  with `tailscale_ip=100.64.0.3` passed explicitly.

## [1.6.4] - 2026-03-15

### Changed
- **DNS TTL minimised**: Managed A records written by `dns-setup.sh` are now set
  to TTL=60 (Namecheap's minimum) instead of the default 1799s. Future IP
  changes propagate within ~60s instead of up to ~30 minutes.
- **DNS propagation wait — two-phase progress**: The propagation loop now queries
  Namecheap's own authoritative nameserver (`dig @<auth-NS>`) in addition to the
  public resolver. This lets the script distinguish "Namecheap accepted the record
  (authoritative updated)" from "globally propagated". Each poll line shows elapsed
  and remaining time so you can see progress at a glance.

## [1.6.3] - 2026-03-15

### Fixed
- **Tailscale bootstrap race on redeploy**: When the control VM gets a new public
  IP after a destroy+redeploy, the Headscale FQDN DNS record is updated but may
  not propagate before Ansible runs. Gateway (and other VMs) would resolve the
  old IP, fail `tailscale up`, and time out. Fixed by pinning `<headscale_fqdn>`
  to the control VM's current public IP in `/etc/hosts` on all VMs at the start
  of the `Base OS configuration` play, before the tailscale role runs. The
  `/etc/hosts` entry takes precedence over DNS during provisioning and remains
  harmless (and correct) after DNS propagates.

## [1.6.2] - 2026-03-15

### Fixed
- **Deployment summary**: `scripts/helpers/deployment-summary.sh` no longer calls
  `terraform output` (which failed without a local state file). All IP/URL values
  are now read directly from `terraform-outputs.json` via `INVENTORY_JSON`.
- **Deployment summary Headscale URL**: The summary now derives `headscale_url`
  from the environment's `group_vars/all.yml` (`base_domain` + `headscale_subdomain`)
  instead of the shared `headscale-authkeys.json` which could contain stale data
  from a different environment.

## [1.6.1] - 2026-03-14

### Added
- **DNS idempotency**: `dns-setup.sh` now compares desired A records against
  current Namecheap DNS state before writing. If all records are already
  correct, the script exits early without making any API write call.
- **DNS pre-write backup**: Before each `setHosts` call, the current
  `getHosts` XML response is saved to `~/.dns-backup/<domain>-<timestamp>.xml`
  for easy manual rollback.
- **DNS post-write verification**: After `setHosts` succeeds, the script
  re-fetches `getHosts` and confirms the desired records are present, failing
  hard if the API silently returned incorrect data.

### Changed
- **Control VM firewall**: Port 80/tcp is now open on the control VM alongside
  443. This allows Caddy to use the HTTP-01 ACME challenge for Let's Encrypt
  certificate issuance and to serve HTTP→HTTPS redirects.
- **DNS test (`15_verify_dns_setup.sh`)**: Live test block expanded to cover
  idempotency (second run must report no changes), backup file creation and
  validity, in addition to the existing dig resolution check.

## [1.6.0] - 2026-03-14

### Added
- **DNS automation (Phase 3)**: New `scripts/helpers/dns-setup.sh` script automates
  Namecheap DNS A record upserts after `terraform apply`. Reads control/gateway
  public IPs from Terraform outputs, fetches existing records (preserves unrelated
  entries), merges desired A records, and atomically updates via Namecheap API.
  Polls `dig` for propagation confirmation (5-minute timeout). Supports dry-run
  mode via `DRY_RUN=1`.
- **`dns` deploy scope**: New `./scripts/deploy.sh dns --env <name>` scope runs
  only the DNS update step without touching Terraform or Ansible. Useful for
  ad-hoc re-runs after a VM rebuild.
- **Automatic DNS in `full` deploy**: When `NAMECHEAP_API_KEY` is set in
  `secrets.env`, `deploy.sh full` automatically runs DNS updates after
  `terraform apply` and before Ansible. Silently skipped when not set
  (fully backwards-compatible).
- **DNS test**: New `scripts/tests/15_verify_dns_setup.sh` validates script
  existence, terraform output parsing, and dry-run behavior. Added to the
  `bootstrap-smoke` test suite.
- **Config variables**: `base_domain` and `headscale_subdomain` in
  `group_vars/all.yml`; `gateway_subdomains` in `group_vars/gateway.yml`
  for automated DNS record management.
- **`admin_email` variable**: Single source-of-truth email in
  `group_vars/all.yml`; `headscale_acme_email` now derives from it
  automatically.
- **Auto-derived Headscale config**: When `base_domain` is set, Ansible
  `pre_tasks` in `site.yml` automatically derive `headscale_url`
  (`https://<subdomain>.<base_domain>`) and switch `headscale_tls_mode`
  from `internal` to `letsencrypt`. No manual overrides needed.

### Changed
- **secrets.env.example**: Added `NAMECHEAP_API_USER` and `NAMECHEAP_API_KEY`
  placeholders to all environment templates (prod, test, example).
- **OPERATIONS.md**: Replaced Phase 3 planned stub with full implementation
  documentation including usage, env vars, and ad-hoc commands.
- **GUIDE.md**: Updated deploy scope reference table with `dns` scope;
  added DNS automation mention to the Headscale URL/TLS section.
- **group_vars consolidation**: Removed manual `headscale_tls_mode`,
  `headscale_acme_email`, and `grafana_admin_password` from group_vars
  templates (auto-derived or already in `secrets.env`).

## [1.5.1] - 2026-03-14

### Changed
- **Environments**: Moved environment-specific configs (`prod/`, `test/`) out of
  version control. Added `environments/example/` as a full reference template
  for creating new environments (`cp -r environments/example environments/prod`).
- **Documentation**: Replaced all site-specific domain references (`babenko.link`)
  with generic `yourdomain.com` throughout docs and roadmap.
- **DNS roadmap**: Expanded Phase 2 (per-domain upstream routing) and Phase 3
  (Namecheap API automation) documentation with detailed config formats,
  domain model, and implementation notes.

## [1.5.0] - 2026-03-14

### Fixed
- **Monitoring containers**: Switched Prometheus, Grafana, and Backrest from
  Docker bridge to host networking. Bridge containers could not reach Tailscale
  IPs for scraping node exporters on other VMs.
- **Node exporter restart**: Fixed Ansible role to use `zinit forget` + `zinit
  monitor` on config change (simple `zinit stop/start` does not re-read config
  files).
- **Prometheus scrape targets**: Template now falls back to `ansible_host` when
  `tailscale_ip` is not in hostvars, ensuring all VMs are scraped even when
  deploying monitoring role standalone.
- **Grafana datasource**: Converted from static file to template using the
  Tailscale IP so Grafana can reach Prometheus on host network.
- **Backup summary script**: Fixed Prometheus URL from `localhost:9090` to
  Tailscale IP (Prometheus now binds to Tailscale IP only). Replaced `bc`
  dependency with pure bash arithmetic. Added instance label to distinguish
  tailscale services across VMs.

### Changed
- **BACKUP.md**: Comprehensive update — reflected implemented status, replaced
  `restic copy` with `restic backup` in diagrams/flow, replaced systemd timer
  references with cron/zinit, replaced Alertmanager references with Prometheus
  alert rules, genericized bucket names, updated roadmap checklist.
- **OPERATIONS.md**: Updated backup examples with generic bucket names, fixed
  weekly summary description.
- **GUIDE.md**: Removed reference to default `sovereign-backups` bucket names.

### Verified
- Full metrics pipeline: node_exporter → Prometheus → Grafana working on all
  3 VMs with 6 backup services showing status=1.
- Prometheus alert rules (BackupFailed, BackupStale, BackupSizeAnomaly,
  BackupDrillFailed) evaluating correctly with health=ok, state=inactive.
- Grafana Backup Overview dashboard displaying real data from all 6 services.
- Backup drill script tested — integrity checks and file restores PASSED on
  both primary and secondary backends.
- Backup summary script tested — produces correct health report with all
  services showing ✓ OK.
- Backrest UI accessible at http://<monitoring-ts-ip>:9898.
- Auto-restore logic reviewed — correct guards on data dir empty + same env.

## [1.4.5] - 2026-03-14

### Fixed
- **Secondary backup**: Replaced `restic copy` (cross-provider credential issue)
  with direct `restic backup` to each backend independently. Both AWS S3
  and Hetzner Object Storage now receive their own backup runs with correct
  credentials.

## [1.4.4] - 2026-03-14

### Changed
- **S3 backend configuration**: Moved `backup_backends` from role defaults to
  per-environment config (`environments/<env>/group_vars/all.yml`). Role defaults
  now ship an empty list; each environment defines its own backends.
- **Hetzner endpoint**: Fixed secondary S3 endpoint from the non-existent
  `s3.eu-central-1.hetzner.com` to the correct Helsinki endpoint
  `hel1.your-objectstorage.com`.
- Updated all docs, examples, and secrets.env comments to reflect the new
  endpoint and configuration location.

## [1.4.3] - 2026-03-14

### Changed
- **Backup scheduling**: Replaced systemd timers with **cron jobs + zinit** for
  compatibility with ThreeFold Grid VMs (which use zinit, not systemd).
- **Backup wrapper scripts**: Added `PATH` export for `/usr/local/bin` so Restic
  is found when scripts run from cron's minimal environment.
- **Secondary backend**: Added `timeout 120` on `restic copy` and `restic forget`
  operations to prevent infinite hangs if the secondary endpoint is unreachable.
  Secondary failures are now non-fatal warnings.
- **Headscale backup manifest**: Fixed target paths from container paths to host
  paths (`/opt/headscale/data` and `/opt/headscale/config`). Changed SQLite backup
  hook from `docker exec` to host-side `sqlite3` command.
- **Backup test script** (`scripts/tests/80_verify_backup_restore.sh`): Updated
  from systemd timer checks to cron job checks.
- **Documentation**: Updated BACKUP.md, OPERATIONS.md, and GUIDE.md to reflect
  cron-based scheduling instead of systemd timers.

### Fixed
- Backup role now installs `cron`, `sqlite3`, and `bzip2` packages as dependencies.
- Fixed manifest discovery using `ansible.builtin.find` + `delegate_to: localhost`
  instead of `fileglob` (which failed inside `include_tasks` context).
- Fixed Ansible 2.16 compatibility by replacing `meta: end_role` with
  `include_tasks` + `when:` guard pattern.
- Fixed `backup-summary.sh.j2` undefined `tailscale_ip` variable — now uses
  `localhost` since the script runs on the monitoring VM.

## [1.4.2] - 2026-03-13

### Changed
- **Rewrote User Guide** (`docs/user/GUIDE.md`): restructured with clear quick-start
  flow, deploy script reference with all flags, node selection explanation,
  Headscale TLS section, and troubleshooting table.
- Added **step-by-step S3 setup instructions** for both AWS S3 (IAM user + bucket
  + minimal policy) and Hetzner Object Storage (bucket + S3 credentials).
- Added backup retention, schedule, and monitoring sections with configuration examples.
- Removed outdated standalone Terraform/Ansible sections that duplicated the
  recommended `deploy.sh` workflow.

## [1.4.1] - 2026-03-13

### Changed
- **Unified secrets management**: all secrets (TFGrid mnemonic, Grafana password,
  backup S3 keys) now live in a single `environments/<env>/secrets.env` file.
  Terraform picks up `TF_VAR_*` variables automatically; Ansible uses `lookup('env', ...)`.
- Removed `tfgrid_mnemonic` from `terraform.tfvars.example` files — it is now set
  via `TF_VAR_tfgrid_mnemonic` in `secrets.env`.
- Improved comments in `secrets.env.example`: clearly labels which S3 keys are
  for AWS (primary) and which are for Hetzner Object Storage (secondary).
- Improved comments in `terraform.tfvars.example`: explains node selection
  (`use_scheduler`, `gateway_node_id`, `control_node_id`) — why pinning nodes
  avoids flaky multi-node network creation on TFGrid.
- `deploy.sh` now warns when `secrets.env` is missing and validates that the
  TFGrid mnemonic is available before running Terraform.
- Updated all documentation (GUIDE, OPERATIONS, BACKUP, README) to reflect the
  new two-file setup: `secrets.env` for secrets + `terraform.tfvars` for config.

## [1.4.0] - 2026-03-13

### Added
- **Backup system** (Restic + S3): encrypted, deduplicated, incremental backups for all services.
  - New `ansible/roles/backup/` role: installs Restic, discovers service manifests,
    deploys per-service wrapper scripts + systemd timers, initializes repos, runs
    first backup on deploy.
  - Backup manifests for existing services: `headscale`, `gateway`, `monitoring`, `tailscale`
    (in each role's `defaults/backup.yml`).
  - Dual S3 backend support: primary + secondary with `restic copy`.
  - Auto-restore on fresh deploy: if snapshot exists and data dir is empty, restores
    automatically. Skippable via `--no-restore` flag on `deploy.sh`.
  - Per-service node_exporter textfile metrics: `backup_last_status`,
    `backup_last_success_timestamp`, `backup_last_size_bytes`, `backup_last_duration_seconds`.
  - Prometheus alert rules: `BackupFailed`, `BackupStale`, `BackupSizeAnomaly`, `BackupDrillFailed`.
  - Grafana "Backup Overview" dashboard: status, sizes, duration trends, drill results.
  - Backrest container on monitoring VM (Tailnet-only): web UI for browsing/restoring snapshots.
  - Weekly backup health summary script + systemd timer (Monday 08:00 UTC).
  - Weekly restore drill: `restic check` + restore to temp dir on all backends.
  - Test script: `scripts/tests/80_verify_backup_restore.sh` + `backup-verify` suite.
  - `--no-restore` flag in `deploy.sh` to skip auto-restore on fresh deploy.
  - `blueprint_env` variable passed from `deploy.sh` to Ansible for S3 path isolation.
  - Backup hook (`scripts/hooks/backup.sh`) now triggers real Ansible backup before destroy.
  - Backup operations section in `docs/technical/OPERATIONS.md`.
  - Backup section in `docs/user/GUIDE.md` with Owner Recovery Card reference.
  - Backup status in deployment summary output.

### Changed
- `node_exporter` role: added textfile collector directory + `--collector.textfile.directory`
  flag so backup metrics are scraped by Prometheus.
- `prometheus.yml.j2`: added `rule_files` for backup alert rules; Prometheus container
  now mounts `backup-alerts.yml`.
- Service roles (`headscale`, `gateway`, `monitoring`, `tailscale`): each now calls
  `backup/tasks/restore.yml` at the start for auto-restore on fresh deploy.
- `deploy.sh`: added `--no-restore` flag, `blueprint_env` extra-var, `NO_RESTORE` state.
- `scripts/hooks/backup.sh`: replaced TODO stub with real pre-destroy backup trigger.

## [1.3.0] - 2026-03-13

### Added
- Multi-network parallel access research document (`docs/research/multi-network-parallel-access.md`):
  evaluates ZeroTier, Netmaker, Nebula, Mycelium, OpenZiti against Tailscale/Headscale
  for multi-org access. Documents mobile VPN slot constraint, exit-node comparison,
  and bridge node architecture with dynamic split DNS.
- Perimeter Links feature specification (`docs/roadmap/perimeter-links.md`):
  complete product and architecture spec for cross-perimeter access via server-side
  bridge nodes. Includes Ansible role design, CoreDNS split DNS forwarding,
  configuration schema, security model, testing strategy, and implementation phases.

### Decision
- Networking stack confirmed: **Tailscale + Headscale** (no layer change).
- Cross-perimeter access approach: **Perimeter Links** (bridge node with subnet
  routing + dynamic split DNS). One-way outbound, runs on existing Gateway VM.

## [1.2.3] - 2026-03-13

### Changed
- Test suite updated for multi-environment model:
  - `scripts/tests/common.sh`: `TEST_ENV=<name>` is now required; derives
    `INVENTORY_DIR` and `TF_STATE` from it. `tf()`, `tf_out_raw()`, inventory
    helpers, and `run_deploy()` all use env-scoped paths.
  - `scripts/tests/run.sh`: `TEST_ENV` documented in usage.
  - `30_verify_tailscale_ssh_optional.sh`: reads `tailscale-ips.json` from
    `INVENTORY_DIR` instead of the legacy `ansible/inventory/` path.
  - `40_break_and_recover_headscale_container.sh`: uses `ssh_root_control`
    (Tailscale-first) instead of public IP SSH; drops `--allow-ssh-from-my-ip`.
  - `70_lockdown_public_ssh.sh`: passes `TF_OUTPUTS_JSON`/`TAILSCALE_IPS_JSON`
    env vars to the raw `ansible-playbook` call.
- `environments/prod/group_vars/all.yml`: `headscale_url`, `headscale_tls_mode`,
  and `headscale_acme_email` are commented out; sslip.io default is used until a
  real domain is configured.
- `environments/*/group_vars/gateway.yml`: added `{}` so all-comment files parse
  as an empty mapping for `--extra-vars @file` (was null, which caused Ansible to
  reject the file).

### Verified
- `TEST_ENV=prod bash scripts/tests/run.sh bootstrap-smoke` — PASS
- `TEST_ENV=prod bash scripts/tests/run.sh tailnet-management` — PASS
- `TEST_ENV=prod bash scripts/tests/run.sh headscale-recovery` — PASS

## [1.2.2] - 2026-03-13

### Changed
- `--env <name>` is now **required** for all scopes. Running without it exits with
  a clear error message instead of falling back to the legacy paths.
- `terraform/terraform.tfvars` present alongside an active env now causes a hard
  error (was a warning) to prevent silent variable conflicts.
- Removed all legacy fallback conditionals from `tf()`, `tf_apply_with_retries()`,
  `tf_state_list()`, `refresh_inventory()`, `ansible_run()`, `ansible_ping()`,
  `ansible_run_firewall_lockdown()`, and all scope functions.

## [1.2.1] - 2026-03-13

### Changed
- Migrated all prod runtime files from legacy paths to `environments/prod/`:
  `terraform.tfvars`, `terraform.tfstate*`, `state.json` (from `terraform/`) and
  `terraform-outputs.json`, `tailscale-ips.json`, `headscale-authkeys.json`,
  `headscale-root-ca.crt` (from `ansible/inventory/`).
- `.gitignore`: added `state.json` (replaces `terraform/state.json`), added
  `ansible/inventory/*.crt`, and `environments/*/state.json` patterns.
- `environments/prod/` is now the single source of truth for all prod state and
  secrets; the `terraform/` directory holds only source files.

## [1.2.0] - 2026-03-13

### Added
- **Multi-environment support** (`--env <name>` flag in `deploy.sh`): each named environment
  under `environments/<name>/` gets isolated Terraform state, tfvars, provider cache, and
  runtime inventory outputs. Environments `prod` and `test` are scaffolded.
- `environments/prod/` and `environments/test/` scaffolds: `group_vars/all.yml`,
  `group_vars/gateway.yml`, and `terraform.tfvars.example` per environment.
- `inv_dir()` helper in `deploy.sh`: all inventory read/write paths now route through this
  function so adding a new env-aware path requires a single-line change.
- `setup_env()` in `deploy.sh`: validates the env directory, populates `ENV_*` globals, and
  builds `ENV_ANSIBLE_EXTRA_FLAGS` with env-specific group_vars at highest Ansible precedence.
- `headscale_local_inventory_dir` Ansible variable in headscale role defaults: controls where
  authkeys and root CA cert are persisted on the controller; overridden per env by deploy.sh.
- `docs/roadmap/multi-environment.md`: roadmap covering remote state backend, per-env ACLs,
  secrets management, and promotion workflow.
- Architecture section: Multi-Environment Model in `docs/technical/ARCHITECTURE.md`.
- Operations runbook: Working with Environments in `docs/technical/OPERATIONS.md`.

### Changed
- `ansible_run()` refactored from a nested if/else tree into a clean array-based command
  builder; also now sets `TF_OUTPUTS_JSON` and `TAILSCALE_IPS_JSON` env vars for env runs.
- `ansible_ping()` and `ansible_run_firewall_lockdown()` similarly updated for env-awareness.
- `print_deployment_summary()` passes `INVENTORY_JSON` env var so the summary reads from
  the correct inventory directory.
- `deployment-summary.sh` now respects `INVENTORY_JSON` env var (falls back to legacy path).
- `.gitignore` extended to cover `environments/*/` runtime files and secrets.
- `GUIDE.md` updated with named-environment deploy instructions.

### Backward compatibility
- Without `--env`, all behavior is identical to v1.1.x. No breaking changes.

## [1.1.7] - 2026-03-13

### Added
- `docs/roadmap/dns-and-visibility.md`: new roadmap covering five phases of domain integration and service visibility (manual DNS + Let's Encrypt, per-domain upstream routing, Namecheap API automation, wildcard DNS-01 certs, Headplane behind MagicDNS).
- `docs/technical/ARCHITECTURE.md`: new "DNS and Service Visibility" section describing the two-namespace model (public DNS vs Tailscale MagicDNS), deploy sequence when IPs change, gateway single-IP anchor pattern, private service access model, and full configuration reference table.
- `docs/technical/OPERATIONS.md`: new runbooks for domain configuration (manual + API options), adding a new public service, and adding a new private (tailnet-only) service.
- `docs/user/GUIDE.md`: updated prerequisites and Headscale URL section to cover real-domain TLS, internal CA, and MagicDNS paths.
- `docs/README.md`: added dns-and-visibility roadmap to docs index.

## [1.1.6] - 2026-03-12

### Fixed
- Tailscale role: consolidated stop-monitor-start sequences into atomic shell tasks so a mid-run Ansible failure can no longer leave `tailscaled` in `target: Down`.
- Tailscale role: added a final "ensure tailscaled is started" safety-net task that always runs at the end of the role, preventing service outages from partial runs.
- Tailscale role: `tailscaled` is now restarted **after** CA trust update (not before), so each node trusts the Headscale CA before the join attempt.
- Headscale role: Caddy root CA cert is now persisted to `ansible/inventory/headscale-root-ca.crt` during deploy, enabling workstation CA bootstrap without public SSH access.
- `deploy.sh`: `ansible_run` and `ansible_ping` now automatically set `PREFER_TAILSCALE=1` when the local Tailscale daemon is healthy, allowing re-converge after public SSH is locked down.
- `deploy.sh`: `ask_destroy_recreate` now has a 20-second timeout and non-interactive-mode auto-default (no-destroy) so unattended runs never hang on the destroy prompt.
- `deploy.sh`: workstation CA bootstrap for `join-local` now tries persisted cert → SSH fallback → live TLS-chain fallback, making it robust even when public SSH is closed by UFW.

## [1.1.5] - 2026-03-12

### Added
- `deploy.sh join-local` now bootstraps the Headscale CA certificate into the local trust store before joining the tailnet, ensuring TLS certificate validation succeeds on workstations and test runners.

### Changed
- `join-local` now performs explicit `tailscale down` before rejoin to clear any stale x509 trust state.

## [1.1.4] - 2026-03-11

### Fixed
- Tailscale convergence now launches `tailscaled` through a wrapper that exports explicit CA paths (`SSL_CERT_FILE`/`SSL_CERT_DIR`) so Headscale TLS trust works reliably with Caddy internal CA on fresh nodes.
- Tailscale role now performs a best-effort `tailscaled` restart before join, ensuring new trust settings are actually applied.

## [1.1.3] - 2026-03-11

### Changed
- Documentation layout: moved user docs to `docs/user/`, technical docs to `docs/technical/`, and roadmap docs to `docs/roadmap/`.
- Updated internal references (README, docs index, deployment summary) to the new doc paths.

## [1.1.2] - 2026-03-11

### Added
- Public-repo documentation structure: explicit User-facing vs Technical doc map, plus contributing and security policy docs.

### Changed
- Root README and docs index now point to `VERSION` (avoid stale hardcoded release strings).

## [1.1.1] - 2026-03-11

### Added
- Repo-wide Copilot workspace instructions in `.github/copilot-instructions.md`, codifying the documentation/test-first/implementation/review/release workflow and approval gates.

## [1.1.0] - 2026-03-11

### Added
- Repo-wide deployment summary output after `deploy.sh` runs, including infrastructure, services, tailnet status, and next steps.
- Headplane support in the Headscale stack and verification coverage for the public control-plane endpoint and monitoring stack.
- Release structure for the whole repo via `VERSION`, `CHANGELOG.md`, Make targets, and `scripts/release.sh`.

### Changed
- Default Headscale TLS mode to internal CA to avoid Let's Encrypt rate-limit failures during iterative deployments.
- Tailscale convergence to skip healthy nodes, add bounded timeout handling, and retry with reset only as a last resort.
- Operations and guide documentation to better explain deploy, recovery, and post-deploy access patterns.

### Fixed
- Deployment summary output now points monitoring services at the monitoring node instead of the control node.
- Deployment summary command examples no longer contain the `tailscale up` typo.
- Test scripts reduce SSH noise and better handle monitoring checks when direct runner-to-monitoring routing is unavailable.
