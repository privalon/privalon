#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# This is the heavy "VM redeploy" scenario. It replaces the whole core deployment
# (control + workloads) because Terraform models control inside grid_deployment.core.
#
# Safety:
# - Requires CONFIRM_REDEPLOY_CORE=1 (or passing --yes) to proceed.

require_basic_tools

yes="${CONFIRM_REDEPLOY_CORE:-0}"
if [[ "${1:-}" == "--yes" ]]; then
  yes=1
fi

if [[ "$yes" != "1" ]]; then
  die "Refusing to redeploy core. Re-run with CONFIRM_REDEPLOY_CORE=1 or pass --yes."
fi

log "Redeploying broken headscale VM via core replace (disruptive)"
log "(this replaces the VM + runs full Ansible converge — may take 10-15 minutes)"

log "Refreshing local tailnet session and waiting for gateway Tailscale SSH"
run_deploy join-local --rejoin-local >/dev/null 2>&1 || true

gateway_ts_ip=""
for _attempt in $(seq 1 12); do
  gateway_ts_ip="$(tailscale_ip_for_host "gateway-vm" || true)"
  [[ -n "${gateway_ts_ip}" ]] && break
  sleep 5
done

assert_nonempty "gateway-vm tailscale ip" "$gateway_ts_ip"

for _attempt in $(seq 1 12); do
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 "root@${gateway_ts_ip}" 'true' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 "root@${gateway_ts_ip}" 'true' >/dev/null 2>&1 \
  || die "Gateway is not reachable over Tailscale SSH; cannot bootstrap core redeploy after public SSH lockdown"

# This exercises the exact path for "broken control VM":
# - best-effort backup hook
# - terraform apply -replace=grid_deployment.core
# - ansible full converge
PREFER_TAILSCALE=1 run_deploy control --yes --allow-ssh-from-my-ip

log "Post-redeploy: verify headscale health"
"${SCRIPT_DIR}/10_verify_headscale.sh"

log "Core redeploy test OK"
