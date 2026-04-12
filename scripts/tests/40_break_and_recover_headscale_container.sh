#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# This simulates a "broken Headscale" where the VM is reachable but the control plane
# process is down, then recovers by re-running Ansible on control.

require_basic_tools
require_tailscale_or_gateway

tf_init_quiet

log "Breaking headscale container on control (Tailscale-first)"
ssh_root_control 'set -euo pipefail
if docker ps --format "{{.Names}}" | grep -qx headscale; then
  docker stop headscale >/dev/null
fi
'

log "Verifying headscale is down"
set +e
ssh_root_control 'set -euo pipefail
if docker ps --format "{{.Names}}" | grep -qx headscale; then
  echo "headscale still running" >&2
  exit 2
fi
' >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || die "Expected headscale container to be stopped"

log "Recovering headscale by converging control via Ansible (no terraform replace)"
log "(this runs terraform apply + full Ansible converge — may take 5-10 minutes)"
# Use deploy.sh control in no-destroy mode to converge; it will run Terraform apply
# but won't replace the deployment.
# --allow-ssh-from-my-ip keeps a recovery SSH path open so we can verify after lockdown.
PREFER_TAILSCALE=0 run_deploy control --no-destroy --allow-ssh-from-my-ip

log "Verifying headscale is up and nodes list works"
ssh_root_control 'set -euo pipefail

docker ps --format "{{.Names}}" | grep -qx headscale

docker exec headscale headscale nodes list >/dev/null
'

log "Headscale container recovery OK"
