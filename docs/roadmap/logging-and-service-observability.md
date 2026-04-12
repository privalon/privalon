# Roadmap: Logging and Service Observability

**Remaining work — March 2026**

The baseline observability stack is already shipped and documented in the main docs:

* architecture: `docs/technical/ARCHITECTURE.md`
* operations: `docs/technical/OPERATIONS.md`
* user-facing access and dashboard flow: `docs/user/GUIDE.md`

What is already implemented and no longer belongs in the roadmap:

* Loki on the monitoring VM
* Grafana Alloy on every managed VM
* Prometheus + Grafana + Blackbox exporter integration
* local `blueprint_service_health` metrics through the node_exporter textfile collector
* generic per-role observability manifests for the current built-in services
* Infrastructure Health, Service Health, Logs Overview, and Backup Overview dashboards
* default `30d` searchable retention and `90d` archive retention with automatic cleanup
* end-to-end observability verification under `scripts/tests/62_verify_service_observability.sh`

This roadmap now tracks only the unfinished parts.

---

## Remaining gaps

### 1. Complete the manifest consumer

The manifest schema already reserves `journald_units`, but the current Alloy rendering path only consumes:

* `docker_containers`
* `files`

Remaining work:

* add `journald_units` collection when a service genuinely needs it
* keep the supported source types intentionally small and documented

### 2. Expand alerting beyond the current baseline

The current alert set covers:

* local service health failures
* remote HTTP/TCP probe failures
* Alloy availability

Remaining work:

* detect restart-loop style failures more explicitly where container state alone is too coarse
* add a "no recent logs from critical service" signal for services where log silence is actionable

### 3. Add dedicated service-focused dashboards where complexity justifies them

The generic dashboards are now in place, and backup already has a dedicated dashboard.

Remaining work for larger services:

* control-plane-specific dashboarding for Headscale and Headplane errors
* gateway/Caddy views for upstream failures and `4xx` / `5xx` spikes
* additional dedicated dashboards only when a service is complex enough to warrant one

### 4. Keep observability as a hard requirement for future services

The shared manifest contract is live for the current built-in services, but future service additions still need a stricter definition of done.

Remaining work:

* require every new service role to ship a manifest, dashboard coverage, and tests as part of the same change
* extend the current manifest catalog as new service roles are added

---

## Definition of done for this roadmap item

This roadmap can be closed when:

* the manifest consumer handles all intended source types, including any justified journald path
* alerting covers the remaining high-value failure modes that the current baseline does not distinguish well
* complex services that need dedicated dashboards have them
* new service integrations consistently treat observability wiring as part of the default delivery contract
