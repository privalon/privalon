#!/usr/bin/env bash
set -euo pipefail

# Deployment Summary Generator
#
# Collects and formats useful information from Terraform and Ansible outputs
# after deployment, showing IP addresses, services, URLs, and next steps.
#
# Usage:
#   scripts/helpers/deployment-summary.sh [--scope full|gateway|control|all]
#
# The summary includes:
# - Infrastructure: public/private IPs, regions, hostnames
# - Services: URLs, ports, and connection methods for Headscale, Prometheus, Grafana
# - Tailnet: Tailscale node registration status and IPs
# - Next Steps: Common connection commands for various scenarios

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TF_DIR="${REPO_ROOT}/terraform"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
# Allow deploy.sh to override the inventory path for per-environment runs.
INVENTORY_JSON="${INVENTORY_JSON:-${ANSIBLE_DIR}/inventory/terraform-outputs.json}"
INVENTORY_SCRIPT="${ANSIBLE_DIR}/inventory/tfgrid.py"

SCOPE="${1:---scope}"
[[ "${SCOPE}" == "--scope" ]] && shift && SCOPE="${1:-all}"

# Keep output readable in terminals without leaking raw escape sequences into logs.
COLOR_RESET=''
COLOR_BOLD=''
COLOR_GREEN=''
COLOR_BLUE=''
COLOR_YELLOW=''
COLOR_CYAN=''

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  COLOR_RESET='\033[0m'
  COLOR_BOLD='\033[1m'
  COLOR_GREEN='\033[0;32m'
  COLOR_BLUE='\033[0;34m'
  COLOR_YELLOW='\033[1;33m'
  COLOR_CYAN='\033[0;36m'
fi

SUMMARY_WIDTH=79
if command -v tput >/dev/null 2>&1; then
  _cols="$(tput cols 2>/dev/null || true)"
  if [[ "${_cols}" =~ ^[0-9]+$ ]] && [[ "${_cols}" -ge 60 ]]; then
    SUMMARY_WIDTH="${_cols}"
  fi
fi

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  while [[ "${count}" -gt 0 ]]; do
    out+="${char}"
    count=$((count - 1))
  done
  printf '%s' "${out}"
}

wrap_text() {
  local text="$1"
  local width="$2"
  python3 - <<PYTHON 2>/dev/null || printf '%s\n' "${text}"
import textwrap

text = ${text@Q}
width = int(${width@Q})
if width < 20:
    width = 20

for line in text.splitlines() or [""]:
    if not line:
        print("")
        continue
    wrapped = textwrap.wrap(
        line,
        width=width,
        break_long_words=True,
        break_on_hyphens=False,
    )
    if wrapped:
        for item in wrapped:
            print(item)
    else:
        print("")
PYTHON
}

print_section() {
  echo ""
  echo -e "${COLOR_BOLD}${COLOR_BLUE}▶ $1${COLOR_RESET}"
  echo -e "${COLOR_BLUE}$(repeat_char '─' "${SUMMARY_WIDTH}")${COLOR_RESET}"
}

print_subsection() {
  echo ""
  echo -e "${COLOR_CYAN}• $1${COLOR_RESET}"
}

print_value() {
  local label="$1"
  local value="$2"
  local label_col=30
  local content_width=$((SUMMARY_WIDTH - label_col - 4))
  if [[ "${content_width}" -lt 20 ]]; then
    content_width=20
  fi

  local first=1
  while IFS= read -r line; do
    if [[ ${first} -eq 1 ]]; then
      printf "  %-${label_col}s %s\n" "${label}:" "${line}"
      first=0
    else
      printf "  %-${label_col}s %s\n" "" "${line}"
    fi
  done < <(wrap_text "${value}" "${content_width}")
}

print_instruction() {
  local text="$1"
  local prefix="  ${COLOR_GREEN}□${COLOR_RESET} "
  local indent="    "
  local content_width=$((SUMMARY_WIDTH - 4))
  if [[ "${content_width}" -lt 20 ]]; then
    content_width=20
  fi

  local first=1
  while IFS= read -r line; do
    if [[ ${first} -eq 1 ]]; then
      echo -e "${prefix}${line}"
      first=0
    else
      echo "${indent}${line}"
    fi
  done < <(wrap_text "${text}" "${content_width}")
}

# Like print_instruction but wraps shell commands with backslash continuation
# so that copied multi-line output can be pasted directly into a terminal.
# Uses break_long_words=False so long tokens (e.g. auth keys) are never split.
print_command() {
  local text="$1"
  local prefix="  ${COLOR_GREEN}□${COLOR_RESET} "
  local indent="      "
  local content_width=$((SUMMARY_WIDTH - 4))
  if [[ "${content_width}" -lt 20 ]]; then
    content_width=20
  fi

  local -a lines=()
  while IFS= read -r line; do
    lines+=("${line}")
  done < <(python3 - <<PYTHON 2>/dev/null || printf '%s\n' "${text}"
import textwrap
text = ${text@Q}
width = int(${content_width@Q})
if width < 20:
    width = 20
for line in text.splitlines() or [""]:
    if not line:
        print("")
        continue
    wrapped = textwrap.wrap(
        line,
        width=width,
        break_long_words=False,
        break_on_hyphens=False,
    )
    if wrapped:
        for item in wrapped:
            print(item)
    else:
        print("")
PYTHON
)

  local total=${#lines[@]}
  local i=0
  for line in "${lines[@]}"; do
    if [[ ${i} -eq 0 ]]; then
      if [[ $((i + 1)) -lt ${total} ]]; then
        echo -e "${prefix}${line} \\"
      else
        echo -e "${prefix}${line}"
      fi
    else
      if [[ $((i + 1)) -lt ${total} ]]; then
        echo "${indent}${line} \\"
      else
        echo "${indent}${line}"
      fi
    fi
    i=$((i + 1))
  done
}

inventory_dir() {
  dirname "${INVENTORY_JSON}"
}

recovery_dir() {
  if [[ -n "${INVENTORY_JSON:-}" ]]; then
    dirname "$(dirname "${INVENTORY_JSON}")"
    return 0
  fi
  return 1
}

environment_name() {
  local env_dir=""
  env_dir="$(recovery_dir 2>/dev/null || true)"
  [[ -n "${env_dir}" ]] || return 1
  basename "${env_dir}"
}

read_recovery_status_field() {
  local field_path="$1"
  local base_dir=""
  base_dir="$(recovery_dir 2>/dev/null || true)"
  [[ -n "${base_dir}" ]] || { echo ""; return 0; }
  local status_file="${base_dir}/.recovery/status.json"
  [[ -f "${status_file}" ]] || { echo ""; return 0; }

  python3 - <<PYTHON 2>/dev/null || true
import json

status_file = ${status_file@Q}
field_path = ${field_path@Q}

with open(status_file, 'r', encoding='utf-8') as handle:
    data = json.load(handle)

value = data
for part in field_path.split('.'):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break

if value is None:
    raise SystemExit(0)
if isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
else:
    print(value)
PYTHON
}

read_recovery_line() {
  local base_dir=""
  base_dir="$(recovery_dir 2>/dev/null || true)"
  [[ -n "${base_dir}" ]] || { echo ""; return 0; }
  local line_file="${base_dir}/.recovery/latest-recovery-line"
  [[ -f "${line_file}" ]] || { echo ""; return 0; }
  head -n1 "${line_file}" 2>/dev/null || true
}

# Read a single value from env-specific group_vars (all.yml or all/main.yml).
get_env_group_var() {
  local key="$1"
  local env_gv_dir=""
  if [[ -n "${INVENTORY_JSON:-}" ]]; then
    env_gv_dir="$(dirname "$(dirname "${INVENTORY_JSON}")")/group_vars"
  fi
  [[ -z "${env_gv_dir}" ]] && { echo ""; return 0; }
  python3 - <<PYTHON 2>/dev/null || true
import os, re
gv_dir = '${env_gv_dir}'
key = '${key}'
for fname in ['all.yml', 'all/main.yml']:
    fpath = os.path.join(gv_dir, fname)
    if os.path.isfile(fpath):
        content = open(fpath).read()
        m = re.search(r'^' + re.escape(key) + r':\s*"?([^"\s#\n]+)"?', content, re.M)
        if m:
            print(m.group(1).strip('"').strip("'"))
            break
PYTHON
}

# Read the Headplane API key saved by the headscale Ansible role.
get_headplane_api_key() {
  # In sanitized mode, emit a pointer to the file instead of the key itself.
  if [[ "${SUMMARY_SANITIZE:-0}" == "1" ]]; then
    echo "(see inventory/headplane-api-key.txt)"
    return 0
  fi
  local key_file=""
  # Prefer env-specific inventory dir when INVENTORY_JSON is set.
  if [[ -n "${INVENTORY_JSON:-}" ]]; then
    local inv_dir; inv_dir="$(dirname "${INVENTORY_JSON}")"
    [[ -f "${inv_dir}/headplane-api-key.txt" ]] && key_file="${inv_dir}/headplane-api-key.txt"
  fi
  [[ -z "${key_file}" && -f "${ANSIBLE_DIR}/inventory/headplane-api-key.txt" ]] && \
    key_file="${ANSIBLE_DIR}/inventory/headplane-api-key.txt"
  [[ -n "${key_file}" ]] && cat "${key_file}" | tr -d '[:space:]' || true
}

# Get the preauth key for --auth-key from headscale-authkeys.json.
# Returns the client key (no tags, for laptops/workstations), NOT the server-tagged key.
get_preauth_key() {
  # In sanitized mode, emit a pointer to the file instead of the key itself.
  if [[ "${SUMMARY_SANITIZE:-0}" == "1" ]]; then
    echo "(see inventory/headscale-authkeys.json)"
    return 0
  fi
  local auth_file=""
  if [[ -n "${INVENTORY_JSON:-}" ]]; then
    local inv_dir; inv_dir="$(dirname "${INVENTORY_JSON}")"
    [[ -f "${inv_dir}/headscale-authkeys.json" ]] && auth_file="${inv_dir}/headscale-authkeys.json"
  fi
  [[ -z "${auth_file}" && -f "${ANSIBLE_DIR}/inventory/headscale-authkeys.json" ]] && \
    auth_file="${ANSIBLE_DIR}/inventory/headscale-authkeys.json"
  if [[ -n "${auth_file}" ]]; then
    python3 -c "
import json
try:
    d = json.load(open('${auth_file}'))
    # Prefer the client key (no tags). Fall back to servers key only if client absent.
    keys = d.get('authkeys', {})
    print(keys.get('client') or keys.get('servers', ''))
except: pass
" 2>/dev/null || true
  fi
}

# Derive the tailscale node name from an inventory hostname.
ts_node_name() {
  echo "$1"
}

read_json_field() {
  local json_path="$1"
  local field_path="$2"
  
  if [[ ! -f "${json_path}" ]]; then
    echo ""
    return 1
  fi

  python3 - <<PYTHON 2>/dev/null || echo ""
import json
import sys

try:
    with open('${json_path}', 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    parts = '${field_path}'.split('.')
    value = data
    for part in parts:
        if isinstance(value, dict):
            value = value.get(part)
        else:
            value = None
            break
    
    if value is not None:
        if isinstance(value, list):
            print(value[0] if value else '')
        else:
            print(str(value))
except:
    pass
PYTHON
}

get_terraform_output() {
  local output_name="$1"
  local json_file="${INVENTORY_JSON:-${ANSIBLE_DIR}/inventory/terraform-outputs.json}"

  if [[ ! -f "${json_file}" ]]; then
    return 1
  fi

  python3 - <<PYTHON 2>/dev/null || true
import json
try:
    with open('${json_file}', 'r', encoding='utf-8') as f:
        data = json.load(f)
    key = '${output_name}'
    entry = data.get(key)
    if isinstance(entry, dict):
        print(str(entry.get('value', '')))
    elif entry is not None:
        print(str(entry))
except:
    pass
PYTHON
}

get_ansible_hosts() {
  local group="$1"
  
  if [[ ! -f "${INVENTORY_JSON}" ]] || [[ ! -x "${INVENTORY_SCRIPT}" ]]; then
    return 1
  fi

  python3 - <<PYTHON 2>/dev/null || true
import json
import sys

try:
    with open('${INVENTORY_JSON}', 'r', encoding='utf-8') as f:
        tf_outputs = json.load(f)
    
    # Parse the dynamic inventory from tfgrid.py structure
    # Groups: control, gateway, monitoring/workloads
    result = []
    
    if '${group}' == 'control':
        if 'core_vm_ip' in tf_outputs:
            result.append(('control-vm', str(tf_outputs['core_vm_ip'])))
    elif '${group}' == 'gateway':
        if 'gateway_vm_ip' in tf_outputs:
            result.append(('gateway-vm', str(tf_outputs['gateway_vm_ip'])))
    elif '${group}' == 'monitoring':
        if 'monitoring_vm_ip' in tf_outputs:
            result.append(('monitoring-vm', str(tf_outputs['monitoring_vm_ip'])))
    
    for name, ip in result:
        print(f"{name} => {ip}")
except:
    pass
PYTHON
}

get_tailscale_ips() {
  local ts_ips_file="$(inventory_dir)/tailscale-ips.json"
  
  if [[ ! -f "${ts_ips_file}" ]]; then
    return 1
  fi
  
  python3 - <<PYTHON 2>/dev/null || true
import json

try:
    with open('${ts_ips_file}', 'r', encoding='utf-8') as f:
        data = json.load(f)
    for hostname, ip in sorted(data.items()):
        print(f"{hostname} => {ip}")
except:
    pass
PYTHON
}

read_gateway_wildcard_status_field() {
  local field_path="$1"
  local status_file="$(inventory_dir)/gateway-wildcard-status.json"

  if [[ ! -f "${status_file}" ]]; then
  echo ""
  return 0
  fi

  python3 - <<PYTHON 2>/dev/null || true
import json

status_file = ${status_file@Q}
field_path = ${field_path@Q}

with open(status_file, 'r', encoding='utf-8') as handle:
  data = json.load(handle)

value = data
for part in field_path.split('.'):
  if not part:
    continue
  if isinstance(value, dict):
    value = value.get(part)
  else:
    value = None
    break

if value is None:
  raise SystemExit(0)
if isinstance(value, bool):
  print('true' if value else 'false')
elif isinstance(value, (dict, list)):
  print(json.dumps(value, sort_keys=True))
else:
  print(value)
PYTHON
}

print_infrastructure() {
  print_section "Infrastructure Overview"

  local control_pub; control_pub="$(get_terraform_output control_public_ip)"
  local gateway_pub; gateway_pub="$(get_terraform_output gateway_public_ip)"
  local control_priv; control_priv="$(get_terraform_output control_private_ip)"
  local gateway_priv; gateway_priv="$(get_terraform_output gateway_private_ip)"
  local monitoring_ts=""

  if [[ -f "$(inventory_dir)/tailscale-ips.json" ]]; then
    monitoring_ts=$(python3 -c "
import json
try:
    d=json.load(open('$(inventory_dir)/tailscale-ips.json'))
    print(d.get('monitoring-vm',''))
except: pass
" 2>/dev/null || true)
  fi

  if [[ -n "${control_pub}" ]]; then
    print_subsection "Control (Headscale + tailnet coordination)"
    print_value "Public IP" "${control_pub}"
    [[ -n "${control_priv}" ]] && print_value "Private IP" "${control_priv}"
  fi

  if [[ -n "${gateway_pub}" ]]; then
    print_subsection "Gateway (Reverse Proxy)"
    print_value "Public IP" "${gateway_pub}"
    [[ -n "${gateway_priv}" ]] && print_value "Private IP" "${gateway_priv}"
  fi

  print_subsection "Monitoring (tailnet-only)"
  if [[ -n "${monitoring_ts}" ]]; then
    print_value "Tailscale IP" "${monitoring_ts}"
  else
    print_value "Host" "monitoring-vm"
  fi
  print_value "Access" "Requires Tailscale (services not publicly exposed)"
}

print_services() {
  print_section "Services & Access"

  local control_pub; control_pub="$(get_terraform_output control_public_ip)"
  local control_ts=""
  local monitoring_ts=""

  if [[ -f "$(inventory_dir)/tailscale-ips.json" ]]; then
    control_ts=$(python3 -c "
import json
try:
    d=json.load(open('$(inventory_dir)/tailscale-ips.json'))
    print(d.get('control-vm',''))
except: pass
" 2>/dev/null || true)
    monitoring_ts=$(python3 -c "
import json
try:
    d=json.load(open('$(inventory_dir)/tailscale-ips.json'))
    print(d.get('monitoring-vm',''))
except: pass
" 2>/dev/null || true)
  fi

  # Derive headscale URL and MagicDNS base domain from env-specific group_vars.
  local base_domain; base_domain="$(get_env_group_var base_domain)"
  local headscale_sub; headscale_sub="$(get_env_group_var headscale_subdomain)"
  local magic_dns_base; magic_dns_base="$(get_env_group_var headscale_magic_dns_base_domain)"
  local public_tls_mode; public_tls_mode="$(get_env_group_var public_service_tls_mode)"
  local internal_tls_mode; internal_tls_mode="$(get_env_group_var internal_service_tls_mode)"
  local backup_enabled; backup_enabled="$(get_env_group_var backup_enabled)"
  local public_wildcard_active=""; public_wildcard_active="$(read_gateway_wildcard_status_field public_active)"
  local internal_wildcard_active=""; internal_wildcard_active="$(read_gateway_wildcard_status_field internal_active)"
  local internal_https_blocked="false"
  [[ -z "${headscale_sub}" ]] && headscale_sub="headscale"
  [[ -z "${public_tls_mode}" ]] && public_tls_mode="letsencrypt"
  [[ -z "${internal_tls_mode}" ]] && internal_tls_mode="internal"

  if [[ "${internal_tls_mode}" == "namecheap" && -n "${magic_dns_base}" && "${internal_wildcard_active}" != "true" ]]; then
    internal_https_blocked="true"
  fi

  local headscale_url=""
  if [[ -n "${base_domain}" ]]; then
    headscale_url="https://${headscale_sub}.${base_domain}"
  elif [[ -n "${control_pub}" ]]; then
    headscale_url="https://${control_pub}.sslip.io"
  fi

  local headplane_url=""
  if [[ -n "${magic_dns_base}" ]]; then
    headplane_url="http://control-vm.${magic_dns_base}:3000"
  elif [[ -n "${control_ts}" ]]; then
    headplane_url="http://${control_ts}:3000"
  fi

  # Derive internal DNS URL for monitoring node.
  local monitoring_dns_url=""
  if [[ -n "${magic_dns_base}" ]]; then
    monitoring_dns_url="monitoring-vm.${magic_dns_base}"
  fi

  print_subsection "Headscale (Self-hosted Tailscale coordination)"
  if [[ -n "${headscale_url}" ]]; then
    print_value "Public URL" "${headscale_url}"
    print_value "Login server flag" "--login-server ${headscale_url}"
    print_value "DERP relay" "Standard fallback enabled at ${headscale_url}/derp (embedded on control VM)"
    if [[ "${headscale_url}" == *"sslip.io"* ]]; then
      print_instruction "For long-term use, replace the sslip.io fallback with a real DNS hostname for Headscale and browser-trusted TLS"
    fi
  fi
  if [[ "${backup_enabled}" == "true" ]]; then
    print_value "Backup scope" "Headscale database and keys, ACL/config, TLS state, and Headplane config are included in the control-plane backup"
  fi

  print_subsection "Headplane (Admin UI)"
  if [[ -n "${headplane_url}" ]]; then
    print_value "URL" "${headplane_url}"
    print_value "Access" "Tailnet-only"
  else
    print_instruction "Headplane is tailnet-only; connect from a tailnet device to control-vm on port 3000"
  fi
  local api_key; api_key="$(get_headplane_api_key)"
  if [[ -n "${api_key}" ]]; then
    print_value "API Key" "${api_key}"
  else
    print_instruction "API key not found — check environments/<env>/inventory/headplane-api-key.txt"
  fi

  if [[ "${internal_https_blocked}" == "true" ]]; then
    local gateway_pub=""; gateway_pub="$(get_terraform_output gateway_public_ip)"
    print_subsection "Internal Monitoring HTTPS Status"
    print_instruction "Action required before opening grafana/prometheus/backrest internal URLs"
    print_instruction "Wildcard TLS for *.${magic_dns_base} is not active yet, so those HTTPS endpoints will fail"
    if [[ -n "${gateway_pub}" ]]; then
      print_instruction "Allowlist gateway public IP in Namecheap API access: ${gateway_pub}"
    fi
    print_instruction "Then rerun: ./scripts/deploy.sh gateway --env <env>"
  fi

  print_subsection "Grafana Dashboards (tailnet only)"
  if [[ "${internal_https_blocked}" == "true" ]]; then
    print_value "URL" "BLOCKED until wildcard TLS is active"
  elif [[ -n "${monitoring_dns_url}" ]]; then
    print_value "URL" "https://grafana.${magic_dns_base}"
    print_value "Alt URL (by node)" "http://${monitoring_dns_url}:3000"
  elif [[ -n "${monitoring_ts}" ]]; then
    print_value "URL (tailscale IP)" "http://${monitoring_ts}:3000"
  fi
  local svc_pass="${SERVICES_ADMIN_PASSWORD:-change-me}"
  print_value "Default creds" "admin / ${svc_pass}  (change on first login)"
  print_value "Dashboards" "Infrastructure Health, Service Health, Logs Overview, Backup Overview"
  print_value "Access" "Tailscale-connected devices only"

  print_subsection "Prometheus Metrics (tailnet only)"
  if [[ "${internal_https_blocked}" == "true" ]]; then
    print_value "URL" "BLOCKED until wildcard TLS is active"
  elif [[ -n "${monitoring_dns_url}" ]]; then
    print_value "URL" "https://prometheus.${magic_dns_base}"
    print_value "Alt URL (by node)" "http://${monitoring_dns_url}:9090"
  elif [[ -n "${monitoring_ts}" ]]; then
    print_value "URL (tailscale IP)" "http://${monitoring_ts}:9090"
  fi
  print_value "Access" "Tailscale-connected devices only"

  print_subsection "Backrest UI (tailnet only)"
  if [[ "${internal_https_blocked}" == "true" ]]; then
    print_value "URL" "BLOCKED until wildcard TLS is active"
  elif [[ -n "${monitoring_dns_url}" ]]; then
    print_value "URL" "https://backrest.${magic_dns_base}"
    print_value "Alt URL (by node)" "http://${monitoring_dns_url}:9898"
  elif [[ -n "${monitoring_ts}" ]]; then
    print_value "URL (tailscale IP)" "http://${monitoring_ts}:9898"
  fi
  print_value "Access" "Tailscale-connected devices only"

  if [[ "${public_tls_mode}" == "namecheap" && -n "${base_domain}" ]]; then
    local gateway_pub=""; gateway_pub="$(get_terraform_output gateway_public_ip)"
    print_subsection "HTTPS Public Wildcard TLS"
    print_instruction "Public gateway services use one wildcard certificate for *.${base_domain}"
    if [[ "${public_wildcard_active}" == "true" ]]; then
      print_instruction "Wildcard TLS for public gateway services is active from the current deploy"
    else
      print_instruction "If the gateway public IP was not allowlisted in Namecheap before this deploy started, add it and rerun ./scripts/deploy.sh gateway --env <env>"
      if [[ -n "${gateway_pub}" ]]; then
        print_instruction "Namecheap API allowlist must include the gateway public IP: ${gateway_pub}"
      fi
    fi
  fi

  if [[ -n "${magic_dns_base}" ]]; then
    if [[ "${internal_tls_mode}" == "namecheap" ]]; then
      local gateway_pub=""; gateway_pub="$(get_terraform_output gateway_public_ip)"
      print_subsection "HTTPS Internal Wildcard TLS"
      print_instruction "Service subdomain URLs use the gateway wildcard certificate for *.${magic_dns_base}"
      if [[ "${internal_wildcard_active}" == "true" ]]; then
        print_instruction "Wildcard TLS for internal service aliases is active from the current deploy"
      else
        print_instruction "If the gateway public IP was not allowlisted in Namecheap before this deploy started, add it and rerun ./scripts/deploy.sh gateway --env <env>"
        if [[ -n "${gateway_pub}" ]]; then
          print_instruction "Namecheap API allowlist must include the gateway public IP: ${gateway_pub}"
        fi
        print_instruction "This follow-up gateway run is only needed when the current deploy could not activate wildcard TLS"
      fi
    else
      print_subsection "HTTPS Internal CA"
      print_instruction "Service subdomain URLs use a self-signed internal CA (Caddy PKI)"
      print_instruction "Root cert:  ssh root@monitoring-vm cat /opt/monitoring-caddy/ca.crt > ca.crt"
      print_instruction "macOS:      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt"
      print_instruction "Linux:      sudo cp ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates"
      print_instruction "Windows:    certmgr.msc → Trusted Root CAs → Import ca.crt"
      print_instruction "Or just accept the browser warning (connection is still encrypted)"
    fi
  fi
}

print_tailnet() {
  print_section "Tailnet Status"

  if [[ ! -f "$(inventory_dir)/tailscale-ips.json" ]]; then
    echo "  ${COLOR_YELLOW}⊗ No Tailscale IPs recorded yet (Ansible has not run yet)${COLOR_RESET}"
    return 0
  fi

  local magic_dns_base; magic_dns_base="$(get_env_group_var headscale_magic_dns_base_domain)"

  print_subsection "Registered Nodes"
  if [[ -n "${magic_dns_base}" ]]; then
    printf "  %-24s %-18s %s\n" "Node" "Tailscale IP" "Internal DNS (MagicDNS)"
    printf "  %-24s %-18s %s\n" "----" "------------" "-----------------------"
  fi

  local ts_ips
  ts_ips=$(get_tailscale_ips) || true

  if [[ -z "${ts_ips}" ]]; then
    echo "  ${COLOR_YELLOW}⊗ No Tailscale nodes found${COLOR_RESET}"
    return 0
  fi

  echo "${ts_ips}" | while read -r line; do
    if [[ -n "${line}" ]]; then
      local inv_name; inv_name="$(echo "$line" | cut -d' ' -f1)"
      local ts_ip; ts_ip="$(echo "$line" | cut -d' ' -f3)"
      local node_name; node_name="$(ts_node_name "${inv_name}")"
      if [[ -n "${magic_dns_base}" ]]; then
        printf "  %-24s %-18s %s\n" "${node_name}" "${ts_ip}" "${node_name}.${magic_dns_base}"
      else
        printf "  %-24s %s\n" "${node_name}" "${ts_ip}"
      fi
    fi
  done

  if [[ -n "${magic_dns_base}" ]]; then
    echo ""
    print_instruction "MagicDNS is active — use hostnames above from any tailnet-connected device"
  fi
}

print_next_steps() {
  print_section "Connecting to the Tailnet"

  local control_pub; control_pub="$(get_terraform_output control_public_ip)"
  local control_ts=""

  if [[ -f "$(inventory_dir)/tailscale-ips.json" ]]; then
    control_ts=$(python3 -c "
import json
try:
    d=json.load(open('$(inventory_dir)/tailscale-ips.json'))
    print(d.get('control-vm',''))
except: pass
" 2>/dev/null || true)
  fi

  local base_domain; base_domain="$(get_env_group_var base_domain)"
  local headscale_sub; headscale_sub="$(get_env_group_var headscale_subdomain)"
  local magic_dns_base; magic_dns_base="$(get_env_group_var headscale_magic_dns_base_domain)"
  [[ -z "${headscale_sub}" ]] && headscale_sub="headscale"

  local headscale_url=""
  if [[ -n "${base_domain}" ]]; then
    headscale_url="https://${headscale_sub}.${base_domain}"
  elif [[ -n "${control_pub}" ]]; then
    headscale_url="https://${control_pub}.sslip.io"
  fi
  local fresh_tailnet="${DEPLOY_FRESH_TAILNET:-0}"
  local env_name=""
  env_name="$(environment_name 2>/dev/null || true)"

  # Preauth key for device auto-join.
  local auth_key; auth_key="$(get_preauth_key)"

  # SSH target: prefer MagicDNS name, fall back to tailscale IP.
  local ssh_target=""
  local headplane_url=""
  if [[ -n "${magic_dns_base}" ]]; then
    headplane_url="http://control-vm.${magic_dns_base}:3000"
  elif [[ -n "${control_ts}" ]]; then
    headplane_url="http://${control_ts}:3000"
  fi

  if [[ -n "${magic_dns_base}" ]]; then
    ssh_target="control-vm.${magic_dns_base}"
  elif [[ -n "${control_ts}" ]]; then
    ssh_target="${control_ts}"
  fi

  print_subsection "Step 1: Install Tailscale on your device"
  print_instruction "Download: https://tailscale.com/download"

  if [[ "${fresh_tailnet}" == "1" ]]; then
    print_subsection "Step 2: Reset stale client state before rejoining"
    print_instruction "Because this deploy used --fresh-tailnet, previously joined clients must reset their local Tailscale session first"
    print_instruction "tailscale down"
    if [[ -n "${env_name}" ]]; then
      print_instruction "Preferred: ./scripts/deploy.sh join-local --env ${env_name} --rejoin-local"
    else
      print_instruction "Preferred: ./scripts/deploy.sh join-local --env <env> --rejoin-local"
    fi
    print_instruction "Manual fallback if the helper is unavailable:"
    print_instruction "Set a safe lowercase hostname first: SAFE_HOSTNAME=testmac"
    print_instruction "tailscale logout"
    if [[ -n "${headscale_url}" && -n "${auth_key}" ]]; then
      print_command "tailscale up --login-server ${headscale_url} --auth-key ${auth_key} --accept-routes --reset --force-reauth --hostname \${SAFE_HOSTNAME}"
    elif [[ -n "${headscale_url}" ]]; then
      print_command "tailscale up --login-server ${headscale_url} --accept-routes --reset --force-reauth --hostname \${SAFE_HOSTNAME}"
    else
      print_instruction "Headscale URL not found — check environments/<env>/group_vars/all.yml"
    fi
    print_instruction "Verify: tailscale status"
    print_instruction "Verify resolver: dig @100.100.100.100 +short grafana.${magic_dns_base:-<magic-dns-base>}"
    print_instruction "If normal hostname lookups are still stale after reconnect, flush the local DNS cache for your OS"
    print_instruction "macOS fallback: sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    print_instruction "Ubuntu/Debian fallback: sudo resolvectl flush-caches   # or: sudo systemd-resolve --flush-caches"
    print_instruction "Windows fallback (Admin PowerShell/cmd): ipconfig /flushdns"
    print_instruction "Mobile fallback: disconnect/reconnect Tailscale, then retry; if needed toggle airplane mode or restart the app"
  elif [[ -n "${headscale_url}" ]]; then
    print_subsection "Step 2: Join the tailnet"
    if [[ -n "${auth_key}" ]]; then
      print_command "tailscale up --login-server ${headscale_url} --auth-key ${auth_key} --accept-routes --reset"
    else
      print_command "tailscale up --login-server ${headscale_url} --accept-routes --reset"
      if [[ -n "${headplane_url}" ]]; then
        print_instruction "Then authorize the node from an already tailnet-connected admin device in Headplane: ${headplane_url}"
      else
        print_instruction "Then authorize the node from an already tailnet-connected admin device or from control-vm over SSH"
      fi
    fi
    print_instruction "Verify: tailscale status"
  else
    print_subsection "Step 2: Join the tailnet"
    print_instruction "Headscale URL not found — check environments/<env>/group_vars/all.yml"
  fi

  print_subsection "Step 3: SSH to control VM"
  if [[ -n "${ssh_target}" ]]; then
    print_instruction "ssh root@${ssh_target}"
  else
    print_instruction "Tailscale IPs not yet available; re-run deployment or check inventory"
  fi

  print_subsection "Diagnostics"
  print_instruction "Smoke tests: PREFER_TAILSCALE=1 ./scripts/tests/run.sh bootstrap-smoke"
  print_instruction "Supported test suites: ./scripts/tests/run.sh --help"
  print_instruction "Relay check: curl -k -I ${headscale_url}/derp   # expect HTTP 426 without upgrade headers"
  if [[ "${fresh_tailnet}" == "1" && -n "${magic_dns_base}" ]]; then
    print_instruction "MagicDNS sanity: dig @100.100.100.100 +short grafana.${magic_dns_base}"
    print_instruction "Grafana sanity: curl -k --connect-timeout 8 https://grafana.${magic_dns_base}"
  fi
}

print_configuration() {
  print_section "Reference"

  local env_dir=""
  if [[ -n "${INVENTORY_JSON:-}" ]]; then
    env_dir="$(dirname "$(dirname "${INVENTORY_JSON}")")" # environments/<env>/
  fi

  print_subsection "Environment Config"
  if [[ -n "${env_dir}" ]]; then
    print_instruction "Env settings: ${env_dir}/group_vars/all.yml"
    print_instruction "Secrets:      ${env_dir}/secrets.env  (never committed)"
  fi
  print_instruction "Apply config-only changes: ./scripts/deploy.sh control --env <env>  (or gateway|monitoring|all)"
  print_instruction "Full redeploy: ./scripts/deploy.sh full --env <env>"

  print_subsection "Docs"
  print_instruction "Operations runbook: docs/technical/OPERATIONS.md"
  print_instruction "Architecture:       docs/technical/ARCHITECTURE.md"
  print_instruction "Test scripts:       scripts/tests/"
}

print_warnings() {
  local has_warnings=0
  local public_tls_mode=""; public_tls_mode="$(get_env_group_var public_service_tls_mode)"
  local internal_tls_mode=""; internal_tls_mode="$(get_env_group_var internal_service_tls_mode)"
  local public_wildcard_active=""; public_wildcard_active="$(read_gateway_wildcard_status_field public_active)"
  local internal_wildcard_active=""; internal_wildcard_active="$(read_gateway_wildcard_status_field internal_active)"
  [[ -z "${public_tls_mode}" ]] && public_tls_mode="letsencrypt"
  
  # Check for common issues
  if [[ ! -f "${INVENTORY_JSON}" ]]; then
    has_warnings=1
  fi
  
  if [[ ! -f "$(inventory_dir)/tailscale-ips.json" ]]; then
    has_warnings=1
  fi

  if [[ "${public_tls_mode}" == "namecheap" && "${public_wildcard_active}" != "true" ]]; then
    has_warnings=1
  fi

  if [[ "${internal_tls_mode}" == "namecheap" && "${internal_wildcard_active}" != "true" ]]; then
    has_warnings=1
  fi
  
  if [[ ${has_warnings} -eq 1 ]]; then
    echo ""
    echo -e "${COLOR_YELLOW}${COLOR_BOLD}⚠ Deployment Status Notes${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}$(repeat_char '─' "${SUMMARY_WIDTH}")${COLOR_RESET}"
    
    if [[ ! -f "${INVENTORY_JSON}" ]]; then
      echo -e "  ${COLOR_YELLOW}⊗ No Terraform outputs found yet${COLOR_RESET}"
      echo "    Try: terraform -chdir=terraform output -json > ansible/inventory/terraform-outputs.json"
    fi
    
    if [[ ! -f "$(inventory_dir)/tailscale-ips.json" ]]; then
      echo -e "  ${COLOR_YELLOW}⊗ Tailscale IPs not yet recorded${COLOR_RESET}"
      echo "    Run: ./scripts/deploy.sh full (or control/gateway/etc)"
      echo "    Or manually: ansible-playbook -i inventory/tfgrid.py playbooks/site.yml"
    fi

    if [[ "${internal_tls_mode}" == "namecheap" && "${internal_wildcard_active}" != "true" ]]; then
      local gateway_pub=""; gateway_pub="$(get_terraform_output gateway_public_ip)"
      echo -e "  ${COLOR_YELLOW}${COLOR_BOLD}ACTION REQUIRED:${COLOR_RESET} Internal HTTPS aliases are blocked until wildcard TLS activates"
      if [[ -n "${gateway_pub}" ]]; then
        echo "    Do not use grafana/prometheus/backrest internal HTTPS URLs yet (they will fail TLS handshake)"
        echo "    Allowlist this gateway public IP in Namecheap API access now: ${gateway_pub}"
        echo "    Then rerun gateway converge: ./scripts/deploy.sh gateway --env <env>"
        echo "    If that IP was already allowlisted before the deploy started, inspect gateway Caddy / Namecheap DNS-01 logs instead of assuming a second pass is required"
      else
        echo "    Add the current gateway public IP to the Namecheap API allowlist before expecting wildcard issuance or renewal to work"
      fi
      echo "    This follow-up run is only needed when the current deploy did not activate wildcard TLS"
    fi

    if [[ "${public_tls_mode}" == "namecheap" && "${public_wildcard_active}" != "true" ]]; then
      local gateway_pub=""; gateway_pub="$(get_terraform_output gateway_public_ip)"
      echo -e "  ${COLOR_YELLOW}${COLOR_BOLD}IMPORTANT:${COLOR_RESET} Namecheap wildcard TLS is enabled for public gateway services"
      if [[ -n "${gateway_pub}" ]]; then
        echo "    Wildcard TLS for public gateway services is not active yet in the current deploy"
        echo "    If the gateway public IP was not already allowlisted in Namecheap, add it now: ${gateway_pub}"
        echo "    Then rerun gateway converge: ./scripts/deploy.sh gateway --env <env>"
        echo "    If that IP was already allowlisted before the deploy started, inspect gateway Caddy / Namecheap DNS-01 logs instead of assuming a second pass is required"
      else
        echo "    Add the current gateway public IP to the Namecheap API allowlist before expecting wildcard issuance or renewal to work"
      fi
      echo "    This follow-up run is only needed when the current deploy did not activate wildcard TLS"
    fi
  fi
}

print_backup_status() {
  print_section "Backup Status"

  # Check if backup is enabled — env-specific group_vars take precedence over base defaults.
  # INVENTORY_JSON is environments/<env>/inventory/terraform-outputs.json, so the env
  # group_vars dir is two levels up from the inventory dir.
  local backup_enabled=""
  if [[ -f "${ANSIBLE_DIR}/group_vars/all/main.yml" ]]; then
    backup_enabled="$(grep -oP 'backup_enabled:\s*\K\S+' "${ANSIBLE_DIR}/group_vars/all/main.yml" 2>/dev/null || true)"
  fi
  # Override with env-specific value if present (mirrors Ansible variable precedence).
  if [[ -n "${INVENTORY_JSON:-}" ]]; then
    local env_gv_dir
    env_gv_dir="$(dirname "$(dirname "${INVENTORY_JSON}")")/group_vars"
    local env_gv_all
    for env_gv_all in "${env_gv_dir}/all.yml" "${env_gv_dir}/all/main.yml"; do
      if [[ -f "${env_gv_all}" ]]; then
        local _env_val
        _env_val="$(grep -oP 'backup_enabled:\s*\K\S+' "${env_gv_all}" 2>/dev/null | head -1 || true)"
        [[ -n "${_env_val}" ]] && backup_enabled="${_env_val}"
      fi
    done
  fi

  if [[ "${backup_enabled}" == "true" ]]; then
    local monitoring_ts=""
    if [[ -f "$(inventory_dir)/tailscale-ips.json" ]]; then
      monitoring_ts=$(python3 -c "
import json
try:
    d=json.load(open('$(inventory_dir)/tailscale-ips.json'))
    print(d.get('monitoring-vm',''))
except: pass
" 2>/dev/null || true)
    fi
    local magic_dns_base; magic_dns_base="$(get_env_group_var headscale_magic_dns_base_domain)"
    local backrest_host="${monitoring_ts}"
    [[ -n "${magic_dns_base}" ]] && backrest_host="backrest.${magic_dns_base}"

    print_subsection "Backup System: ENABLED"
    if [[ -n "${backrest_host}" ]]; then
      print_instruction "Backrest UI:      http://${backrest_host}"
      local grafana_host="${monitoring_ts}"
      [[ -n "${magic_dns_base}" ]] && grafana_host="grafana.${magic_dns_base}"
      [[ -n "${grafana_host}" ]] && print_instruction "Grafana overview: http://${grafana_host} → Backup dashboard"
    fi
    print_instruction "Check backup schedules: crontab -l | grep backup  (on any VM)"
    print_instruction "Run verification: ./scripts/tests/run.sh backup-verify"
  else
    print_subsection "Backup System: DISABLED"
    print_instruction "Enable: set backup_enabled=true in group_vars and export RESTIC_PASSWORD"
    print_instruction "See: docs/technical/BACKUP.md for setup instructions"
  fi

  if [[ -n "${monitoring_ts:-}" ]]; then
    print_subsection "Service Observability"
    print_instruction "Grafana logs:      http://${monitoring_ts}:3000/explore"
    print_instruction "Grafana dashboards: Infrastructure Health / Service Health / Logs Overview"
    print_instruction "Run verification: ./scripts/tests/run.sh tailnet-management"
  fi
}

print_recovery_status() {
  print_section "Portable Recovery"

  local recovery_status=""; recovery_status="$(read_recovery_status_field status)"
  local created_at=""; created_at="$(read_recovery_status_field created_at_utc)"
  local message=""; message="$(read_recovery_status_field message)"
  local primary_status=""; primary_status="$(read_recovery_status_field primary.status)"
  local secondary_status=""; secondary_status="$(read_recovery_status_field secondary.status)"
  local recovery_line=""; recovery_line="$(read_recovery_line)"
  local base_dir=""; base_dir="$(recovery_dir 2>/dev/null || true)"

  if [[ -z "${recovery_status}" ]]; then
    print_subsection "Recovery Bundle: NOT YET GENERATED"
    print_instruction "Run ./scripts/deploy.sh full --env <env> after backup storage is configured"
    return 0
  fi

  case "${recovery_status}" in
    refreshed)
      print_subsection "Recovery Bundle: REFRESHED"
      ;;
    degraded)
      print_subsection "Recovery Bundle: DEGRADED"
      ;;
    failed)
      print_subsection "Recovery Bundle: FAILED"
      ;;
    skipped)
      print_subsection "Recovery Bundle: NOT CONFIGURED"
      ;;
    *)
      print_subsection "Recovery Bundle: ${recovery_status}"
      ;;
  esac

  [[ -n "${created_at}" ]] && print_value "Created" "${created_at}"
  [[ -n "${primary_status}" ]] && print_value "Primary upload" "${primary_status}"
  [[ -n "${secondary_status}" ]] && print_value "Secondary upload" "${secondary_status}"
  [[ -n "${message}" ]] && print_value "Status detail" "${message}"

  if [[ "${SUMMARY_SANITIZE:-0}" == "1" ]]; then
    if [[ -n "${base_dir}" ]]; then
      print_value "Recovery line" "Stored locally at ${base_dir}/.recovery/latest-recovery-line"
    fi
  elif [[ -n "${recovery_line}" ]]; then
    echo ""
    echo "Break-glass recovery line:"
    while IFS= read -r line; do
      echo "  ${line}"
    done < <(wrap_text "${recovery_line}" "$((SUMMARY_WIDTH - 2))")
    print_instruction "Store this line offline. It can rebuild this environment from backup on a fresh macOS/Linux machine."
    print_instruction "Portable restore: ./scripts/restore.sh --recovery-line '<paste the break-glass recovery line above>'"
  fi

  if [[ "${recovery_status}" == "skipped" ]]; then
    print_instruction "Enable backup_enabled=true and define two backup_backends in environments/<env>/group_vars/all.yml"
  fi
}

main() {
  echo ""
  echo -e "${COLOR_BOLD}${COLOR_GREEN}$(repeat_char '═' "${SUMMARY_WIDTH}")${COLOR_RESET}"
  echo -e "${COLOR_BOLD}${COLOR_GREEN}DEPLOYMENT SUMMARY & NEXT STEPS${COLOR_RESET}"
  echo -e "${COLOR_BOLD}${COLOR_GREEN}$(repeat_char '═' "${SUMMARY_WIDTH}")${COLOR_RESET}"
  
  print_infrastructure
  print_services
  print_tailnet
  print_backup_status
  print_recovery_status
  print_next_steps
  print_configuration
  print_warnings
  
  echo ""
  echo -e "${COLOR_BOLD}${COLOR_GREEN}$(repeat_char '═' "${SUMMARY_WIDTH}")${COLOR_RESET}"
  echo ""
}

main "$@"
