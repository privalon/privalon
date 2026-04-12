#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
require_tailscale_or_gateway

tf_init_quiet

ssh_ts_host() {
  local hostname="$1"; shift
  local ip
  ip="$(tailscale_ip_for_host "${hostname}" || true)"
  if [[ -z "${ip}" ]]; then
    warn "Could not find Tailscale IP for ${hostname}; skipping"
    return 1
  fi

  if tailscale_active; then
    if ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o BatchMode=yes \
        -o ConnectTimeout=6 \
        "root@${ip}" "$@" 2>/dev/null; then
      return 0
    fi
  fi

  ssh_via_gateway "${ip}" "$@"
}

curl_json() {
  local url="$1"
  if curl -fsS --noproxy '*' --connect-timeout 8 --max-time 20 "$url" 2>/dev/null; then
    return 0
  fi
  ssh_root_control "curl -fsS --connect-timeout 8 --max-time 20 '$url'"
}

curl_json_auth() {
  local url="$1"
  local creds="$2"
  if curl -fsS --noproxy '*' --connect-timeout 8 --max-time 20 -u "${creds}" "$url" 2>/dev/null; then
    return 0
  fi
  ssh_root_control "curl -fsS --connect-timeout 8 --max-time 20 -u '${creds}' '$url'"
}

monitoring_ts_ip="$(tailscale_ip_for_host "monitoring-vm" || true)"
assert_nonempty "monitoring-vm tailscale ip" "${monitoring_ts_ip}"

services_pass="${SERVICES_ADMIN_PASSWORD:-change-me}"
grafana_url="http://${monitoring_ts_ip}:3000"
prom_url="http://${monitoring_ts_ip}:9090"
loki_url="http://${monitoring_ts_ip}:3100"

log "Observability: verify Loki readiness on the monitoring VM"
curl_json "${loki_url}/ready" >/dev/null

log "Observability: verify Loki listens on the Tailscale IP only"
ssh_ts_host monitoring-vm "ss -ltn sport = :3100 | grep -q '${monitoring_ts_ip}:3100'"

log "Observability: verify Grafana Loki datasource exists"
loki_ds_uid="$(curl_json_auth "${grafana_url}/api/datasources/uid/loki" "admin:${services_pass}" | jq -r '.uid // empty')"
[[ "${loki_ds_uid}" == "loki" ]] || die "Grafana Loki datasource uid mismatch: ${loki_ds_uid:-<empty>}"

log "Observability: verify Service Health and Logs Overview dashboards exist"
dashboard_count="$(curl_json_auth "${grafana_url}/api/search?query=" "admin:${services_pass}" | jq -r '[.[] | select(.uid == "service-health" or .uid == "logs-overview")] | length')"
[[ "${dashboard_count}" -ge 2 ]] || die "Grafana observability dashboards were not provisioned"

log "Observability: verify a local service health metric appears in Prometheus"
health_samples="$(curl_json_auth "${prom_url}/api/v1/query?query=blueprint_service_health%7Bscope%3D%22local%22%7D" "admin:${services_pass}" | jq -r '.data.result | length')"
[[ "${health_samples}" -gt 0 ]] || die "No local service health metrics found in Prometheus"

log "Observability: verify HTTP probes appear in Prometheus"
probe_samples="$(curl_json_auth "${prom_url}/api/v1/query?query=probe_success%7Bjob%3D%22service_probe_http%22%7D" "admin:${services_pass}" | jq -r '.data.result | length')"
[[ "${probe_samples}" -gt 0 ]] || die "No HTTP blackbox probe metrics found in Prometheus"

log "Observability: verify Loki ingests container logs (always-active docker source)"
# Docker container log sources are always active on monitoring-vm (grafana, prometheus, loki).
# Querying for any recent loki-service log proves Loki is ingesting without depending on
# backup-summary.log, which is only shipped when backup is enabled.
sleep 5
loki_container_result="$(curl -fsS -G --connect-timeout 8 --max-time 30 \
    --data-urlencode "query={service=\"loki\"}" \
    --data-urlencode 'limit=5' \
    "${loki_url}/loki/api/v1/query_range" \
    2>/dev/null \
  || ssh_root_control "curl -fsS -G --connect-timeout 8 --max-time 30 --data-urlencode 'query={service=\"loki\"}' --data-urlencode 'limit=5' '${loki_url}/loki/api/v1/query_range'")"
loki_container_count="$(printf '%s' "${loki_container_result}" | jq -r '.data.result | length')"
[[ "${loki_container_count}" -gt 0 ]] || die "Loki did not return any container log streams (docker source not working)"

# When backup is enabled, also verify that file log injection works.
backup_enabled="$(sed -n 's/^backup_enabled:[[:space:]]*//p' "${REPO_ROOT}/environments/${TEST_ENV}/group_vars/all.yml" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
if [[ "${backup_enabled:-false}" == "true" ]]; then
  log "Observability: emit a test line into backup logs and verify Loki ingests it"
  log_token="observability-test-$(date +%s)"
  ssh_ts_host monitoring-vm "printf '%s\n' '${log_token}' >> /var/log/backup-summary.log"
  sleep 8
  query_result="$(curl -fsS -G --connect-timeout 8 --max-time 30 \
      --data-urlencode "query={service=\"backup\"} |= \"${log_token}\"" \
      --data-urlencode 'limit=20' \
      "${loki_url}/loki/api/v1/query" \
      2>/dev/null \
    || ssh_root_control "curl -fsS -G --connect-timeout 8 --max-time 30 --data-urlencode 'query={service=\"backup\"} |= \"${log_token}\"' --data-urlencode 'limit=20' '${loki_url}/loki/api/v1/query'")"
  match_count="$(printf '%s' "${query_result}" | jq -r '.data.result | length')"
  [[ "${match_count}" -gt 0 ]] || die "Loki did not return the injected backup log line"
else
  log "Observability: backup log injection test skipped (backup_enabled=false in this environment)"
fi

log "Observability: verify Loki config tuning is rendered on the monitoring VM"
ssh_ts_host monitoring-vm "grep -q 'retention_period: 720h' /opt/loki/config.yml"
ssh_ts_host monitoring-vm "grep -q 'split_queries_by_interval: 2h' /opt/loki/config.yml"
ssh_ts_host monitoring-vm "grep -q 'max_outstanding_per_tenant: 2048' /opt/loki/config.yml"
ssh_ts_host monitoring-vm "grep -q 'max_outstanding_requests_per_tenant: 4096' /opt/loki/config.yml"
ssh_ts_host monitoring-vm "grep -q 'max_concurrent: 8' /opt/loki/config.yml"

if [[ "${backup_enabled:-false}" == "true" ]]; then
  log "Observability: verify archive configuration rendered (backup enabled)"
  ssh_ts_host monitoring-vm "grep -q 'RETENTION_DAYS = 90' /opt/monitoring/archive/archive-loki-logs.py"
  ssh_ts_host monitoring-vm "grep -q 'logs/${TEST_ENV}' /opt/monitoring/archive/archive-loki-logs.py"
else
  log "Observability: archive config check skipped (backup_enabled=false in this environment)"
fi

log "Observability stack OK"