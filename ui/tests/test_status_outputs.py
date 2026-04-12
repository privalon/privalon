import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path

from ui import server


class StatusOutputsTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(prefix="ui-status-outputs-")
        self.old_env_root = os.environ.get("BLUEPRINT_ENVIRONMENTS_DIR")
        os.environ["BLUEPRINT_ENVIRONMENTS_DIR"] = self.tempdir.name

        self.env = "sample"
        self.env_dir = Path(self.tempdir.name) / self.env
        (self.env_dir / "inventory").mkdir(parents=True, exist_ok=True)
        (self.env_dir / "group_vars").mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        if self.old_env_root is None:
            os.environ.pop("BLUEPRINT_ENVIRONMENTS_DIR", None)
        else:
            os.environ["BLUEPRINT_ENVIRONMENTS_DIR"] = self.old_env_root
        self.tempdir.cleanup()

    def test_status_route_tolerates_provider_metadata_in_outputs(self):
        (self.env_dir / "inventory" / "terraform-outputs.json").write_text(
            json.dumps(
                {
                    "provider": "threefold",
                    "control_public_ip": {"value": "203.0.113.10"},
                    "gateway_public_ip": {"value": "203.0.113.11"},
                    "gateway_private_ip": {"value": "10.0.0.2"},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (self.env_dir / "group_vars" / "all.yml").write_text(
            "base_domain: example.com\nheadscale_subdomain: headscale\n",
            encoding="utf-8",
        )

        status = asyncio.run(server.get_status(self.env))

        self.assertTrue(status["has_outputs"])
        self.assertEqual(status["control"]["public_ip"], "203.0.113.10")
        self.assertEqual(status["gateway"]["public_ip"], "203.0.113.11")
        self.assertEqual(status["gateway"]["private_ip"], "10.0.0.2")

    def test_status_route_builds_tailnet_only_headplane_url(self):
        (self.env_dir / "inventory" / "terraform-outputs.json").write_text(
            json.dumps({"control_public_ip": {"value": "203.0.113.10"}}) + "\n",
            encoding="utf-8",
        )
        (self.env_dir / "inventory" / "tailscale-ips.json").write_text(
            json.dumps({"control-vm": "100.64.0.10"}) + "\n",
            encoding="utf-8",
        )
        (self.env_dir / "group_vars" / "all.yml").write_text(
            "headscale_magic_dns_base_domain: in.example.com\n",
            encoding="utf-8",
        )

        status = asyncio.run(server.get_status(self.env))

        self.assertEqual(status["urls"]["headplane"], "http://control-vm.in.example.com:3000")


if __name__ == "__main__":
    unittest.main()