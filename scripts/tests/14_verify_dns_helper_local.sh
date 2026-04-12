#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

DNS_SCRIPT="${REPO_ROOT}/scripts/helpers/dns-setup.sh"
assert_file "${DNS_SCRIPT}"

make_stub_dir() {
  mktemp -d
}

write_fake_outputs() {
  local dir="$1"
  cat > "${dir}/outputs.json" <<'JSON'
{
  "control_public_ip": {"value": "213.232.253.34"},
  "gateway_public_ip": {"value": "185.69.166.147"}
}
JSON
}

write_dig_stub() {
  local dir="$1"
  cat > "${dir}/dig" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

count_file="${DNS_STUB_STATE_DIR}/sethosts-count"
sethosts_count="0"
if [[ -f "${count_file}" ]]; then
  sethosts_count="$(cat "${count_file}")"
fi

if [[ "$*" == *"+short NS"* ]]; then
  printf 'dns1.registrar-servers.com.\n'
  exit 0
fi

if [[ "$*" == *"@dns1.registrar-servers.com"*"headscale.babenko.live"* ]]; then
  if [[ -n "${DNS_STUB_AUTH_HEADSCALE_AFTER_SECOND_SET:-}" && "${sethosts_count}" -ge 2 ]]; then
    printf '%s\n' "${DNS_STUB_AUTH_HEADSCALE_AFTER_SECOND_SET}"
    exit 0
  fi
  printf '%s\n' "${DNS_STUB_AUTH_HEADSCALE:-213.232.253.34}"
  exit 0
fi

if [[ "$*" == *"headscale.babenko.live"* ]]; then
  if [[ -n "${DNS_STUB_PUBLIC_HEADSCALE_AFTER_SECOND_SET:-}" && "${sethosts_count}" -ge 2 ]]; then
    printf '%s\n' "${DNS_STUB_PUBLIC_HEADSCALE_AFTER_SECOND_SET}"
    exit 0
  fi
  printf '%s\n' "${DNS_STUB_PUBLIC_HEADSCALE:-213.232.253.34}"
  exit 0
fi

exit 0
SH
  chmod +x "${dir}/dig"
}

write_curl_stub() {
  local dir="$1"
  cat > "${dir}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
state_file="${DNS_STUB_STATE_DIR}/state"

if [[ "$args" == *"api.ipify.org"* ]]; then
  printf '127.0.0.1'
  exit 0
fi

if [[ "$args" == *"Command=namecheap.domains.dns.getHosts"* ]]; then
  if [[ -f "$state_file" ]]; then
    cat "${DNS_STUB_STATE_DIR}/gethosts-updated.xml"
  else
    cat "${DNS_STUB_STATE_DIR}/gethosts-initial.xml"
  fi
  exit 0
fi

if [[ "$args" == *"Command=namecheap.domains.dns.setHosts"* ]]; then
  [[ "$args" == *"HostName1=headscale"* ]] || {
    printf 'missing HostName1 in setHosts request\n' >&2
    exit 1
  }
  [[ "$args" == *"Address1=213.232.253.34"* ]] || {
    printf 'missing updated headscale address in setHosts request\n' >&2
    exit 1
  }
  sethosts_count="0"
  if [[ -f "${DNS_STUB_STATE_DIR}/sethosts-count" ]]; then
    sethosts_count="$(cat "${DNS_STUB_STATE_DIR}/sethosts-count")"
  fi
  sethosts_count="$((sethosts_count + 1))"
  printf '%s' "${sethosts_count}" > "${DNS_STUB_STATE_DIR}/sethosts-count"
  touch "$state_file"
  cat <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<ApiResponse Status="OK" xmlns="http://api.namecheap.com/xml.response">
  <Errors />
  <Warnings />
  <CommandResponse Type="namecheap.domains.dns.setHosts">
    <DomainDNSSetHostsResult Domain="babenko.live" IsSuccess="true" />
  </CommandResponse>
</ApiResponse>
XML
  exit 0
fi

printf 'unexpected curl invocation: %s\n' "$args" >&2
exit 1
SH
  chmod +x "${dir}/curl"
}

write_namecheap_xml() {
  local file_path="$1"
  local headscale_ip="$2"
  cat > "${file_path}" <<XML
<?xml version="1.0" encoding="utf-8"?>
<ApiResponse Status="OK" xmlns="http://api.namecheap.com/xml.response">
  <Errors />
  <Warnings />
  <RequestedCommand>namecheap.domains.dns.gethosts</RequestedCommand>
  <CommandResponse Type="namecheap.domains.dns.getHosts">
    <DomainDNSGetHostsResult Domain="babenko.live" EmailType="FWD" IsUsingOurDNS="true">
      <host HostId="1" Name="headscale" Type="A" Address="${headscale_ip}" MXPref="10" TTL="60" />
      <host HostId="2" Name="test" Type="A" Address="185.69.166.153" MXPref="10" TTL="60" />
    </DomainDNSGetHostsResult>
  </CommandResponse>
</ApiResponse>
XML
}

run_dns_helper() {
  local dir="$1"
  shift
  PATH="${dir}:$PATH" \
  DNS_STUB_STATE_DIR="${dir}" \
  NAMECHEAP_API_USER="test-user" \
  NAMECHEAP_API_KEY="test-key" \
  BASE_DOMAIN="babenko.live" \
  HEADSCALE_SUBDOMAIN="headscale" \
  TERRAFORM_OUTPUTS_JSON="${dir}/outputs.json" \
  bash "${DNS_SCRIPT}" "$@"
}

log "DNS helper: updates stale Namecheap records and waits for public resolution"
dir_update="$(make_stub_dir)"
trap 'rm -rf "${dir_update:-}" "${dir_stale_public:-}"' EXIT
write_fake_outputs "${dir_update}"
write_dig_stub "${dir_update}"
write_curl_stub "${dir_update}"
write_namecheap_xml "${dir_update}/gethosts-initial.xml" "185.69.166.147"
write_namecheap_xml "${dir_update}/gethosts-updated.xml" "213.232.253.34"
DNS_STUB_PUBLIC_HEADSCALE="213.232.253.34" DNS_STUB_AUTH_HEADSCALE="213.232.253.34" \
  run_dns_helper "${dir_update}" >/tmp/dns-helper-local-update.log 2>&1 \
  || die "dns-setup.sh should succeed when Namecheap zone updates and public DNS resolves"
[[ -f "${dir_update}/state" ]] || die "dns-setup.sh did not call setHosts for stale Namecheap records"

log "DNS helper: fails when public resolution stays stale even if Namecheap zone is already correct"
dir_stale_public="$(make_stub_dir)"
write_fake_outputs "${dir_stale_public}"
write_dig_stub "${dir_stale_public}"
write_curl_stub "${dir_stale_public}"
write_namecheap_xml "${dir_stale_public}/gethosts-initial.xml" "213.232.253.34"
write_namecheap_xml "${dir_stale_public}/gethosts-updated.xml" "213.232.253.34"
if DNS_STUB_PUBLIC_HEADSCALE="185.69.166.147" DNS_STUB_AUTH_HEADSCALE="213.232.253.34" \
  DNS_PROPAGATION_TIMEOUT=0 run_dns_helper "${dir_stale_public}" >/tmp/dns-helper-local-stale.log 2>&1; then
  die "dns-setup.sh should fail when public DNS does not resolve to the desired control IP"
fi
[[ -f "${dir_stale_public}/state" ]] || die "dns-setup.sh should still reapply the merged record set before checking public resolution"

log "DNS helper: reapplies the merged zone when Namecheap management state is updated but authoritative DNS is still stale"
dir_authoritative_lag="$(make_stub_dir)"
trap 'rm -rf "${dir_update:-}" "${dir_stale_public:-}" "${dir_authoritative_lag:-}"' EXIT
write_fake_outputs "${dir_authoritative_lag}"
write_dig_stub "${dir_authoritative_lag}"
write_curl_stub "${dir_authoritative_lag}"
write_namecheap_xml "${dir_authoritative_lag}/gethosts-initial.xml" "185.69.166.147"
write_namecheap_xml "${dir_authoritative_lag}/gethosts-updated.xml" "213.232.253.34"
if ! DNS_STUB_PUBLIC_HEADSCALE="185.69.166.147" \
  DNS_STUB_AUTH_HEADSCALE="185.69.166.147" \
  DNS_STUB_PUBLIC_HEADSCALE_AFTER_SECOND_SET="213.232.253.34" \
  DNS_STUB_AUTH_HEADSCALE_AFTER_SECOND_SET="213.232.253.34" \
  DNS_PROPAGATION_TIMEOUT=1 \
  DNS_PROPAGATION_POLL_INTERVAL=0 \
  DNS_REAPPLY_INTERVAL=0 \
  run_dns_helper "${dir_authoritative_lag}" >/tmp/dns-helper-local-authoritative-lag.log 2>&1; then
  die "dns-setup.sh should replay the merged record set until authoritative DNS catches up"
fi
[[ "$(cat "${dir_authoritative_lag}/sethosts-count")" == "2" ]] || die "dns-setup.sh should call setHosts twice when authoritative DNS only updates after the replay"

log "DNS helper local logic OK"