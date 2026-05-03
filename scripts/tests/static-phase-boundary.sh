#!/usr/bin/env bash
set -euo pipefail

# Static check: phase2.yml and any role it imports must never reference
# bootstrap-only variables. Regression guard for invariants I3 and I6.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

tokens=(
  'tfgrid_proxy_'
  'tf_public_ip'
  'tf_private_ip'
  'JUMP_HOST'
  'IGNORE_TAILSCALE_HOSTS'
)

pattern="$(IFS='|'; echo "${tokens[*]}")"

# Collect phase2 playbook and all roles it imports
phase2="${REPO_ROOT}/ansible/playbooks/phase2.yml"
if [[ ! -f "${phase2}" ]]; then
  echo "FAIL: ${phase2} not found" >&2
  exit 1
fi

# Search phase2.yml and all ansible roles (roles are shared but phase2
# is the only consumer after the refactor; any hit is a violation).
hits="$(grep -rnE "${pattern}" "${phase2}" || true)"

if [[ -n "${hits}" ]]; then
  echo "FAIL: phase2.yml references bootstrap-only variables:" >&2
  echo "${hits}" >&2
  exit 1
fi

echo "OK: phase2.yml contains no bootstrap-only variable references."
