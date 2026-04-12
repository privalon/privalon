#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# dns-setup.sh — Namecheap DNS A record automation
# ═══════════════════════════════════════════════════════════════════════
#
# Reads control/gateway public IPs from Terraform outputs and upserts
# DNS A records via the Namecheap API. Preserves all existing records.
#
# Called automatically by deploy.sh when NAMECHEAP_API_KEY is set.
# Can also be called standalone: ./scripts/deploy.sh dns --env prod
#
# Required env vars:
#   NAMECHEAP_API_USER        Namecheap account username
#   NAMECHEAP_API_KEY         Namecheap API key
#   TERRAFORM_OUTPUTS_JSON    Path to terraform-outputs.json
#   BASE_DOMAIN               Root domain (e.g. yourdomain.com)
#   HEADSCALE_SUBDOMAIN       Subdomain for control VM (default: headscale)
#
# Optional:
#   GATEWAY_SUBDOMAINS        Comma-separated list of gateway subdomains (e.g. "app,matrix")
#   DRY_RUN=1                 Print what would be done without making API calls
#   DNS_PROPAGATION_TIMEOUT   Seconds to wait for dig confirmation (default: 300)
#   DNS_PROPAGATION_POLL_INTERVAL  Seconds between propagation checks (default: 15)
#   DNS_REAPPLY_INTERVAL      Seconds between replaying merged Namecheap zone while auth DNS is stale (default: 60)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ───────────────────────────────────────────────────────────
HEADSCALE_SUBDOMAIN="${HEADSCALE_SUBDOMAIN:-headscale}"
DRY_RUN="${DRY_RUN:-0}"
DNS_PROPAGATION_TIMEOUT="${DNS_PROPAGATION_TIMEOUT:-300}"
DNS_PROPAGATION_POLL_INTERVAL="${DNS_PROPAGATION_POLL_INTERVAL:-15}"
DNS_REAPPLY_INTERVAL="${DNS_REAPPLY_INTERVAL:-60}"
NAMECHEAP_API_URL="https://api.namecheap.com/xml.response"

log()  { printf '[dns] %s\n' "$*" >&2; }
warn() { printf '[dns][WARN] %s\n' "$*" >&2; }
die()  { printf '[dns][FAIL] %s\n' "$*" >&2; exit 1; }

fqdn_for_subdomain() {
  local subdomain="$1"
  if [[ "${subdomain}" == "@" ]]; then
    printf '%s\n' "${BASE_DOMAIN}"
    return 0
  fi
  printf '%s.%s\n' "${subdomain}" "${BASE_DOMAIN}"
}

extract_namecheap_api_error() {
  local response="$1"
  printf '%s' "${response}" | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
for err in root.iter():
    if 'Error' in err.tag:
        print(err.text or 'Unknown error')
        break
" 2>/dev/null || echo "Unknown API error"
}

namecheap_get_hosts() {
  curl -fsS "${NAMECHEAP_API_URL}" \
    --data-urlencode "ApiUser=${NAMECHEAP_API_USER}" \
    --data-urlencode "ApiKey=${NAMECHEAP_API_KEY}" \
    --data-urlencode "UserName=${NAMECHEAP_API_USER}" \
    --data-urlencode "ClientIp=${CLIENT_IP}" \
    --data-urlencode "Command=namecheap.domains.dns.getHosts" \
    --data-urlencode "SLD=${NC_SLD}" \
    --data-urlencode "TLD=${NC_TLD}" \
    2>/dev/null
}

namecheap_set_hosts() {
  curl -fsS "${NAMECHEAP_API_URL}" \
    --data-urlencode "ApiUser=${NAMECHEAP_API_USER}" \
    --data-urlencode "ApiKey=${NAMECHEAP_API_KEY}" \
    --data-urlencode "UserName=${NAMECHEAP_API_USER}" \
    --data-urlencode "ClientIp=${CLIENT_IP}" \
    --data-urlencode "Command=namecheap.domains.dns.setHosts" \
    --data-urlencode "SLD=${NC_SLD}" \
    --data-urlencode "TLD=${NC_TLD}" \
    "${SET_HOST_ARGS[@]}" \
    2>/dev/null
}

verify_namecheap_hosts_response() {
  local response="$1"
  local verify_file verify_output
  verify_file="$(mktemp)"
  printf '%s' "${response}" > "${verify_file}"

  if ! verify_output="$(NC_RESPONSE_FILE="${verify_file}" \
    DESIRED="$(printf '%s\n' "${DESIRED_RECORDS[@]}")" \
    python3 - <<'PYEOF'
import os
import sys
import xml.etree.ElementTree as ET

with open(os.environ["NC_RESPONSE_FILE"], "r", encoding="utf-8") as fh:
    response_xml = fh.read()
desired_raw = os.environ.get("DESIRED", "")

desired = {}
for line in desired_raw.strip().splitlines():
    if not line.strip():
        continue
    parts = line.strip().split()
    if len(parts) == 2:
        desired[parts[0].lower()] = parts[1]

root = ET.fromstring(response_xml)
ns_uri = ""
if "{" in root.tag:
    ns_uri = root.tag.split("}")[0] + "}"

current = {}
for host in root.iter(f"{ns_uri}host"):
    if host.get("Type", "") == "A":
        current[host.get("Name", "").lower()] = host.get("Address", "")

ok = True
for subdomain, ip in desired.items():
    if current.get(subdomain, None) != ip:
        ok = False
        break
print("yes" if ok else "no")
PYEOF
  )"; then
    rm -f "${verify_file}"
    return 1
  fi
  rm -f "${verify_file}"
  printf '%s\n' "${verify_output}"
}

apply_namecheap_zone() {
  local reason="$1"
  local set_response verify_response verify_ok

  log "${reason}"
  set_response="$(namecheap_set_hosts)" || die "Namecheap API setHosts request failed"

  if echo "${set_response}" | grep -q 'Status="ERROR"'; then
    die "Namecheap setHosts error: $(extract_namecheap_api_error "${set_response}")"
  fi

  if echo "${set_response}" | grep -q 'IsSuccess="true"'; then
    log "DNS records updated successfully"
  else
    warn "Namecheap returned unexpected response (no IsSuccess=true)"
    warn "Response: ${set_response:0:500}"
  fi

  verify_response="$(namecheap_get_hosts)" || die "Namecheap API getHosts verification failed"
  verify_ok="$(verify_namecheap_hosts_response "${verify_response}")"
  if [[ "${verify_ok}" != "yes" ]]; then
    die "Post-write verification failed: DNS records not as expected."
  fi
}

wait_for_dns_resolution() {
  local auth_ns="$1"
  local deadline=$((SECONDS + DNS_PROPAGATION_TIMEOUT))
  local public_ok=0
  local last_reapply_at="${SECONDS}"

  log "Waiting for DNS propagation (timeout: ${DNS_PROPAGATION_TIMEOUT}s)…"

  while [[ ${SECONDS} -lt ${deadline} ]]; do
    public_ok=1
    local auth_stale=0

    local elapsed remaining
    elapsed=$((SECONDS - (deadline - DNS_PROPAGATION_TIMEOUT)))
    remaining=$((deadline - SECONDS))

    local progress_lines=()
    local rec subdomain expected_ip fqdn public_resolved auth_resolved
    for rec in "${DESIRED_RECORDS[@]}"; do
      subdomain="${rec%% *}"
      expected_ip="${rec##* }"
      fqdn="$(fqdn_for_subdomain "${subdomain}")"
      public_resolved="$(dig +short +time=3 +tries=1 "${fqdn}" A 2>/dev/null | head -n1 || true)"
      auth_resolved=""
      if [[ -n "${auth_ns}" ]]; then
        auth_resolved="$(dig +short +time=3 +tries=1 "@${auth_ns%%.}" "${fqdn}" A 2>/dev/null | head -n1 || true)"
      fi

      if [[ "${public_resolved}" != "${expected_ip}" ]]; then
        public_ok=0
      fi

      if [[ -n "${auth_ns}" && "${auth_resolved}" != "${expected_ip}" ]]; then
        auth_stale=1
      fi

      if [[ -n "${auth_ns}" ]]; then
        progress_lines+=("${fqdn}: auth='${auth_resolved:-<empty>}' public='${public_resolved:-<empty>}' expected='${expected_ip}'")
      else
        progress_lines+=("${fqdn}: public='${public_resolved:-<empty>}' expected='${expected_ip}'")
      fi
    done

    if [[ ${public_ok} -eq 1 ]]; then
      for rec in "${DESIRED_RECORDS[@]}"; do
        subdomain="${rec%% *}"
        expected_ip="${rec##* }"
        fqdn="$(fqdn_for_subdomain "${subdomain}")"
        log "DNS propagated: ${fqdn} → ${expected_ip} (elapsed: ${elapsed}s)"
      done
      return 0
    fi

    log "  [${elapsed}s elapsed, ~${remaining}s remaining] waiting for managed records to resolve"
    local line
    for line in "${progress_lines[@]}"; do
      log "    ${line}"
    done

    if [[ -n "${auth_ns}" && ${auth_stale} -eq 1 && $((SECONDS - last_reapply_at)) -ge ${DNS_REAPPLY_INTERVAL} ]]; then
      apply_namecheap_zone "Authoritative DNS is still stale after ${elapsed}s; replaying the merged Namecheap zone"
      last_reapply_at="${SECONDS}"
      continue
    fi

    sleep "${DNS_PROPAGATION_POLL_INTERVAL}"
  done

  public_ok=1
  for rec in "${DESIRED_RECORDS[@]}"; do
    subdomain="${rec%% *}"
    expected_ip="${rec##* }"
    fqdn="$(fqdn_for_subdomain "${subdomain}")"
    public_resolved="$(dig +short +time=3 +tries=1 "${fqdn}" A 2>/dev/null | head -n1 || true)"
    if [[ "${public_resolved}" != "${expected_ip}" ]]; then
      public_ok=0
      break
    fi
  done

  if [[ ${public_ok} -eq 1 ]]; then
    log "DNS propagated at the timeout boundary; accepting final resolved state"
    return 0
  fi

  warn "DNS propagation timeout after ${DNS_PROPAGATION_TIMEOUT}s"
  for rec in "${DESIRED_RECORDS[@]}"; do
    subdomain="${rec%% *}"
    expected_ip="${rec##* }"
    fqdn="$(fqdn_for_subdomain "${subdomain}")"
    public_resolved="$(dig +short +time=3 +tries=1 "${fqdn}" A 2>/dev/null | head -n1 || true)"
    auth_resolved=""
    if [[ -n "${auth_ns}" ]]; then
      auth_resolved="$(dig +short +time=3 +tries=1 "@${auth_ns%%.}" "${fqdn}" A 2>/dev/null | head -n1 || true)"
      warn "  ${fqdn}: public='${public_resolved:-<empty>}' auth='${auth_resolved:-<empty>}' expected='${expected_ip}'"
    else
      warn "  ${fqdn}: public='${public_resolved:-<empty>}' expected='${expected_ip}'"
    fi
  done
  return 1
}

# ── Validate inputs ───────────────────────────────────────────────────
[[ -n "${NAMECHEAP_API_USER:-}" ]] || die "NAMECHEAP_API_USER is not set"
[[ -n "${NAMECHEAP_API_KEY:-}"  ]] || die "NAMECHEAP_API_KEY is not set"
[[ -n "${BASE_DOMAIN:-}"        ]] || die "BASE_DOMAIN is not set"
[[ -n "${TERRAFORM_OUTPUTS_JSON:-}" ]] || die "TERRAFORM_OUTPUTS_JSON is not set"
[[ -f "${TERRAFORM_OUTPUTS_JSON}"   ]] || die "Terraform outputs file not found: ${TERRAFORM_OUTPUTS_JSON}"

for cmd in curl python3 dig; do
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
done

# ── Read IPs from Terraform outputs ──────────────────────────────────
read_tf_output() {
  local key="$1"
  TF_JSON="${TERRAFORM_OUTPUTS_JSON}" TF_KEY="${key}" python3 -c "
import json, os, sys
with open(os.environ['TF_JSON'], 'r') as f:
    data = json.load(f)
key = os.environ['TF_KEY']
if key not in data:
    sys.exit(1)
val = data[key]
if isinstance(val, dict):
    print(val.get('value', ''))
else:
    print(val)
" 2>/dev/null || die "Could not read '${key}' from ${TERRAFORM_OUTPUTS_JSON}"
}

CONTROL_IP="$(read_tf_output control_public_ip)"
GATEWAY_IP="$(read_tf_output gateway_public_ip)"

[[ -n "${CONTROL_IP}" ]] || die "control_public_ip is empty in terraform outputs"
[[ -n "${GATEWAY_IP}" ]] || die "gateway_public_ip is empty in terraform outputs"

log "Control IP: ${CONTROL_IP}"
log "Gateway IP: ${GATEWAY_IP}"

# ── Parse domain into SLD + TLD (Namecheap API requirement) ──────────
# Namecheap API treats the domain as SLD.TLD (e.g. "example" + "com").
# For multi-level TLDs (e.g. co.uk), this naive split won't work, but
# it covers typical .com/.io/.org/.net domains.
parse_domain() {
  local domain="$1"
  local parts
  IFS='.' read -ra parts <<< "${domain}"
  local count="${#parts[@]}"

  if [[ ${count} -lt 2 ]]; then
    die "Invalid domain: ${domain} (expected at least SLD.TLD)"
  fi

  NC_TLD="${parts[$((count - 1))]}"
  NC_SLD="${parts[$((count - 2))]}"
}

parse_domain "${BASE_DOMAIN}"
log "Domain: SLD=${NC_SLD}, TLD=${NC_TLD}"

# ── Detect client IP (Namecheap requires it) ─────────────────────────
CLIENT_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
[[ -n "${CLIENT_IP}" ]] || die "Could not detect public IP (needed for Namecheap API ClientIp parameter)"
log "Client IP: ${CLIENT_IP}"

# ── Build list of records to upsert ──────────────────────────────────
# Each record: "subdomain IP"
declare -a DESIRED_RECORDS=()
DESIRED_RECORDS+=("${HEADSCALE_SUBDOMAIN} ${CONTROL_IP}")

# Parse GATEWAY_SUBDOMAINS (comma-separated) if set
if [[ -n "${GATEWAY_SUBDOMAINS:-}" ]]; then
  IFS=',' read -ra GW_SUBS <<< "${GATEWAY_SUBDOMAINS}"
  for sub in "${GW_SUBS[@]}"; do
    sub="$(echo "${sub}" | tr -d '[:space:]')"
    [[ -n "${sub}" ]] && DESIRED_RECORDS+=("${sub} ${GATEWAY_IP}")
  done
fi

log "Records to upsert:"
for rec in "${DESIRED_RECORDS[@]}"; do
  log "  ${rec%% *}.${BASE_DOMAIN} → ${rec##* }"
done

# ── DRY_RUN early exit ────────────────────────────────────────────────
if [[ "${DRY_RUN}" == "1" ]]; then
  log "DRY_RUN=1 — would upsert the above records via Namecheap API. Exiting."
  exit 0
fi

# ── Fetch existing records from Namecheap ────────────────────────────
log "Fetching existing DNS records from Namecheap…"

NC_RESPONSE="$(namecheap_get_hosts)" || die "Namecheap API getHosts request failed"

echo "${NC_RESPONSE}" | grep -q 'IsUsingOurDNS="true"' \
  || die "Namecheap BasicDNS is not authoritative for ${BASE_DOMAIN}; public DNS automation would not be reliable."

# Check for API errors
if echo "${NC_RESPONSE}" | grep -q 'Status="ERROR"'; then
  ERROR_MSG="$(extract_namecheap_api_error "${NC_RESPONSE}")"
  die "Namecheap API error: ${ERROR_MSG}"
fi


# ── Pre-write backup ────────────────────────────────────────────────
BACKUP_DIR="${HOME}/.dns-backup"
mkdir -p "${BACKUP_DIR}"
BACKUP_FILE="${BACKUP_DIR}/${BASE_DOMAIN}-$(date +%Y%m%d-%H%M%S).xml"
echo "${NC_RESPONSE}" > "${BACKUP_FILE}"
log "Backed up current DNS records to ${BACKUP_FILE}"

# ── Merge and build setHosts params ─────────────────────────────────
# Re-apply the merged record set on every run instead of relying on a no-op
# short-circuit. The previous optimization could misclassify stale Namecheap
# zones as current, which is worse than a harmless idempotent rewrite.
MERGED_PARAMS_FILE="$(mktemp)"
MERGED_PARAMS="$(NC_RESPONSE_FILE="${BACKUP_FILE}" \
  DESIRED="$(printf '%s\n' "${DESIRED_RECORDS[@]}")" \
  python3 - <<'PYEOF'
import os
import sys
import xml.etree.ElementTree as ET

with open(os.environ["NC_RESPONSE_FILE"], "r", encoding="utf-8") as fh:
    response_xml = fh.read()
desired_raw = os.environ.get("DESIRED", "")

# Parse desired records: "subdomain IP" per line
desired = {}
for line in desired_raw.strip().splitlines():
    if not line.strip():
        continue
    parts = line.strip().split()
    if len(parts) == 2:
        desired[parts[0].lower()] = parts[1]

# Parse existing records from XML
root = ET.fromstring(response_xml)
ns_uri = ""
if "{" in root.tag:
    ns_uri = root.tag.split("}")[0] + "}"

records = []
for host in root.iter(f"{ns_uri}host"):
    rec = {
        "HostName": host.get("Name", ""),
        "RecordType": host.get("Type", ""),
        "Address": host.get("Address", ""),
        "MXPref": host.get("MXPref", "10"),
        "TTL": host.get("TTL", "1799"),
    }
    records.append(rec)

# Merge: for each desired record, find existing A record with same hostname
# and update it, or add a new one.
# Always set TTL=60 (Namecheap minimum) on managed records so the next
# change propagates within 60s instead of the default ~30 minutes.
MIN_TTL = "60"
for subdomain, ip in desired.items():
    found = False
    for rec in records:
        if rec["HostName"].lower() == subdomain.lower() and rec["RecordType"] == "A":
            rec["Address"] = ip
            rec["TTL"] = MIN_TTL
            found = True
            break
    if not found:
        records.append({
            "HostName": subdomain,
            "RecordType": "A",
            "Address": ip,
            "MXPref": "10",
            "TTL": MIN_TTL,
        })

# Build parameters for setHosts (one key=value per line; shell wraps each with
# --data-urlencode so special characters in values are encoded correctly).
params = []
for i, rec in enumerate(records, 1):
    params.append(f"HostName{i}={rec['HostName']}")
    params.append(f"RecordType{i}={rec['RecordType']}")
    params.append(f"Address{i}={rec['Address']}")
    params.append(f"MXPref{i}={rec['MXPref']}")
    params.append(f"TTL{i}={rec['TTL']}")

print("\n".join(params))
PYEOF
 )" || die "Failed to parse/merge DNS records"

[[ -n "${MERGED_PARAMS}" ]] || die "No records to set (merge produced empty output)"
printf '%s\n' "${MERGED_PARAMS}" > "${MERGED_PARAMS_FILE}"

SET_HOST_ARGS=()
while IFS= read -r param; do
  [[ -n "${param}" ]] || continue
  SET_HOST_ARGS+=(--data-urlencode "${param}")
done < "${MERGED_PARAMS_FILE}"
rm -f "${MERGED_PARAMS_FILE}"

[[ ${#SET_HOST_ARGS[@]} -gt 0 ]] || die "No setHosts parameters were generated"

# ── Set records via Namecheap API ────────────────────────────────────
apply_namecheap_zone "Setting DNS records via Namecheap API…"

# ── Wait for DNS propagation ─────────────────────────────────────────
NC_AUTH_NS="$(dig +short NS "${BASE_DOMAIN}" 2>/dev/null | grep -i 'registrar-servers\|name-services\|namecheap' | head -n1 || true)"
if [[ -z "${NC_AUTH_NS}" ]]; then
  NC_AUTH_NS="$(dig +short NS "${BASE_DOMAIN}" 2>/dev/null | head -n1 || true)"
fi
if [[ -n "${NC_AUTH_NS}" ]]; then
  log "Authoritative NS for ${BASE_DOMAIN}: ${NC_AUTH_NS%%.}"
fi

wait_for_dns_resolution "${NC_AUTH_NS}" || die "Public DNS did not converge to the desired records in time."
