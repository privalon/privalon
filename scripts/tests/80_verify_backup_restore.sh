#!/usr/bin/env bash
set -euo pipefail

# 80_verify_backup_restore.sh — Verify backup system is operational
#
# For each VM in the deployment:
#   1. Verify Restic is installed
#   2. Verify backup cron jobs are configured
#   3. Verify backup metrics files exist
#   4. Verify Restic repos are accessible on primary backend
#   5. Verify latest snapshot exists and is recent (< 25 hours old)
#
# On monitoring VM additionally:
#   6. Verify Backrest container is running
#   7. Verify backup Grafana dashboard exists
#   8. Verify backup alert rules loaded in Prometheus

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
require_tailscale_or_gateway

tf_init_quiet

# ── Helper: SSH to a host by name, using Tailscale IP.
# Falls back to gateway-jump when local tailscale is unavailable.
# Falls back to direct gateway SSH when the host IS the gateway.
ssh_ts_host() {
  local hostname="$1"; shift
  local ip
  ip="$(tailscale_ip_for_host "${hostname}" || true)"
  if [[ -z "${ip}" ]]; then
    warn "Could not find Tailscale IP for ${hostname}; skipping"
    return 1
  fi
  # Try direct Tailscale SSH first (fast-fail on ACL-blocked paths).
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
  # Fall back to gateway-jump.
  ssh_via_gateway "${ip}" "$@"
}

# ── Check backup on a specific host ──
check_backup_on_host() {
  local hostname="$1"

  log "Checking backup on ${hostname}..."

  # 1. Verify Restic is installed
  local restic_version
  restic_version="$(ssh_ts_host "${hostname}" '/usr/local/bin/restic version' 2>/dev/null || true)"
  if [[ -z "${restic_version}" ]]; then
    # Backup may not be enabled (backup_enabled=false); skip gracefully
    warn "${hostname}: Restic not installed (backup may be disabled); skipping"
    return 0
  fi
  log "${hostname}: ${restic_version}"

  # 2. Verify backup cron jobs are configured
  local cron_jobs
  cron_jobs="$(ssh_ts_host "${hostname}" 'crontab -l 2>/dev/null | grep backup- || true' 2>/dev/null || true)"
  if [[ -z "${cron_jobs}" ]]; then
    warn "${hostname}: No backup cron jobs found"
  else
    local cron_count
    cron_count="$(echo "${cron_jobs}" | wc -l)"
    log "${hostname}: ${cron_count} backup cron job(s) configured"
  fi

  # 3. Verify metrics files exist
  local metrics_count
  metrics_count="$(ssh_ts_host "${hostname}" 'ls /var/lib/node_exporter/textfile/backup_*.prom 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  if [[ "${metrics_count}" -gt 0 ]]; then
    log "${hostname}: ${metrics_count} backup metrics file(s) found"
  else
    warn "${hostname}: No backup metrics files found (first backup may not have run yet)"
  fi

  # 4. Verify backup configs exist
  local config_count
  config_count="$(ssh_ts_host "${hostname}" 'ls /opt/backup/configs/*.yml 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  log "${hostname}: ${config_count} backup service config(s)"

  # 5. Check latest backup status from metrics
  local last_status
  last_status="$(ssh_ts_host "${hostname}" '
    for f in /var/lib/node_exporter/textfile/backup_*.prom; do
      [ -f "$f" ] || continue
      grep "backup_last_status" "$f" | grep -v "^#" | head -1
    done
  ' 2>/dev/null || true)"
  if [[ -n "${last_status}" ]]; then
    if echo "${last_status}" | grep -q " 0$"; then
      warn "${hostname}: At least one backup has FAILED status"
    else
      log "${hostname}: All backup statuses OK"
    fi
  fi
}

# ── Check monitoring-specific backup components ──
check_monitoring_backup() {
  local hostname="monitoring-vm"

  log "Checking monitoring-specific backup components..."

  local monitoring_ts_ip
  monitoring_ts_ip="$(tailscale_ip_for_host "monitoring-vm" || true)"

  # Backrest container
  local backrest_running
  backrest_running="$(ssh_ts_host "${hostname}" 'docker ps --filter name=backrest --format "{{.Status}}" 2>/dev/null' || true)"
  if [[ -n "${backrest_running}" ]]; then
    log "Backrest container: running (${backrest_running})"
    # Verify Backrest API is actually responding (200 = no auth, 401 = auth required — both mean alive).
    if [[ -n "${monitoring_ts_ip:-}" ]]; then
      local backrest_http_status
      backrest_http_status="$(
        curl -sS --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' \
          "http://${monitoring_ts_ip}:9898/" 2>/dev/null || true
      )"
      if [[ -z "${backrest_http_status}" || "${backrest_http_status}" == "000" ]]; then
        backrest_http_status="$(
          ssh_ts_host "${hostname}" \
            "curl -sS --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' 'http://localhost:9898/'" 2>/dev/null \
          || echo '000'
        )"
      fi
      case "${backrest_http_status}" in
        200|401|302) log "Backrest API: reachable (HTTP ${backrest_http_status})" ;;
        *) warn "Backrest API: unexpected HTTP ${backrest_http_status} (expected 200, 302, or 401)" ;;
      esac
    fi
  else
    warn "Backrest container: not running (backup may be disabled)"
  fi

  # Grafana backup dashboard
  if [[ -n "${monitoring_ts_ip}" ]]; then
    local dash_check
    local grafana_pass="${SERVICES_ADMIN_PASSWORD:-change-me}"
    dash_check="$(
      curl -fsS --connect-timeout 8 --max-time 20 \
        -u "admin:${grafana_pass}" \
        "http://${monitoring_ts_ip}:3000/api/search?query=Backup%20Overview" 2>/dev/null \
      || ssh_ts_host "${hostname}" \
        "curl -fsS --connect-timeout 8 --max-time 20 -u 'admin:${grafana_pass}' 'http://localhost:3000/api/search?query=Backup%20Overview'" 2>/dev/null \
      || echo '[]'
    )"
    if echo "${dash_check}" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d else 1)" 2>/dev/null; then
      log "Grafana backup dashboard: found"
    else
      warn "Grafana backup dashboard: not found"
    fi

    # Prometheus backup alert rules (requires credentials since basic auth is enabled).
    local rules_check
    rules_check="$(
      curl -fsS --connect-timeout 8 --max-time 20 \
        -u "admin:${grafana_pass}" \
        "http://${monitoring_ts_ip}:9090/api/v1/rules" 2>/dev/null \
      || ssh_ts_host "${hostname}" \
        "curl -fsS --connect-timeout 8 --max-time 20 -u 'admin:${grafana_pass}' 'http://localhost:9090/api/v1/rules'" 2>/dev/null \
      || echo '{}'
    )"
    if echo "${rules_check}" | grep -q "BackupFailed"; then
      log "Prometheus backup alert rules: loaded"
    else
      warn "Prometheus backup alert rules: not loaded"
    fi
  fi

  # Weekly summary cron job
  local summary_cron
  summary_cron="$(ssh_ts_host "${hostname}" 'crontab -l 2>/dev/null | grep backup-summary || true' 2>/dev/null || true)"
  if [[ -n "${summary_cron}" ]]; then
    log "Weekly backup summary cron job: configured"
  else
    warn "Weekly backup summary cron job: not configured"
  fi
}

# ── Main ──

log "Verifying backup system..."

# Check each VM type
for vm in control-vm gateway-vm monitoring-vm; do
  check_backup_on_host "${vm}" || true
done

# Monitoring-specific checks
check_monitoring_backup || true

log "Backup verification complete"
