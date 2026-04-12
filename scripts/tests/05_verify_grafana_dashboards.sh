#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools

server_json="${REPO_ROOT}/ansible/roles/monitoring/files/grafana-dashboards/server-health.json"
service_health_json="${REPO_ROOT}/ansible/roles/monitoring/files/grafana-dashboards/service-health.json"
logs_overview_json="${REPO_ROOT}/ansible/roles/monitoring/files/grafana-dashboards/logs-overview.json"
backup_json="${REPO_ROOT}/ansible/roles/monitoring/files/grafana-dashboards/backup-overview.json"
prom_template="${REPO_ROOT}/ansible/roles/monitoring/templates/prometheus.yml.j2"

assert_file "${server_json}"
assert_file "${service_health_json}"
assert_file "${logs_overview_json}"
assert_file "${backup_json}"
assert_file "${prom_template}"

log "Dashboard JSON: verify Prometheus scrape labels for readable node names"
grep -q 'node_name:' "${prom_template}" || die "Prometheus template is missing node_name scrape labels"
grep -q 'node_display_name:' "${prom_template}" || die "Prometheus template is missing node_display_name scrape labels"

log "Dashboard JSON: verify Server Health panel titles, layout, and MagicDNS-aware labels"
jq -e '.title == "Infrastructure Health"' "${server_json}" >/dev/null || die "Infrastructure dashboard title is not updated"
jq -e 'any(.links[]; .uid == "service-health") and any(.links[]; .uid == "logs-overview")' "${server_json}" >/dev/null || die "Infrastructure dashboard is missing navigation links to service/log dashboards"
jq -e '.panels[] | select(.id == 1) | .title == "Node status" and .gridPos.h == 10 and .gridPos.w == 12 and .gridPos.x == 0 and .gridPos.y == 0' "${server_json}" >/dev/null || die "Server Health panel 1 does not match the expected title or layout"
jq -e '.panels[] | select(.id == 2) | .title == "CPU usage (%)" and .gridPos.h == 10 and .gridPos.w == 12 and .gridPos.x == 12 and .gridPos.y == 0' "${server_json}" >/dev/null || die "Server Health panel 2 does not match the expected layout"
jq -e '.panels[] | select(.id == 3) | .title == "Memory usage (%)" and .gridPos.h == 10 and .gridPos.w == 12 and .gridPos.x == 0 and .gridPos.y == 10' "${server_json}" >/dev/null || die "Server Health panel 3 does not match the expected layout"
jq -e '.panels[] | select(.id == 4) | .title == "Root filesystem used (%)" and .gridPos.h == 10 and .gridPos.w == 12 and .gridPos.x == 12 and .gridPos.y == 10' "${server_json}" >/dev/null || die "Server Health panel 4 does not match the expected layout"
jq -e 'all(.panels[] | select(.id == 1 or .id == 2 or .id == 3 or .id == 4); .targets[0].legendFormat == "{{node_display_name}}" and (.targets[0].expr | contains("node_display_name=~")))' "${server_json}" >/dev/null || die "Server Health panels are not using node_display_name legends and filters"
jq -e '.templating.list[] | select(.name == "node") | .definition == "label_values(up{job=\"node\"}, node_display_name)" and .query.query == "label_values(up{job=\"node\"}, node_display_name)"' "${server_json}" >/dev/null || die "Server Health node filter does not query node_display_name"

log "Dashboard JSON: verify Service Health dashboard variables and required panels"
jq -e '.title == "Service Health" and .uid == "service-health"' "${service_health_json}" >/dev/null || die "Service Health dashboard title or uid is wrong"
jq -e 'any(.panels[]; .title == "Service status summary") and any(.panels[]; .title == "HTTP/TCP probe status") and any(.panels[]; .title == "Container service status") and any(.panels[]; .title == "Recent service failures") and any(.panels[]; .title == "Backup service health")' "${service_health_json}" >/dev/null || die "Service Health dashboard is missing one or more required panels"
jq -e '(.templating.list | map(.name) | sort) == ["env","node","role","service"]' "${service_health_json}" >/dev/null || die "Service Health dashboard variables are incomplete"

log "Dashboard JSON: verify Logs Overview dashboard panels"
jq -e '.title == "Logs Overview" and .uid == "logs-overview"' "${logs_overview_json}" >/dev/null || die "Logs Overview dashboard title or uid is wrong"
jq -e 'any(.panels[]; .title == "Log volume by service") and any(.panels[]; .title == "Recent error count by service") and any(.panels[]; .title == "Top noisy services in the last 1h / 24h") and any(.panels[]; .title == "Latest critical log lines") and any(.panels[]; .title == "Backup log failures")' "${logs_overview_json}" >/dev/null || die "Logs Overview dashboard is missing one or more required panels"
jq -e '.panels[] | select(.id == 2) | (.targets[0].expr | contains("|= \"error\"") and contains("!= \"level=info\"") and contains("!= \"level=debug\"") and contains("!= \"level=trace\""))' "${logs_overview_json}" >/dev/null || die "Logs Overview error-count panel is not filtering info/debug/trace noise"
jq -e '.panels[] | select(.id == 4) | (.targets[0].expr | contains("|= \"error\"") and contains("!= \"level=info\"") and contains("!= \"level=debug\"") and contains("!= \"level=trace\""))' "${logs_overview_json}" >/dev/null || die "Logs Overview critical-lines panel is not filtering info/debug/trace noise"

log "Dashboard JSON: verify Backup Overview top-row layout"
jq -e '
  any(.panels[]; .id == 1 and .title == "Backup Status" and .gridPos.h == 6 and .gridPos.w == 12 and .gridPos.x == 0 and .gridPos.y == 0) and
  any(.panels[]; .id == 6 and .title == "Restore Drill Status" and .gridPos.h == 6 and .gridPos.w == 12 and .gridPos.x == 12 and .gridPos.y == 0)
' "${backup_json}" >/dev/null || die "Backup Overview dashboard JSON does not match the expected top-row layout"

log "Prometheus template: verify observability scrape jobs are provisioned"
grep -q 'job_name: alloy' "${prom_template}" || die "Prometheus template is missing the Alloy scrape job"
grep -q 'job_name: service_probe_http' "${prom_template}" || die "Prometheus template is missing the HTTP probe scrape job"
grep -q 'job_name: service_probe_tcp' "${prom_template}" || die "Prometheus template is missing the TCP probe scrape job"

log "Dashboard JSON OK"