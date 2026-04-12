#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
need_cmd curl

tf_init_quiet

require_control_ssh="${REQUIRE_CONTROL_SSH:-0}"

headscale_url="$(headscale_url_from_authkeys || true)"
if [[ -z "${headscale_url}" ]]; then
  headscale_url="https://$(control_public_ip).sslip.io"
fi

log "Headscale: verify public /health at ${headscale_url}"
status_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "${headscale_url}/health")"
[[ "${status_code}" == "200" ]] || die "Expected HTTP 200 from ${headscale_url}/health, got ${status_code}"

log "Headscale: verify containers + list nodes on control (Tailscale-first, public fallback)"
control_check_script="$(cat <<'EOF'
set -euo pipefail
command -v docker >/dev/null

docker ps --format "{{.Names}}" | grep -qx headscale

if docker ps --format "{{.Names}}" | grep -qx derper; then
  echo "standalone derper container should not be running" >&2
  exit 1
fi

awk '
  /^derp:$/ { in_derp=1; next }
  in_derp && /^[[:space:]]+server:$/ { in_server=1; next }
  in_derp && in_server && /^[[:space:]]+enabled: / { print $2; found_enabled=1 }
  in_derp && in_server && /^[[:space:]]+stun_listen_addr: / { print $2; found_stun=1 }
  END {
    if (!found_enabled || !found_stun) {
      exit 2
    }
  }
' /opt/headscale/config/config.yaml | {
  read -r derp_enabled
  read -r derp_stun_addr
  derp_enabled="${derp_enabled//\"/}"
  derp_stun_addr="${derp_stun_addr//\"/}"
  [[ "${derp_enabled}" == "true" ]]
  [[ "${derp_stun_addr}" == "0.0.0.0:3478" ]]
}

docker exec headscale headscale users list >/dev/null
EOF
)"

ssh_rc=1
for attempt in 1 2 3; do
  set +e
  ssh_root_control "${control_check_script}"
  ssh_rc=$?
  set -e
  if [[ "${ssh_rc}" -eq 0 ]]; then
    break
  fi
  if [[ "${attempt}" -lt 3 ]]; then
    warn "Control SSH probe failed on attempt ${attempt}/3; retrying..."
    sleep 2
  fi
done

if [[ "${ssh_rc}" -ne 0 ]]; then
  if [[ "${require_control_ssh}" == "1" ]]; then
    die "Control SSH is required but not reachable (set REQUIRE_CONTROL_SSH=0 to allow public-only checks)"
  fi
  warn "Control SSH not reachable from this runner; skipping node-list assertions."
  log "Headscale OK (public checks)"
  exit 0
fi

while read -r h; do
  [[ -n "$h" ]] || continue
  ssh_root_control "docker exec headscale headscale nodes list | grep -q '$h'" || die "missing node: $h"
done < <(expected_headscale_nodes)

nodes_json="$(ssh_root_control 'docker exec headscale headscale nodes list --output json')"
set +e
NODES_JSON="${nodes_json}" python3 - <<'PY'
import json
import os

wanted = {"0.0.0.0/0", "::/0"}

nodes = json.loads(os.environ.get("NODES_JSON", "[]")) or []
gateway = next((node for node in nodes if (node.get("name") or node.get("given_name") or "") == "gateway-vm"), None)
if gateway is None:
    raise SystemExit(1)

available = set(gateway.get("available_routes") or [])
approved = set(gateway.get("approved_routes") or [])

if not wanted.issubset(available):
    raise SystemExit(2)
if not wanted.issubset(approved):
    raise SystemExit(3)
PY
route_rc=$?
set -e
if [[ "${route_rc}" -ne 0 ]]; then
  die "gateway-vm exit-node routes are not fully approved in Headscale"
fi

log "Headscale OK"
