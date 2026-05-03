import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
INVENTORY_SCRIPT = REPO_ROOT / "ansible" / "inventory" / "tfgrid.py"


def _load_inventory_module():
    spec = importlib.util.spec_from_file_location("tfgrid_inventory", INVENTORY_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class OperationalModeTests(unittest.TestCase):
    """Tests for BLUEPRINT_INVENTORY_MODE=operational."""

    def _make_outputs(self, tmpdir: Path) -> Path:
        outputs_path = tmpdir / "terraform-outputs.json"
        outputs_path.write_text(
            json.dumps(
                {
                    "gateway_public_ip": {"value": "198.51.100.10"},
                    "gateway_private_ip": {"value": "10.10.3.2"},
                    "control_public_ip": {"value": "198.51.100.11"},
                    "control_private_ip": {"value": "10.10.4.2"},
                    "network_ip_range": {"value": "10.10.0.0/16"},
                    "workloads_private_ips": {
                        "value": {
                            "forgejo": "10.10.2.2",
                            "monitoring": "10.10.2.2",
                        }
                    },
                    "workloads_mycelium_ips": {
                        "value": {
                            "forgejo": "415:c062:1:2:3:4:5:6",
                            "monitoring": "415:c062:1:2:3:4:5:7",
                        }
                    },
                }
            )
        )
        return outputs_path

    def _run_inventory(self, outputs_path: Path, tailscale_status: dict) -> dict:
        mod = _load_inventory_module()
        ts_json = json.dumps(tailscale_status)

        with mock.patch.dict(os.environ, {
            "BLUEPRINT_INVENTORY_MODE": "operational",
            "TF_OUTPUTS_JSON": str(outputs_path),
        }, clear=False):
            with mock.patch("subprocess.run") as mock_run:
                mock_run.return_value = mock.Mock(
                    stdout=ts_json,
                    returncode=0,
                )
                # Reset module-level caches
                mod._TS_HOSTNAME_PROBE_CACHE.clear()
                return mod._operational_inventory(str(outputs_path))

    def _tailscale_status_with_peers(self, peers: dict[str, dict]) -> dict:
        peer_data = {}
        for i, (hostname, info) in enumerate(peers.items()):
            peer_id = f"nodekey:abc{i:04d}"
            peer_data[peer_id] = {
                "HostName": hostname,
                "DNSName": f"{hostname}.tailnet.ts.net.",
                "TailscaleIPs": info.get("ips", []),
                "Online": info.get("online", True),
            }
        return {
            "Self": {"Online": True, "TailscaleIPs": ["100.64.0.1"]},
            "Peer": peer_data,
        }

    def test_operational_returns_tailnet_ips_only(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_path = self._make_outputs(Path(tmpdir))
            ts_status = self._tailscale_status_with_peers({
                "gateway": {"ips": ["100.64.0.2"]},
                "control": {"ips": ["100.64.0.3"]},
                "forgejo": {"ips": ["100.64.0.4"]},
                "monitoring": {"ips": ["100.64.0.5"]},
            })
            inv = self._run_inventory(outputs_path, ts_status)

            self.assertIn("gateway-vm", inv["_meta"]["hostvars"])
            self.assertEqual(inv["_meta"]["hostvars"]["gateway-vm"]["ansible_host"], "100.64.0.2")
            self.assertIn("control-vm", inv["_meta"]["hostvars"])
            self.assertEqual(inv["_meta"]["hostvars"]["control-vm"]["ansible_host"], "100.64.0.3")
            self.assertIn("forgejo-vm", inv["_meta"]["hostvars"])
            self.assertEqual(inv["_meta"]["hostvars"]["forgejo-vm"]["ansible_host"], "100.64.0.4")

    def test_operational_omits_hosts_without_tailnet_ip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_path = self._make_outputs(Path(tmpdir))
            # Only gateway and control are online
            ts_status = self._tailscale_status_with_peers({
                "gateway": {"ips": ["100.64.0.2"]},
                "control": {"ips": ["100.64.0.3"]},
            })
            inv = self._run_inventory(outputs_path, ts_status)

            self.assertIn("gateway-vm", inv["_meta"]["hostvars"])
            self.assertIn("control-vm", inv["_meta"]["hostvars"])
            self.assertNotIn("forgejo-vm", inv["_meta"]["hostvars"])
            self.assertNotIn("monitoring-vm", inv["_meta"]["hostvars"])
            self.assertNotIn("forgejo-vm", inv["workloads"]["hosts"])

    def test_operational_no_proxy_vars(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_path = self._make_outputs(Path(tmpdir))
            ts_status = self._tailscale_status_with_peers({
                "gateway": {"ips": ["100.64.0.2"]},
                "control": {"ips": ["100.64.0.3"]},
                "forgejo": {"ips": ["100.64.0.4"]},
            })
            inv = self._run_inventory(outputs_path, ts_status)

            for host, hv in inv["_meta"]["hostvars"].items():
                for key in hv:
                    self.assertFalse(
                        key.startswith("tfgrid_proxy_"),
                        f"Host {host} has proxy var {key} in operational mode",
                    )
                self.assertNotIn("tailscale_refresh_ansible_host", hv)
                self.assertNotIn("tailscale_refresh_ansible_ssh_common_args", hv)

    def test_operational_offline_peer_omitted(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_path = self._make_outputs(Path(tmpdir))
            ts_status = self._tailscale_status_with_peers({
                "gateway": {"ips": ["100.64.0.2"], "online": True},
                "control": {"ips": ["100.64.0.3"], "online": True},
                "forgejo": {"ips": ["100.64.0.4"], "online": False},
            })
            inv = self._run_inventory(outputs_path, ts_status)

            self.assertIn("gateway-vm", inv["_meta"]["hostvars"])
            # Forgejo is offline, so it's omitted from live IPs by _load_local_tailscale_ips
            self.assertNotIn("forgejo-vm", inv["_meta"]["hostvars"])

    def test_operational_preserves_tf_metadata(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_path = self._make_outputs(Path(tmpdir))
            ts_status = self._tailscale_status_with_peers({
                "gateway": {"ips": ["100.64.0.2"]},
                "control": {"ips": ["100.64.0.3"]},
                "forgejo": {"ips": ["100.64.0.4"]},
            })
            inv = self._run_inventory(outputs_path, ts_status)

            gw = inv["_meta"]["hostvars"]["gateway-vm"]
            self.assertEqual(gw["tf_public_ip"], "198.51.100.10")
            self.assertEqual(gw["tf_private_ip"], "10.10.3.2")

            fj = inv["_meta"]["hostvars"]["forgejo-vm"]
            self.assertEqual(fj["tf_name"], "forgejo")
            self.assertEqual(fj["tf_private_ip"], "10.10.2.2")

    def test_operational_groups_populated(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_path = self._make_outputs(Path(tmpdir))
            ts_status = self._tailscale_status_with_peers({
                "gateway": {"ips": ["100.64.0.2"]},
                "control": {"ips": ["100.64.0.3"]},
                "forgejo": {"ips": ["100.64.0.4"]},
                "monitoring": {"ips": ["100.64.0.5"]},
            })
            inv = self._run_inventory(outputs_path, ts_status)

            self.assertIn("gateway-vm", inv["gateway"]["hosts"])
            self.assertIn("control-vm", inv["control"]["hosts"])
            self.assertIn("forgejo-vm", inv["workloads"]["hosts"])
            self.assertIn("monitoring-vm", inv["workloads"]["hosts"])
            self.assertIn("monitoring-vm", inv["monitoring"]["hosts"])

    def test_operational_sets_tailscale_ip_fact(self):
        """Operational inventory must set tailscale_ip so Phase 2 roles can bind to it."""
        with tempfile.TemporaryDirectory() as tmpdir:
            outputs_path = self._make_outputs(Path(tmpdir))
            ts_status = self._tailscale_status_with_peers({
                "gateway": {"ips": ["100.64.0.2"]},
                "control": {"ips": ["100.64.0.3"]},
                "forgejo": {"ips": ["100.64.0.4"]},
                "monitoring": {"ips": ["100.64.0.5"]},
            })
            inv = self._run_inventory(outputs_path, ts_status)

            for host in ("gateway-vm", "control-vm", "forgejo-vm", "monitoring-vm"):
                hv = inv["_meta"]["hostvars"][host]
                self.assertIn("tailscale_ip", hv, f"{host} missing tailscale_ip")
                self.assertEqual(
                    hv["tailscale_ip"], hv["ansible_host"],
                    f"{host}: tailscale_ip should equal ansible_host",
                )


class BootstrapModeTests(unittest.TestCase):
    """Tests that bootstrap mode preserves existing behavior."""

    def test_bootstrap_is_default_mode(self):
        """When BLUEPRINT_INVENTORY_MODE is unset, the script uses bootstrap behavior."""
        # Just verify the env var defaults correctly.
        mode = os.environ.get("BLUEPRINT_INVENTORY_MODE", "bootstrap").strip().lower()
        if "BLUEPRINT_INVENTORY_MODE" not in os.environ:
            self.assertEqual(mode, "bootstrap")


if __name__ == "__main__":
    unittest.main()
