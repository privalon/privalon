import unittest
from pathlib import Path

from ui.lib.deploy_progress import PlanContext, build_plan, build_step_blueprint, count_listed_tasks


class DeployProgressPlanTests(unittest.TestCase):
    def test_count_listed_tasks_matches_ansible_list_tasks_output_shape(self):
        output = """
playbook: playbooks/site.yml

  play #1 (all): Base OS configuration  TAGS: [common]
    tasks:
      Install packages  TAGS: [common]
      Configure service TAGS: [common]

  play #2 (control): Headscale control plane    TAGS: [headscale]
    tasks:
      Render config TAGS: [headscale]
"""

        self.assertEqual(count_listed_tasks(output), 5)

    def test_full_destroy_join_local_plan_shapes_expected_steps(self):
        ctx = PlanContext(
            repo_root=Path("/tmp/repo"),
            env_name="test",
            scope="full",
            destroy_first=True,
            join_local=True,
        )

        steps = build_step_blueprint(ctx)

        self.assertEqual(
            [step.step_id for step in steps],
            [
                "tf-init",
                "pre-destroy-backup",
                "terraform-destroy",
                "deployment-tag",
                "terraform-apply",
                "refresh-inventory",
                "data-migrations",
                "clear-host-keys",
                "dns-setup",
                "wait-ssh",
                "ansible-bootstrap",
                "join-local",
                "ansible-main",
                "recovery-refresh",
                "deployment-summary",
            ],
        )

    def test_build_plan_resolves_ansible_weights_via_counter(self):
        ctx = PlanContext(
            repo_root=Path("/tmp/repo"),
            env_name="test",
            scope="gateway",
            destroy_first=False,
            join_local=True,
        )

        counts = {
            "ansible-main": 37,
        }

        def fake_counter(_ctx, step):
            return counts[step.step_id]

        plan = build_plan(ctx, task_counter=fake_counter)
        weights = {step["id"]: step["weight"] for step in plan["steps"]}

        self.assertEqual(weights["ansible-main"], 37)
        self.assertEqual(plan["units_total"], sum(weights.values()))
        self.assertIn("join-local", weights)

    def test_dns_plan_stays_script_only(self):
        ctx = PlanContext(
            repo_root=Path("/tmp/repo"),
            env_name="test",
            scope="dns",
        )

        plan = build_plan(ctx, task_counter=lambda *_: 999)

        self.assertEqual(plan["steps"], [{"id": "dns-setup", "label": "Update DNS", "kind": "script", "weight": 2}])
        self.assertEqual(plan["units_total"], 2)

    def test_control_plan_includes_dns_step_when_control_scope_updates_public_records(self):
        ctx = PlanContext(
            repo_root=Path("/tmp/repo"),
            env_name="test",
            scope="control",
        )

        steps = build_step_blueprint(ctx)

        self.assertEqual(
            [step.step_id for step in steps],
            [
                "tf-init",
                "deployment-tag",
                "terraform-apply",
                "refresh-inventory",
                "data-migrations",
                "clear-host-keys",
                "dns-setup",
                "wait-ssh",
                "ansible-main",
                "recovery-refresh",
                "deployment-summary",
            ],
        )


if __name__ == "__main__":
    unittest.main()
