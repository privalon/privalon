#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need_cmd python3

log "Gateway static: helper and template unit tests"
python3 -m unittest discover -s "${SCRIPT_DIR}" -p 'test_gateway_*.py'

log "Gateway static OK"