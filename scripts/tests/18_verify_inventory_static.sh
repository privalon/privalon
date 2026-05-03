#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need_cmd python3

log "Inventory static: dynamic inventory transport tests"
python3 "${SCRIPT_DIR}/test_inventory_tailscale_transport.py"

log "Inventory static: serialized tailnet refresh play test"
python3 "${SCRIPT_DIR}/test_tailnet_refresh_serial.py"

log "Inventory static: join-local tailscale map preservation test"
python3 "${SCRIPT_DIR}/test_join_local_tailscale_map_preserved.py"

log "Inventory static OK"