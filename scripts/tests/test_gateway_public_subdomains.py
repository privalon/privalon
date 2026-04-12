import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts" / "helpers" / "gateway_public_subdomains.py"


class GatewayPublicSubdomainsTests(unittest.TestCase):
    def _run_helper(self, config_text: str, base_domain: str) -> str:
        with tempfile.TemporaryDirectory(prefix="gateway-subdomains-") as tmpdir:
            config_path = Path(tmpdir) / "gateway.yml"
            config_path.write_text(textwrap.dedent(config_text), encoding="utf-8")
            result = subprocess.run(
                ["python3", str(HELPER), "--file", str(config_path), "--base-domain", base_domain],
                check=True,
                capture_output=True,
                text=True,
            )
            return result.stdout.strip()

    def test_explicit_gateway_subdomains_take_precedence(self):
        output = self._run_helper(
            """
            gateway_subdomains:
              - app
              - matrix
            gateway_services:
              - name: ignored
                upstream_host: app-vm
                upstream_port: 3000
            """,
            "example.com",
        )
        self.assertEqual(output, "app,matrix")

    def test_gateway_services_are_derived_when_no_explicit_subdomains_exist(self):
        output = self._run_helper(
            """
            gateway_services:
              - name: app
                upstream_host: app-vm
                upstream_port: 3000
              - name: matrix
                upstream_host: matrix-vm
                upstream_port: 8448
            """,
            "example.com",
        )
        self.assertEqual(output, "app,matrix")

    def test_legacy_gateway_domains_fall_back_to_base_domain_derivation(self):
        output = self._run_helper(
            """
            gateway_domains:
              - app.example.com
              - matrix.example.com
            gateway_upstream_host: app-vm
            gateway_upstream_port: 3000
            """,
            "example.com",
        )
        self.assertEqual(output, "app,matrix")


if __name__ == "__main__":
    unittest.main()