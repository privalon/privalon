import json
import tempfile
import unittest
from pathlib import Path

from ui.lib.timing import build_timing_profile, refresh_timing_profile


class TimingProfileTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.env_root = Path(self.tempdir.name) / "environments"
        self.logs_dir = self.env_root / "test" / ".ui-logs"
        self.logs_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.tempdir.cleanup()

    def _write_job(self, job_id, *, scope, start_time, end_time, status, log_lines):
        meta = {
            "job_id": job_id,
            "env": "test",
            "scope": scope,
            "extra_args": [],
            "source": "ui",
            "start_time": start_time,
            "end_time": end_time,
            "exit_code": 0 if status == "done" else 1,
            "status": status,
        }
        (self.logs_dir / f"{job_id}.json").write_text(json.dumps(meta), encoding="utf-8")
        (self.logs_dir / f"{job_id}.log").write_text("\n".join(log_lines) + "\n", encoding="utf-8")

    def test_build_timing_profile_uses_successful_logs_and_ema(self):
        self._write_job(
            "test-20260410-080000",
            scope="full",
            start_time="2026-04-10T08:00:00+00:00",
            end_time="2026-04-10T08:10:00+00:00",
            status="done",
            log_lines=[
                '[bp-progress] {"type":"plan","scope":"full","env":"test","steps":[{"id":"tf-init","label":"Initialize Terraform","kind":"script","weight":1},{"id":"ansible-main","label":"Run Ansible","kind":"ansible","weight":3}]}',
                '[bp-progress] {"type":"ansible-task","step_id":"ansible-main"}',
                '[bp-progress] {"type":"ansible-task","step_id":"ansible-main"}',
                '[bp-progress] {"type":"ansible-task","step_id":"ansible-main"}',
                '[bp-progress] {"type":"step-done","step_id":"tf-init","step_elapsed_ms":1000}',
                '[bp-progress] {"type":"step-done","step_id":"ansible-main","step_elapsed_ms":9000}',
            ],
        )
        self._write_job(
            "test-20260410-090000",
            scope="full",
            start_time="2026-04-10T09:00:00+00:00",
            end_time="2026-04-10T09:15:00+00:00",
            status="done",
            log_lines=[
                '[bp-progress] {"type":"plan","scope":"full","env":"test","steps":[{"id":"tf-init","label":"Initialize Terraform","kind":"script","weight":1},{"id":"ansible-main","label":"Run Ansible","kind":"ansible","weight":4}]}',
                '[bp-progress] {"type":"ansible-task","step_id":"ansible-main"}',
                '[bp-progress] {"type":"ansible-task","step_id":"ansible-main"}',
                '[bp-progress] {"type":"ansible-task","step_id":"ansible-main"}',
                '[bp-progress] {"type":"ansible-task","step_id":"ansible-main"}',
                '[bp-progress] {"type":"step-done","step_id":"tf-init","step_elapsed_ms":4000}',
                '[bp-progress] {"type":"step-done","step_id":"ansible-main","step_elapsed_ms":20000}',
            ],
        )
        self._write_job(
            "test-20260410-100000",
            scope="full",
            start_time="2026-04-10T10:00:00+00:00",
            end_time="2026-04-10T10:05:00+00:00",
            status="failed",
            log_lines=[
                '[bp-progress] {"type":"plan","scope":"full","env":"test","steps":[{"id":"tf-init","label":"Initialize Terraform","kind":"script","weight":1}]}',
                '[bp-progress] {"type":"step-done","step_id":"tf-init","step_elapsed_ms":99999}',
            ],
        )

        profile = build_timing_profile("test", env_root=self.env_root)

        self.assertEqual(profile["job_count"], 2)
        self.assertEqual(profile["scopes"]["full"]["runs"], 2)

        tf_init = profile["scopes"]["full"]["steps"]["tf-init"]
        ansible = profile["scopes"]["full"]["steps"]["ansible-main"]

        self.assertAlmostEqual(tf_init["avg_ms"], 1900.0)
        self.assertAlmostEqual(ansible["avg_ms"], 12300.0)
        self.assertAlmostEqual(ansible["avg_units"], 3.3)
        self.assertAlmostEqual(ansible["avg_unit_ms"], 3600.0)

        summary = profile["scopes"]["full"]["summary"]
        self.assertAlmostEqual(summary["avg_script_ms_per_weight"], 1900.0)
        self.assertAlmostEqual(summary["avg_ansible_unit_ms"], ansible["avg_unit_ms"])

    def test_refresh_timing_profile_writes_profile_file(self):
        self._write_job(
            "test-20260410-080000",
            scope="gateway",
            start_time="2026-04-10T08:00:00+00:00",
            end_time="2026-04-10T08:01:00+00:00",
            status="done",
            log_lines=[
                '[bp-progress] {"type":"plan","scope":"gateway","env":"test","steps":[{"id":"dns-setup","label":"Update DNS","kind":"script","weight":2}]}',
                '[bp-progress] {"type":"step-done","step_id":"dns-setup","step_elapsed_ms":2500}',
            ],
        )

        profile = refresh_timing_profile("test", env_root=self.env_root)

        target = self.logs_dir / "timing-profile.json"
        self.assertTrue(target.exists())
        persisted = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(
            persisted["scopes"]["gateway"]["steps"]["dns-setup"]["avg_ms"],
            profile["scopes"]["gateway"]["steps"]["dns-setup"]["avg_ms"],
        )


if __name__ == "__main__":
    unittest.main()