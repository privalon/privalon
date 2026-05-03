"""Test that deploy.sh calls phases in the correct order.

Static-grep regression guard for invariant I2: the literal call order must be
phase1_bootstrap_and_join → controller_join_tailnet → phase1_harden →
phase1_gate → phase2.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEPLOY_SCRIPT = REPO_ROOT / "scripts" / "deploy.sh"


class TestDeployPhaseOrder(unittest.TestCase):

    def test_phase_order_in_scope_full(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")

        # Extract scope_full function body
        match = re.search(r'^scope_full\(\)\s*\{', content, re.MULTILINE)
        self.assertIsNotNone(match, "scope_full function not found")

        # Find the phase calls in order
        phase_tokens = [
            "PLAYBOOK_PHASE1_BOOTSTRAP",
            "controller_join_tailnet",
            "PLAYBOOK_PHASE1_HARDEN",
            "PLAYBOOK_PHASE1_GATE",
            "PLAYBOOK_PHASE2",
        ]

        scope_start = match.start()
        last_pos = scope_start
        for token in phase_tokens:
            pos = content.find(token, last_pos)
            self.assertGreater(
                pos, last_pos,
                f"Expected '{token}' after position {last_pos} in scope_full, "
                f"but found at {pos} (or not found at all)",
            )
            last_pos = pos

    def test_phase1_harden_uses_operational_mode(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")
        # Find the ansible_run_phase call for PLAYBOOK_PHASE1_HARDEN
        matches = re.findall(
            r'ansible_run_phase\s+"\$\{PLAYBOOK_PHASE1_HARDEN\}"\s+"(\w+)"',
            content,
        )
        self.assertTrue(len(matches) > 0, "No ansible_run_phase call for PHASE1_HARDEN found")
        for mode in matches:
            self.assertEqual(mode, "operational", f"PHASE1_HARDEN should use operational mode, got {mode}")

    def test_phase2_uses_operational_mode(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")
        matches = re.findall(
            r'ansible_run_phase\s+"\$\{PLAYBOOK_PHASE2\}"\s+"(\w+)"',
            content,
        )
        self.assertTrue(len(matches) > 0, "No ansible_run_phase call for PHASE2 found")
        for mode in matches:
            self.assertEqual(mode, "operational", f"PHASE2 should use operational mode, got {mode}")

    def test_phase1_bootstrap_uses_bootstrap_mode(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")
        matches = re.findall(
            r'ansible_run_phase\s+"\$\{PLAYBOOK_PHASE1_BOOTSTRAP\}"\s+"(\w+)"',
            content,
        )
        self.assertTrue(len(matches) > 0, "No ansible_run_phase call for PHASE1_BOOTSTRAP found")
        for mode in matches:
            self.assertEqual(mode, "bootstrap", f"PHASE1_BOOTSTRAP should use bootstrap mode, got {mode}")

    def test_no_legacy_flags_in_parser(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")
        legacy_flags = [
            "--fresh-tailnet",
            "--join-local",
            "--rejoin-local",
            "--allow-ssh-from",
            "--allow-ssh-from-my-ip",
            "--keep-ssh-allowlist",
        ]
        # Check the argument parser section (the while/case block in main)
        parser_match = re.search(r'while \[\[.*\$# -gt 0.*\]\]', content)
        self.assertIsNotNone(parser_match, "Argument parser not found")
        parser_section = content[parser_match.start():]
        # Find the end of the case/esac
        esac_pos = parser_section.find("esac")
        self.assertGreater(esac_pos, 0, "esac not found in parser section")
        parser_text = parser_section[:esac_pos]

        for flag in legacy_flags:
            self.assertNotIn(
                flag, parser_text,
                f"Legacy flag '{flag}' should not appear in the argument parser",
            )

    def test_no_legacy_env_vars(self):
        content = DEPLOY_SCRIPT.read_text(encoding="utf-8")
        # These should not appear as variable assignments or exports
        legacy_vars = [
            "IGNORE_TAILSCALE_HOSTS",
            "FRESH_TAILNET",
        ]
        for var in legacy_vars:
            # Allow in comments, but not as active code assignments
            assignments = re.findall(
                rf'^[^#]*\b{var}\s*=', content, re.MULTILINE
            )
            self.assertEqual(
                len(assignments), 0,
                f"Legacy variable '{var}' should not be assigned in deploy.sh: {assignments}",
            )


if __name__ == "__main__":
    unittest.main()
