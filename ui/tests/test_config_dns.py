import asyncio
import os
import tempfile
import unittest
from pathlib import Path

import yaml

from ui import server
from ui.lib import config_reader


class DnsConfigTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(prefix="ui-config-dns-")
        self.old_env_root = os.environ.get("BLUEPRINT_ENVIRONMENTS_DIR")
        os.environ["BLUEPRINT_ENVIRONMENTS_DIR"] = self.tempdir.name

        self.env = "sample"
        self.env_dir = Path(self.tempdir.name) / self.env
        (self.env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
        (self.env_dir / "secrets.env").write_text("NAMECHEAP_API_USER=user\n", encoding="utf-8")

    def tearDown(self):
        if self.old_env_root is None:
            os.environ.pop("BLUEPRINT_ENVIRONMENTS_DIR", None)
        else:
            os.environ["BLUEPRINT_ENVIRONMENTS_DIR"] = self.old_env_root
        self.tempdir.cleanup()

    def test_config_view_exposes_internal_dns_fields(self):
        config_reader.write_group_vars(
            self.env,
            {
                "base_domain": "example.com",
                "headscale_subdomain": "headscale",
                "headscale_magic_dns_base_domain": "in.example.com",
                "public_service_tls_mode": "namecheap",
                "internal_service_tls_mode": "namecheap",
            },
        )

        view = config_reader.get_config_view(self.env)

        self.assertEqual(view["dns"]["magic_dns_base_domain"], "in.example.com")
        self.assertEqual(view["dns"]["public_service_tls_mode"], "namecheap")
        self.assertEqual(view["dns"]["internal_service_tls_mode"], "namecheap")

    def test_update_dns_persists_internal_dns_fields(self):
        body = server.DnsUpdate(
            base_domain="example.com",
            headscale_subdomain="headscale",
            magic_dns_base_domain="in.example.com",
            public_service_tls_mode="namecheap",
            internal_service_tls_mode="namecheap",
            admin_email="ops@example.com",
        )

        result = asyncio.run(server.update_dns(self.env, body))

        self.assertEqual(result, {"ok": True})
        saved = yaml.safe_load((self.env_dir / "group_vars" / "all.yml").read_text(encoding="utf-8"))
        self.assertEqual(saved["base_domain"], "example.com")
        self.assertEqual(saved["headscale_subdomain"], "headscale")
        self.assertEqual(saved["headscale_magic_dns_base_domain"], "in.example.com")
        self.assertEqual(saved["public_service_tls_mode"], "namecheap")
        self.assertEqual(saved["internal_service_tls_mode"], "namecheap")
        self.assertEqual(saved["admin_email"], "ops@example.com")


if __name__ == "__main__":
    unittest.main()