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

log "Checking Backrest snapshot indexing and listing API..."

backrest_running="$(ssh_ts_host monitoring-vm 'docker ps --filter name=backrest --format "{{.Status}}" 2>/dev/null' || true)"
if [[ -z "${backrest_running}" ]]; then
  warn "Backrest container: not running (backup may be disabled)"
  exit 0
fi

backrest_config="$(ssh_ts_host monitoring-vm 'cat /opt/backrest/config/config.json' 2>/dev/null || true)"
assert_nonempty "backrest config" "${backrest_config}"

mapfile -t repo_ids < <(
  BACKREST_CONFIG_JSON="${backrest_config}" python3 - <<'PY'
import json
import os

cfg = json.loads(os.environ["BACKREST_CONFIG_JSON"])
for repo in cfg.get("repos") or []:
    repo_id = (repo.get("id") or "").strip()
    if repo_id:
        print(repo_id)
PY
)

if [[ "${#repo_ids[@]}" -eq 0 ]]; then
  die "Backrest config contains no repos to validate"
fi

for repo_id in "${repo_ids[@]}"; do
  log "Backrest repo API: indexing ${repo_id}"
  index_status="$(
    ssh_ts_host monitoring-vm \
      "curl -sS -X POST -u 'admin:${SERVICES_ADMIN_PASSWORD}' -H 'Content-Type: application/json' --data '{\"repoId\":\"${repo_id}\",\"task\":1}' http://localhost:9898/v1.Backrest/DoRepoTask -o /dev/null -w '%{http_code}'" \
      2>/dev/null || echo '000'
  )"
  [[ "${index_status}" == "200" ]] || die "Backrest DoRepoTask index failed for ${repo_id} (HTTP ${index_status})"

  snapshot_count="$(
    ssh_ts_host monitoring-vm \
      "python3 - <<'PY'
import json
import subprocess

payload = json.dumps({\"repoId\": \"${repo_id}\"})
result = subprocess.run(
    [
        \"curl\", \"-sS\", \"-X\", \"POST\",
        \"-u\", \"admin:${SERVICES_ADMIN_PASSWORD}\",
        \"-H\", \"Content-Type: application/json\",
        \"--data\", payload,
        \"http://localhost:9898/v1.Backrest/ListSnapshots\",
    ],
    check=True,
    capture_output=True,
    text=True,
)
data = json.loads(result.stdout)
print(len(data.get(\"snapshots\") or []))
PY" \
      2>/dev/null || echo '0'
  )"

  if [[ "${snapshot_count}" -le 0 ]]; then
    die "Backrest ListSnapshots returned no snapshots for ${repo_id}"
  fi

  log "Backrest repo API: ${repo_id} has ${snapshot_count} snapshot(s)"
done

log "Backrest snapshot API verification complete"