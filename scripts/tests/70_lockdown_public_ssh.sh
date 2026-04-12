#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# This test enforces the intended security posture:
# - Public SSH should be disabled (no allowlist) after bootstrap.
#
# Safety: requires CONFIRM_LOCKDOWN=1 to run.

require_basic_tools

if [[ "${CONFIRM_LOCKDOWN:-0}" != "1" ]]; then
  die "Refusing to remove public SSH allowlist. Re-run with CONFIRM_LOCKDOWN=1."
fi

tf_init_quiet
c_ip="$(control_public_ip)"
g_ip="$(gateway_public_ip)"
assert_nonempty "control_public_ip" "$c_ip"
assert_nonempty "gateway_public_ip" "$g_ip"

log "Applying firewall lockdown (empty public SSH allowlist)"
(cd "${ANSIBLE_DIR}" && \
  PREFER_TAILSCALE=0 \
  TF_OUTPUTS_JSON="${INVENTORY_DIR}/terraform-outputs.json" \
  TAILSCALE_IPS_JSON="${INVENTORY_DIR}/tailscale-ips.json" \
  ansible-playbook -i inventory/tfgrid.py playbooks/site.yml --tags firewall --extra-vars '{"firewall_allow_public_ssh_from_cidrs":[]}')

log "Expecting public SSH to be blocked on control/gateway"

# Use a short timeout; success is a failure.
public_ssh_ok=0
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes root@"$c_ip" 'echo ok' >/dev/null 2>&1; then
  public_ssh_ok=1
fi
if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes root@"$g_ip" 'echo ok' >/dev/null 2>&1; then
  public_ssh_ok=1
fi

if [[ "$public_ssh_ok" == "1" ]]; then
  die "Public SSH still reachable (allowlist not removed or another rule exists)"
fi

log "Lockdown OK: public SSH not reachable"
