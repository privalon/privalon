#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
need_cmd curl
need_cmd nc

tf_init_quiet

control_ip="$(control_public_ip)"
assert_nonempty "control_public_ip" "${control_ip}"

headscale_url="$(headscale_url_from_authkeys || true)"
if [[ -z "${headscale_url}" ]]; then
  headscale_url="https://${control_ip}.sslip.io"
fi

log "Headscale public: verify tcp/443 is reachable on ${control_ip}"
nc -z -w 5 "${control_ip}" 443 >/dev/null

log "Headscale public: verify /health responds on ${headscale_url}"
status_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "${headscale_url}/health")"
[[ "${status_code}" == "200" ]] || die "Expected HTTP 200 from ${headscale_url}/health, got ${status_code}"

log "Headscale public: verify /derp endpoint is exposed for relay fallback"
derp_status_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "${headscale_url}/derp")"
[[ "${derp_status_code}" == "426" ]] || die "Expected HTTP 426 from ${headscale_url}/derp without upgrade headers, got ${derp_status_code}"

log "Headscale public endpoint OK"
