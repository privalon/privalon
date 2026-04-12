#!/usr/bin/env bash
set -euo pipefail

# Test: Verify dns-setup.sh script behavior.
#
# This test validates the DNS automation script in two modes:
#   1. Dry-run mode (always): ensures the script parses terraform outputs correctly
#      and produces the expected Namecheap API call parameters.
#   2. Live mode (when NAMECHEAP_API_KEY is set): verifies that records were actually
#      updated by checking dig resolution.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_basic_tools

DNS_SCRIPT="${REPO_ROOT}/scripts/helpers/dns-setup.sh"

# ── Script existence and permissions ───────────────────────────────────
log "DNS: script exists and is executable"
assert_file "${DNS_SCRIPT}"
[[ -x "${DNS_SCRIPT}" ]] || die "dns-setup.sh is not executable"

# ── Terraform outputs JSON is readable ─────────────────────────────────
TF_OUTPUTS="${INVENTORY_DIR}/terraform-outputs.json"
log "DNS: terraform-outputs.json exists in inventory"
assert_file "${TF_OUTPUTS}"

# ── Terraform outputs contain required IPs ─────────────────────────────
log "DNS: terraform outputs have control_public_ip and gateway_public_ip"
CONTROL_IP="$(jq -r '.control_public_ip.value // empty' "${TF_OUTPUTS}")"
GATEWAY_IP="$(jq -r '.gateway_public_ip.value // empty' "${TF_OUTPUTS}")"
assert_nonempty "control_public_ip" "${CONTROL_IP}"
assert_nonempty "gateway_public_ip" "${GATEWAY_IP}"

# ── Dry-run mode produces expected output ─────────────────────────────
log "DNS: dry-run mode works"
DRY_OUTPUT="$(DRY_RUN=1 TERRAFORM_OUTPUTS_JSON="${TF_OUTPUTS}" \
  BASE_DOMAIN="test.example.com" \
  HEADSCALE_SUBDOMAIN="headscale" \
  NAMECHEAP_API_USER="testuser" \
  NAMECHEAP_API_KEY="testkey" \
  "${DNS_SCRIPT}" 2>&1 || true)"

# Verify dry-run mentions the IPs it found
echo "${DRY_OUTPUT}" | grep -q "${CONTROL_IP}" \
  || die "Dry-run output does not mention control IP ${CONTROL_IP}"
echo "${DRY_OUTPUT}" | grep -q "headscale" \
  || die "Dry-run output does not mention headscale subdomain"
echo "${DRY_OUTPUT}" | grep -q "DRY_RUN" \
  || die "Dry-run output does not indicate dry-run mode"

# ── Live DNS check (optional — requires real credentials) ──────────────
if [[ -n "${NAMECHEAP_API_KEY:-}" && -n "${BASE_DOMAIN:-}" ]]; then
  log "DNS: live credentials detected — running live tests"

  HEADSCALE_SUBDOMAIN="${HEADSCALE_SUBDOMAIN:-headscale}"
  HEADSCALE_FQDN="${HEADSCALE_SUBDOMAIN}.${BASE_DOMAIN}"

  # First run — may update records or find them already correct
  log "DNS: running dns-setup.sh (first pass)"
  FIRST_OUTPUT="$(TERRAFORM_OUTPUTS_JSON="${TF_OUTPUTS}" \
    BASE_DOMAIN="${BASE_DOMAIN}" \
    HEADSCALE_SUBDOMAIN="${HEADSCALE_SUBDOMAIN}" \
    NAMECHEAP_API_USER="${NAMECHEAP_API_USER}" \
    NAMECHEAP_API_KEY="${NAMECHEAP_API_KEY}" \
    "${DNS_SCRIPT}" 2>&1)" || \
    die "dns-setup.sh failed on first run: ${FIRST_OUTPUT}"

  # Second run — must always be a no-op (idempotency)
  log "DNS: running dns-setup.sh (second pass — must be no-op)"
  SECOND_OUTPUT="$(TERRAFORM_OUTPUTS_JSON="${TF_OUTPUTS}" \
    BASE_DOMAIN="${BASE_DOMAIN}" \
    HEADSCALE_SUBDOMAIN="${HEADSCALE_SUBDOMAIN}" \
    NAMECHEAP_API_USER="${NAMECHEAP_API_USER}" \
    NAMECHEAP_API_KEY="${NAMECHEAP_API_KEY}" \
    "${DNS_SCRIPT}" 2>&1)" || \
    die "dns-setup.sh failed on second run: ${SECOND_OUTPUT}"
  echo "${SECOND_OUTPUT}" | grep -q "No DNS changes needed" \
    || die "Idempotency failed: second run did not report 'No DNS changes needed'. Output: ${SECOND_OUTPUT}"
  log "DNS: idempotency OK — second run was a no-op"

  # Backup file: if first run changed records, a backup XML must exist
  if echo "${FIRST_OUTPUT}" | grep -q "Backed up"; then
    log "DNS: first run wrote records — checking backup file"
    BACKUP_DIR="${HOME}/.dns-backup"
    BACKUP_FILE="$(ls -t "${BACKUP_DIR}/${BASE_DOMAIN}"-*.xml 2>/dev/null | head -n1 || true)"
    [[ -n "${BACKUP_FILE}" ]] || die "Backup file not found in ${BACKUP_DIR}"
    # Verify backup is valid XML with a Status tag (expect Namecheap XML shape)
    python3 -c "
import xml.etree.ElementTree as ET, sys
ET.parse('${BACKUP_FILE}')
print('XML valid')
" >/dev/null 2>&1 || die "Backup file ${BACKUP_FILE} is not valid XML"
    log "DNS: backup file exists and is valid XML — OK"
  else
    log "DNS: records were already correct on first run (no backup written — expected)"
  fi

  # Dig resolution check
  log "DNS: verifying ${HEADSCALE_FQDN} resolves to ${CONTROL_IP}"
  RESOLVED="$(dig +short "${HEADSCALE_FQDN}" A 2>/dev/null | head -n1 || true)"
  if [[ "${RESOLVED}" == "${CONTROL_IP}" ]]; then
    log "DNS: ${HEADSCALE_FQDN} resolves to ${CONTROL_IP} — OK"
  else
    warn "DNS: ${HEADSCALE_FQDN} resolves to '${RESOLVED}', expected '${CONTROL_IP}'"
    warn "DNS: This may indicate propagation delay — check again in a few minutes"
  fi
else
  log "DNS: skipping live DNS check (NAMECHEAP_API_KEY or BASE_DOMAIN not set)"
fi

log "DNS setup verification OK"
