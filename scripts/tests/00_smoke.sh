#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools

log "Smoke: SSH to control VM (Tailscale-first, gateway-jump fallback)"
ssh_root_control 'echo ok-control >/dev/null'

log "Smoke: SSH to gateway VM (Tailscale-first, public fallback)"
ssh_root_gateway 'echo ok-gateway >/dev/null'

log "Smoke: inventory script exists"
assert_file "$INVENTORY_SCRIPT"

log "Smoke OK"
