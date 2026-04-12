#!/usr/bin/env bash
set -euo pipefail

# Deploy/redeploy helper for this blueprint.
#
# Behavior:
# - Single command per scope (full, gateway, control)
# - Reuse existing configs/secrets (terraform.tfvars, state, ansible group_vars)
# - If the target exists already: ask whether to destroy & recreate
#   - If yes: attempt to connect + run backup hook, then destroy/replace
#   - If no: run terraform apply (converge) + ansible

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${BLUEPRINT_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SCRIPT_PATH="${SCRIPT_DIR}/deploy.sh"
JOB_HELPER="${REPO_ROOT}/ui/lib/job_cli.py"
PROGRESS_HELPER="${REPO_ROOT}/ui/lib/deploy_progress.py"
ENVIRONMENTS_ROOT="${BLUEPRINT_ENVIRONMENTS_DIR:-${REPO_ROOT}/environments}"

TF_DIR="${REPO_ROOT}/terraform"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY_SCRIPT="${ANSIBLE_DIR}/inventory/tfgrid.py"
PLAYBOOK_REL="playbooks/site.yml"
BACKUP_HOOK="${REPO_ROOT}/scripts/hooks/backup.sh"
RECOVERY_HELPER="${REPO_ROOT}/scripts/helpers/recovery_bundle.py"
DATA_MIGRATIONS_HELPER="${REPO_ROOT}/scripts/helpers/data_migrations.py"

# Optional: pass firewall allowlist via Ansible extra-vars.
ANSIBLE_EXTRA_VARS_JSON=""
ALLOWLIST_CIDRS=()

JOIN_LOCAL=0
REJOIN_LOCAL=0
NO_DESTROY=0
NO_RESTORE=0
FRESH_TAILNET=0

# If we pass a temporary public SSH allowlist during bootstrap, we usually want to
# remove it at the end once the controller is on the tailnet.
KEEP_SSH_ALLOWLIST=0
IGNORE_TAILSCALE_HOSTS=""

# Environment name (required via --env <name>).
# All Terraform state, tfvars, and runtime inventory outputs are scoped to environments/<name>/.
ENV_NAME=""
ENV_DIR=""
ENV_INVENTORY_DIR=""
ENV_TF_STATE=""
ENV_TF_VARFILE=""
ENV_ANSIBLE_EXTRA_FLAGS=()
RECORD_EXTRA_ARGS=()
RECOVERY_REFRESH_EXIT_CODE=0
RECOVERY_REFRESH_SEVERITY="not-run"
PROGRESS_SCRIPT_STARTED_AT_MS=""

progress_now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local seconds fraction millis
    seconds="${EPOCHREALTIME%.*}"
    fraction="${EPOCHREALTIME#*.}"
    fraction="${fraction}000"
    millis="${fraction:0:3}"
    printf '%s\n' "$((10#${seconds} * 1000 + 10#${millis}))"
    return 0
  fi

  date +%s000
}

progress_step_var_name() {
  local step_id="$1"
  step_id="${step_id//[^A-Za-z0-9_]/_}"
  printf 'PROGRESS_STEP_STARTED_AT_MS_%s\n' "${step_id}"
}

progress_set_step_started_at_ms() {
  local step_id="$1"
  local started_at_ms="$2"
  local var_name
  var_name="$(progress_step_var_name "${step_id}")"
  printf -v "${var_name}" '%s' "${started_at_ms}"
}

progress_get_step_started_at_ms() {
  local step_id="$1"
  local var_name
  var_name="$(progress_step_var_name "${step_id}")"
  printf '%s\n' "${!var_name:-}"
}

PROGRESS_SCRIPT_STARTED_AT_MS="$(progress_now_ms)"

usage() {
  cat <<'USAGE'
Usage:
  scripts/deploy.sh <scope> --env <name> [--yes] [--no-destroy] [--no-restore] [--fresh-tailnet] [--join-local] [--rejoin-local] [--allow-ssh-from <cidr>] [--allow-ssh-from-my-ip]

Scopes:
  full        Deploy everything; if existing infra is detected, optionally destroy+recreate first
  gateway     Deploy gateway; if gateway exists, optionally destroy+recreate first
  control     Deploy control/core; if core exists, optionally destroy+recreate first
  dns         Update DNS A records only (requires Namecheap API credentials in secrets.env)
  join-local  Join THIS machine to Headscale using persisted preauth key (no Terraform/Ansible)
  service-x   Reserved scope for future service workflows

Options:
  --env <name>   (Required) Named environment under environments/<name>/ (e.g. prod, test).
                 Isolates Terraform state, tfvars, and inventory output files per environment.
  --yes          Auto-answer "yes" to destroy+recreate prompts
  --no-destroy   Auto-answer "no" to destroy+recreate prompts (converge in-place)
  --no-restore   Skip auto-restore from backup on fresh deploy (force fresh install)
  --fresh-tailnet Reset Headscale node registrations and per-VM Tailscale identities on destructive redeploys
  --join-local   Install Tailscale on this machine and join it to Headscale after Ansible runs
  --rejoin-local Force re-auth this machine to the Headscale login server (use with care)
  --allow-ssh-from <cidr>     Add a CIDR to firewall_allow_public_ssh_from_cidrs (repeatable)
  --allow-ssh-from-my-ip      Detect public IP and allow <ip>/32 for SSH during/after bootstrap
  --keep-ssh-allowlist        Do NOT auto-remove the temporary allowlist at the end (use with care)

Notes:
  - uses environments/<name>/terraform.tfvars (must exist) and writes runtime
    outputs to environments/<name>/inventory/.
  - terminal-triggered runs are recorded automatically into environments/<name>/.ui-logs/
    so the local Web UI History tab can replay them later.
  - Refreshes inventory/terraform-outputs.json from Terraform outputs after each apply.
USAGE
}

progress_step_start() {
  local step_id="$1"
  local now_ms elapsed_ms
  now_ms="$(progress_now_ms)"
  elapsed_ms="$((now_ms - PROGRESS_SCRIPT_STARTED_AT_MS))"
  progress_set_step_started_at_ms "${step_id}" "${now_ms}"
  echo "[bp-progress] {\"type\":\"step-start\",\"step_id\":\"${step_id}\",\"ts_ms\":${now_ms},\"elapsed_ms\":${elapsed_ms}}" >&2
}

progress_step_done() {
  local step_id="$1"
  local now_ms elapsed_ms step_started_at_ms step_elapsed_ms
  now_ms="$(progress_now_ms)"
  elapsed_ms="$((now_ms - PROGRESS_SCRIPT_STARTED_AT_MS))"
  step_started_at_ms="$(progress_get_step_started_at_ms "${step_id}")"
  if [[ -n "${step_started_at_ms}" ]]; then
    step_elapsed_ms="$((now_ms - step_started_at_ms))"
    echo "[bp-progress] {\"type\":\"step-done\",\"step_id\":\"${step_id}\",\"ts_ms\":${now_ms},\"elapsed_ms\":${elapsed_ms},\"step_elapsed_ms\":${step_elapsed_ms}}" >&2
    return 0
  fi
  echo "[bp-progress] {\"type\":\"step-done\",\"step_id\":\"${step_id}\",\"ts_ms\":${now_ms},\"elapsed_ms\":${elapsed_ms}}" >&2
}

emit_progress_plan() {
  local scope="$1"
  local destroy_first="${2:-0}"
  local converge_join_local="${3:-0}"

  if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "${PROGRESS_HELPER}" ]]; then
    return 0
  fi

  local cmd=(
    python3 "${PROGRESS_HELPER}" emit-plan
    --repo-root "${REPO_ROOT}"
    --env "${ENV_NAME}"
    --scope "${scope}"
  )

  [[ "${destroy_first}" == "1" ]] && cmd+=(--destroy-first)
  [[ "${JOIN_LOCAL}" == "1" ]] && cmd+=(--join-local)
  [[ "${converge_join_local}" == "1" ]] && cmd+=(--converge-join-local)
  [[ "${NO_RESTORE}" == "1" ]] && cmd+=(--no-restore)
  [[ "${FRESH_TAILNET}" == "1" ]] && cmd+=(--fresh-tailnet)

  local cidr
  for cidr in "${ALLOWLIST_CIDRS[@]}"; do
    cmd+=(--allow-ssh-from "${cidr}")
  done

  "${cmd[@]}" >&2 || true
}

maybe_record_terminal_run() {
  local scope="$1"
  shift
  local full_args=("$@")

  if [[ "${BLUEPRINT_DEPLOY_RECORDING_ACTIVE:-0}" == "1" ]]; then
    return 0
  fi

  if [[ "${BLUEPRINT_UI_JOB:-0}" == "1" ]]; then
    return 0
  fi

  if [[ "${BLUEPRINT_DISABLE_UI_RECORDING:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -z "${ENV_NAME}" ]]; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "${JOB_HELPER}" ]]; then
    echo "[history] UI job recorder unavailable; continuing without History import." >&2
    return 0
  fi

  local inner_script="${BLUEPRINT_DEPLOY_INNER_SCRIPT:-${SCRIPT_PATH}}"
  local job_start_cmd=(
    python3 "${JOB_HELPER}" start
    --env "${ENV_NAME}"
    --scope "${scope}"
    --source terminal
    --pid "$$"
  )

  local arg
  for arg in "${RECORD_EXTRA_ARGS[@]}"; do
    job_start_cmd+=("--extra-arg=${arg}")
  done

  local job_start_output
  if ! job_start_output="$("${job_start_cmd[@]}")"; then
    echo "[history] Failed to initialize UI History recording; continuing without it." >&2
    return 0
  fi

  eval "${job_start_output}"

  local finished=0

  finish_job() {
    local exit_code="$1"
    local end_time
    end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 "${JOB_HELPER}" finish --meta-file "${META_FILE}" --exit-code "${exit_code}" --end-time "${end_time}" >/dev/null
    finished=1
  }

  interrupt_job() {
    [[ "${finished}" -eq 1 ]] && return 0
    local end_time
    end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 "${JOB_HELPER}" interrupt --meta-file "${META_FILE}" --end-time "${end_time}" >/dev/null || true
  }

  trap 'interrupt_job; exit 130' INT
  trap 'interrupt_job; exit 143' TERM
  trap 'interrupt_job' EXIT

  set +e
  BLUEPRINT_DEPLOY_RECORDING_ACTIVE=1 "${inner_script}" "${full_args[@]}" 2>&1 | tee -a "${LOG_FILE}"
  local deploy_rc=${PIPESTATUS[0]}
  set -e

  finish_job "${deploy_rc}"
  trap - EXIT INT TERM
  exit "${deploy_rc}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }
}

json_escape() {
  # Minimal JSON string escaper for our simple CIDR values.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

build_ansible_extra_vars() {
  if [[ ${#ALLOWLIST_CIDRS[@]} -eq 0 ]]; then
    ANSIBLE_EXTRA_VARS_JSON=""
    return 0
  fi

  local json='{"firewall_allow_public_ssh_from_cidrs":['
  local first=1
  local cidr
  for cidr in "${ALLOWLIST_CIDRS[@]}"; do
    if [[ $first -eq 1 ]]; then
      first=0
    else
      json+=','
    fi
    json+='"'"$(json_escape "$cidr")"'"'
  done
  json+=']}'
  ANSIBLE_EXTRA_VARS_JSON="$json"
}

detect_public_ip() {
  # Best-effort; avoids hard fail if the lookup service is unreachable.
  if command -v curl >/dev/null 2>&1; then
    curl -fsS https://api.ipify.org 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://api.ipify.org 2>/dev/null || true
  else
    echo "";
  fi
}

read_json_value() {
  local path="$1"
  local expr="$2"

  [[ -f "$path" ]] || return 1
  PY_PATH="$path" PY_EXPR="$expr" python3 - <<'PY'
import json
import os

path = os.environ.get("PY_PATH", "")
expr = os.environ.get("PY_EXPR", "")

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

def get_value(d, parts):
    cur = d
    for p in parts:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur

parts = expr.split(".") if expr else []
val = get_value(data, parts)
if val is None:
    raise SystemExit(1)
print(val)
PY
}

install_tailscale_local_best_effort() {
  if command -v tailscale >/dev/null 2>&1; then
    return 0
  fi

  if [[ ! -f /etc/os-release ]]; then
    echo "tailscale not installed; unsupported OS for auto-install (no /etc/os-release)." >&2
    return 1
  fi

  need_cmd sudo
  need_cmd curl

  echo "Installing Tailscale locally (best-effort)…" >&2
  # Use upstream installer to avoid distro/codename edge cases.
  curl -fsSL https://tailscale.com/install.sh | sudo sh
}

local_tailscale_has_ip() {
  command -v tailscale >/dev/null 2>&1 || return 1
  local ip
  ip="$(tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  [[ -n "${ip}" ]]
}

local_tailscale_healthy() {
  command -v tailscale >/dev/null 2>&1 || return 1

  local status_json
  status_json="$(tailscale status --json 2>/dev/null || true)"
  [[ -n "${status_json}" ]] || return 1

  STATUS_JSON="${status_json}" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("STATUS_JSON", ""))
except Exception:
    raise SystemExit(1)

if data.get("BackendState") != "Running":
    raise SystemExit(1)

ips = data.get("TailscaleIPs") or []
if not ips:
    self_peer = data.get("Self") or {}
    ips = self_peer.get("TailscaleIPs") or []

if not ips:
    raise SystemExit(1)

health = data.get("Health") or []
for item in health:
    text = str(item).lower()
    if (
        "logged out" in text
        or "certificate signed by unknown authority" in text
        or "tls" in text
        or "x509" in text
        or "unable to connect to the tailscale coordination server" in text
        or "node not found" in text
    ):
        raise SystemExit(1)

self_peer = data.get("Self") or {}
if self_peer and (
    self_peer.get("Active") is False
    or self_peer.get("InMagicSock") is False
    or self_peer.get("InEngine") is False
):
    raise SystemExit(1)

raise SystemExit(0)
PY
}

restart_local_tailscaled_best_effort() {
  need_cmd sudo

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl restart tailscaled >/dev/null 2>&1 && return 0
  fi

  if command -v service >/dev/null 2>&1; then
    sudo service tailscaled restart >/dev/null 2>&1 && return 0
  fi

  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
    open -a Tailscale >/dev/null 2>&1 && return 0
  fi

  return 1
}

local_tailscale_versions_match() {
  command -v tailscale >/dev/null 2>&1 || return 0

  local version_output
  version_output="$(tailscale version 2>/dev/null || true)"
  [[ -n "${version_output}" ]] || return 0

  VERSION_OUTPUT="${version_output}" python3 - <<'PY'
import os
import re

output = os.environ.get("VERSION_OUTPUT", "")
client = re.search(r'long version:\s*(\S+)', output)
server = re.search(r'tailscaled server version\s*"([^"]+)"', output)

if not client or not server:
    raise SystemExit(0)

raise SystemExit(0 if client.group(1) == server.group(1) else 1)
PY
}

print_local_tailscale_version_mismatch_guidance() {
  local version_output
  version_output="$(tailscale version 2>&1 || true)"

  echo "[join-local] Local Tailscale CLI and daemon versions do not match." >&2
  if [[ -n "${version_output}" ]]; then
    echo "${version_output}" >&2
  fi

  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
    local tailscale_path
    tailscale_path="$(command -v tailscale 2>/dev/null || true)"
    echo "[join-local] On macOS this usually means the Homebrew CLI and Tailscale.app are on different versions." >&2
    [[ -n "${tailscale_path}" ]] && echo "[join-local] Active tailscale binary: ${tailscale_path}" >&2
    echo "[join-local] Update or remove the duplicate install so the CLI and app-managed daemon match, then retry." >&2
  else
    echo "[join-local] Update the local tailscale client/daemon so both sides report the same version, then retry." >&2
  fi
}

normalize_hostname_label() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  if [[ -n "$raw" ]]; then
    printf '%s' "$raw"
    return 0
  fi

  local fallback
  fallback="$(id -un 2>/dev/null || true)"
  fallback="$(printf '%s' "$fallback" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  if [[ -n "$fallback" ]]; then
    printf 'client-%s' "$fallback"
    return 0
  fi

  printf 'local-client'
}

local_tailscale_hostname() {
  local candidate=""

  if command -v scutil >/dev/null 2>&1; then
    candidate="$(scutil --get LocalHostName 2>/dev/null || true)"
  fi

  if [[ -z "$candidate" ]]; then
    candidate="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  fi

  normalize_hostname_label "$candidate"
}

local_tailscale_self_hostnames() {
  command -v tailscale >/dev/null 2>&1 || return 0

  local status_json
  status_json="$(tailscale status --json 2>/dev/null || true)"
  [[ -n "${status_json}" ]] || return 0

  STATUS_JSON="${status_json}" python3 - <<'PY'
import json
import os

try:
  data = json.loads(os.environ.get("STATUS_JSON", ""))
except Exception:
  raise SystemExit(0)

self_peer = data.get("Self") or {}
names = []

for value in (self_peer.get("HostName"), self_peer.get("DNSName")):
  if not value:
    continue
  text = str(value).strip().rstrip(".")
  if not text:
    continue
  names.append(text.split(".", 1)[0])

seen = set()
for name in names:
  if name and name not in seen:
    seen.add(name)
    print(name)
PY
}

headscale_host_from_url() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%/*}"
  echo "${url}"
}

install_headscale_ca_local_best_effort() {
  local login_server="$1"
  local persisted_cert
  persisted_cert="$(inv_dir)/headscale-root-ca.crt"
  local host
  host="$(headscale_host_from_url "${login_server}")"
  [[ -n "${host}" || -f "${persisted_cert}" ]] || return 1

  need_cmd sudo

  local tmp_cert
  tmp_cert="$(mktemp)"

  if [[ -f "${persisted_cert}" ]]; then
    cp "${persisted_cert}" "${tmp_cert}"
  else
    local fetched=0

    if command -v ssh >/dev/null 2>&1; then
      if ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "root@${host}" \
        'cat /opt/caddy/data/caddy/pki/authorities/local/root.crt' >"${tmp_cert}" 2>/dev/null; then
        fetched=1
      fi
    fi

    # Fallback when SSH is unavailable/blocked: trust the CA cert shipped in the TLS chain.
    # For Caddy internal TLS this is normally the intermediate CA and is safe to trust locally.
    if [[ "${fetched}" != "1" ]] && command -v openssl >/dev/null 2>&1; then
      local chain_tmp
      chain_tmp="$(mktemp)"
      if timeout 15 openssl s_client -connect "${host}:443" -servername "${host}" -showcerts </dev/null 2>/dev/null \
        | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' >"${chain_tmp}"; then
        if csplit -s -z "${chain_tmp}" '/-----BEGIN CERTIFICATE-----/' '{*}' -f "${chain_tmp}.part." -b '%02d.pem'; then
          local last_cert
          last_cert="$(ls "${chain_tmp}.part."*.pem 2>/dev/null | tail -n1 || true)"
          if [[ -n "${last_cert}" ]]; then
            cp "${last_cert}" "${tmp_cert}"
            fetched=1
          fi
        fi
      fi
      rm -f "${chain_tmp}" "${chain_tmp}.part."*.pem 2>/dev/null || true
    fi

    if [[ "${fetched}" != "1" ]]; then
      rm -f "${tmp_cert}"
      return 1
    fi
  fi

  if ! grep -q "BEGIN CERTIFICATE" "${tmp_cert}"; then
    rm -f "${tmp_cert}"
    return 1
  fi

  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "${tmp_cert}" >/dev/null 2>&1 || {
      rm -f "${tmp_cert}"
      return 1
    }
    rm -f "${tmp_cert}"
    return 0
  fi

  sudo install -m 0644 "${tmp_cert}" /usr/local/share/ca-certificates/headscale-local-ca.crt
  if command -v update-ca-certificates >/dev/null 2>&1; then
    sudo update-ca-certificates >/dev/null 2>&1 || true
  fi

  rm -f "${tmp_cert}"
  return 0
}

join_local_tailnet() {
  local authkeys_path
  authkeys_path="$(inv_dir)/headscale-authkeys.json"

  if [[ ! -f "${authkeys_path}" ]]; then
    echo "[join-local] Missing ${authkeys_path}; skipping local tailnet join." >&2
    echo "[join-local] Ensure Ansible ran the headscale role successfully." >&2
    return 1
  fi

  local login_server=""
  login_server="$(read_json_value "${authkeys_path}" "headscale_url" 2>/dev/null || true)"
  if [[ -z "${login_server}" ]]; then
    # Fallback to computed default
    if tf_init 2>/dev/null; then
      local cip
      cip="$(tf output -raw control_public_ip 2>/dev/null || true)"
      if [[ -n "${cip}" ]]; then
        login_server="https://${cip}.sslip.io"
      fi
    fi
  fi

  local authkey
  authkey="$(read_json_value "${authkeys_path}" "authkeys.client" 2>/dev/null || true)"
  if [[ -z "${authkey}" ]]; then
    authkey="$(read_json_value "${authkeys_path}" "authkeys.servers" 2>/dev/null || true)"
  fi

  if [[ -z "${login_server}" || -z "${authkey}" ]]; then
    echo "[join-local] Could not determine login server or authkey from ${authkeys_path}." >&2
    return 1
  fi

  if [[ "${REJOIN_LOCAL}" != "1" ]] && local_tailscale_healthy; then
    echo "[join-local] This machine already has a Tailscale IP; skipping auto-join." >&2
    echo "[join-local] Use --rejoin-local to force re-auth to ${login_server}." >&2
    refresh_tailscale_ips_from_local || true
    return 0
  fi

  install_tailscale_local_best_effort || {
    echo "[join-local] tailscale not available; cannot auto-join this machine." >&2
    return 1
  }

  if install_headscale_ca_local_best_effort "${login_server}"; then
    echo "[join-local] Installed Headscale CA cert into local trust store." >&2
  else
    echo "[join-local] Could not install Headscale CA cert locally (best-effort)." >&2
  fi

  if restart_local_tailscaled_best_effort; then
    echo "[join-local] Restarted local tailscaled to pick up trust store changes." >&2
  else
    echo "[join-local] Could not restart local tailscaled automatically (best-effort)." >&2
  fi

  if ! local_tailscale_versions_match; then
    print_local_tailscale_version_mismatch_guidance
    return 1
  fi

  echo "[join-local] Joining this machine to Headscale: ${login_server}" >&2
  local local_hostname
  local_hostname="$(local_tailscale_hostname)"
  if [[ "${REJOIN_LOCAL}" == "1" ]]; then
    delete_local_headscale_node_best_effort
    sudo tailscale logout >/dev/null 2>&1 || true
  fi
  sudo tailscale down >/dev/null 2>&1 || true
  if ! timeout 90 sudo tailscale up \
    --reset \
    --login-server "${login_server}" \
    --authkey "${authkey}" \
    --hostname "${local_hostname}" \
    --accept-routes \
    --force-reauth; then
    echo "[join-local] tailscale up failed or timed out after 90s." >&2
    tailscale status --json 2>/dev/null | head -n 80 >&2 || true
    return 1
  fi

  if ! local_tailscale_has_ip; then
    echo "[join-local] tailscale up completed but no Tailscale IPv4 is assigned." >&2
    tailscale status --json 2>/dev/null | head -n 80 >&2 || true
    return 1
  fi

  refresh_tailscale_ips_from_local || true
}

can_auto_join_local() {
  local require_tailscale_ips="${1:-1}"

  # Explicit --join-local / --rejoin-local takes precedence over auto behavior.
  if [[ "${JOIN_LOCAL}" == "1" ]]; then
    return 1
  fi

  local authkeys_path
  authkeys_path="$(inv_dir)/headscale-authkeys.json"
  [[ -f "${authkeys_path}" ]] || return 1

  if [[ "${require_tailscale_ips}" == "1" ]]; then
    [[ -f "$(inv_dir)/tailscale-ips.json" ]] || return 1
  fi

  return 0
}

control_public_ip_from_inventory() {
  local outputs_file
  outputs_file="$(inv_dir)/terraform-outputs.json"

  if [[ -f "${outputs_file}" ]]; then
    read_json_value "${outputs_file}" "control_public_ip.value" 2>/dev/null || true
    return 0
  fi

  tf_init 2>/dev/null || return 0
  tf output -state="${ENV_TF_STATE}" -raw control_public_ip 2>/dev/null || true
}

delete_local_headscale_node_best_effort() {
  local control_ip
  local local_hostname
  local raw_hostname
  local nodes_json
  local matched_nodes
  local -a candidate_names=()

  control_ip="$(control_public_ip_from_inventory)"
  [[ -n "${control_ip}" ]] || return 0

  local_hostname="$(local_tailscale_hostname)"
  raw_hostname="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"

  [[ -n "${local_hostname}" ]] && candidate_names+=("${local_hostname}")
  [[ -n "${raw_hostname}" ]] && candidate_names+=("${raw_hostname}")

  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] && candidate_names+=("${candidate}")
  done < <(local_tailscale_self_hostnames)

  if [[ ${#candidate_names[@]} -eq 0 ]]; then
    return 0
  fi

  nodes_json="$(ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "root@${control_ip}" \
    'docker exec headscale headscale nodes list --output json' 2>/dev/null || true)"

  [[ -n "${nodes_json}" ]] || return 0

  matched_nodes="$(printf '%s' "${nodes_json}" | python3 -c '
import json
import sys

targets = {item for item in sys.argv[1:] if item}

try:
    nodes = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

for node in nodes:
    names = {str(node.get("name") or ""), str(node.get("given_name") or "")}
    if names & targets:
        node_id = node.get("id")
        if node_id is not None:
            label = str(node.get("name") or node.get("given_name") or "")
            print(f"{node_id}\t{label}")
' "${candidate_names[@]}" 2>/dev/null || true)"

  [[ -n "${matched_nodes}" ]] || return 0

  while IFS=$'\t' read -r node_id node_label; do
    [[ -n "${node_id}" ]] || continue
    echo "[join-local] Deleting existing Headscale node '${node_label:-unknown}' (id=${node_id}) before rejoin." >&2
    ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      "root@${control_ip}" \
      "docker exec headscale headscale nodes delete --identifier ${node_id} --force" >/dev/null 2>&1 || true
  done <<< "${matched_nodes}"
}

refresh_tailscale_ips_from_local() {
  command -v tailscale >/dev/null 2>&1 || return 1

  local out_path
  out_path="$(inv_dir)/tailscale-ips.json"

  # Wait briefly for peers to appear.
  local i
  for i in 1 2 3 4 5; do
    if tailscale status --json >/tmp/ts-status.json 2>/dev/null; then
      if python3 - <<'PY'
import json
import sys
with open('/tmp/ts-status.json','r',encoding='utf-8') as f:
    data=json.load(f)
peers=data.get('Peer',{}) or {}
print(len(peers))
PY
      then
        break
      fi
    fi
    sleep 1
  done

  tailscale status --json > /tmp/ts-status.json
  local tmp_out_path
  tmp_out_path="${out_path}.tmp"
  jq '
    reduce ([((.Peer // {}) | to_entries[]? | .value), .Self] | .[]) as $peer
      ({};
        if (($peer.HostName // "") != "") and ((($peer.TailscaleIPs // []) | length) > 0) then
          .[$peer.HostName] = $peer.TailscaleIPs[0]
        else
          .
        end
      )
  ' /tmp/ts-status.json > "${tmp_out_path}"

  local mapping_count
  mapping_count="$(jq 'length' "${tmp_out_path}")"
  if [[ "${mapping_count}" -eq 0 && -f "${out_path}" ]]; then
    rm -f "${tmp_out_path}"
    echo "[join-local] Preserved existing tailscale IP map because the local peer view is currently empty." >&2
    return 0
  fi

  mv "${tmp_out_path}" "${out_path}"
  echo "[join-local] Wrote ${mapping_count} tailscale IP(s) to ${out_path}"
}

prune_replaced_core_tailscale_ips() {
  local ts_ips_file="$(inv_dir)/tailscale-ips.json"
  local outputs_file="$(inv_dir)/terraform-outputs.json"

  [[ -f "${ts_ips_file}" ]] || return 0

  TS_IPS_FILE="${ts_ips_file}" OUTPUTS_FILE="${outputs_file}" python3 - <<'PY'
import json
import os

ts_ips_file = os.environ["TS_IPS_FILE"]
outputs_file = os.environ["OUTPUTS_FILE"]

try:
  with open(ts_ips_file, "r", encoding="utf-8") as handle:
    mapping = json.load(handle) or {}
except Exception:
  raise SystemExit(0)

stale_hosts = {"control", "control-vm"}

try:
  with open(outputs_file, "r", encoding="utf-8") as handle:
    outputs = json.load(handle) or {}
  workloads = ((outputs.get("workloads_private_ips") or {}).get("value") or {}).keys()
  for workload in workloads:
    stale_hosts.add(str(workload))
    stale_hosts.add(f"{workload}-vm")
except Exception:
  pass

for host in stale_hosts:
  mapping.pop(host, None)

with open(ts_ips_file, "w", encoding="utf-8") as handle:
  json.dump(mapping, handle, indent=2, sort_keys=True)
PY
}

tf() {
  # Restore the ThreeFold Grid provider's subnet registry (state.json) for this
  # environment before running Terraform, then save it back afterwards.
  # The provider writes state.json relative to its working dir (TF_DIR), so
  # without this each environment would overwrite the same shared file.
  local grid_state_src="${ENV_DIR}/tf-grid-state.json"
  local grid_state_dst="${TF_DIR}/state.json"
  if [[ -f "${grid_state_src}" ]]; then
    cp "${grid_state_src}" "${grid_state_dst}"
  fi
  TF_DATA_DIR="${ENV_DIR}/.terraform" terraform -chdir="${TF_DIR}" "$@"
  local rc=$?
  if [[ -f "${grid_state_dst}" ]]; then
    cp "${grid_state_dst}" "${grid_state_src}"
  fi
  return ${rc}
}

tf_init() {
  tf init -input=false >/dev/null
}

tf_apply_with_retries() {
  local max_attempts="${1:-8}"
  local attempt=1
  local sleep_s=10

  local tf_extra=(-state="${ENV_TF_STATE}" -var-file="${ENV_TF_VARFILE}")

  while true; do
    echo "[terraform] apply (attempt ${attempt}/${max_attempts})" >&2

    set +e
    tf apply -auto-approve "${tf_extra[@]}" 2>&1 | tee /tmp/tf-apply.log
    local rc=${PIPESTATUS[0]}
    set -e

    if [[ ${rc} -eq 0 ]]; then
      return 0
    fi

    # ThreeFold can take a bit to fully remove old deployments/networks.
    # If we immediately recreate with the same name, we can hit a conflict.
    if grep -q "global workload with the same name" /tmp/tf-apply.log && grep -q "exists: conflict" /tmp/tf-apply.log; then
      if [[ ${attempt} -ge ${max_attempts} ]]; then
        echo "[terraform] apply failed after ${max_attempts} attempts due to name conflict." >&2
        return ${rc}
      fi
      echo "[terraform] Detected name conflict; waiting ${sleep_s}s then retrying…" >&2
      sleep "${sleep_s}"
      attempt=$((attempt + 1))
      # Exponential-ish backoff capped at 120s.
      sleep_s=$((sleep_s < 120 ? sleep_s * 2 : 120))
      continue
    fi

    return ${rc}
  done
}

tf_state_list() {
  tf_init 2>/dev/null || return 0
  tf state list -state="${ENV_TF_STATE}" 2>/dev/null || true
}

tf_state_has() {
  local addr="$1"
  tf_state_list | grep -qx "${addr}"
}

# Returns the active inventory directory.
inv_dir() {
  echo "${ENV_INVENTORY_DIR}"
}

# Validates the environment directory and populates ENV_* globals.
setup_env() {
  if [[ -z "${ENV_NAME}" ]]; then
    echo "Error: --env <name> is required." >&2
    echo "Example: scripts/deploy.sh full --env prod" >&2
    exit 2
  fi

  ENV_DIR="${ENVIRONMENTS_ROOT}/${ENV_NAME}"
  ENV_INVENTORY_DIR="${ENV_DIR}/inventory"
  ENV_TF_STATE="${ENV_DIR}/terraform.tfstate"
  ENV_TF_VARFILE="${ENV_DIR}/terraform.tfvars"

  if [[ ! -d "${ENV_DIR}" ]]; then
    echo "[env] Environment directory not found: ${ENV_DIR}" >&2
    echo "[env] Create it: mkdir -p \"${ENV_DIR}/group_vars\" \"${ENV_DIR}/inventory\"" >&2
    echo "[env] Then copy and edit: environments/${ENV_NAME}/terraform.tfvars.example → environments/${ENV_NAME}/terraform.tfvars" >&2
    exit 1
  fi

  if [[ ! -f "${ENV_TF_VARFILE}" ]]; then
    echo "[env] Missing Terraform vars file: ${ENV_TF_VARFILE}" >&2
    echo "[env] Copy and edit: environments/${ENV_NAME}/terraform.tfvars.example → environments/${ENV_NAME}/terraform.tfvars" >&2
    exit 1
  fi

  mkdir -p "${ENV_INVENTORY_DIR}"

  # Source per-environment secrets file (if it exists).
  # This exports all variables (including TF_VAR_* for Terraform).
  local secrets_file="${ENV_DIR}/secrets.env"
  if [[ -f "${secrets_file}" ]]; then
    echo "[env] Loading secrets from ${secrets_file}" >&2
    set -a
    # shellcheck source=/dev/null
    source "${secrets_file}"
    set +a
  else
    echo "[env] WARNING: ${secrets_file} not found." >&2
    echo "[env]          Copy secrets.env.example to secrets.env and fill in values." >&2
  fi

  # Validate that the TFGrid mnemonic is available (from secrets.env or tfvars).
  if [[ -z "${TF_VAR_tfgrid_mnemonic:-}" ]] && ! grep -q 'tfgrid_mnemonic' "${ENV_TF_VARFILE}" 2>/dev/null; then
    echo "[env] ERROR: tfgrid_mnemonic not set." >&2
    echo "[env]        Set TF_VAR_tfgrid_mnemonic in ${secrets_file}" >&2
    echo "[env]        (or add tfgrid_mnemonic to ${ENV_TF_VARFILE})." >&2
    exit 1
  fi

  if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
    echo "[env] ERROR: ${TF_DIR}/terraform.tfvars exists and would be auto-loaded by Terraform" >&2
    echo "[env]        alongside ${ENV_TF_VARFILE}, causing variable conflicts." >&2
    echo "[env]        Remove or rename it: mv terraform/terraform.tfvars terraform/terraform.tfvars.local" >&2
    exit 1
  fi

  # Build Ansible extra flags: env group_vars at highest precedence, plus all
  # other per-env group_vars files (gateway, control, monitoring) if present.
  ENV_ANSIBLE_EXTRA_FLAGS=(--extra-vars "headscale_local_inventory_dir=${ENV_INVENTORY_DIR} tailscale_local_inventory_dir=${ENV_INVENTORY_DIR} blueprint_env=${ENV_NAME}")

  for gv_name in all gateway control monitoring; do
    local gv="${ENV_DIR}/group_vars/${gv_name}.yml"
    [[ -f "${gv}" ]] && ENV_ANSIBLE_EXTRA_FLAGS+=(--extra-vars "@${gv}")
  done

  local headscale_dns_hint=""
  local headscale_url_hint=""
  local gv_all_path=""
  for gv_all_path in "${ENV_DIR}/group_vars/all.yml" "${ENV_DIR}/group_vars/all/main.yml"; do
    [[ -f "${gv_all_path}" ]] || continue
    [[ -z "${headscale_dns_hint}" ]] && headscale_dns_hint="$(sed -n 's/^base_domain:[[:space:]]*//p' "${gv_all_path}" | head -n1 | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]' | tr -d '"' | tr -d "'" || true)"
    [[ -z "${headscale_url_hint}" ]] && headscale_url_hint="$(sed -n 's/^headscale_url:[[:space:]]*//p' "${gv_all_path}" | head -n1 | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]' | tr -d '"' | tr -d "'" || true)"
  done
  if [[ -z "${headscale_dns_hint}" && -z "${headscale_url_hint}" ]]; then
    echo "[security] WARNING: Headscale will use the control IP sslip.io fallback." >&2
    echo "[security] Configure base_domain/headscale_subdomain or an explicit headscale_url for stable DNS and proper long-term TLS." >&2
  fi

  # Append CLI overrides after env group_vars so they win on precedence, and
  # pass booleans as JSON so Ansible receives real false values instead of the
  # truthy string "false".
  if [[ "${NO_RESTORE}" == "1" ]]; then
    ENV_ANSIBLE_EXTRA_FLAGS+=(--extra-vars '{"backup_restore_enabled": false}')
  fi

  # Pass --fresh-tailnet as explicit control-plane/node identity reset while
  # keeping all other backup restore behavior intact.
  if [[ "${FRESH_TAILNET}" == "1" ]]; then
    ENV_ANSIBLE_EXTRA_FLAGS+=(--extra-vars '{"headscale_restore_database": false, "tailscale_restore_state": false}')
  fi

  echo "[env] Active environment: ${ENV_NAME} (${ENV_DIR})" >&2
}

# Ensure a deployment tag is set for Terraform. The tag is a YYYYMMDD_HHMMSS
# timestamp appended to the TFGrid network name to guarantee global uniqueness —
# TFGrid enforces globally unique network names and old names linger for several
# minutes after destroy, making re-deploys with the same name fail with "conflict".
#
# Behaviour:
#   - If a cached tag file exists: read and export it (idempotent re-runs).
#   - If no cached tag exists: generate a fresh timestamp tag and cache it.
#   - The cache file is deleted by scope_full when --yes destroy is confirmed,
#     so the next apply gets a fresh tag.
ensure_deployment_tag() {
  local tag_file="${ENV_DIR}/deployment-tag"
  if [[ -f "${tag_file}" ]]; then
    export TF_VAR_deployment_tag
    TF_VAR_deployment_tag="$(cat "${tag_file}")"
    echo "[env] Using cached deployment tag: ${TF_VAR_deployment_tag}" >&2
  else
    TF_VAR_deployment_tag="$(date -u +%Y%m%d_%H%M%S)"
    export TF_VAR_deployment_tag
    echo "${TF_VAR_deployment_tag}" > "${tag_file}"
    echo "[env] Generated new deployment tag: ${TF_VAR_deployment_tag}" >&2
  fi
}

normalize_inventory_schema() {
  local outputs_file="$1"
  [[ -f "${outputs_file}" ]] || return 0

  python3 - <<'PY' "${outputs_file}"
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
if isinstance(data, dict) and not data.get("provider"):
    data["provider"] = "threefold"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

refresh_inventory() {
  local dest_dir
  dest_dir="$(inv_dir)"
  mkdir -p "${dest_dir}"
  tf output -state="${ENV_TF_STATE}" -json > "${dest_dir}/terraform-outputs.json"
  normalize_inventory_schema "${dest_dir}/terraform-outputs.json"
  chmod +x "${INVENTORY_SCRIPT}" || true
}

run_data_model_migrations() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[migrate] ERROR: python3 is required for data-model migrations." >&2
    exit 127
  fi

  if [[ ! -f "${DATA_MIGRATIONS_HELPER}" ]]; then
    echo "[migrate] ERROR: helper missing at ${DATA_MIGRATIONS_HELPER}" >&2
    exit 1
  fi

  echo "[migrate] Ensuring environment data model is current..." >&2
  python3 "${DATA_MIGRATIONS_HELPER}" migrate --env-dir "${ENV_DIR}"
}

# Remove stale SSH known_hosts entries for all IPs in the current terraform outputs.
# ThreeFold frequently reuses public IPs across deploys, causing "REMOTE HOST
# IDENTIFICATION HAS CHANGED" errors. This must run after refresh_inventory.
clear_stale_host_keys() {
  local outputs_file="${ENV_INVENTORY_DIR}/terraform-outputs.json"
  [[ -f "${outputs_file}" ]] || return 0

  local known_hosts_files=()
  [[ -f "${HOME}/.ssh/known_hosts" ]] && known_hosts_files+=("${HOME}/.ssh/known_hosts")
  # Some systems also have a system-wide file; skip if absent.

  [[ ${#known_hosts_files[@]} -eq 0 ]] && return 0

  # Collect all public IPs from terraform outputs.
  local ips
  ips="$(python3 - <<'PY' "${outputs_file}"
import json, re, sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

# Only match valid IPv4 addresses (not CIDRs, not hostnames, not IPv6).
IPV4_RE = re.compile(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')

ips = set()
for key, val in data.items():
    if "ip" not in key.lower():
        continue
    candidates = []
    if isinstance(val, str):
        candidates.append(val.split("/")[0])
    elif isinstance(val, dict):
        for v in val.values():
            if isinstance(v, str):
                candidates.append(v.split("/")[0])
    for c in candidates:
        if IPV4_RE.match(c):
            ips.add(c)

print("\n".join(sorted(ips)))
PY
)"

  [[ -z "${ips}" ]] && return 0

  local ip removed=0
  for ip in ${ips}; do
    for kh in "${known_hosts_files[@]}"; do
      if ssh-keygen -F "${ip}" -f "${kh}" >/dev/null 2>&1; then
        ssh-keygen -R "${ip}" -f "${kh}" >/dev/null 2>&1 || true
        removed=$((removed + 1))
      fi
    done
  done

  [[ $removed -gt 0 ]] && echo "[ssh] Cleared ${removed} stale known_hosts entries for reused IPs." >&2
  return 0
}

prefer_tailscale_for_ansible() {
  local force_tailscale=0

  case "${PREFER_TAILSCALE:-}" in
    0|false|False|FALSE|no|No|NO)
      return 1
      ;;
    1|true|True|TRUE|yes|Yes|YES)
      force_tailscale=1
      ;;
  esac

  if [[ ${force_tailscale} -eq 1 ]]; then
    # Explicitly requested; skip the SSH probe and trust tailscale.
    return 0
  fi

  if ! local_tailscale_healthy; then
    return 1
  fi

  # Local Tailscale is healthy, but ACL rules may block SSH from this machine to the cluster.
  # Probe actual SSH connectivity to the gateway's Tailscale IP before deciding to use it.
  local gw_ts_ip
  gw_ts_ip="$(python3 -c "
import json, os, sys

try:
  import subprocess
  status = subprocess.run(
    ['tailscale', 'status', '--json'],
    check=True,
    capture_output=True,
    text=True,
  )
  peers = json.loads(status.stdout).get('Peer') or {}
  for peer in peers.values():
    hostname = (peer.get('HostName') or '').strip()
    if hostname == 'gateway-vm':
      ips = peer.get('TailscaleIPs') or []
      if ips:
        print(ips[0])
        raise SystemExit(0)
except Exception:
  pass

try:
  d = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else {}
    print(d.get('gateway-vm', ''))
except Exception:
    pass
" "${ENV_INVENTORY_DIR}/tailscale-ips.json" 2>/dev/null || true)"

  [[ -n "${gw_ts_ip}" ]] || return 1

  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=20 \
      "root@${gw_ts_ip}" "true" 2>/dev/null
}

ansible_ping() {
  local limit="$1"
  pushd "${ANSIBLE_DIR}" >/dev/null

  local ansible_env=(
    TF_OUTPUTS_JSON="${ENV_INVENTORY_DIR}/terraform-outputs.json"
    TAILSCALE_IPS_JSON="${ENV_INVENTORY_DIR}/tailscale-ips.json"
  )
  [[ -n "${IGNORE_TAILSCALE_HOSTS}" ]] && ansible_env+=(IGNORE_TAILSCALE_HOSTS="${IGNORE_TAILSCALE_HOSTS}")
  prefer_tailscale_for_ansible && ansible_env+=(PREFER_TAILSCALE=1)

  env "${ansible_env[@]}" ansible -i "inventory/tfgrid.py" "${limit}" -m ping >/dev/null 2>&1 || { popd >/dev/null; return 1; }
  popd >/dev/null
}

attempt_backup() {
  local scope="$1"
  local limit="$2"

  # Refresh inventory from current TF outputs if possible.
  if tf_init 2>/dev/null; then
    refresh_inventory || true
  fi

  echo "[backup] Attempting to connect for backup (best-effort): ${limit}" >&2
  if ansible_ping "${limit}"; then
    echo "[backup] Connection OK to ${limit}; running backup hook." >&2
  else
    echo "[backup] Could not reach ${limit} via Ansible SSH; running backup hook anyway." >&2
  fi

  export DEPLOY_SCOPE="${scope}"
  export DEPLOY_LIMIT="${limit}"
  export REPO_ROOT
  export ENV_INVENTORY_DIR
  export ENV_NAME

  if [[ -x "${BACKUP_HOOK}" ]]; then
    "${BACKUP_HOOK}" || true
  else
    echo "[backup] ${BACKUP_HOOK} not executable or missing; skipping hook." >&2
  fi
}

ask_destroy_recreate() {
  local label="$1"

  if [[ "${NO_DESTROY}" == "1" ]]; then
    return 1
  fi

  if [[ "${DEPLOY_YES:-}" == "1" ]]; then
    echo "[deploy] --yes passed; destroying and recreating '${label}' without interactive confirmation." >&2
    return 0
  fi

  # Avoid blocking forever when stdin is not interactive (CI, piped runs, wrappers).
  if [[ ! -t 0 ]]; then
    echo "[deploy] Non-interactive mode detected; defaulting to in-place converge (equivalent to --no-destroy)." >&2
    return 1
  fi

  echo "Detected existing ${label}." >&2
  if ! read -r -t 20 -p "Destroy and recreate it first? [y/N] " ans; then
    echo >&2
    echo "[deploy] No response after 20s; defaulting to in-place converge (no destroy)." >&2
    return 1
  fi

  # Case-insensitive handling.
  ans="${ans,,}"
  case "${ans}" in
    y|yes) return 0 ;;
    n|no|"") return 1 ;;
    *) return 1 ;;
  esac
}

ansible_run() {
  local limit="${1:-}"
  local progress_step_id="${2:-ansible-main}"
  pushd "${ANSIBLE_DIR}" >/dev/null

  local ansible_env=(
    TF_OUTPUTS_JSON="${ENV_INVENTORY_DIR}/terraform-outputs.json"
    TAILSCALE_IPS_JSON="${ENV_INVENTORY_DIR}/tailscale-ips.json"
    ANSIBLE_CALLBACK_PLUGINS="${ANSIBLE_DIR}/callback_plugins"
    ANSIBLE_CALLBACKS_ENABLED="blueprint_progress"
    BLUEPRINT_PROGRESS_STEP_ID="${progress_step_id}"
  )
  [[ -n "${IGNORE_TAILSCALE_HOSTS}" ]] && ansible_env+=(IGNORE_TAILSCALE_HOSTS="${IGNORE_TAILSCALE_HOSTS}")
  prefer_tailscale_for_ansible && ansible_env+=(PREFER_TAILSCALE=1)

  local cmd=(env "${ansible_env[@]}" ansible-playbook -i "inventory/tfgrid.py" "${PLAYBOOK_REL}")
  [[ -n "${limit}" ]]                   && cmd+=(--limit "${limit}")
  [[ -n "${ANSIBLE_EXTRA_VARS_JSON}" ]]  && cmd+=(--extra-vars "${ANSIBLE_EXTRA_VARS_JSON}")
  cmd+=("${ENV_ANSIBLE_EXTRA_FLAGS[@]}")

  "${cmd[@]}"
  popd >/dev/null
}

wait_for_public_ssh() {
  local host_label="$1"
  local host_ip="$2"

  [[ -n "${host_ip}" ]] || return 0

  local timeout=180
  local elapsed=0
  local interval=5

  echo "[ssh-wait] Waiting for SSH on ${host_label} (${host_ip}:22, timeout ${timeout}s)…" >&2
  while true; do
    if timeout 3 bash -c "echo >/dev/tcp/${host_ip}/22" 2>/dev/null; then
      echo "[ssh-wait] SSH reachable on ${host_label} (${host_ip}) after ${elapsed}s" >&2
      # Give sshd a moment to finish initialising after first TCP accept.
      sleep 3
      return 0
    fi
    if [[ ${elapsed} -ge ${timeout} ]]; then
      echo "[ssh-wait] WARNING: SSH not reachable on ${host_label} (${host_ip}) after ${timeout}s; proceeding anyway." >&2
      return 0
    fi
    echo "[ssh-wait]   ${host_label}: [${elapsed}s elapsed] not ready yet…" >&2
    sleep ${interval}
    elapsed=$((elapsed + interval))
  done
}

# Wait until the gateway's public SSH port is reachable.
# ThreeFold VMs take 60-120s to boot sshd after the deployment completes.
# Without this wait, Ansible immediately gets "Connection refused" and fails.
wait_for_ssh() {
  local outputs_file="${ENV_INVENTORY_DIR}/terraform-outputs.json"
  [[ -f "${outputs_file}" ]] || return 0

  local gateway_ip
  gateway_ip="$(python3 -c "
import json
try:
    d=json.load(open('${outputs_file}'))
    print(d.get('gateway_public_ip',{}).get('value','') or d.get('gateway_public_ip',''))
except: pass
" 2>/dev/null || true)"

  wait_for_public_ssh "gateway" "${gateway_ip}"
}

should_skip_public_ssh_wait() {
  if prefer_tailscale_for_ansible; then
    echo "[ssh-wait] Skipping public SSH wait because Tailscale transport is active." >&2
    return 0
  fi
  return 1
}

ansible_run_firewall_lockdown() {
  # Re-apply ONLY the firewall tag with an empty allowlist.
  # This keeps public SSH closed after bootstrap while preserving tailscale0 access.
  pushd "${ANSIBLE_DIR}" >/dev/null

  local ansible_env=(
    PREFER_TAILSCALE=1
    TF_OUTPUTS_JSON="${ENV_INVENTORY_DIR}/terraform-outputs.json"
    TAILSCALE_IPS_JSON="${ENV_INVENTORY_DIR}/tailscale-ips.json"
  )

  env "${ansible_env[@]}" ansible-playbook -i "inventory/tfgrid.py" "${PLAYBOOK_REL}" \
    --tags firewall \
    --extra-vars '{"firewall_allow_public_ssh_from_cidrs":[]}' \
    "${ENV_ANSIBLE_EXTRA_FLAGS[@]}"
  popd >/dev/null
}

print_deployment_summary() {
  # Print a formatted summary of deployment outputs, IPs, services, and next steps.
  # This helps users quickly understand what was deployed and how to access it.
  INVENTORY_JSON="$(inv_dir)/terraform-outputs.json" \
  DEPLOY_FRESH_TAILNET="${FRESH_TAILNET}" \
    "${REPO_ROOT}/scripts/helpers/deployment-summary.sh" || true

  # Also save a sanitized copy (no API keys, no auth keys) to the environment dir.
  local summary_file="${ENV_DIR}/deployment-summary.txt"
  INVENTORY_JSON="$(inv_dir)/terraform-outputs.json" \
  DEPLOY_FRESH_TAILNET="${FRESH_TAILNET}" \
  SUMMARY_SANITIZE=1 NO_COLOR=1 \
    "${REPO_ROOT}/scripts/helpers/deployment-summary.sh" > "${summary_file}" 2>/dev/null || true
  echo ""
  echo "  Deployment summary saved to: ${summary_file}"
}

refresh_recovery_bundle() {
  local recovery_dir="${ENV_DIR}/.recovery"
  mkdir -p "${recovery_dir}"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[recovery] WARNING: python3 not found; skipping portable recovery bundle refresh." >&2
    RECOVERY_REFRESH_EXIT_CODE=12
    RECOVERY_REFRESH_SEVERITY="skipped"
    return 0
  fi

  if [[ ! -f "${RECOVERY_HELPER}" ]]; then
    echo "[recovery] WARNING: helper missing at ${RECOVERY_HELPER}; skipping portable recovery bundle refresh." >&2
    RECOVERY_REFRESH_EXIT_CODE=12
    RECOVERY_REFRESH_SEVERITY="skipped"
    return 0
  fi

  echo "[recovery] Refreshing portable control-plane recovery bundle..." >&2

  set +e
  python3 "${RECOVERY_HELPER}" refresh \
    --repo-root "${REPO_ROOT}" \
    --env "${ENV_NAME}" \
    --state-file "${recovery_dir}/status.json" \
    --line-file "${recovery_dir}/latest-recovery-line"
  RECOVERY_REFRESH_EXIT_CODE=$?
  set -e

  case "${RECOVERY_REFRESH_EXIT_CODE}" in
    0)
      RECOVERY_REFRESH_SEVERITY="ok"
      echo "[recovery] Portable recovery bundle refreshed to both backup storages." >&2
      ;;
    10)
      RECOVERY_REFRESH_SEVERITY="degraded"
      echo "[recovery] WARNING: portable recovery bundle refreshed to primary storage, but secondary replication failed." >&2
      ;;
    11)
      RECOVERY_REFRESH_SEVERITY="failed"
      echo "[recovery] ERROR: portable recovery bundle refresh failed the required publication checks." >&2
      ;;
    12)
      RECOVERY_REFRESH_SEVERITY="skipped"
      echo "[recovery] WARNING: portable recovery bundle is not configured for this environment." >&2
      ;;
    *)
      RECOVERY_REFRESH_SEVERITY="failed"
      echo "[recovery] ERROR: portable recovery bundle helper exited unexpectedly with code ${RECOVERY_REFRESH_EXIT_CODE}." >&2
      ;;
  esac
}

enforce_recovery_refresh_result() {
  if [[ "${RECOVERY_REFRESH_SEVERITY}" == "failed" ]]; then
    echo "[recovery] Deploy finished, but the portable recovery bundle did not meet the required primary/secondary publication rules." >&2
    exit 1
  fi
}

dns_setup() {
  # Update DNS A records via Namecheap API (opt-in: runs only when NAMECHEAP_API_KEY is set).
  if [[ -z "${NAMECHEAP_API_KEY:-}" ]]; then
    return 0
  fi

  echo "[dns] NAMECHEAP_API_KEY detected — running DNS A record update" >&2

  local dns_script="${REPO_ROOT}/scripts/helpers/dns-setup.sh"
  if [[ ! -x "${dns_script}" ]]; then
    echo "[dns] WARNING: ${dns_script} not found or not executable; skipping DNS update." >&2
    return 0
  fi

  # Read base_domain from env group_vars if available.
  local base_domain="${BASE_DOMAIN:-}"
  if [[ -z "${base_domain}" ]]; then
    local gv_all="${ENV_DIR}/group_vars/all.yml"
    if [[ -f "${gv_all}" ]]; then
      base_domain="$(grep -E '^base_domain:' "${gv_all}" | head -n1 | sed 's/^base_domain:[[:space:]]*//' | tr -d '"' | tr -d "'" || true)"
    fi
  fi
  if [[ -z "${base_domain}" ]]; then
    echo "[dns] WARNING: base_domain not set (set it in ${ENV_DIR}/group_vars/all.yml or BASE_DOMAIN env var); skipping DNS update." >&2
    return 0
  fi

  # Read optional headscale_subdomain and gateway_subdomains from env group_vars.
  local headscale_sub="${HEADSCALE_SUBDOMAIN:-}"
  if [[ -z "${headscale_sub}" ]]; then
    local gv_all="${ENV_DIR}/group_vars/all.yml"
    if [[ -f "${gv_all}" ]]; then
      headscale_sub="$(grep -E '^headscale_subdomain:' "${gv_all}" | head -n1 | sed 's/^headscale_subdomain:[[:space:]]*//' | tr -d '"' | tr -d "'" || true)"
    fi
  fi

  local gw_subs="${GATEWAY_SUBDOMAINS:-}"
  if [[ -z "${gw_subs}" ]]; then
    local gv_gw="${ENV_DIR}/group_vars/gateway.yml"
    if [[ -f "${gv_gw}" ]]; then
      gw_subs="$(python3 "${REPO_ROOT}/scripts/helpers/gateway_public_subdomains.py" --file "${gv_gw}" --base-domain "${base_domain}" 2>/dev/null || true)"
    fi
  fi

  TERRAFORM_OUTPUTS_JSON="$(inv_dir)/terraform-outputs.json" \
    BASE_DOMAIN="${base_domain}" \
    HEADSCALE_SUBDOMAIN="${headscale_sub}" \
    GATEWAY_SUBDOMAINS="${gw_subs}" \
    "${dns_script}"
}

maybe_lockdown_public_ssh() {
  # If we used a temporary public SSH allowlist and we also joined this machine to the tailnet,
  # automatically remove the allowlist at the end.
  if [[ ${#ALLOWLIST_CIDRS[@]} -eq 0 ]]; then
    return 0
  fi
  if [[ "${KEEP_SSH_ALLOWLIST}" == "1" ]]; then
    return 0
  fi
  if [[ "${JOIN_LOCAL}" != "1" ]]; then
    echo "[lockdown] Public SSH allowlist was used but --join-local was not set; leaving allowlist in place." >&2
    echo "[lockdown] Re-run with --join-local (recommended) and then run firewall lockdown." >&2
    return 0
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    echo "[lockdown] tailscale not present locally; leaving allowlist in place to avoid lockout." >&2
    return 0
  fi

  if ! local_tailscale_has_ip; then
    echo "[lockdown] Local machine has no Tailscale IP; leaving allowlist in place to avoid lockout." >&2
    return 0
  fi

  echo "[lockdown] Removing temporary public SSH allowlist (firewall tag only)…" >&2
  ansible_run_firewall_lockdown
}

scope_full() {
  progress_step_start "tf-init"
  tf_init
  progress_step_done "tf-init"

  local did_destroy=0
  local will_destroy=0
  local auto_post_destroy_join_local=0

  local existing=""
  if [[ -n "$(tf_state_list)" ]]; then
    existing=1
  fi

  if [[ -n "${existing}" ]] && ask_destroy_recreate "Terraform-managed infrastructure"; then
    will_destroy=1
  fi

  # On converge-in-place: if the inventory already has Headscale credentials and
  # Tailscale IPs from a prior deploy, automatically join this machine to the tailnet
  # before Ansible runs so public SSH is not required.
  local converge_join_local=0
  if [[ "${will_destroy}" == "0" ]] && can_auto_join_local 1; then
    converge_join_local=1
  fi

  # After destructive full redeploys, preexisting credentials may be stale.
  # We can still auto-join safely after a control-only bootstrap refreshes
  # Headscale auth artifacts for the new control plane.
  if [[ "${will_destroy}" == "1" ]] && [[ "${JOIN_LOCAL}" != "1" ]]; then
    auto_post_destroy_join_local=1
  fi

  emit_progress_plan "full" "${will_destroy}" "${converge_join_local}"

  if [[ "${will_destroy}" == "1" ]]; then
    progress_step_start "pre-destroy-backup"
    attempt_backup "full" "all"
    progress_step_done "pre-destroy-backup"

    progress_step_start "terraform-destroy"
    tf destroy -auto-approve -state="${ENV_TF_STATE}" -var-file="${ENV_TF_VARFILE}" || true
    progress_step_done "terraform-destroy"
    did_destroy=1

    # Delete the cached deployment tag so a fresh one is generated for the new deploy.
    rm -f "${ENV_DIR}/deployment-tag" || true

    # If we recreate the tailnet (Headscale state), any previously-saved peer IPs are stale.
    rm -f "$(inv_dir)/tailscale-ips.json" || true
  fi

  progress_step_start "deployment-tag"
  ensure_deployment_tag
  progress_step_done "deployment-tag"

  progress_step_start "terraform-apply"
  tf_apply_with_retries 8
  progress_step_done "terraform-apply"

  progress_step_start "refresh-inventory"
  refresh_inventory
  progress_step_done "refresh-inventory"

  progress_step_start "data-migrations"
  run_data_model_migrations
  progress_step_done "data-migrations"

  progress_step_start "clear-host-keys"
  clear_stale_host_keys || true
  progress_step_done "clear-host-keys"

  # Update DNS before Ansible so headscale.babenko.live → control-vm IP
  # before Caddy requests a TLS cert and before Tailscale tries to connect.
  progress_step_start "dns-setup"
  dns_setup
  progress_step_done "dns-setup"

  # Converge-in-place auto-join: the prior deploy locked down public SSH, so join
  # this machine to the existing tailnet *before* Ansible runs.  Idempotent: if
  # already connected to the right network, join_local_tailnet exits immediately.
  if [[ "${converge_join_local}" == "1" ]]; then
    progress_step_start "join-local"
    echo "[converge] Auto-joining this machine to the tailnet before Ansible (converge-in-place)..." >&2
    if join_local_tailnet; then
      # Join succeeded — force Tailscale transport for Ansible without the SSH probe.
      PREFER_TAILSCALE=1
    fi
    progress_step_done "join-local"
  fi

  progress_step_start "wait-ssh"
  if should_skip_public_ssh_wait; then
    true
  else
    wait_for_ssh
  fi
  progress_step_done "wait-ssh"

  if [[ "${JOIN_LOCAL}" == "1" || "${auto_post_destroy_join_local}" == "1" ]]; then
    # Bring up control plane first so we have Headscale keys persisted,
    # then join this machine before the full run (helps when public SSH is locked down).
    progress_step_start "ansible-bootstrap"
    ansible_run "control" "ansible-bootstrap"
    progress_step_done "ansible-bootstrap"

    # If we destroyed/recreated, force re-auth this machine to the new Headscale.
    if [[ ${did_destroy} -eq 1 ]]; then
      REJOIN_LOCAL=1
    fi

    progress_step_start "join-local"
    if [[ "${auto_post_destroy_join_local}" == "1" ]]; then
      echo "[converge] Auto-joining this machine to the tailnet after control bootstrap (destructive full deploy)..." >&2
    fi
    join_local_tailnet || true
    progress_step_done "join-local"
  fi

  progress_step_start "ansible-main"
  ansible_run "" "ansible-main"
  progress_step_done "ansible-main"

  # Post-Ansible re-join for converge-in-place: Ansible always restarts Headscale,
  # which regenerates the noise key on a fresh/rebuilt control VM.  Re-join after
  # Ansible to heal any stale-key connection.  The JOIN_LOCAL path already handles
  # this via the bootstrap block above, so only add it for the converge-only case.
  if [[ "${converge_join_local}" == "1" && "${JOIN_LOCAL}" != "1" ]]; then
    progress_step_start "join-local"
    echo "[converge] Re-checking local tailnet connection after Ansible (Headscale may have restarted with a new noise key)..." >&2
    join_local_tailnet || true
    progress_step_done "join-local"
  fi

  maybe_lockdown_public_ssh

  progress_step_start "recovery-refresh"
  refresh_recovery_bundle
  progress_step_done "recovery-refresh"

  progress_step_start "deployment-summary"
  print_deployment_summary
  progress_step_done "deployment-summary"
  enforce_recovery_refresh_result
}

scope_gateway() {
  progress_step_start "tf-init"
  tf_init
  progress_step_done "tf-init"

  progress_step_start "deployment-tag"
  ensure_deployment_tag
  progress_step_done "deployment-tag"

  local tf_extra=(-state="${ENV_TF_STATE}" -var-file="${ENV_TF_VARFILE}")
  local will_destroy=0
  local converge_join_local=0

  if tf_state_has "grid_deployment.gateway" && ask_destroy_recreate "gateway"; then
    will_destroy=1
  fi

  # Converge-in-place auto-join: if prior Headscale auth artifacts exist,
  # join this machine before Ansible so tailnet transport is available even
  # when public SSH is locked down or temporarily unreachable.
  if can_auto_join_local 0; then
    converge_join_local=1
  fi

  emit_progress_plan "gateway" "${will_destroy}" "${converge_join_local}"

  if [[ "${will_destroy}" == "1" ]]; then
    progress_step_start "pre-destroy-backup"
    attempt_backup "gateway" "gateway"
    progress_step_done "pre-destroy-backup"

    progress_step_start "terraform-apply"
    tf apply -auto-approve -replace=grid_deployment.gateway "${tf_extra[@]}"
  else
    progress_step_start "terraform-apply"
    tf apply -auto-approve "${tf_extra[@]}"
  fi
  progress_step_done "terraform-apply"

  progress_step_start "refresh-inventory"
  refresh_inventory
  progress_step_done "refresh-inventory"

  progress_step_start "data-migrations"
  run_data_model_migrations
  progress_step_done "data-migrations"

  progress_step_start "clear-host-keys"
  clear_stale_host_keys || true
  progress_step_done "clear-host-keys"

  progress_step_start "dns-setup"
  dns_setup
  progress_step_done "dns-setup"

  if [[ "${converge_join_local}" == "1" ]]; then
    progress_step_start "join-local"
    echo "[converge] Auto-joining this machine to the tailnet before Ansible (gateway converge-in-place)..." >&2
    if join_local_tailnet; then
      # Join succeeded — force Tailscale transport for Ansible without the SSH probe.
      PREFER_TAILSCALE=1
    fi
    progress_step_done "join-local"
  fi

  progress_step_start "wait-ssh"
  if should_skip_public_ssh_wait; then
    true
  else
    wait_for_ssh
  fi
  progress_step_done "wait-ssh"
  # Include the control plane and monitoring tier in the limited play so
  # gateway-only follow-up converges still have the hostvars they need for the
  # Tailscale/Headscale preauth-key path and the internal wildcard upstreams.
  progress_step_start "ansible-main"
  ansible_run "control:gateway:monitoring-vm" "ansible-main"
  progress_step_done "ansible-main"

  # Post-Ansible re-join: Ansible unconditionally restarts the Headscale container.
  # On a fresh or rebuilt environment this generates a new noise private key, which
  # silently breaks the pre-Ansible converge join done above.  Re-joining after
  # Ansible is idempotent (skipped when the connection is still healthy) and
  # corrects the stale-key situation without requiring --rejoin-local.
  if [[ "${JOIN_LOCAL}" == "1" || "${converge_join_local}" == "1" ]]; then
    progress_step_start "join-local"
    join_local_tailnet || true
    progress_step_done "join-local"
  fi

  maybe_lockdown_public_ssh

  progress_step_start "recovery-refresh"
  refresh_recovery_bundle
  progress_step_done "recovery-refresh"

  progress_step_start "deployment-summary"
  print_deployment_summary
  progress_step_done "deployment-summary"
  enforce_recovery_refresh_result
}

scope_control() {
  progress_step_start "tf-init"
  tf_init
  progress_step_done "tf-init"

  progress_step_start "deployment-tag"
  ensure_deployment_tag
  progress_step_done "deployment-tag"

  local tf_extra=(-state="${ENV_TF_STATE}" -var-file="${ENV_TF_VARFILE}")
  local replaced_core=0
  local will_destroy=0
  local converge_join_local=0
  local auto_post_destroy_join_local=0

  if tf_state_has "grid_deployment.core" && ask_destroy_recreate "control/core"; then
    will_destroy=1
  fi

  # Converge-in-place auto-join for control-only runs (same rationale as full/gateway).
  if [[ "${will_destroy}" == "0" ]] && can_auto_join_local 1; then
    converge_join_local=1
  fi

  if [[ "${will_destroy}" == "1" ]] && [[ "${JOIN_LOCAL}" != "1" ]]; then
    auto_post_destroy_join_local=1
  fi

  emit_progress_plan "control" "${will_destroy}" "${converge_join_local}"

  if [[ "${will_destroy}" == "1" ]]; then
    progress_step_start "pre-destroy-backup"
    attempt_backup "control" "control"
    progress_step_done "pre-destroy-backup"

    progress_step_start "terraform-apply"
    tf apply -auto-approve -replace=grid_deployment.core "${tf_extra[@]}"
    replaced_core=1
  else
    progress_step_start "terraform-apply"
    tf apply -auto-approve "${tf_extra[@]}"
  fi
  progress_step_done "terraform-apply"

  if [[ ${replaced_core} -eq 1 ]]; then
    prune_replaced_core_tailscale_ips
    IGNORE_TAILSCALE_HOSTS="control,control-vm"
  fi

  progress_step_start "refresh-inventory"
  refresh_inventory
  progress_step_done "refresh-inventory"

  progress_step_start "data-migrations"
  run_data_model_migrations
  progress_step_done "data-migrations"

  progress_step_start "clear-host-keys"
  clear_stale_host_keys || true
  progress_step_done "clear-host-keys"

  progress_step_start "dns-setup"
  dns_setup
  progress_step_done "dns-setup"

  if [[ "${converge_join_local}" == "1" ]]; then
    progress_step_start "join-local"
    echo "[converge] Auto-joining this machine to the tailnet before Ansible (control converge-in-place)..." >&2
    if join_local_tailnet; then
      # Join succeeded — force Tailscale transport for Ansible without the SSH probe.
      PREFER_TAILSCALE=1
    fi
    progress_step_done "join-local"
  fi

  if [[ "${auto_post_destroy_join_local}" == "1" ]]; then
    progress_step_start "ansible-bootstrap"
    ansible_run "control" "ansible-bootstrap"
    progress_step_done "ansible-bootstrap"

    REJOIN_LOCAL=1
    progress_step_start "join-local"
    echo "[converge] Auto-joining this machine to the tailnet after control bootstrap (destructive control deploy)..." >&2
    if join_local_tailnet; then
      PREFER_TAILSCALE=1
    fi
    progress_step_done "join-local"
  fi

  progress_step_start "wait-ssh"
  if should_skip_public_ssh_wait; then
    true
  else
    wait_for_ssh
    if [[ ${replaced_core} -eq 1 ]]; then
      wait_for_public_ssh "control" "$(control_public_ip_from_inventory)"
    fi
  fi
  progress_step_done "wait-ssh"

  progress_step_start "ansible-main"
  ansible_run "" "ansible-main"
  progress_step_done "ansible-main"
  IGNORE_TAILSCALE_HOSTS=""

  # Post-Ansible re-join: same rationale as scope_full/scope_gateway — Headscale
  # container is always restarted by Ansible, so heal any stale noise-key connection.
  if [[ "${converge_join_local}" == "1" && "${JOIN_LOCAL}" != "1" && "${auto_post_destroy_join_local}" != "1" ]]; then
    progress_step_start "join-local"
    echo "[converge] Re-checking local tailnet connection after Ansible (Headscale may have restarted with a new noise key)..." >&2
    join_local_tailnet || true
    progress_step_done "join-local"
  fi

  maybe_lockdown_public_ssh

  progress_step_start "recovery-refresh"
  refresh_recovery_bundle
  progress_step_done "recovery-refresh"

  progress_step_start "deployment-summary"
  print_deployment_summary
  progress_step_done "deployment-summary"
  enforce_recovery_refresh_result
}

scope_dns() {
  emit_progress_plan "dns" "0"

  # Standalone DNS update — uses existing terraform-outputs.json, no Terraform apply.
  # If the outputs file is missing or empty, try refreshing from TF state.
  local outputs_file
  outputs_file="$(inv_dir)/terraform-outputs.json"

  if [[ ! -s "${outputs_file}" ]] || [[ "$(cat "${outputs_file}")" == "{}" ]]; then
    echo "[dns] terraform-outputs.json is empty; attempting to refresh from TF state…" >&2
    if tf_init 2>/dev/null; then
      refresh_inventory
    fi
  fi

  progress_step_start "dns-setup"
  dns_setup
  progress_step_done "dns-setup"
}

scope_service_x() {
  echo "service-x is a reserved scope and is not implemented yet." >&2
  echo "Use full, gateway, control, dns, or join-local scopes." >&2
  exit 2
}

scope_join_local() {
  emit_progress_plan "join-local" "0"

  progress_step_start "join-local"
  join_local_tailnet
  progress_step_done "join-local"
}

validate_flag_combinations() {
  local scope="$1"

  if [[ "${NO_DESTROY}" == "1" && "${DEPLOY_YES:-}" == "1" ]]; then
    echo "Conflicting deploy flags: --yes and --no-destroy cannot be used together" >&2
    exit 2
  fi

  if [[ "${FRESH_TAILNET}" != "1" ]]; then
    return 0
  fi

  case "${scope}" in
    full|control|gateway)
      ;;
    *)
      echo "--fresh-tailnet is only supported with full, control, or gateway scopes." >&2
      exit 2
      ;;
  esac

  if [[ "${NO_DESTROY}" == "1" ]]; then
    echo "--fresh-tailnet requires destructive redeploy behavior; do not combine it with --no-destroy." >&2
    exit 2
  fi

  if [[ "${scope}" == "join-local" || "${scope}" == "dns" ]]; then
    echo "--fresh-tailnet is not valid for ${scope}." >&2
    exit 2
  fi
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  local scope_raw="$1"; shift
  local scope="${scope_raw,,}"
  scope="${scope//_/-}"
  local full_args=("${scope_raw}" "$@")

  # Allow DEPLOY_YES=1 from the environment; --yes still overrides.
  DEPLOY_YES="${DEPLOY_YES:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --env" >&2; exit 2
        fi
        ENV_NAME="$2"
        shift 2
        ;;
      --yes)
        DEPLOY_YES=1
        RECORD_EXTRA_ARGS+=("$1")
        shift
        ;;
      --no-destroy)
        NO_DESTROY=1
        RECORD_EXTRA_ARGS+=("$1")
        shift
        ;;
      --no-restore)
        NO_RESTORE=1
        RECORD_EXTRA_ARGS+=("$1")
        shift
        ;;
      --fresh-tailnet)
        FRESH_TAILNET=1
        RECORD_EXTRA_ARGS+=("$1")
        shift
        ;;
      --join-local)
        JOIN_LOCAL=1
        RECORD_EXTRA_ARGS+=("$1")
        shift
        ;;
      --rejoin-local)
        JOIN_LOCAL=1
        REJOIN_LOCAL=1
        RECORD_EXTRA_ARGS+=("$1")
        shift
        ;;
      --allow-ssh-from)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --allow-ssh-from" >&2
          exit 2
        fi
        ALLOWLIST_CIDRS+=("$2")
        RECORD_EXTRA_ARGS+=("$1" "$2")
        shift 2
        ;;
      --allow-ssh-from-my-ip)
        local ip
        ip="$(detect_public_ip)"
        if [[ -z "${ip}" ]]; then
          echo "Could not detect public IP (install curl/wget or pass --allow-ssh-from <cidr>)." >&2
          exit 2
        fi
        ALLOWLIST_CIDRS+=("${ip}/32")
        RECORD_EXTRA_ARGS+=("$1")
        shift
        ;;
      --keep-ssh-allowlist)
        KEEP_SSH_ALLOWLIST=1
        RECORD_EXTRA_ARGS+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done

  need_cmd terraform
  need_cmd ansible-playbook
  need_cmd ansible

  maybe_record_terminal_run "${scope}" "${full_args[@]}"

  validate_flag_combinations "${scope}"

  # --env is required for all scopes except --help.
  setup_env
  build_ansible_extra_vars

  case "${scope}" in
    full) scope_full ;;
    gateway) scope_gateway ;;
    control) scope_control ;;
    dns) scope_dns ;;
    join-local|join_local) scope_join_local ;;
    service-x|service_x) scope_service_x ;;
    *)
      echo "Unknown scope: ${scope}" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
