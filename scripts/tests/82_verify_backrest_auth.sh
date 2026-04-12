#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
require_tailscale_or_gateway

tf_init_quiet

ssh_ts_host() {
  local hostname="$1"; shift
  local ip
  ip="$(tailscale_ip_for_host "${hostname}" || true)"
  if [[ -z "${ip}" ]]; then
    warn "Could not find Tailscale IP for ${hostname}; skipping"
    return 1
  fi

  if tailscale_active; then
    if ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o BatchMode=yes \
        -o ConnectTimeout=6 \
        "root@${ip}" "$@" 2>/dev/null; then
      return 0
    fi
  fi

  ssh_via_gateway "${ip}" "$@"
}

log "Checking Backrest auth and config format..."

backrest_running="$(ssh_ts_host monitoring-vm 'docker ps --filter name=backrest --format "{{.Status}}" 2>/dev/null' || true)"
if [[ -z "${backrest_running}" ]]; then
  warn "Backrest container: not running (backup may be disabled)"
  exit 0
fi

backrest_config="$(ssh_ts_host monitoring-vm 'cat /opt/backrest/config/config.json' 2>/dev/null || true)"
assert_nonempty "backrest config" "${backrest_config}"

if ! BACKREST_CONFIG_JSON="${backrest_config}" python3 - <<'PY' >/dev/null 2>&1
import base64
import json
import os

cfg = json.loads(os.environ["BACKREST_CONFIG_JSON"])
instance = (cfg.get("instance") or "").strip()
if not instance:
    raise SystemExit("Backrest instance is empty")

auth = cfg.get("auth") or {}
if auth.get("disabled"):
    raise SystemExit("Backrest auth is disabled")

users = auth.get("users") or []
if not users:
    raise SystemExit("Backrest auth has no configured users")

password_bcrypt = users[0].get("passwordBcrypt", "")
if not password_bcrypt:
    raise SystemExit("Backrest auth passwordBcrypt is empty")

decoded = base64.b64decode(password_bcrypt, validate=True)
if not decoded.startswith(b"$2"):
    raise SystemExit("Backrest passwordBcrypt does not decode to a bcrypt hash")

repos = cfg.get("repos") or []
if not repos:
    raise SystemExit("Backrest has no configured repos")

for repo in repos:
    guid = (repo.get("guid") or "").strip()
    auto_initialize = bool(repo.get("autoInitialize"))
    if not guid and not auto_initialize:
        raise SystemExit(
            f"Backrest repo {repo.get('id', '<unknown>')} is missing both guid and autoInitialize"
        )
PY
then
  die "Backrest config is invalid: instance must be non-empty, passwordBcrypt must be a valid base64-encoded bcrypt hash, and every repo must declare guid or autoInitialize"
fi

log "Backrest config: instance, repo bootstrap fields, and auth hash format are valid"