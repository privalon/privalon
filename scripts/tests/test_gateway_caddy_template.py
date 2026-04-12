import json
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TEMPLATE_PATH = REPO_ROOT / "ansible" / "roles" / "gateway" / "templates" / "Caddyfile.j2"


class GatewayCaddyTemplateTests(unittest.TestCase):
    def _render(self, **overrides):
        context = {
            "gateway_services": [],
            "gateway_domains": [],
            "gateway_upstream_host": "app-vm",
            "gateway_upstream_port": 80,
            "public_service_tls_mode": "letsencrypt",
            "base_domain": "example.com",
            "headscale_magic_dns_base_domain": "",
            "internal_service_tls_mode": "internal",
            "internal_service_tls_namecheap_resolvers": ["1.1.1.1", "1.0.0.1"],
            "internal_service_tls_namecheap_propagation_delay": "2m",
            "internal_service_tls_namecheap_propagation_timeout": "10m",
            "gateway_namecheap_client_ip_effective": "203.0.113.10",
            "tailscale_ip": "100.64.0.2",
            "admin_email": "ops@example.com",
            "backup_enabled": False,
            "hostvars": {
                "app-vm": {"tailscale_ip": "100.64.0.10"},
                "matrix-vm": {"tailscale_ip": "100.64.0.11"},
                "monitoring-vm": {"tailscale_ip": "100.64.0.20"},
            },
        }
        context.update(overrides)
        with tempfile.TemporaryDirectory(prefix="gateway-caddy-render-") as tmpdir:
            output_path = Path(tmpdir) / "Caddyfile"
            inventory_path = Path(tmpdir) / "inventory.yml"
            playbook_path = Path(tmpdir) / "playbook.yml"

            inventory_path.write_text(
                textwrap.dedent(
                    f"""
                    all:
                      hosts:
                        localhost:
                          ansible_connection: local
                          tailscale_ip: {json.dumps(context['tailscale_ip'])}
                          gateway_services: {json.dumps(context['gateway_services'])}
                          gateway_domains: {json.dumps(context['gateway_domains'])}
                          gateway_upstream_host: {json.dumps(context['gateway_upstream_host'])}
                          gateway_upstream_port: {json.dumps(context['gateway_upstream_port'])}
                          public_service_tls_mode: {json.dumps(context['public_service_tls_mode'])}
                          base_domain: {json.dumps(context['base_domain'])}
                          headscale_magic_dns_base_domain: {json.dumps(context['headscale_magic_dns_base_domain'])}
                          internal_service_tls_mode: {json.dumps(context['internal_service_tls_mode'])}
                          internal_service_tls_namecheap_resolvers: {json.dumps(context['internal_service_tls_namecheap_resolvers'])}
                          internal_service_tls_namecheap_propagation_delay: {json.dumps(context['internal_service_tls_namecheap_propagation_delay'])}
                          internal_service_tls_namecheap_propagation_timeout: {json.dumps(context['internal_service_tls_namecheap_propagation_timeout'])}
                          gateway_namecheap_client_ip_effective: {json.dumps(context['gateway_namecheap_client_ip_effective'])}
                          admin_email: {json.dumps(context['admin_email'])}
                          backup_enabled: {json.dumps(context['backup_enabled'])}
                        app-vm:
                          tailscale_ip: {json.dumps(context['hostvars']['app-vm']['tailscale_ip'])}
                        matrix-vm:
                          tailscale_ip: {json.dumps(context['hostvars']['matrix-vm']['tailscale_ip'])}
                        monitoring-vm:
                          tailscale_ip: {json.dumps(context['hostvars']['monitoring-vm']['tailscale_ip'])}
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            playbook_path.write_text(
                textwrap.dedent(
                    f"""
                    - hosts: localhost
                      gather_facts: false
                      tasks:
                        - ansible.builtin.template:
                            src: {json.dumps(str(TEMPLATE_PATH))}
                            dest: {json.dumps(str(output_path))}
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            subprocess.run(
                ["ansible-playbook", "-i", str(inventory_path), str(playbook_path)],
                check=True,
                capture_output=True,
                text=True,
            )
            return output_path.read_text(encoding="utf-8")

    def test_legacy_gateway_domains_still_render(self):
        rendered = self._render(
            gateway_domains=["app.example.com"],
            gateway_upstream_host="app-vm",
            gateway_upstream_port=3000,
        )

        self.assertIn("app.example.com {", rendered)
        self.assertIn("reverse_proxy http://100.64.0.10:3000", rendered)

    def test_gateway_services_render_distinct_public_upstreams(self):
        rendered = self._render(
            gateway_services=[
                {"name": "app", "upstream_host": "app-vm", "upstream_port": 3000},
                {"name": "matrix", "upstream_host": "matrix-vm", "upstream_port": 8448},
            ]
        )

        self.assertIn("app.example.com {", rendered)
        self.assertIn("matrix.example.com {", rendered)
        self.assertIn("reverse_proxy http://100.64.0.10:3000", rendered)
        self.assertIn("reverse_proxy http://100.64.0.11:8448", rendered)

    def test_public_namecheap_mode_renders_wildcard_site(self):
        rendered = self._render(
            gateway_services=[
                {"name": "app", "upstream_host": "app-vm", "upstream_port": 3000},
                {"name": "matrix", "upstream_host": "matrix-vm", "upstream_port": 8448},
            ],
            public_service_tls_mode="namecheap",
        )

        self.assertIn("*.example.com {", rendered)
        self.assertIn("dns namecheap {", rendered)
        self.assertIn("client_ip 203.0.113.10", rendered)
        self.assertIn("propagation_delay 2m", rendered)
        self.assertIn("propagation_timeout 10m", rendered)
        self.assertIn("@public_service_1 host app.example.com", rendered)
        self.assertIn("@public_service_2 host matrix.example.com", rendered)
        self.assertIn("respond \"unknown public service under example.com\" 404", rendered)


if __name__ == "__main__":
    unittest.main()