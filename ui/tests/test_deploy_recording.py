import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class DeploySelfRecordingTests(unittest.TestCase):
    def test_deploy_sh_records_terminal_run_without_wrapper(self):
        repo_root = Path(__file__).resolve().parents[2]
        tempdir = tempfile.TemporaryDirectory(prefix="deploy-recording-envroot-")
        env_root = Path(tempdir.name)
        env_name = f"ui-self-record-{os.getpid()}"
        env_dir = env_root / env_name
        fake_script = None

        try:
            env_dir.mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text("tfgrid_mnemonic = \"dummy words here\"\n", encoding="utf-8")

            with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as handle:
                handle.write("#!/usr/bin/env bash\n")
                handle.write("echo fake deploy output\n")
                handle.write("exit 0\n")
                fake_script = Path(handle.name)
            fake_script.chmod(0o755)

            env = os.environ.copy()
            env["BLUEPRINT_DEPLOY_INNER_SCRIPT"] = str(fake_script)
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            proc = subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "full",
                    "--env",
                    env_name,
                    "--no-destroy",
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertIn("fake deploy output", proc.stdout)

            logs_dir = env_dir / ".ui-logs"
            meta_files = sorted(logs_dir.glob("*.json"))
            log_files = sorted(logs_dir.glob("*.log"))
            self.assertEqual(len(meta_files), 1)
            self.assertEqual(len(log_files), 1)

            meta = json.loads(meta_files[0].read_text(encoding="utf-8"))
            self.assertEqual(meta["env"], env_name)
            self.assertEqual(meta["scope"], "full")
            self.assertEqual(meta["source"], "terminal")
            self.assertEqual(meta["status"], "done")
            self.assertEqual(meta["exit_code"], 0)
            self.assertEqual(meta["extra_args"], ["--no-destroy"])

            log_text = log_files[0].read_text(encoding="utf-8")
            self.assertIn("fake deploy output", log_text)
        finally:
            if fake_script is not None and fake_script.exists():
                fake_script.unlink()
            tempdir.cleanup()

    def test_deploy_sh_records_fresh_tailnet_flag(self):
        repo_root = Path(__file__).resolve().parents[2]
        tempdir = tempfile.TemporaryDirectory(prefix="deploy-recording-fresh-envroot-")
        env_root = Path(tempdir.name)
        env_name = f"ui-self-record-fresh-{os.getpid()}"
        env_dir = env_root / env_name
        fake_script = None

        try:
            env_dir.mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text("tfgrid_mnemonic = \"dummy words here\"\n", encoding="utf-8")

            with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as handle:
                handle.write("#!/usr/bin/env bash\n")
                handle.write("echo fresh tailnet deploy\n")
                handle.write("exit 0\n")
                fake_script = Path(handle.name)
            fake_script.chmod(0o755)

            env = os.environ.copy()
            env["BLUEPRINT_DEPLOY_INNER_SCRIPT"] = str(fake_script)
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            proc = subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "full",
                    "--env",
                    env_name,
                    "--yes",
                    "--fresh-tailnet",
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            self.assertIn("fresh tailnet deploy", proc.stdout)

            logs_dir = env_dir / ".ui-logs"
            meta_files = sorted(logs_dir.glob("*.json"))
            self.assertEqual(len(meta_files), 1)

            meta = json.loads(meta_files[0].read_text(encoding="utf-8"))
            self.assertEqual(meta["extra_args"], ["--yes", "--fresh-tailnet"])
        finally:
            if fake_script is not None and fake_script.exists():
                fake_script.unlink()
            tempdir.cleanup()


if __name__ == "__main__":
    unittest.main()