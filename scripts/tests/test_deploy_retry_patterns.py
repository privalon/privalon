import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEPLOY_SCRIPT = REPO_ROOT / "scripts" / "deploy.sh"
PLAYBOOK = REPO_ROOT / "ansible" / "playbooks" / "phase1_bootstrap_and_join.yml"


class DeployRetryPatternTests(unittest.TestCase):
    def test_tf_apply_retries_transient_network_contract_failures(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")

        self.assertRegex(
            content,
            re.compile(r"could not deploy network \.\*failed to create contract on node \[0-9\]\+"),
        )
        self.assertIn(
            "[terraform] Detected transient TFGrid network/control-plane failure; waiting ${sleep_s}s then retrying…",
            content,
        )

    def test_tf_apply_quarantines_failed_scheduler_nodes(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('ENV_TF_RUNTIME_VARFILE="${ENV_DIR}/scheduler-runtime-overrides.tfvars.json"', content)
        self.assertIn("failed_node_id=\"$(sed -nE", content)
        self.assertIn('quarantine_scheduler_node "${failed_node_id}"', content)
        self.assertIn('[terraform] Quarantined scheduler node ${node_id} in ${ENV_TF_RUNTIME_VARFILE}.', content)

    def test_tf_apply_forces_scheduler_reselection_after_quarantine(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('local force_scheduler_reselect=0', content)
        self.assertIn('scheduler_replace_args()', content)
        self.assertIn('tf_extra+=("${replace_arg}")', content)
        self.assertIn('force_scheduler_reselect=1', content)

    def test_join_local_can_override_stale_headscale_dns_locally(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('update_local_headscale_host_override()', content)
        self.assertIn('headscale_control_public_ip()', content)
        self.assertIn('control_public_ip.value', content)
        self.assertIn('# BEGIN blueprint headscale override', content)
        self.assertIn('if host in parts[1:]:', content)
        self.assertIn('Ensured local hosts override for ${login_host} -> ${current_ip} during local rejoin.', content)

    def test_join_local_applies_headscale_override_before_restart(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")

        override_index = content.index('  update_local_headscale_host_override "${login_server}"\n')
        restart_index = content.index('  if restart_local_tailscaled_best_effort; then\n')
        wait_index = content.index('wait_for_local_tailscaled_best_effort || true')

        self.assertLess(override_index, restart_index)
        self.assertLess(restart_index, wait_index)

    def test_deploy_script_defines_die_helper(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('die() {', content)
        self.assertIn('  exit 1', content)

    def test_deploy_falls_back_to_internal_headscale_tls_when_dns_is_stale(self):
        deploy_content = DEPLOY_SCRIPT.read_text(encoding="utf-8")
        playbook_content = PLAYBOOK.read_text(encoding="utf-8")

        self.assertIn('DNS_PUBLIC_CONVERGED=1', deploy_content)
        self.assertIn('DNS_PUBLIC_CONVERGED=0', deploy_content)
        self.assertIn('FORCE_INTERNAL_TLS_BOOTSTRAP=0', deploy_content)
        self.assertIn('headscale_tls_bootstrap_fallback_internal', deploy_content)
        self.assertIn(
            'Public Headscale DNS has not converged; forcing headscale_tls_mode=internal for this Ansible run so bootstrap can complete.',
            deploy_content,
        )
        self.assertIn(
            'Destructive redeploy forces headscale_tls_mode=internal for this Ansible run until the new control plane and peers finish tailnet bootstrap.',
            deploy_content,
        )
        self.assertIn('if [[ "${FORCE_INTERNAL_TLS_BOOTSTRAP}" == "1" ]]; then', deploy_content)
        self.assertIn(
            'Temporarily fall back to internal TLS when public Headscale DNS is not converged for this run',
            playbook_content,
        )
        self.assertIn('headscale_tls_bootstrap_fallback_internal | default(false) | bool', playbook_content)

        auto_index = playbook_content.index('    - name: Auto-enable letsencrypt when base_domain provides a real DNS name\n')
        fallback_index = playbook_content.index(
            '    - name: Temporarily fall back to internal TLS when public Headscale DNS is not converged for this run\n'
        )
        self.assertLess(auto_index, fallback_index)


if __name__ == "__main__":
    unittest.main()