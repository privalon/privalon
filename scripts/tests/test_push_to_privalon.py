import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "local" / "push-to-privalon.sh"
HELPER_PATH = REPO_ROOT / "scripts" / "helpers" / "privalon_changelog_sync.py"


class PushToPrivalonTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="push-to-privalon-")
        self.root = Path(self.tempdir.name)
        self.remote_repo = self.root / "remote.git"
        self.source_repo = self.root / "source"
        self.target_repo = self.root / "target"
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()

        self._run(["git", "init", "--bare", str(self.remote_repo)])
        self._run(["git", "init", str(self.source_repo)])
        self._run(["git", "init", str(self.target_repo)])
        self._run(["git", "-C", str(self.target_repo), "remote", "add", "origin", str(self.remote_repo)])
        self._run(["git", "-C", str(self.source_repo), "config", "user.name", "Test User"])
        self._run(["git", "-C", str(self.source_repo), "config", "user.email", "test@example.com"])
        self._run(["git", "-C", str(self.target_repo), "config", "user.name", "Test User"])
        self._run(["git", "-C", str(self.target_repo), "config", "user.email", "test@example.com"])

        (self.source_repo / "scripts" / "local").mkdir(parents=True)
        (self.source_repo / "scripts" / "helpers").mkdir(parents=True)

        shutil.copy2(SCRIPT_PATH, self.source_repo / "scripts" / "local" / "push-to-privalon.sh")
        shutil.copy2(HELPER_PATH, self.source_repo / "scripts" / "helpers" / "privalon_changelog_sync.py")
        os.chmod(self.source_repo / "scripts" / "local" / "push-to-privalon.sh", 0o755)
        os.chmod(self.source_repo / "scripts" / "helpers" / "privalon_changelog_sync.py", 0o755)

        (self.source_repo / ".privalon-syncignore").write_text(
            textwrap.dedent(
                """\
                scripts/local/push-to-privalon.sh
                .privalon-syncignore
                """
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _run(self, command: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(command, check=True, capture_output=True, text=True, env=env)

    def _write_date_stub(self, date_value: str, timestamp_value: str) -> None:
        (self.fake_bin / "date").write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "$*" == *"%Y-%m-%dT%H:%M:%SZ"* ]]; then
                  printf '%s\\n' '{timestamp_value}'
                  exit 0
                fi
                if [[ "$*" == *"%Y-%m-%d"* ]]; then
                  printf '%s\\n' '{date_value}'
                  exit 0
                fi
                /usr/bin/date "$@"
                """
            ),
            encoding="utf-8",
        )
        os.chmod(self.fake_bin / "date", 0o755)

    def _commit_all(self, repo: Path, message: str) -> None:
        self._run(["git", "-C", str(repo), "add", "-A"])
        self._run(
            [
                "git",
                "-C",
                str(repo),
                "-c",
                "user.name=Test User",
                "-c",
                "user.email=test@example.com",
                "commit",
                "-m",
                message,
            ]
        )

    def _run_sync(self, date_value: str, timestamp_value: str) -> None:
        self._write_date_stub(date_value, timestamp_value)
        env = os.environ.copy()
        env["PATH"] = f"{self.fake_bin}:{env['PATH']}"

        self._run(
            [
                str(self.source_repo / "scripts" / "local" / "push-to-privalon.sh"),
                "--target",
                str(self.target_repo),
                "--remote",
                "origin",
                "--branch",
                "main",
            ],
            env=env,
        )

    def test_public_sync_stamps_new_release_entries_with_push_date(self) -> None:
        (self.source_repo / "CHANGELOG.md").write_text(
            textwrap.dedent(
                """\
                # Changelog

                ## [Unreleased]

                ## [1.0.1] — 2026-04-10

                ### Fixed
                - Public-safe change.

                ## [1.0.0] — 2026-04-01

                ### Added
                - Initial release.
                """
            ),
            encoding="utf-8",
        )
        (self.source_repo / "README.md").write_text("mirror test\n", encoding="utf-8")
        self._commit_all(self.source_repo, "Initial private commit")

        self._run_sync("2026-04-21", "2026-04-21T12:00:00Z")

        target_changelog = (self.target_repo / "CHANGELOG.md").read_text(encoding="utf-8")
        source_changelog = (self.source_repo / "CHANGELOG.md").read_text(encoding="utf-8")

        self.assertIn("## [1.0.1] — 2026-04-21", target_changelog)
        self.assertIn("## [1.0.0] — 2026-04-21", target_changelog)
        self.assertIn("## [1.0.1] — 2026-04-10", source_changelog)
        self.assertIn("## [1.0.0] — 2026-04-01", source_changelog)

    def test_existing_public_release_keeps_its_earlier_public_date(self) -> None:
        (self.source_repo / "CHANGELOG.md").write_text(
            textwrap.dedent(
                """\
                # Changelog

                ## [Unreleased]

                ## [1.0.1] — 2026-04-10

                ### Fixed
                - Private-safe follow-up.

                ## [1.0.0] — 2026-04-01

                ### Added
                - Initial release.
                """
            ),
            encoding="utf-8",
        )
        (self.source_repo / "README.md").write_text("mirror test\n", encoding="utf-8")
        self._commit_all(self.source_repo, "Initial private commit")

        self._run(["git", "-C", str(self.target_repo), "checkout", "-b", "main"])
        (self.target_repo / "CHANGELOG.md").write_text(
            textwrap.dedent(
                """\
                # Changelog

                ## [Unreleased]

                ## [1.0.0] — 2026-04-05

                ### Added
                - Initial release.
                """
            ),
            encoding="utf-8",
        )
        (self.target_repo / "README.md").write_text("public mirror\n", encoding="utf-8")
        self._commit_all(self.target_repo, "Initial public commit")
        self._run(["git", "-C", str(self.target_repo), "push", "-u", "origin", "main"])

        self._run_sync("2026-04-21", "2026-04-21T12:00:00Z")

        target_changelog = (self.target_repo / "CHANGELOG.md").read_text(encoding="utf-8")
        source_changelog = (self.source_repo / "CHANGELOG.md").read_text(encoding="utf-8")

        self.assertIn("## [1.0.1] — 2026-04-21", target_changelog)
        self.assertIn("## [1.0.0] — 2026-04-05", target_changelog)
        self.assertIn("## [1.0.1] — 2026-04-10", source_changelog)
        self.assertIn("## [1.0.0] — 2026-04-01", source_changelog)

    def test_second_sync_preserves_existing_public_dates_and_updates_new_entries_only(self) -> None:
        (self.source_repo / "CHANGELOG.md").write_text(
            textwrap.dedent(
                """\
                # Changelog

                ## [Unreleased]

                ## [1.0.1] — 2026-04-10

                ### Fixed
                - Public-safe change.

                ## [1.0.0] — 2026-04-01

                ### Added
                - Initial release.
                """
            ),
            encoding="utf-8",
        )
        (self.source_repo / "README.md").write_text("mirror test\n", encoding="utf-8")
        self._commit_all(self.source_repo, "Initial private commit")

        self._run_sync("2026-04-21", "2026-04-21T12:00:00Z")

        (self.source_repo / "CHANGELOG.md").write_text(
            textwrap.dedent(
                """\
                # Changelog

                ## [Unreleased]

                ## [1.0.2] — 2026-04-22

                ### Changed
                - Newly mirrored release.

                ## [1.0.1] — 2026-04-10

                ### Fixed
                - Public-safe change.

                ## [1.0.0] — 2026-04-01

                ### Added
                - Initial release.
                """
            ),
            encoding="utf-8",
        )
        self._commit_all(self.source_repo, "Second private commit")

        self._run_sync("2026-04-23", "2026-04-23T12:00:00Z")

        target_changelog = (self.target_repo / "CHANGELOG.md").read_text(encoding="utf-8")
        source_changelog = (self.source_repo / "CHANGELOG.md").read_text(encoding="utf-8")

        self.assertIn("## [1.0.2] — 2026-04-23", target_changelog)
        self.assertIn("## [1.0.1] — 2026-04-21", target_changelog)
        self.assertIn("## [1.0.0] — 2026-04-21", target_changelog)
        self.assertIn("## [1.0.2] — 2026-04-22", source_changelog)
        self.assertIn("## [1.0.1] — 2026-04-10", source_changelog)
        self.assertIn("## [1.0.0] — 2026-04-01", source_changelog)


if __name__ == "__main__":
    unittest.main()