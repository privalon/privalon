import json
import os
import subprocess
import tempfile
import unittest
import asyncio
from datetime import datetime, timezone
from pathlib import Path

from ui.lib import job_runner
from fastapi import HTTPException
from ui import server


class JobRegistryRecoveryTests(unittest.TestCase):
    def setUp(self):
        self._old_repo_root = job_runner.REPO_ROOT
        self.tempdir = tempfile.TemporaryDirectory()
        job_runner.REPO_ROOT = Path(self.tempdir.name)

    def tearDown(self):
        job_runner.REPO_ROOT = self._old_repo_root
        self.tempdir.cleanup()

    def _write_job_meta(self, env, name, payload, lines=None):
        logs_dir = job_runner.REPO_ROOT / 'environments' / env / '.ui-logs'
        logs_dir.mkdir(parents=True, exist_ok=True)
        meta_file = logs_dir / f'{name}.json'
        log_file = logs_dir / f'{name}.log'
        meta_file.write_text(json.dumps(payload), encoding='utf-8')
        log_file.write_text(''.join(f'{line}\n' for line in (lines or [])), encoding='utf-8')
        return meta_file, log_file

    def test_rebuild_from_disk_imports_terminal_job(self):
        payload = {
            'job_id': 'test-20260320-010203-terminal',
            'env': 'test',
            'scope': 'full',
            'extra_args': ['--no-destroy'],
            'source': 'terminal',
            'pid': None,
            'start_time': '2026-03-20T01:02:03+0000',
            'end_time': '2026-03-20T01:03:03+0000',
            'exit_code': 0,
            'status': 'done',
        }
        self._write_job_meta('test', payload['job_id'], payload, lines=['alpha', 'beta'])

        registry = job_runner.JobRegistry()
        registry.rebuild_from_disk()

        job = registry.get(payload['job_id'])
        self.assertIsNotNone(job)
        self.assertEqual(job.source, 'terminal')
        self.assertEqual(job.status, 'done')
        self.assertEqual(job._total_lines, 2)

    def test_rebuild_from_disk_marks_stale_running_terminal_job_interrupted(self):
        proc = subprocess.Popen(['sleep', '0.1'])
        proc.wait(timeout=2)
        payload = {
            'job_id': 'test-20260320-010203-terminal',
            'env': 'test',
            'scope': 'full',
            'extra_args': [],
            'source': 'terminal',
            'pid': proc.pid,
            'start_time': '2026-03-20T01:02:03+0000',
            'end_time': None,
            'exit_code': None,
            'status': 'running',
        }
        meta_file, _ = self._write_job_meta('test', payload['job_id'], payload, lines=['alpha'])

        registry = job_runner.JobRegistry()
        registry.rebuild_from_disk()

        job = registry.get(payload['job_id'])
        self.assertEqual(job.status, 'interrupted')
        self.assertEqual(job.exit_code, -1)

        saved = json.loads(meta_file.read_text(encoding='utf-8'))
        self.assertEqual(saved['status'], 'interrupted')
        self.assertEqual(saved['exit_code'], -1)
        self.assertIsNotNone(saved['end_time'])

    def test_rebuild_from_disk_keeps_live_running_terminal_job_running(self):
        proc = subprocess.Popen(['sleep', '5'])
        try:
            payload = {
                'job_id': 'test-20260320-010203-terminal',
                'env': 'test',
                'scope': 'full',
                'extra_args': [],
                'source': 'terminal',
                'pid': proc.pid,
                'start_time': '2026-03-20T01:02:03+0000',
                'end_time': None,
                'exit_code': None,
                'status': 'running',
            }
            self._write_job_meta('test', payload['job_id'], payload, lines=['alpha'])

            registry = job_runner.JobRegistry()
            registry.rebuild_from_disk()

            job = registry.get(payload['job_id'])
            self.assertEqual(job.status, 'running')
            self.assertEqual(job.pid, proc.pid)
        finally:
            proc.terminate()
            proc.wait(timeout=2)


class JobArgumentValidationTests(unittest.TestCase):
    def test_rejects_conflicting_fresh_tailnet_and_no_destroy(self):
        with self.assertRaises(HTTPException) as ctx:
            server._validate_job_args('full', ['--no-destroy', '--fresh-tailnet'])

        self.assertEqual(ctx.exception.status_code, 422)
        self.assertIn('--fresh-tailnet', str(ctx.exception.detail))

    def test_rejects_fresh_tailnet_for_join_local_scope(self):
        with self.assertRaises(HTTPException) as ctx:
            server._validate_job_args('join-local', ['--fresh-tailnet'])

        self.assertEqual(ctx.exception.status_code, 422)
        self.assertIn('only supported with full, gateway, or control scopes', str(ctx.exception.detail))


class JobProgressLoggingTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self._old_repo_root = job_runner.REPO_ROOT
        self._old_env_root = os.environ.get("BLUEPRINT_ENVIRONMENTS_DIR")
        self._saved_jobs = dict(job_runner.registry._jobs)
        self._saved_server_jobs = dict(server.registry._jobs)
        self.tempdir = tempfile.TemporaryDirectory()
        repo_root = Path(self.tempdir.name)
        job_runner.REPO_ROOT = repo_root
        os.environ.pop("BLUEPRINT_ENVIRONMENTS_DIR", None)

        env_dir = repo_root / "environments" / "test"
        env_dir.mkdir(parents=True, exist_ok=True)
        (env_dir / "terraform.tfvars").write_text("tfgrid_mnemonic = \"dummy words here\"\n", encoding="utf-8")
        job_runner.registry._jobs.clear()
        server.registry._jobs.clear()

    def tearDown(self):
        job_runner.registry._jobs.clear()
        job_runner.registry._jobs.update(self._saved_jobs)
        server.registry._jobs.clear()
        server.registry._jobs.update(self._saved_server_jobs)
        job_runner.REPO_ROOT = self._old_repo_root
        if self._old_env_root is None:
            os.environ.pop("BLUEPRINT_ENVIRONMENTS_DIR", None)
        else:
            os.environ["BLUEPRINT_ENVIRONMENTS_DIR"] = self._old_env_root
        self.tempdir.cleanup()

    async def test_progress_log_route_appends_ui_snapshot_to_job_log(self):
        job = job_runner.create_job("test", "full", [], source="ui", job_id="test-20260404-010203")
        server.registry.register(job)

        payload = server.ProgressLogRequest(
            event_type="step-start",
            event_ts_ms=1712192523000,
            pct=42,
            label="Run Ansible - Role A",
            eta_text="ETA 3m 12s",
            eta_seconds=192,
            has_plan=True,
            units_done=21,
            units_total=50,
            elapsed_ms=87000,
            current_step_id="ansible-main",
            current_play="Role A",
            event_payload={"step_id": "ansible-main"},
        )

        response = await server.append_job_progress_log(job.job_id, payload)

        self.assertEqual(response, {"ok": True})
        log_text = job.log_file.read_text(encoding="utf-8")
        self.assertIn("[bp-progress-ui] ", log_text)
        record = json.loads(log_text.strip().split("[bp-progress-ui] ", 1)[1])
        self.assertEqual(record["event_type"], "step-start")
        self.assertEqual(record["pct"], 42)
        self.assertEqual(record["current_step_id"], "ansible-main")
        self.assertEqual(record["event_payload"], {"step_id": "ansible-main"})
        self.assertIn("server_ts_ms", record)

    async def test_progress_log_route_rejects_non_running_jobs(self):
        job = job_runner.create_job("test", "full", [], source="ui", job_id="test-20260404-010204")
        job.status = "done"
        job.end_time = datetime.now(timezone.utc).isoformat()
        job.exit_code = 0
        job.save_meta()
        server.registry.register(job)

        with self.assertRaises(HTTPException) as ctx:
            await server.append_job_progress_log(
                job.job_id,
                server.ProgressLogRequest(
                    event_type="step-done",
                    event_ts_ms=1712192524000,
                    pct=100,
                    label="Complete",
                    eta_text="Done",
                    has_plan=True,
                    units_done=50,
                    units_total=50,
                ),
            )

        self.assertEqual(ctx.exception.status_code, 409)


class JobRunnerLaunchTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self._old_repo_root = job_runner.REPO_ROOT
        self._old_env_root = os.environ.get("BLUEPRINT_ENVIRONMENTS_DIR")
        self.tempdir = tempfile.TemporaryDirectory()
        repo_root = Path(self.tempdir.name)
        job_runner.REPO_ROOT = repo_root
        os.environ.pop("BLUEPRINT_ENVIRONMENTS_DIR", None)

        scripts_dir = repo_root / "scripts"
        env_dir = repo_root / "environments" / "test"
        scripts_dir.mkdir(parents=True, exist_ok=True)
        env_dir.mkdir(parents=True, exist_ok=True)
        (env_dir / "terraform.tfvars").write_text("tfgrid_mnemonic = \"dummy words here\"\n", encoding="utf-8")

        self.deploy_script = scripts_dir / "deploy.sh"

    def tearDown(self):
        job_runner.REPO_ROOT = self._old_repo_root
        if self._old_env_root is None:
            os.environ.pop("BLUEPRINT_ENVIRONMENTS_DIR", None)
        else:
            os.environ["BLUEPRINT_ENVIRONMENTS_DIR"] = self._old_env_root
        self.tempdir.cleanup()

    async def _wait_for_job(self, job):
        for _ in range(200):
            if job.status != "running":
                return
            await asyncio.sleep(0.02)
        self.fail("job did not finish in time")

    async def test_start_job_uses_snapshot_so_late_repo_edits_do_not_change_running_job(self):
        self.deploy_script.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "echo start:$1\n"
            "sleep 0.2\n"
            "echo done\n",
            encoding="utf-8",
        )
        self.deploy_script.chmod(0o755)

        job = await job_runner.start_job("test", "full", ["--no-destroy"])
        await asyncio.sleep(0.05)

        self.deploy_script.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "echo mutated\n"
            "ogress_step_start \"boom\"\n",
            encoding="utf-8",
        )
        self.deploy_script.chmod(0o755)

        await self._wait_for_job(job)

        self.assertEqual(job.exit_code, 0)
        log_text = job.log_file.read_text(encoding="utf-8")
        self.assertIn("start:full", log_text)
        self.assertIn("done", log_text)
        self.assertNotIn("mutated", log_text)

        snapshot_path = job.log_dir / f"{job.job_id}.deploy.sh"
        self.assertTrue(snapshot_path.exists())
        self.assertIn("sleep 0.2", snapshot_path.read_text(encoding="utf-8"))

    async def test_start_job_rejects_unknown_progress_helper_before_launch(self):
        self.deploy_script.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "echo start\n"
            "ogress_step_start \"boom\"\n",
            encoding="utf-8",
        )
        self.deploy_script.chmod(0o755)

        job = await job_runner.start_job("test", "full", [])
        await self._wait_for_job(job)

        self.assertEqual(job.exit_code, 127)
        self.assertEqual(job.status, "failed")
        log_text = job.log_file.read_text(encoding="utf-8")
        self.assertIn("Deploy preflight failed", log_text)
        self.assertIn("ogress_step_start", log_text)

    async def test_start_job_sets_repo_root_for_snapshot_execution(self):
        self.deploy_script.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "SCRIPT_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n"
            "REPO_ROOT=\"${BLUEPRINT_REPO_ROOT:-$(cd \"${SCRIPT_DIR}/..\" && pwd)}\"\n"
            "EXPECTED_ROOT=\"$(pwd)\"\n"
            "[[ \"${REPO_ROOT}\" == \"${EXPECTED_ROOT}\" ]]\n"
            "echo repo-root-ok\n",
            encoding="utf-8",
        )
        self.deploy_script.chmod(0o755)

        job = await job_runner.start_job("test", "full", [])
        await self._wait_for_job(job)

        self.assertEqual(job.exit_code, 0)
        log_text = job.log_file.read_text(encoding="utf-8")
        self.assertIn("repo-root-ok", log_text)


if __name__ == '__main__':
    unittest.main()