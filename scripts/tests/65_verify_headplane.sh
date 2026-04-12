#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
need_cmd curl

tf_init_quiet

headscale_url="$(headscale_url_from_authkeys || true)"
if [[ -z "${headscale_url}" ]]; then
  headscale_url="https://$(control_public_ip).sslip.io"
fi
control_ip="$(control_public_ip)"

log "Headplane: verify public ${headscale_url}/admin is no longer exposed"
public_status="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "${headscale_url}/admin" || true)"
case "${public_status}" in
  200|301|302|307|308) die "Headplane is still publicly reachable at ${headscale_url}/admin (HTTP ${public_status})" ;;
  *) ;;
esac

log "Headplane: verify public control port ${control_ip}:3000 is not reachable"
public_port_status="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://${control_ip}:3000" || true)"
if [[ -n "${public_port_status}" && "${public_port_status}" != "000" ]]; then
  die "Headplane is still publicly reachable on ${control_ip}:3000 (HTTP ${public_port_status})"
fi

control_ts_ip="$(tailscale_ip_for_host "control-vm" || true)"

if [[ -n "${control_ts_ip}" ]] && tailscale_active; then
  log "Headplane: check tailnet-only endpoint at http://${control_ts_ip}:3000"
  status_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://${control_ts_ip}:3000" || true)"
else
  log "Headplane: check tailnet-only listener from control-vm itself"
  if [[ -n "${control_ts_ip}" ]]; then
    status_code="$(ssh_root_control "curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 http://${control_ts_ip}:3000" || true)"
  else
    status_code="$(ssh_root_control "curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 http://127.0.0.1:3000" || true)"
  fi
fi

case "${status_code}" in
  200|301|302|307|308|401|403|404) ;;
  *) die "Headplane tailnet-only endpoint returned unexpected HTTP status: ${status_code}" ;;
esac

log "Headplane OK"
