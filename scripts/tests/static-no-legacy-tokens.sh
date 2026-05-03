#!/usr/bin/env bash
# static-no-legacy-tokens.sh — §11.7 cleanup gate.
# Exits non-zero if any legacy token from the pre-2.0.0 transport heuristics
# is still present in the working tree (excluding docs/roadmap, CHANGELOG.md,
# and .ui-logs directories).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"

LEGACY_TOKENS=(
  "IGNORE_TAILSCALE_HOSTS"
  "PREFER_TAILSCALE"
  "JUMP_HOST"
  "tfgrid_proxy_"
  "tailscale_refresh_ansible_host"
  "tailscale_refresh_ansible_ssh_common_args"
  "auto_post_destroy_join_local"
  "_validated_persisted_tailscale_ips"
  "_load_local_tailscale_candidate_ips"
  "prefer_tailscale_for_ansible"
  "controller_ip_allowlist"
  "--fresh-tailnet"
  "--join-local"
  "--rejoin-local"
  "--allow-ssh-from"
  "--allow-ssh-from-my-ip"
  "FRESH_TAILNET"
)

# Build a single regex pattern from all tokens.
pattern=""
for token in "${LEGACY_TOKENS[@]}"; do
  if [[ -n "${pattern}" ]]; then
    pattern="${pattern}|"
  fi
  # Escape regex special characters in the token.
  escaped="$(printf '%s' "${token}" | sed 's/[.[\*^$()+?{|]/\\&/g')"
  pattern="${pattern}${escaped}"
done

# Run git grep, excluding files that legitimately use bootstrap transport vars.
matches="$(git grep -nE "${pattern}" -- \
  ':!CHANGELOG.md' \
  ':!docs/roadmap/' \
  ':!environments/*/.ui-logs/' \
  ':!scripts/tests/static-no-legacy-tokens.sh' \
  ':!scripts/tests/static-phase-boundary.sh' \
  ':!scripts/tests/test_deploy_phase_order.py' \
  ':!scripts/tests/test_inventory_modes.py' \
  ':!ansible/inventory/tfgrid.py' \
  ':!ansible/playbooks/phase1_bootstrap_and_join.yml' \
  2>/dev/null || true)"

if [[ -n "${matches}" ]]; then
  echo "FAIL: Legacy tokens still present in the working tree:" >&2
  echo "${matches}" >&2
  echo "" >&2
  echo "These tokens were removed in the 2.0.0 two-phase deployment refactor." >&2
  echo "See docs/roadmap/two-phase-deployment-refactor.md §11.7 for details." >&2
  exit 1
fi

echo "OK: No legacy tokens found."
