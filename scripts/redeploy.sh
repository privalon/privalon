#!/usr/bin/env bash
set -euo pipefail

# Backwards-compatible wrapper.
# The command is now called scripts/deploy.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[deprecated] Use ./scripts/deploy.sh instead of ./scripts/redeploy.sh" >&2
exec "${REPO_ROOT}/scripts/deploy.sh" "$@"
