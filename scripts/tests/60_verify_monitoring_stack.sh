#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
require_tailscale_or_gateway

tf_init_quiet

monitoring_ts_ip="$(tailscale_ip_for_host "monitoring-vm" || true)"
if [[ -z "${monitoring_ts_ip}" ]]; then
  monitoring_ts_ip="$(tailscale status --json 2>/dev/null | jq -r '(.Peer // {}) | to_entries[]? | .value | select((.HostName // "") == "monitoring-vm") | (.TailscaleIPs[]? | select(test("^[0-9]+\\.")))' | head -n1)"
fi
if [[ -z "${monitoring_ts_ip}" ]]; then
  set +e
  nodes_json="$(ssh_root_control 'docker exec headscale headscale nodes list --output json' 2>/dev/null)"
  set -e
  if [[ -n "${nodes_json:-}" ]]; then
    monitoring_ts_ip="$(printf '%s' "$nodes_json" | jq -r '.[] | select((.hostname // "") == "monitoring-vm") | (.ip_addresses[]? | select(test("^[0-9]+\\.")))' | head -n1)"
  fi
fi
assert_nonempty "monitoring-vm tailscale ip" "$monitoring_ts_ip"

grafana_url="http://${monitoring_ts_ip}:3000"
prom_url="http://${monitoring_ts_ip}:9090"
magic_dns_domain="$(ssh_root_control "awk -F'\"' '/base_domain:/{print \$2; exit}' /opt/headscale/config/config.yaml" 2>/dev/null | tr -d '[:space:]')"
internal_tls_mode="$(sed -n 's/^internal_service_tls_mode:[[:space:]]*//p' "${REPO_ROOT}/environments/${TEST_ENV}/group_vars/all.yml" 2>/dev/null | head -n1 | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]' | tr -d '\"' | tr -d "'" || true)"
internal_tls_mode="${internal_tls_mode:-internal}"

if tailscale_active; then
  log "Monitoring: verify direct tailnet HTTP path to monitoring-vm (${monitoring_ts_ip})"

  wait_for_direct_http_status() {
    local url="$1"
    local expected_codes="$2"
    local attempts="${3:-6}"
    local delay="${4:-2}"
    local try=1
    local status=""

    while [[ "${try}" -le "${attempts}" ]]; do
      tailscale ping --tsmp -c 1 "${monitoring_ts_ip}" >/dev/null 2>&1 \
        || tailscale ping --peerapi -c 1 "${monitoring_ts_ip}" >/dev/null 2>&1 \
        || true

      status="$(curl -sS --noproxy '*' --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true)"
      case "${status}" in
        ${expected_codes})
          echo "${status}"
          return 0
          ;;
      esac

      sleep "${delay}"
      try=$((try + 1))
    done

    echo "${status:-000}"
    return 1
  }

  grafana_direct_status="$(wait_for_direct_http_status "${grafana_url}/login" '200' 10 2 || true)"
  [[ "${grafana_direct_status}" == "200" ]] \
    || die "Local tailnet client cannot reach Grafana on monitoring-vm (${monitoring_ts_ip}) directly (HTTP ${grafana_direct_status})"

  prom_direct_status="$(wait_for_direct_http_status "${prom_url}/api/v1/targets" '200|401' 10 2 || true)"
  case "${prom_direct_status}" in
    200|401) ;;
    *) die "Local tailnet client cannot reach Prometheus on monitoring-vm (${monitoring_ts_ip}) directly (HTTP ${prom_direct_status})" ;;
  esac
fi

curl_json() {
  local url="$1"
  if curl -fsS --noproxy '*' --connect-timeout 8 --max-time 20 "$url" 2>/dev/null; then
    return 0
  fi

  # Fallback: query from control VM when runner-to-monitoring routing is unavailable.
  ssh_root_control "curl -fsS --connect-timeout 8 --max-time 20 '$url'"
}

# curl with HTTP basic auth (used for authenticated APIs after services_admin_password is set).
curl_json_auth() {
  local url="$1"
  local creds="$2"  # user:password
  if curl -fsS --noproxy '*' --connect-timeout 8 --max-time 20 -u "${creds}" "$url" 2>/dev/null; then
    return 0
  fi
  ssh_root_control "curl -fsS --connect-timeout 8 --max-time 20 -u '${creds}' '$url'"
}

http_status_direct_or_control() {
  local url="$1"
  shift

  local status
  status="$(curl -sS --noproxy '*' --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "$@" "${url}" 2>/dev/null || true)"
  if [[ -n "${status}" && "${status}" != "000" ]]; then
    echo "${status}"
    return 0
  fi

  status="$(ssh_root_control "curl -sS --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' $* '${url}'" 2>/dev/null || true)"
  if [[ -n "${status}" ]]; then
    echo "${status}"
    return 0
  fi

  echo '000'
}

services_pass="${SERVICES_ADMIN_PASSWORD:-change-me}"

log "Monitoring: check Prometheus targets health at ${prom_url}"
healthy_targets="$(curl_json_auth "${prom_url}/api/v1/targets" "admin:${services_pass}" | jq -r '[.data.activeTargets[] | select(.health=="up")] | length')"
expected_nodes="$(expected_vm_count)"

if [[ "$healthy_targets" -lt "$expected_nodes" ]]; then
  die "Prometheus healthy targets ${healthy_targets} is less than expected VM count ${expected_nodes}"
fi

log "Monitoring: verify Prometheus rejects unauthenticated requests"
unauth_status="$(http_status_direct_or_control "${prom_url}/api/v1/targets")"
if [[ "${unauth_status}" == "401" ]]; then
  log "Prometheus: unauthenticated request correctly rejected (401)"
else
  warn "Prometheus: unauthenticated request returned HTTP ${unauth_status} (expected 401 — check basic auth config)"
fi

log "Monitoring: check Grafana health endpoint at ${grafana_url}"
curl_json "${grafana_url}/api/health" >/dev/null

log "Monitoring: validate provisioned dashboard exists"
dash_uid="$(
  if curl -fsS --connect-timeout 8 --max-time 20 -u "admin:${services_pass}" "${grafana_url}/api/search?query=Infrastructure%20Health" 2>/dev/null; then
    :
  else
    curl_via_gateway "${grafana_url}/api/search?query=Infrastructure%20Health" -u "admin:${services_pass}"
  fi | jq -r '.[0].uid // empty'
)"
assert_nonempty "Grafana dashboard uid" "$dash_uid"

if [[ -n "${magic_dns_domain}" ]]; then
  if [[ "${internal_tls_mode}" == "namecheap" ]]; then
    log "Monitoring: check MagicDNS service aliases via control (public-trust wildcard TLS)"
    ssh_root_gateway "docker exec caddy caddy list-modules | grep -qx 'dns.providers.namecheap'"
    gateway_ts_ip="$(tailscale_ip_for_host "gateway-vm" || true)"
    assert_nonempty "gateway-vm tailscale ip" "$gateway_ts_ip"
    grafana_alias_ip="$(ssh_root_control "getent hosts grafana.${magic_dns_domain} | awk '{print \$1}' | head -n1")"
    prom_alias_ip="$(ssh_root_control "getent hosts prometheus.${magic_dns_domain} | awk '{print \$1}' | head -n1")"
    backrest_alias_ip="$(ssh_root_control "getent hosts backrest.${magic_dns_domain} | awk '{print \$1}' | head -n1")"
    [[ "$grafana_alias_ip" == "$gateway_ts_ip" ]] || die "grafana MagicDNS alias target mismatch: expected ${gateway_ts_ip}, got ${grafana_alias_ip:-<empty>}"
    [[ "$prom_alias_ip" == "$gateway_ts_ip" ]] || die "prometheus MagicDNS alias target mismatch: expected ${gateway_ts_ip}, got ${prom_alias_ip:-<empty>}"
    [[ "$backrest_alias_ip" == "$gateway_ts_ip" ]] || die "backrest MagicDNS alias target mismatch: expected ${gateway_ts_ip}, got ${backrest_alias_ip:-<empty>}"
    ssh_root_control "curl -fsS --connect-timeout 8 --max-time 20 'https://grafana.${magic_dns_domain}/api/health' >/dev/null"
    ssh_root_control "curl -fsS --connect-timeout 8 --max-time 20 'https://prometheus.${magic_dns_domain}/-/healthy' -u 'admin:${services_pass}' >/dev/null"
  else
    log "Monitoring: check MagicDNS service aliases via control (HTTPS via internal CA)"
    # -k to skip cert validation (Caddy internal CA not installed system-wide on control VM).
    ssh_root_control "curl -fsSk --connect-timeout 8 --max-time 20 'https://grafana.${magic_dns_domain}/api/health' >/dev/null"
    ssh_root_control "curl -fsSk --connect-timeout 8 --max-time 20 'https://prometheus.${magic_dns_domain}/-/healthy' -u 'admin:${services_pass}' >/dev/null"

    log "Monitoring: verify Caddy internal CA cert present on monitoring VM"
    monitoring_ts_ip_check="${monitoring_ts_ip}"
    if [[ -n "${monitoring_ts_ip_check}" ]]; then
      ssh_root_control "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 root@${monitoring_ts_ip_check} 'test -s /opt/monitoring-caddy/ca.crt'" 2>/dev/null \
        && log "Monitoring: Caddy internal CA cert: present" \
        || warn "Monitoring: Caddy internal CA cert not found at /opt/monitoring-caddy/ca.crt (HTTPS via Caddy PKI may not be set up yet)"
    fi
  fi

  log "Monitoring: check Backrest health (if running)"
  backrest_status="$(http_status_direct_or_control "http://${monitoring_ts_ip}:9898/")"
  case "${backrest_status}" in
    200|302|401) log "Backrest UI: reachable (HTTP ${backrest_status})" ;;
    000) warn "Backrest UI: not reachable (backup may be disabled or container not running)" ;;
    *) warn "Backrest UI: unexpected HTTP ${backrest_status}" ;;
  esac
fi

log "Monitoring stack OK"
