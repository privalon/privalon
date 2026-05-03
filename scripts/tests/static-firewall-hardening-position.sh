#!/usr/bin/env bash
set -euo pipefail

# Static check: phase1_harden.yml is referenced from deploy.sh strictly
# between controller_join_tailnet and phase1_gate. Regression guard for I2.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

deploy="${REPO_ROOT}/scripts/deploy.sh"
if [[ ! -f "${deploy}" ]]; then
  echo "FAIL: ${deploy} not found" >&2
  exit 1
fi

# Extract line numbers for the three key calls in the main deploy flow.
# Look for actual invocations (ansible_run_phase with the playbook var),
# not variable assignments or function definitions.
join_line="$(grep -n 'controller_join_tailnet' "${deploy}" | grep -v '^[0-9]*:.*#' | grep -v 'function\|()' | head -1 | cut -d: -f1)"
harden_line="$(grep -n 'PLAYBOOK_PHASE1_HARDEN' "${deploy}" | grep -v '^[0-9]*:.*#' | grep -v '="' | head -1 | cut -d: -f1)"
gate_line="$(grep -n 'PLAYBOOK_PHASE1_GATE' "${deploy}" | grep -v '^[0-9]*:.*#' | grep -v '="' | head -1 | cut -d: -f1)"

if [[ -z "${join_line}" || -z "${harden_line}" || -z "${gate_line}" ]]; then
  echo "FAIL: Could not locate controller_join_tailnet (${join_line:-missing}), phase1_harden (${harden_line:-missing}), or phase1_gate (${gate_line:-missing}) in deploy.sh" >&2
  exit 1
fi

if [[ "${harden_line}" -le "${join_line}" ]]; then
  echo "FAIL: phase1_harden (line ${harden_line}) must come AFTER controller_join_tailnet (line ${join_line})" >&2
  exit 1
fi

if [[ "${gate_line}" -le "${harden_line}" ]]; then
  echo "FAIL: phase1_gate (line ${gate_line}) must come AFTER phase1_harden (line ${harden_line})" >&2
  exit 1
fi

echo "OK: phase1_harden is positioned between controller_join_tailnet (L${join_line}) and phase1_gate (L${gate_line})."
