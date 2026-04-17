#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

TASK_FILE="${REPO_ROOT}/ansible/roles/observability/tasks/main.yml"

log "Observability static: task file exists"
assert_file "${TASK_FILE}"

log "Observability static: log-shipping guard fact is present"
grep -q "Determine whether Loki log shipping can be configured" "${TASK_FILE}" \
  || die "Missing observability_log_collection_active guard task"

log "Observability static: Alloy tasks are gated by the guard fact"
grep -q "observability_log_collection_active | bool" "${TASK_FILE}" \
  || die "Alloy tasks are not gated by observability_log_collection_active"

log "Observability static: hard fail on missing monitoring tailscale_ip is removed"
grep -q "Fail if Loki write URL cannot be derived" "${TASK_FILE}" \
  && die "Found legacy hard-fail task name for missing monitoring-vm tailscale_ip"

grep -q "monitoring-vm tailscale_ip is empty; cannot configure Alloy log shipping\." "${TASK_FILE}" \
  && die "Found legacy hard-fail message for missing monitoring-vm tailscale_ip"

log "Observability static guard OK"
