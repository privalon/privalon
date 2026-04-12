#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
require_tailscale

log "Gateway exit node: refreshing local tailnet state"
run_deploy join-local >/dev/null 2>&1 || true

gateway_public_ipv4="$(gateway_public_ip)"
assert_nonempty "gateway public IPv4" "${gateway_public_ipv4}"

gateway_public_ipv6="$(ssh_root_gateway 'curl -6fsS --connect-timeout 8 --max-time 20 https://api64.ipify.org || true' | tr -d '[:space:]')"

gateway_ts_ip="$(tailscale_ip_for_host "gateway-vm")"
assert_nonempty "gateway Tailscale IP" "${gateway_ts_ip}"
log "Gateway exit node: gateway Tailscale IP is ${gateway_ts_ip}"

log "Gateway exit node: using control-vm as the disposable client"
# Pass the gateway Tailscale IP as $1 to the remote bash session so we don't
# need any env var forwarding or double-quote escaping.
test_output="$(ssh_root_control 'bash -s' "${gateway_ts_ip}" <<'REMOTE'
set -euo pipefail
exit_node_ip="$1"

cleanup() {
  tailscale set --exit-node="" --exit-node-allow-lan-access=false >/dev/null 2>&1 || true
}

fetch_ip() {
  local family="$1"
  local url="$2"
  local out=""
  local rc=1

  for _ in 1 2 3; do
    set +e
    out="$(curl "-${family}"fsS --connect-timeout 8 --max-time 20 "${url}" 2>/dev/null)"
    rc=$?
    set -e
    if [[ ${rc} -eq 0 && -n "${out}" ]]; then
      printf "%s" "${out}"
      return 0
    fi
  done

  return 1
}

trap cleanup EXIT

tailscale set --exit-node="${exit_node_ip}" --exit-node-allow-lan-access=true

printf "ipv4=%s\n" "$(fetch_ip 4 https://api.ipify.org)"

if ipv6="$(fetch_ip 6 https://api64.ipify.org)"; then
  printf "ipv6=%s\n" "${ipv6}"
else
  printf "ipv6=\n"
fi

cleanup
trap - EXIT
REMOTE
)"

exit_ipv4="$(printf '%s\n' "${test_output}" | awk -F= '/^ipv4=/{print $2; exit}')"
exit_ipv6="$(printf '%s\n' "${test_output}" | awk -F= '/^ipv6=/{print $2; exit}')"

assert_nonempty "exit-node IPv4 result" "${exit_ipv4}"
[[ "${exit_ipv4}" == "${gateway_public_ipv4}" ]] \
  || die "Exit-node IPv4 egress mismatch: expected ${gateway_public_ipv4}, got ${exit_ipv4}"

if [[ -n "${gateway_public_ipv6}" ]]; then
  assert_nonempty "exit-node IPv6 result" "${exit_ipv6}"
  [[ "${exit_ipv6}" == "${gateway_public_ipv6}" ]] \
    || die "Exit-node IPv6 egress mismatch: expected ${gateway_public_ipv6}, got ${exit_ipv6}"
fi

log "Gateway exit node OK"
