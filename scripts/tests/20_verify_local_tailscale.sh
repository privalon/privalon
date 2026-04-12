#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_basic_tools
require_tailscale

authkeys_path="$(headscale_authkeys_path)"
assert_file "$authkeys_path"

hs_url="$(headscale_url_from_authkeys || true)"
assert_nonempty "headscale_url" "$hs_url"

log "Local Tailscale: ensure this machine is joined (best-effort via deploy script)"
run_deploy join-local >/dev/null

ip4="$(local_ts_ip4 || true)"
assert_nonempty "local tailscale ip" "$ip4"
log "Local Tailscale IP: ${ip4}"

log "Local Tailscale: verify we can fetch status JSON"
local_ts_status_json >/dev/null

wait_for_peer_ip() {
	local peer_ip="$1"
	local attempts="${2:-12}"
	local delay="${3:-5}"
	local try=1

	while [[ "$try" -le "$attempts" ]]; do
		if [[ -n "${peer_ip}" ]] && \
			(
				tailscale ping --tsmp -c 1 "${peer_ip}" >/dev/null 2>&1 \
				|| tailscale ping --icmp -c 1 "${peer_ip}" >/dev/null 2>&1 \
				|| tailscale ping --peerapi -c 1 "${peer_ip}" >/dev/null 2>&1
			); then
			return 0
		fi
		sleep "$delay"
		try=$((try + 1))
	done

	return 1
}

wait_for_cluster_peer() {
	# Resolve peer IPs from tailscale-ips.json / live tailscale status —
	# never use hardcoded MagicDNS hostnames which are environment-specific.
	local control_ip; control_ip="$(tailscale_ip_for_host "control-vm" || true)"
	local gateway_ip; gateway_ip="$(tailscale_ip_for_host "gateway-vm" || true)"
	if [[ -z "${control_ip}${gateway_ip}" ]]; then
		warn "No control/gateway Tailscale IPs found; skipping cluster peer ping"
		return 1
	fi

	if [[ -n "${control_ip}" ]] && wait_for_peer_ip "${control_ip}" "$1" "$2"; then
		return 0
	fi
	if [[ -n "${gateway_ip}" ]] && wait_for_peer_ip "${gateway_ip}" "$1" "$2"; then
		return 0
	fi

	return 1
}

monitoring_ip="$(tailscale_ip_for_host "monitoring-vm" || true)"

if ! wait_for_cluster_peer 6 2; then
	warn "Local Tailscale session is up but cluster peers are unreachable; forcing rejoin"
	run_deploy join-local --rejoin-local >/dev/null
	wait_for_cluster_peer 12 5 \
		|| die "Local Tailscale rejoin completed but cluster peers are still unreachable"
fi

if [[ -n "${monitoring_ip}" ]]; then
	log "Local Tailscale: verify direct transport reachability to monitoring-vm (${monitoring_ip})"
	if ! wait_for_peer_ip "${monitoring_ip}" 6 2; then
		warn "Local Tailscale session can reach control/gateway but not monitoring-vm; forcing rejoin"
		run_deploy join-local --rejoin-local >/dev/null
		wait_for_peer_ip "${monitoring_ip}" 12 5 \
			|| die "Local Tailscale rejoin completed but monitoring-vm is still unreachable from this client"
	fi
else
	warn "No monitoring-vm Tailscale IP found; skipping direct monitoring peer check"
fi

log "Local Tailscale OK"
