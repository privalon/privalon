"""Tests for the phase1_gate logic: tailscale status parsing and reachability decisions.

These tests validate the gate's behavior independent of Ansible by testing the
decision logic directly against various tailscale status --json shapes.
"""

import json
import re
import unittest


def parse_peer_map(ts_status: dict) -> list[dict]:
    """Extract peer list from tailscale status --json (mirrors gate's Jinja2 logic)."""
    return list((ts_status.get("Peer") or {}).values())


def find_host_peer(peer_map: list[dict], hostname: str) -> list[dict]:
    """Find online peers matching a hostname pattern (mirrors gate's selectattr chain)."""
    pattern = re.compile(rf"^{re.escape(hostname)}(-vm)?(-[a-z0-9]+)?$")
    return [
        p for p in peer_map
        if p.get("Online") is True
        and pattern.match(p.get("HostName", ""))
    ]


def host_is_reachable(ts_status: dict, hostname: str) -> tuple[bool, str]:
    """Check if a host would pass the phase1_gate assertions.

    Returns (passed, reason).
    """
    if not (ts_status.get("Self") or {}).get("Online"):
        return False, "controller not online"

    peer_map = parse_peer_map(ts_status)
    host_peers = find_host_peer(peer_map, hostname)

    if not host_peers:
        return False, "peer not found"

    peer = host_peers[0]
    if not peer.get("Online"):
        return False, f"peer Online={peer.get('Online')}"

    ips = peer.get("TailscaleIPs") or []
    if not ips:
        return False, "no TailscaleIPs"

    return True, f"reachable via {ips[0]}"


class TestPhase1Gate(unittest.TestCase):

    def _make_status(self, *, self_online=True, peers=None):
        peer_data = {}
        for i, peer in enumerate(peers or []):
            peer_id = f"nodekey:test{i:04d}"
            peer_data[peer_id] = {
                "HostName": peer.get("hostname", ""),
                "DNSName": f"{peer.get('hostname', '')}.tailnet.ts.net.",
                "TailscaleIPs": peer.get("ips", []),
                "Online": peer.get("online", True),
            }
        return {
            "Self": {"Online": self_online, "TailscaleIPs": ["100.64.0.1"]},
            "Peer": peer_data,
        }

    def test_happy_path_all_hosts_online(self):
        status = self._make_status(peers=[
            {"hostname": "gateway", "ips": ["100.64.0.2"], "online": True},
            {"hostname": "control", "ips": ["100.64.0.3"], "online": True},
            {"hostname": "forgejo", "ips": ["100.64.0.4"], "online": True},
        ])
        for host in ["gateway", "control", "forgejo"]:
            ok, reason = host_is_reachable(status, host)
            self.assertTrue(ok, f"{host}: {reason}")

    def test_missing_host_fails(self):
        status = self._make_status(peers=[
            {"hostname": "gateway", "ips": ["100.64.0.2"], "online": True},
            {"hostname": "control", "ips": ["100.64.0.3"], "online": True},
        ])
        ok, reason = host_is_reachable(status, "forgejo")
        self.assertFalse(ok)
        self.assertIn("peer not found", reason)

    def test_offline_peer_fails(self):
        status = self._make_status(peers=[
            {"hostname": "gateway", "ips": ["100.64.0.2"], "online": True},
            {"hostname": "control", "ips": ["100.64.0.3"], "online": True},
            {"hostname": "forgejo", "ips": ["100.64.0.4"], "online": False},
        ])
        ok, reason = host_is_reachable(status, "forgejo")
        self.assertFalse(ok)
        # Offline peer is filtered out by find_host_peer
        self.assertIn("peer not found", reason)

    def test_controller_offline_fails(self):
        status = self._make_status(self_online=False, peers=[
            {"hostname": "gateway", "ips": ["100.64.0.2"], "online": True},
        ])
        ok, reason = host_is_reachable(status, "gateway")
        self.assertFalse(ok)
        self.assertIn("controller not online", reason)

    def test_suffixed_hostname_matches(self):
        """Hosts with Headscale suffixes (e.g. gateway-a1b2c3d4) should match."""
        status = self._make_status(peers=[
            {"hostname": "gateway-a1b2c3d4", "ips": ["100.64.0.2"], "online": True},
        ])
        ok, reason = host_is_reachable(status, "gateway")
        self.assertTrue(ok, reason)

    def test_vm_suffix_matches(self):
        """Hosts with -vm suffix should match."""
        status = self._make_status(peers=[
            {"hostname": "gateway-vm", "ips": ["100.64.0.2"], "online": True},
        ])
        ok, reason = host_is_reachable(status, "gateway")
        self.assertTrue(ok, reason)

    def test_peer_no_ips_fails(self):
        status = self._make_status(peers=[
            {"hostname": "gateway", "ips": [], "online": True},
        ])
        ok, reason = host_is_reachable(status, "gateway")
        self.assertFalse(ok)
        self.assertIn("no TailscaleIPs", reason)

    def test_empty_peer_map(self):
        status = self._make_status(peers=[])
        ok, reason = host_is_reachable(status, "gateway")
        self.assertFalse(ok)
        self.assertIn("peer not found", reason)


if __name__ == "__main__":
    unittest.main()
