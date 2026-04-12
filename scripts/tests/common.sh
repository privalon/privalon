#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY_SCRIPT="${ANSIBLE_DIR}/inventory/tfgrid.py"

# TEST_ENV defaults to 'test'; override to target another environment (e.g. TEST_ENV=prod).
TEST_ENV="${TEST_ENV:-${ENV:-test}}"
INVENTORY_DIR="${REPO_ROOT}/environments/${TEST_ENV}/inventory"
TF_STATE="${REPO_ROOT}/environments/${TEST_ENV}/terraform.tfstate"

# Load secrets for the active environment so tests can use credentials
# (e.g. SERVICES_ADMIN_PASSWORD, BACKUP_S3_* keys) without requiring the
# user to pre-export them.
_secrets_file="${REPO_ROOT}/environments/${TEST_ENV}/secrets.env"
if [[ -f "${_secrets_file}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${_secrets_file}"
  set +a
fi
unset _secrets_file

log() { printf '[test] %s\n' "$*" >&2; }
warn() { printf '[test][WARN] %s\n' "$*" >&2; }
die() { printf '[test][FAIL] %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_basic_tools() {
  need_cmd bash
  need_cmd terraform
  need_cmd python3
  need_cmd ssh
  need_cmd jq
}

tf() {
  TF_DATA_DIR="${REPO_ROOT}/environments/${TEST_ENV}/.terraform" \
    terraform -chdir="${TF_DIR}" "$@"
}

tf_init_quiet() {
  tf init -input=false >/dev/null
}

tf_out_raw() {
  local name="$1"
  tf output -state="${TF_STATE}" -raw "$name"
}

ssh_quiet() {
  local host="$1"; shift
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    "$host" \
    "$@"
}

ssh_root_public_ip() {
  local ip="$1"; shift
  ssh_quiet "root@${ip}" "$@"
}

tailscale_ip_for_host() {
  local host="$1"

  # Prefer live local tailscale state when available. It reflects the current
  # peer map after redeploys and avoids stale controller-side JSON.
  if command -v tailscale >/dev/null 2>&1; then
    local live_ip
    live_ip="$(tailscale status --json 2>/dev/null | jq -r --arg h "$host" '
      (.Peer // {}) | to_entries[]? | .value
      | select((.HostName // "") == $h)
      | (.TailscaleIPs[]? | select(test("^[0-9]+\\.")))
      ' | head -n1)"
    if [[ -n "${live_ip}" ]]; then
      echo "${live_ip}"
      return 0
    fi
  fi

  local ts_map="${INVENTORY_DIR}/tailscale-ips.json"
  if [[ -f "$ts_map" ]]; then
    local mapped
    mapped="$(jq -r --arg h "$host" '.[$h] // empty' "$ts_map")"
    if [[ -n "$mapped" ]]; then
      echo "$mapped"
      return 0
    fi
  fi

  # Fallback: derive peer IP from local tailscale status JSON.
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status --json 2>/dev/null | jq -r --arg h "$host" '
      (.Peer // {}) | to_entries[]? | .value
      | select((.HostName // "") == $h)
      | (.TailscaleIPs[]? | select(test("^[0-9]+\\.")))
      ' | head -n1
    return 0
  fi

  return 1
}

ssh_root_control() {
  local prefer_ts="${PREFER_TAILSCALE:-1}"
  local ts_ip=""
  if [[ "$prefer_ts" == "1" || "$prefer_ts" == "true" || "$prefer_ts" == "yes" ]]; then
    ts_ip="$(tailscale_ip_for_host "control-vm" || true)"
  fi

  # Try direct Tailscale connection first (works when this machine is an ACL-allowed peer).
  # Use a short 6s probe so we fall through quickly if the firewall silently drops the packet.
  if [[ -n "${ts_ip}" ]] && tailscale_active; then
    if ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o BatchMode=yes \
        -o ConnectTimeout=6 \
        "root@${ts_ip}" "$@" 2>/dev/null; then
      return 0
    fi
  fi

  # Gateway-jump fallback: route via gateway public SSH → control Tailscale IP.
  # Used when public SSH to control is firewalled or direct Tailscale SSH is rejected.
  if [[ -n "${ts_ip}" ]]; then
    ssh_via_gateway "${ts_ip}" "$@"
    return
  fi

  # Last resort: try the control public IP directly.
  ssh_quiet "root@$(control_public_ip)" "$@"
}

ssh_root_gateway() {
  local prefer_ts="${PREFER_TAILSCALE:-1}"
  local ts_ip=""
  if [[ "$prefer_ts" == "1" || "$prefer_ts" == "true" || "$prefer_ts" == "yes" ]]; then
    ts_ip="$(tailscale_ip_for_host "gateway-vm" || true)"
  fi

  # Try direct Tailscale connection first.
  if [[ -n "${ts_ip}" ]] && tailscale_active; then
    if ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o BatchMode=yes \
        -o ConnectTimeout=6 \
        "root@${ts_ip}" "$@" 2>/dev/null; then
      return 0
    fi
  fi

  # Fallback: gateway public IP (always reachable).
  local pub_ip
  pub_ip="$(gateway_public_ip)"
  ssh_quiet "root@${pub_ip}" "$@"
}

expected_headscale_nodes() {
  echo "control-vm"
  echo "gateway-vm"

  local tf_out="${INVENTORY_DIR}/terraform-outputs.json"
  if [[ -f "$tf_out" ]]; then
    jq -r '.workloads_private_ips.value | keys[]' "$tf_out" 2>/dev/null | while read -r name; do
      if [[ "$name" == *-vm ]]; then
        echo "$name"
      else
        echo "${name}-vm"
      fi
    done
    return 0
  fi

  tf output -json workloads_private_ips | jq -r 'keys[]' | while read -r name; do
    if [[ "$name" == *-vm ]]; then
      echo "$name"
    else
      echo "${name}-vm"
    fi
  done
}

expected_vm_count() {
  local tf_out="${INVENTORY_DIR}/terraform-outputs.json"
  if [[ -f "$tf_out" ]]; then
    local count
    count="$(jq -r '.workloads_private_ips.value | length' "$tf_out" 2>/dev/null)"
    if [[ -n "$count" && "$count" != "null" ]]; then
      echo $((count + 2))
      return 0
    fi
  fi
  local workload_count
  workload_count="$(tf output -json workloads_private_ips | jq -r 'length')"
  echo $((workload_count + 2))
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Expected file to exist: $path"
}

assert_nonempty() {
  local label="$1"
  local value="$2"
  [[ -n "${value}" ]] || die "Expected non-empty: ${label}"
}

have_tailscale() {
  command -v tailscale >/dev/null 2>&1
}

# Returns true only when tailscale is installed AND the local daemon has a usable IP.
# Use this instead of have_tailscale when you actually need Tailscale routing to work.
tailscale_active() {
  have_tailscale || return 1
  local self_ip
  self_ip="$(tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [[ -n "${self_ip}" ]]
}

require_tailscale() {
  tailscale_active || die "tailscale is not installed/connected on this machine (required for this test)"
}

# Succeed when either local tailscale is active OR the gateway public SSH is usable.
require_tailscale_or_gateway() {
  tailscale_active && return 0
  local gw_ip
  gw_ip="$(gateway_public_ip 2>/dev/null || true)"
  if [[ -n "${gw_ip}" ]]; then
    ssh_quiet "root@${gw_ip}" echo ok >/dev/null 2>&1 && return 0
  fi
  die "Neither local tailscale nor gateway SSH is available (required for this test)"
}

# SSH to an internal host (identified by Tailscale IP) via the gateway as a jump.
# Usage: ssh_via_gateway <tailscale-ip> [command...]
ssh_via_gateway() {
  local target_ip="$1"; shift
  local gw_ip
  gw_ip="$(tailscale_ip_for_host "gateway-vm" || true)"
  # If gateway's own Tailscale IP is the target, just SSH directly to gateway public IP.
  if [[ "${target_ip}" == "${gw_ip}" ]]; then
    local gw_pub
    gw_pub="$(gateway_public_ip)"
    ssh_quiet "root@${gw_pub}" "$@"
    return
  fi
  # Jump via gateway public SSH → target Tailscale IP.
  local gw_pub
  gw_pub="$(gateway_public_ip)"
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o "ProxyCommand=ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=15 -W %h:%p root@${gw_pub}" \
    "root@${target_ip}" \
    "$@"
}

# curl_via_gateway: try direct curl first; fall back to running curl on the gateway.
# Usage: curl_via_gateway <url>
curl_via_gateway() {
  local url="$1"; shift
  if curl -fsS --connect-timeout 8 --max-time 20 "${url}" "$@" 2>/dev/null; then
    return 0
  fi
  local gw_pub
  gw_pub="$(gateway_public_ip)"
  ssh_quiet "root@${gw_pub}" "curl -fsS --connect-timeout 8 --max-time 20 '${url}' $*"
}

local_ts_ip4() {
  tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]'
}

local_ts_status_json() {
  tailscale status --json
}

headscale_authkeys_path() {
  echo "${INVENTORY_DIR}/headscale-authkeys.json"
}

headscale_url_from_authkeys() {
  local p
  p="$(headscale_authkeys_path)"
  [[ -f "$p" ]] || return 1
  jq -r '.headscale_url // empty' "$p"
}

control_public_ip() {
  local tf_out="${INVENTORY_DIR}/terraform-outputs.json"
  if [[ -f "$tf_out" ]]; then
    local v
    v="$(jq -r '.control_public_ip.value // empty' "$tf_out" 2>/dev/null)"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  fi
  tf_out_raw control_public_ip
}

gateway_public_ip() {
  local tf_out="${INVENTORY_DIR}/terraform-outputs.json"
  if [[ -f "$tf_out" ]]; then
    local v
    v="$(jq -r '.gateway_public_ip.value // empty' "$tf_out" 2>/dev/null)"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  fi
  tf_out_raw gateway_public_ip
}

run_deploy() {
  # shellcheck disable=SC2068
  (cd "$REPO_ROOT" && ./scripts/deploy.sh $@ --env "${TEST_ENV}")
}
