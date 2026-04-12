#!/usr/bin/env bash
set -euo pipefail

# Backup hook — invoked by deploy.sh before destructive actions.
#
# Triggers an ad-hoc backup of services affected by the current deploy scope.
# This ensures a snapshot exists before destroying/recreating infrastructure.
#
# Inputs (env vars):
# - DEPLOY_SCOPE: full|gateway|control|service-x
# - DEPLOY_LIMIT: ansible limit/group passed by deploy script (best-effort)
# - REPO_ROOT: absolute path to repo root

scope="${DEPLOY_SCOPE:-unknown}"
limit="${DEPLOY_LIMIT:-all}"
backup_timeout_seconds="${BACKUP_HOOK_TIMEOUT_SECONDS:-120}"

ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY_SCRIPT="${ANSIBLE_DIR}/inventory/tfgrid.py"

echo "[backup] Pre-destroy backup for scope=${scope}, limit=${limit}" >&2

# Run the backup tag via Ansible to trigger immediate backups before destroy.
# This is best-effort — if Ansible can't reach the hosts, we still proceed.
if command -v ansible-playbook >/dev/null 2>&1; then
  pushd "${ANSIBLE_DIR}" >/dev/null

  local_env=(
    TF_OUTPUTS_JSON="${ENV_INVENTORY_DIR}/terraform-outputs.json"
    TAILSCALE_IPS_JSON="${ENV_INVENTORY_DIR}/tailscale-ips.json"
  )

  # Probe gateway Tailscale IP: if reachable, prefer Tailscale routing (same
  # logic as prefer_tailscale_for_ansible() in deploy.sh).
  _gw_ts_ip="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('gateway-vm', ''))
except Exception:
    pass
" "${ENV_INVENTORY_DIR}/tailscale-ips.json" 2>/dev/null || true)"
  if [[ -n "${_gw_ts_ip}" ]] && ssh \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5 \
      "root@${_gw_ts_ip}" true 2>/dev/null; then
    local_env+=(PREFER_TAILSCALE=1)
  fi

  # Build --extra-vars flags to load environment group_vars (same files
  # deploy.sh loads via ENV_ANSIBLE_EXTRA_FLAGS). Without these, Ansible
  # would only see role defaults and miss backup_backends and backup_enabled.
  env_extra_args=()
  if [[ -n "${ENV_NAME:-}" && -n "${REPO_ROOT:-}" ]]; then
    env_dir="${REPO_ROOT}/environments/${ENV_NAME}"
    env_extra_args+=(--extra-vars "blueprint_env=${ENV_NAME} headscale_local_inventory_dir=${ENV_INVENTORY_DIR:-${env_dir}/inventory} tailscale_local_inventory_dir=${ENV_INVENTORY_DIR:-${env_dir}/inventory}")
    for gv_name in all gateway control monitoring; do
      gv="${env_dir}/group_vars/${gv_name}.yml"
      [[ -f "${gv}" ]] && env_extra_args+=(--extra-vars "@${gv}")
    done
  fi

  ansible_cmd=(
    env "${local_env[@]}" ansible-playbook
    -i "inventory/tfgrid.py"
    "playbooks/site.yml"
    --tags backup
    --limit "${limit}"
    ${env_extra_args[@]+"${env_extra_args[@]}"}
  )

  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "${backup_timeout_seconds}"s "${ansible_cmd[@]}" 2>&1 || \
      echo "[backup] Ansible backup run failed or timed out after ${backup_timeout_seconds}s (best-effort, continuing)." >&2
  else
    "${ansible_cmd[@]}" 2>&1 || \
      echo "[backup] Ansible backup run failed (best-effort, continuing)." >&2
  fi

  popd >/dev/null
else
  echo "[backup] ansible-playbook not found; skipping pre-destroy backup." >&2
fi
