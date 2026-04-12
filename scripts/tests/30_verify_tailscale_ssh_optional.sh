#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# This test is intentionally optional: it only enforces Tailscale SSH reachability
# if REQUIRE_TS_SSH=1 is set. This makes it usable across different ACL policies.

require_basic_tools
require_tailscale

require_ts_ssh="${REQUIRE_TS_SSH:-0}"

log "Local Tailscale: checking whether control/gateway are reachable over Tailscale SSH"

# Ensure we have a fresh peer -> IP mapping from this machine's tailscale client.
run_deploy join-local >/dev/null 2>&1 || true

is_ipv4() {
  local s="$1"
  [[ "$s" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Prefer reading IPs from tailscale-ips.json (generated from `tailscale status --json` on this host).
# Fallback to headscale JSON output if needed.

control_ts_ip="$(tailscale_ip_for_host "control-vm" || true)"
gateway_ts_ip="$(tailscale_ip_for_host "gateway-vm" || true)"

if ! is_ipv4 "$control_ts_ip"; then control_ts_ip=""; fi
if ! is_ipv4 "$gateway_ts_ip"; then gateway_ts_ip=""; fi

if [[ -z "$control_ts_ip" || -z "$gateway_ts_ip" ]]; then
  set +e
  peers_json="$(tailscale status --json 2>/dev/null)"
  set -e

  if [[ -n "${peers_json:-}" ]]; then
    if [[ -z "$control_ts_ip" ]]; then
      control_ts_ip="$(printf '%s' "$peers_json" | jq -r '(.Peer // {}) | to_entries[]? | .value | select((.HostName // "") == "control-vm") | (.TailscaleIPs[]? | select(test("^[0-9]+\\.")))' | head -n1)"
    fi
    if [[ -z "$gateway_ts_ip" ]]; then
      gateway_ts_ip="$(printf '%s' "$peers_json" | jq -r '(.Peer // {}) | to_entries[]? | .value | select((.HostName // "") == "gateway-vm") | (.TailscaleIPs[]? | select(test("^[0-9]+\\.")))' | head -n1)"
    fi
  fi
fi

if [[ -z "$control_ts_ip" || -z "$gateway_ts_ip" ]]; then
  warn "Missing control/gateway entries in tailscale-ips.json; attempting to derive via headscale (best-effort)."

  set +e
  nodes_json="$(ssh_root_control 'docker exec headscale headscale nodes list --output json' 2>/dev/null)"
  set -e

  if [[ -n "${nodes_json:-}" ]]; then
    # Pick the first IPv4 address for each hostname.
    control_ts_ip="$(python3 - <<'PY'
import json,sys
nodes=json.loads(sys.stdin.read() or '[]')
def first_v4(ips):
  for ip in ips or []:
    if isinstance(ip,str) and ip.count('.')==3:
      return ip
  return ''
for n in nodes:
  if n.get('hostname')=='control-vm':
    print(first_v4(n.get('ip_addresses')))
    break
PY
<<<"$nodes_json")"

    gateway_ts_ip="$(python3 - <<'PY'
import json,sys
nodes=json.loads(sys.stdin.read() or '[]')
def first_v4(ips):
  for ip in ips or []:
    if isinstance(ip,str) and ip.count('.')==3:
      return ip
  return ''
for n in nodes:
  if n.get('hostname')=='gateway-vm':
    print(first_v4(n.get('ip_addresses')))
    break
PY
<<<"$nodes_json")"
  fi
fi

if ! is_ipv4 "$control_ts_ip"; then control_ts_ip=""; fi
if ! is_ipv4 "$gateway_ts_ip"; then gateway_ts_ip=""; fi

if [[ -z "$control_ts_ip" || -z "$gateway_ts_ip" ]]; then
  warn "No control/gateway Tailscale IPs available to test."

  # Last-resort path: try helper-based SSH directly (which may still resolve a usable host).
  set +e
  ssh_root_control 'echo ok' >/dev/null 2>&1
  ok_control_fallback=$?
  ssh_root_gateway 'echo ok' >/dev/null 2>&1
  ok_gateway_fallback=$?
  set -e

  ok_control=$([[ "$ok_control_fallback" -eq 0 ]] && echo 1 || echo 0)
  ok_gateway=$([[ "$ok_gateway_fallback" -eq 0 ]] && echo 1 || echo 0)
  log "Tailscale SSH (fallback): control=${ok_control}, gateway=${ok_gateway}"

  if [[ "$require_ts_ssh" == "1" ]]; then
    [[ "$ok_control" == "1" ]] || die "Control not reachable over SSH in fallback path"
    [[ "$ok_gateway" == "1" ]] || die "Gateway not reachable over SSH in fallback path"
  fi
  exit 0
fi

try_ssh() {
  local ip="$1"
  local attempts="${2:-6}"
  local delay="${3:-5}"
  local try=1

  while [[ "$try" -le "$attempts" ]]; do
    if ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      "root@${ip}" 'echo ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
    try=$((try + 1))
  done

  return 1
}

ok_control=0
ok_gateway=0

if try_ssh "$control_ts_ip"; then ok_control=1; fi
if try_ssh "$gateway_ts_ip"; then ok_gateway=1; fi

log "Tailscale SSH: control=${ok_control} (ip=${control_ts_ip}), gateway=${ok_gateway} (ip=${gateway_ts_ip})"

if [[ "$require_ts_ssh" == "1" ]]; then
  [[ "$ok_control" == "1" ]] || die "Control not reachable over Tailscale SSH (ACL/firewall?)"
  [[ "$ok_gateway" == "1" ]] || die "Gateway not reachable over Tailscale SSH (ACL/firewall?)"
else
  if [[ "$ok_control" != "1" || "$ok_gateway" != "1" ]]; then
    warn "Tailscale SSH not reachable (this can be expected with restrictive ACLs)."
    warn "If you want Ansible/SSH over Tailscale, adjust Headscale ACL to allow tag:servers -> tag:servers:22."
  fi
fi
