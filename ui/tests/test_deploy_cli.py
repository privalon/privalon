import os
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


class DeployCliFreshTailnetTests(unittest.TestCase):
    def test_yes_destroys_when_existing_infrastructure_is_detected(self):
        repo_root = Path(__file__).resolve().parents[2]
        temp_env_root = tempfile.TemporaryDirectory(prefix="deploy-cli-yes-envroot-")
        env_root = Path(temp_env_root.name)
        env_name = f"deploy-cli-yes-{os.getpid()}"
        env_dir = env_root / env_name
        bin_dir = None
        capture_file = None

        try:
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text(
                "tfgrid_network = \"test\"\n"
                "tfgrid_mnemonic = \"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"\n",
                encoding="utf-8",
            )

            tmpdir = Path(tempfile.mkdtemp(prefix="deploy-cli-yes-test-"))
            bin_dir = tmpdir / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            capture_file = tmpdir / "terraform-commands.txt"

            terraform_script = textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail
                printf '%s\n' "$*" >> {capture_file}

                while [[ "${{1:-}}" == -* ]]; do
                  shift || true
                done

                cmd="${{1:-}}"
                shift || true

                case "$cmd" in
                  init)
                    exit 0
                    ;;
                  state)
                    if [[ "${{1:-}}" == "list" ]]; then
                      printf 'grid_deployment.gateway\ngrid_deployment.core\n'
                      exit 0
                    fi
                    ;;
                  destroy)
                    exit 0
                    ;;
                  apply)
                    exit 0
                    ;;
                  output)
                    printf '{{}}\n'
                    exit 0
                    ;;
                esac

                exit 0
                """
            )
            ansible_playbook_script = "#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n"
            ansible_script = "#!/usr/bin/env bash\nexit 0\n"

            for name, content in {
                "terraform": terraform_script,
                "ansible-playbook": ansible_playbook_script,
                "ansible": ansible_script,
            }.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IEXEC)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["BLUEPRINT_DISABLE_UI_RECORDING"] = "1"
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            result = subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "full",
                    "--env",
                    env_name,
                    "--yes",
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            captured = capture_file.read_text(encoding="utf-8")
            self.assertIn("destroy", captured)
            self.assertIn("apply", captured)
        finally:
            temp_env_root.cleanup()
            if bin_dir is not None and bin_dir.parent.exists():
                for path in sorted(bin_dir.parent.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_yes_destroy_times_out_stuck_backup_hook_and_continues(self):
        repo_root = Path(__file__).resolve().parents[2]
        temp_env_root = tempfile.TemporaryDirectory(prefix="deploy-cli-backup-timeout-envroot-")
        env_root = Path(temp_env_root.name)
        env_name = f"deploy-cli-backup-timeout-{os.getpid()}"
        env_dir = env_root / env_name
        bin_dir = None
        capture_file = None

        try:
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text(
                "tfgrid_network = \"test\"\n"
                "tfgrid_mnemonic = \"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"\n",
                encoding="utf-8",
            )

            tmpdir = Path(tempfile.mkdtemp(prefix="deploy-cli-backup-timeout-test-"))
            bin_dir = tmpdir / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            capture_file = tmpdir / "terraform-commands.txt"

            terraform_script = textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail
                printf '%s\n' "$*" >> {capture_file}

                while [[ "${{1:-}}" == -* ]]; do
                  shift || true
                done

                cmd="${{1:-}}"
                shift || true

                case "$cmd" in
                  init)
                    exit 0
                    ;;
                  state)
                    if [[ "${{1:-}}" == "list" ]]; then
                      printf 'grid_deployment.gateway\ngrid_deployment.core\n'
                      exit 0
                    fi
                    ;;
                  destroy)
                    exit 0
                    ;;
                  apply)
                    exit 0
                    ;;
                  output)
                    printf '{{}}\n'
                    exit 0
                    ;;
                esac

                exit 0
                """
            )
            ansible_playbook_script = textwrap.dedent(
                """#!/usr/bin/env bash
                set -euo pipefail
                if [[ " $* " == *" --tags backup "* ]]; then
                  sleep 5
                  exit 1
                fi
                exit 0
                """
            )
            ansible_script = "#!/usr/bin/env bash\nexit 1\n"

            for name, content in {
                "terraform": terraform_script,
                "ansible-playbook": ansible_playbook_script,
                "ansible": ansible_script,
            }.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IEXEC)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["BLUEPRINT_DISABLE_UI_RECORDING"] = "1"
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)
            env["BACKUP_HOOK_TIMEOUT_SECONDS"] = "1"

            started_at = time.monotonic()
            result = subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "full",
                    "--env",
                    env_name,
                    "--yes",
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=15,
            )
            elapsed = time.monotonic() - started_at

            captured = capture_file.read_text(encoding="utf-8")
            self.assertIn("destroy", captured)
            self.assertIn("apply", captured)
            self.assertIn("timed out after 1s", f"{result.stdout}\n{result.stderr}")
            self.assertLess(elapsed, 15.0)
        finally:
            temp_env_root.cleanup()
            if bin_dir is not None and bin_dir.parent.exists():
                for path in sorted(bin_dir.parent.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_fresh_tailnet_passes_identity_reset_extra_vars(self):
        repo_root = Path(__file__).resolve().parents[2]
        temp_env_root = tempfile.TemporaryDirectory(prefix="deploy-cli-envroot-")
        env_root = Path(temp_env_root.name)
        env_name = f"deploy-cli-fresh-{os.getpid()}"
        env_dir = env_root / env_name
        bin_dir = None
        capture_file = None

        try:
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text(
                "tfgrid_network = \"test\"\n"
                "tfgrid_mnemonic = \"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"\n",
                encoding="utf-8",
            )
            (env_dir / "group_vars" / "all.yml").write_text(
                "headscale_restore_database: true\n",
                encoding="utf-8",
            )

            tmpdir = Path(tempfile.mkdtemp(prefix="deploy-cli-test-"))
            bin_dir = tmpdir / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            capture_file = tmpdir / "ansible-playbook-args.txt"

            terraform_script = textwrap.dedent(
                """#!/usr/bin/env bash
                set -euo pipefail
                                while [[ "${1:-}" == -* ]]; do
                                    shift || true
                                done
                                cmd="${1:-}"
                                shift || true
                case "$cmd" in
                  init)
                    exit 0
                    ;;
                  state)
                    if [[ "${1:-}" == "list" ]]; then
                      exit 0
                    fi
                    ;;
                  apply)
                    exit 0
                    ;;
                  output)
                    printf '{}\n'
                    exit 0
                    ;;
                esac
                exit 0
                """
            )
            ansible_playbook_script = textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail
                printf '%s\n' "$@" > {capture_file}
                exit 0
                """
            )
            ansible_script = "#!/usr/bin/env bash\nexit 0\n"

            for name, content in {
                "terraform": terraform_script,
                "ansible-playbook": ansible_playbook_script,
                "ansible": ansible_script,
            }.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IEXEC)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["BLUEPRINT_DISABLE_UI_RECORDING"] = "1"
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "full",
                    "--env",
                    env_name,
                    "--fresh-tailnet",
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            captured = capture_file.read_text(encoding="utf-8")
            self.assertIn('{"headscale_restore_database": false, "tailscale_restore_state": false}', captured)
            self.assertNotIn("backup_restore_enabled=false", captured)
            self.assertLess(
                captured.index(f"@{env_dir / 'group_vars' / 'all.yml'}"),
                captured.index('{"headscale_restore_database": false, "tailscale_restore_state": false}'),
            )
        finally:
            temp_env_root.cleanup()
            if bin_dir is not None and bin_dir.parent.exists():
                for path in sorted(bin_dir.parent.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_no_restore_passes_boolean_restore_disable_extra_var(self):
        repo_root = Path(__file__).resolve().parents[2]
        temp_env_root = tempfile.TemporaryDirectory(prefix="deploy-cli-no-restore-envroot-")
        env_root = Path(temp_env_root.name)
        env_name = f"deploy-cli-no-restore-{os.getpid()}"
        env_dir = env_root / env_name
        bin_dir = None
        capture_file = None

        try:
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text(
                "tfgrid_network = \"test\"\n"
                "tfgrid_mnemonic = \"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"\n",
                encoding="utf-8",
            )

            tmpdir = Path(tempfile.mkdtemp(prefix="deploy-cli-no-restore-test-"))
            bin_dir = tmpdir / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            capture_file = tmpdir / "ansible-playbook-args.txt"

            terraform_script = textwrap.dedent(
                """#!/usr/bin/env bash
                set -euo pipefail
                                while [[ "${1:-}" == -* ]]; do
                                    shift || true
                                done
                                cmd="${1:-}"
                                shift || true
                case "$cmd" in
                  init)
                    exit 0
                    ;;
                  state)
                    if [[ "${1:-}" == "list" ]]; then
                      exit 0
                    fi
                    ;;
                  apply)
                    exit 0
                    ;;
                  output)
                    printf '{}\n'
                    exit 0
                    ;;
                esac
                exit 0
                """
            )
            ansible_playbook_script = textwrap.dedent(
                f"""#!/usr/bin/env bash
                set -euo pipefail
                printf '%s\n' "$@" > {capture_file}
                exit 0
                """
            )
            ansible_script = "#!/usr/bin/env bash\nexit 0\n"

            for name, content in {
                "terraform": terraform_script,
                "ansible-playbook": ansible_playbook_script,
                "ansible": ansible_script,
            }.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IEXEC)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["BLUEPRINT_DISABLE_UI_RECORDING"] = "1"
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "full",
                    "--env",
                    env_name,
                    "--no-restore",
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            captured = capture_file.read_text(encoding="utf-8")
            self.assertIn('{"backup_restore_enabled": false}', captured)
            self.assertNotIn("backup_restore_enabled=false", captured)
        finally:
            temp_env_root.cleanup()
            if bin_dir is not None and bin_dir.parent.exists():
                for path in sorted(bin_dir.parent.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_fresh_tailnet_summary_includes_client_reset_steps(self):
        repo_root = Path(__file__).resolve().parents[2]

        with tempfile.TemporaryDirectory(prefix="deploy-summary-test-") as tempdir_name:
            tempdir = Path(tempdir_name)
            env_dir = tempdir / "environments" / "summary"
            inventory_dir = env_dir / "inventory"
            group_vars_dir = env_dir / "group_vars"
            inventory_dir.mkdir(parents=True, exist_ok=True)
            group_vars_dir.mkdir(parents=True, exist_ok=True)

            (inventory_dir / "terraform-outputs.json").write_text(
                '{"control_public_ip": {"value": "203.0.113.10"}}\n',
                encoding="utf-8",
            )
            (inventory_dir / "headscale-authkeys.json").write_text(
                '{"authkeys": {"client": "tskey-client-123"}}\n',
                encoding="utf-8",
            )
            (inventory_dir / "tailscale-ips.json").write_text(
                '{"control-vm": "100.64.0.2", "monitoring-vm": "100.64.0.3"}\n',
                encoding="utf-8",
            )
            (group_vars_dir / "all.yml").write_text(
                "base_domain: example.com\n"
                "headscale_subdomain: headscale\n"
                "headscale_magic_dns_base_domain: in.example.com\n",
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["INVENTORY_JSON"] = str(inventory_dir / "terraform-outputs.json")
            env["DEPLOY_FRESH_TAILNET"] = "1"
            env["SERVICES_ADMIN_PASSWORD"] = "dummy-password"
            env["NO_COLOR"] = "1"

            proc = subprocess.run(
                [str(repo_root / "scripts" / "helpers" / "deployment-summary.sh")],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            output = proc.stdout
            self.assertIn("Reset stale client state before rejoining", output)
            self.assertIn("tailscale down", output)
            self.assertIn("./scripts/deploy.sh join-local --env summary --rejoin-local", output)
            self.assertIn("SAFE_HOSTNAME=testmac", output)
            self.assertIn("tailscale logout", output)
            # Command wraps with backslash continuation; check flags independently
            self.assertIn("--accept-routes --reset --force-reauth", output)
            self.assertIn("--hostname", output)
            self.assertIn("${SAFE_HOSTNAME}", output)
            self.assertIn("sudo dscacheutil -flushcache", output)
            self.assertIn("mDNSResponder", output)
            self.assertIn("dig @100.100.100.100 +short grafana.in.example.com", output)

    def test_join_local_sanitizes_hostname_before_tailscale_up(self):
        repo_root = Path(__file__).resolve().parents[2]
        temp_env_root = tempfile.TemporaryDirectory(prefix="join-local-envroot-")
        env_root = Path(temp_env_root.name)
        env_name = f"join-local-{os.getpid()}"
        env_dir = env_root / env_name
        bin_dir = None
        capture_file = None

        try:
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text(
                "tfgrid_network = \"test\"\n"
                "tfgrid_mnemonic = \"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"\n",
                encoding="utf-8",
            )
            (env_dir / "inventory" / "headscale-authkeys.json").write_text(
                '{"headscale_url": "https://headscale.example.com", "authkeys": {"client": "tskey-client-123"}}\n',
                encoding="utf-8",
            )

            tmpdir = Path(tempfile.mkdtemp(prefix="join-local-test-"))
            bin_dir = tmpdir / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            capture_file = tmpdir / "tailscale-up-args.txt"

            scripts = {
                "terraform": "#!/usr/bin/env bash\nexit 0\n",
                "ansible-playbook": "#!/usr/bin/env bash\nexit 0\n",
                "ansible": "#!/usr/bin/env bash\nexit 0\n",
                "hostname": "#!/usr/bin/env bash\necho \"Nick's MacBook Pro\"\n",
                "sudo": "#!/usr/bin/env bash\nshift 0\nexec \"$@\"\n",
                "tailscale": textwrap.dedent(
                    f"""#!/usr/bin/env bash
                    set -euo pipefail
                    cmd="${{1:-}}"
                    shift || true
                    case "$cmd" in
                      status)
                        printf '{{"BackendState":"Stopped","TailscaleIPs":[]}}\n'
                        ;;
                      down)
                        exit 0
                        ;;
                      up)
                        printf '%s\n' "$@" > {capture_file}
                        exit 0
                        ;;
                      ip)
                        printf '100.64.0.10\n'
                        ;;
                    esac
                    exit 0
                    """
                ),
            }

            for name, content in scripts.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IEXEC)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["BLUEPRINT_DISABLE_UI_RECORDING"] = "1"
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "join-local",
                    "--env",
                    env_name,
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            captured = capture_file.read_text(encoding="utf-8")
            self.assertIn("--hostname", captured)
            self.assertIn("nick-s-macbook-pro", captured)
            self.assertNotIn("Nick's MacBook Pro", captured)
        finally:
            temp_env_root.cleanup()
            if bin_dir is not None and bin_dir.parent.exists():
                for path in sorted(bin_dir.parent.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_rejoin_local_deletes_stale_invalid_self_hostname(self):
        repo_root = Path(__file__).resolve().parents[2]
        temp_env_root = tempfile.TemporaryDirectory(prefix="rejoin-local-envroot-")
        env_root = Path(temp_env_root.name)
        env_name = f"rejoin-local-{os.getpid()}"
        env_dir = env_root / env_name
        bin_dir = None
        capture_up_file = None
        capture_delete_file = None

        try:
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text(
                "tfgrid_network = \"test\"\n"
                "tfgrid_mnemonic = \"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"\n",
                encoding="utf-8",
            )
            (env_dir / "inventory" / "headscale-authkeys.json").write_text(
                '{"headscale_url": "https://headscale.example.com", "authkeys": {"client": "tskey-client-123"}}\n',
                encoding="utf-8",
            )
            (env_dir / "inventory" / "terraform-outputs.json").write_text(
                '{"control_public_ip": {"value": "203.0.113.10"}}\n',
                encoding="utf-8",
            )

            tmpdir = Path(tempfile.mkdtemp(prefix="rejoin-local-test-"))
            bin_dir = tmpdir / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            capture_up_file = tmpdir / "tailscale-up-args.txt"
            capture_delete_file = tmpdir / "headscale-delete-args.txt"

            scripts = {
                "terraform": "#!/usr/bin/env bash\nexit 0\n",
                "ansible-playbook": "#!/usr/bin/env bash\nexit 0\n",
                "ansible": "#!/usr/bin/env bash\nexit 0\n",
                "hostname": "#!/usr/bin/env bash\necho \"Mykolas-MacBook-Air\"\n",
                "sudo": "#!/usr/bin/env bash\nshift 0\nexec \"$@\"\n",
                "ssh": textwrap.dedent(
                    f"""#!/usr/bin/env bash
                    set -euo pipefail
                    args="$*"
                    if [[ "$args" == *"nodes list --output json"* ]]; then
                      printf '[{{"id":42,"name":"invalid-diuqm4jr","given_name":"invalid-diuqm4jr"}}]\n'
                      exit 0
                    fi
                    if [[ "$args" == *"nodes delete --identifier 42 --force"* ]]; then
                      printf '%s\n' "$args" >> {capture_delete_file}
                      exit 0
                    fi
                    exit 0
                    """
                ),
                                "tailscale": textwrap.dedent(
                                        """#!/usr/bin/env bash
                                        set -euo pipefail
                                        cmd="${1:-}"
                                        shift || true
                                        case "$cmd" in
                                            status)
                                                printf '{"BackendState":"Running","Self":{"HostName":"invalid-diuqm4jr","TailscaleIPs":["100.64.0.10"],"Active":true,"InMagicSock":true,"InEngine":true},"TailscaleIPs":["100.64.0.10"]}\n'
                                                ;;
                                            logout)
                                                exit 0
                                                ;;
                                            down)
                                                exit 0
                                                ;;
                                            up)
                                                printf '%s\n' "$@" > __CAPTURE_UP_FILE__
                                                exit 0
                                                ;;
                                            ip)
                                                printf '100.64.0.10\n'
                                                ;;
                                        esac
                                        exit 0
                                        """.replace("__CAPTURE_UP_FILE__", str(capture_up_file))
                                ),
            }

            for name, content in scripts.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IEXEC)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["BLUEPRINT_DISABLE_UI_RECORDING"] = "1"
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "join-local",
                    "--env",
                    env_name,
                    "--rejoin-local",
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            deleted = capture_delete_file.read_text(encoding="utf-8")
            captured = capture_up_file.read_text(encoding="utf-8")
            self.assertIn("nodes delete --identifier 42 --force", deleted)
            self.assertIn("--hostname", captured)
            self.assertIn("mykolas-macbook-air", captured)
            self.assertIn("--force-reauth", captured)
        finally:
            temp_env_root.cleanup()
            if bin_dir is not None and bin_dir.parent.exists():
                for path in sorted(bin_dir.parent.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_join_local_fails_fast_on_tailscale_client_daemon_version_skew(self):
        repo_root = Path(__file__).resolve().parents[2]
        temp_env_root = tempfile.TemporaryDirectory(prefix="join-local-version-skew-envroot-")
        env_root = Path(temp_env_root.name)
        env_name = f"join-local-version-skew-{os.getpid()}"
        env_dir = env_root / env_name
        bin_dir = None

        try:
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text(
                "tfgrid_network = \"test\"\n"
                "tfgrid_mnemonic = \"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"\n",
                encoding="utf-8",
            )
            (env_dir / "inventory" / "headscale-authkeys.json").write_text(
                '{"headscale_url": "https://headscale.example.com", "authkeys": {"client": "tskey-client-123"}}\n',
                encoding="utf-8",
            )

            tmpdir = Path(tempfile.mkdtemp(prefix="join-local-version-skew-test-"))
            bin_dir = tmpdir / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)

            scripts = {
                "terraform": "#!/usr/bin/env bash\nexit 0\n",
                "ansible-playbook": "#!/usr/bin/env bash\nexit 0\n",
                "ansible": "#!/usr/bin/env bash\nexit 0\n",
                "hostname": "#!/usr/bin/env bash\necho \"Mykolas-MacBook-Air\"\n",
                "uname": "#!/usr/bin/env bash\necho Darwin\n",
                "open": "#!/usr/bin/env bash\nexit 0\n",
                "sudo": "#!/usr/bin/env bash\nshift 0\nexec \"$@\"\n",
                "tailscale": textwrap.dedent(
                    """#!/usr/bin/env bash
                    set -euo pipefail
                    cmd="${1:-}"
                    shift || true
                    case "$cmd" in
                      version)
                        cat <<'EOF'
1.94.2
  tailscale commit: 2de4d317a8c2595904f1563ebd98fdcf843da275
  long version: 1.94.2-t2de4d317a
  go version: go1.26.0
Warning: client version "1.94.2-t2de4d317a" != tailscaled server version "1.96.5-t4ee448d3a-g74ffbefc2"
EOF
                        ;;
                      status)
                        printf '{"BackendState":"Stopped","TailscaleIPs":[]}\n'
                        ;;
                      down)
                        exit 0
                        ;;
                      up)
                        echo "tailscale up should not run when versions differ" >&2
                        exit 99
                        ;;
                      ip)
                        exit 0
                        ;;
                    esac
                    exit 0
                    """
                ),
            }

            for name, content in scripts.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IEXEC)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["BLUEPRINT_DISABLE_UI_RECORDING"] = "1"
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            proc = subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "join-local",
                    "--env",
                    env_name,
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Local Tailscale CLI and daemon versions do not match", proc.stderr)
            self.assertIn("Homebrew CLI and Tailscale.app", proc.stderr)
            self.assertNotIn("tailscale up should not run", proc.stderr)
        finally:
            temp_env_root.cleanup()
            if bin_dir is not None and bin_dir.parent.exists():
                for path in sorted(bin_dir.parent.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_join_local_trusts_headscale_ca_via_macos_system_keychain(self):
        repo_root = Path(__file__).resolve().parents[2]
        temp_env_root = tempfile.TemporaryDirectory(prefix="join-local-macos-ca-envroot-")
        env_root = Path(temp_env_root.name)
        env_name = f"join-local-macos-ca-{os.getpid()}"
        env_dir = env_root / env_name
        bin_dir = None
        capture_security_file = None
        capture_up_file = None

        try:
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            (env_dir / "terraform.tfvars").write_text(
                "tfgrid_network = \"test\"\n"
                "tfgrid_mnemonic = \"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\"\n",
                encoding="utf-8",
            )
            (env_dir / "inventory" / "headscale-authkeys.json").write_text(
                '{"headscale_url": "https://headscale.example.com", "authkeys": {"client": "tskey-client-123"}}\n',
                encoding="utf-8",
            )
            (env_dir / "inventory" / "headscale-root-ca.crt").write_text(
                "-----BEGIN CERTIFICATE-----\nTESTCERT\n-----END CERTIFICATE-----\n",
                encoding="utf-8",
            )

            tmpdir = Path(tempfile.mkdtemp(prefix="join-local-macos-ca-test-"))
            bin_dir = tmpdir / "bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            capture_security_file = tmpdir / "security-args.txt"
            capture_up_file = tmpdir / "tailscale-up-args.txt"

            scripts = {
                "terraform": "#!/usr/bin/env bash\nexit 0\n",
                "ansible-playbook": "#!/usr/bin/env bash\nexit 0\n",
                "ansible": "#!/usr/bin/env bash\nexit 0\n",
                "hostname": "#!/usr/bin/env bash\necho \"Mykolas-MacBook-Air\"\n",
                "uname": "#!/usr/bin/env bash\necho Darwin\n",
                "open": "#!/usr/bin/env bash\nexit 0\n",
                "sudo": "#!/usr/bin/env bash\nshift 0\nexec \"$@\"\n",
                "security": textwrap.dedent(
                    f"""#!/usr/bin/env bash
                    set -euo pipefail
                    printf '%s\n' \"$@\" > {capture_security_file}
                    exit 0
                    """
                ),
                "tailscale": textwrap.dedent(
                    f"""#!/usr/bin/env bash
                    set -euo pipefail
                    cmd="${{1:-}}"
                    shift || true
                    case "$cmd" in
                      version)
                        cat <<'EOF'
1.96.5
  tailscale commit: abcdef
  long version: 1.96.5-tabcdef
  go version: go1.26.1
EOF
                        ;;
                      status)
                        printf '{{"BackendState":"Stopped","TailscaleIPs":[]}}\n'
                        ;;
                      down)
                        exit 0
                        ;;
                      up)
                        printf '%s\n' "$@" > {capture_up_file}
                        exit 0
                        ;;
                      ip)
                        printf '100.64.0.10\n'
                        ;;
                    esac
                    exit 0
                    """
                ),
            }

            for name, content in scripts.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(path.stat().st_mode | stat.S_IEXEC)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["BLUEPRINT_DISABLE_UI_RECORDING"] = "1"
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(env_root)

            subprocess.run(
                [
                    str(repo_root / "scripts" / "deploy.sh"),
                    "join-local",
                    "--env",
                    env_name,
                ],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            security_args = capture_security_file.read_text(encoding="utf-8")
            self.assertIn("add-trusted-cert", security_args)
            self.assertIn("/Library/Keychains/System.keychain", security_args)

            captured_up = capture_up_file.read_text(encoding="utf-8")
            self.assertIn("--login-server", captured_up)
            self.assertIn("https://headscale.example.com", captured_up)
        finally:
            temp_env_root.cleanup()
            if bin_dir is not None and bin_dir.parent.exists():
                for path in sorted(bin_dir.parent.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_deployment_summary_includes_break_glass_recovery_line(self):
        repo_root = Path(__file__).resolve().parents[2]

        with tempfile.TemporaryDirectory(prefix="deploy-recovery-summary-") as tempdir_name:
            tempdir = Path(tempdir_name)
            env_dir = tempdir / "environments" / "summary"
            inventory_dir = env_dir / "inventory"
            recovery_dir = env_dir / ".recovery"
            inventory_dir.mkdir(parents=True, exist_ok=True)
            recovery_dir.mkdir(parents=True, exist_ok=True)

            (inventory_dir / "terraform-outputs.json").write_text(
                '{"control_public_ip": {"value": "203.0.113.10"}}\n',
                encoding="utf-8",
            )
            (recovery_dir / "status.json").write_text(
                '{'
                '"status": "refreshed", '
                '"created_at_utc": "2026-03-24T12:00:00Z", '
                '"message": "Recovery bundle refreshed to both backup storages.", '
                '"recovery_line": {"state": "created", "fingerprint": "abc123def456", "printed_in_summary": true}, '
                '"primary": {"status": "ok"}, '
                '"secondary": {"status": "ok"}'
                '}\n',
                encoding="utf-8",
            )
            (recovery_dir / "latest-recovery-line").write_text(
                "bp1.testing-recovery-line\n",
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["INVENTORY_JSON"] = str(inventory_dir / "terraform-outputs.json")
            env["NO_COLOR"] = "1"

            proc = subprocess.run(
                [str(repo_root / "scripts" / "helpers" / "deployment-summary.sh")],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            output = proc.stdout
            self.assertIn("Portable Recovery", output)
            self.assertIn("Break-glass recovery line:", output)
            self.assertIn("bp1.testing-recovery-line", output)
            # The restore command shows a generic placeholder; the actual line is shown above it
            self.assertIn("./scripts/restore.sh --recovery-line", output)

    def test_deployment_summary_does_not_reprint_stable_recovery_line(self):
        repo_root = Path(__file__).resolve().parents[2]

        with tempfile.TemporaryDirectory(prefix="deploy-recovery-summary-stable-") as tempdir_name:
            tempdir = Path(tempdir_name)
            env_dir = tempdir / "environments" / "summary"
            inventory_dir = env_dir / "inventory"
            recovery_dir = env_dir / ".recovery"
            inventory_dir.mkdir(parents=True, exist_ok=True)
            recovery_dir.mkdir(parents=True, exist_ok=True)

            (inventory_dir / "terraform-outputs.json").write_text(
                '{"control_public_ip": {"value": "203.0.113.10"}}\n',
                encoding="utf-8",
            )
            (recovery_dir / "status.json").write_text(
                '{'
                '"status": "refreshed", '
                '"created_at_utc": "2026-03-24T12:00:00Z", '
                '"message": "Recovery bundle refreshed to both backup storages.", '
                '"recovery_line": {"state": "unchanged", "fingerprint": "abc123def456", "printed_in_summary": false}, '
                '"primary": {"status": "ok"}, '
                '"secondary": {"status": "ok"}'
                '}\n',
                encoding="utf-8",
            )
            (recovery_dir / "latest-recovery-line").write_text(
                "bp1.testing-recovery-line\n",
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["INVENTORY_JSON"] = str(inventory_dir / "terraform-outputs.json")
            env["NO_COLOR"] = "1"

            proc = subprocess.run(
                [str(repo_root / "scripts" / "helpers" / "deployment-summary.sh")],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            output = proc.stdout
            self.assertIn("Portable Recovery", output)
            self.assertNotIn("Break-glass recovery line:", output)
            self.assertIn("Already initialized", output)
            self.assertIn("abc123def456", output)

    def test_namecheap_summary_suppresses_second_run_warning_when_wildcard_is_active(self):
        repo_root = Path(__file__).resolve().parents[2]

        with tempfile.TemporaryDirectory(prefix="deploy-namecheap-summary-") as tempdir_name:
            tempdir = Path(tempdir_name)
            env_dir = tempdir / "environments" / "summary"
            inventory_dir = env_dir / "inventory"
            group_vars_dir = env_dir / "group_vars"
            inventory_dir.mkdir(parents=True, exist_ok=True)
            group_vars_dir.mkdir(parents=True, exist_ok=True)

            (inventory_dir / "terraform-outputs.json").write_text(
                '{"control_public_ip": {"value": "203.0.113.10"}, "gateway_public_ip": {"value": "203.0.113.20"}}\n',
                encoding="utf-8",
            )
            (inventory_dir / "gateway-wildcard-status.json").write_text(
                '{"public_enabled": true, "public_active": true, "internal_enabled": true, "internal_active": true}\n',
                encoding="utf-8",
            )
            (inventory_dir / "tailscale-ips.json").write_text(
                '{"control-vm": "100.64.0.2", "monitoring-vm": "100.64.0.3"}\n',
                encoding="utf-8",
            )
            (group_vars_dir / "all.yml").write_text(
                "base_domain: example.com\n"
                "headscale_subdomain: headscale\n"
                "headscale_magic_dns_base_domain: in.example.com\n"
                "public_service_tls_mode: namecheap\n"
                "internal_service_tls_mode: namecheap\n",
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["INVENTORY_JSON"] = str(inventory_dir / "terraform-outputs.json")
            env["SERVICES_ADMIN_PASSWORD"] = "dummy-password"
            env["NO_COLOR"] = "1"

            proc = subprocess.run(
                [str(repo_root / "scripts" / "helpers" / "deployment-summary.sh")],
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            output = proc.stdout
            self.assertIn("Wildcard TLS for public gateway services is active from the current deploy", output)
            self.assertIn("Wildcard TLS for internal service aliases is active from the current deploy", output)
            self.assertNotIn("rerun ./scripts/deploy.sh gateway --env <env>", output)
            self.assertNotIn("Then run a second gateway converge", output)

    def test_recovery_helper_refreshes_bundle_when_configured(self):
        temp_env_root = tempfile.TemporaryDirectory(prefix="deploy-recovery-envroot-")
        workspace_root = Path(temp_env_root.name) / "workspace"
        env_name = f"recovery-helper-{os.getpid()}"
        env_dir = workspace_root / "environments" / env_name

        try:
            workspace_root.mkdir(parents=True, exist_ok=True)
            (env_dir / "inventory").mkdir(parents=True, exist_ok=True)
            (env_dir / "group_vars").mkdir(parents=True, exist_ok=True)
            storage_root = workspace_root / "storage"
            primary_root = storage_root / "primary"
            secondary_root = storage_root / "secondary"
            primary_root.mkdir(parents=True, exist_ok=True)
            secondary_root.mkdir(parents=True, exist_ok=True)
            (workspace_root / "VERSION").write_text("1.10.0\n", encoding="utf-8")

            (env_dir / "secrets.env").write_text(
                "TF_VAR_tfgrid_mnemonic=alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\n"
                "SERVICES_ADMIN_PASSWORD=dummy-password\n",
                encoding="utf-8",
            )
            (env_dir / "terraform.tfvars").write_text(
                'tfgrid_network = "test"\nname = "portable-recovery-offline"\n',
                encoding="utf-8",
            )
            (env_dir / "group_vars" / "all.yml").write_text(
                "backup_enabled: true\n"
                "backup_backends:\n"
                f"  - name: primary\n    type: s3\n    endpoint: file://{primary_root}\n    bucket: primary-bucket\n    access_key: ignored\n    secret_key: ignored\n"
                f"  - name: secondary\n    type: s3\n    endpoint: file://{secondary_root}\n    bucket: secondary-bucket\n    access_key: ignored\n    secret_key: ignored\n",
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["BLUEPRINT_ENVIRONMENTS_DIR"] = str(workspace_root / "environments")

            subprocess.run(
                [
                    str(Path(__file__).resolve().parents[2] / "scripts" / "helpers" / "recovery_bundle.py"),
                    "refresh",
                    "--repo-root",
                    str(workspace_root),
                    "--env",
                    env_name,
                ],
                cwd=Path(__file__).resolve().parents[2],
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            line_file = env_dir / ".recovery" / "latest-recovery-line"
            self.assertTrue(line_file.exists())
            first_line = line_file.read_text(encoding="utf-8").strip()

            subprocess.run(
                [
                    str(Path(__file__).resolve().parents[2] / "scripts" / "helpers" / "recovery_bundle.py"),
                    "refresh",
                    "--repo-root",
                    str(workspace_root),
                    "--env",
                    env_name,
                ],
                cwd=Path(__file__).resolve().parents[2],
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            second_line = line_file.read_text(encoding="utf-8").strip()
            self.assertEqual(first_line, second_line)
            latest_files = list(primary_root.rglob("latest.json"))
            self.assertTrue(latest_files)
            self.assertIn('"bundle_password":', latest_files[0].read_text(encoding="utf-8"))
        finally:
            temp_env_root.cleanup()


if __name__ == "__main__":
    unittest.main()