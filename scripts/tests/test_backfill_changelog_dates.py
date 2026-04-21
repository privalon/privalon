import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = REPO_ROOT / "scripts" / "helpers" / "backfill_changelog_dates.py"


class BackfillChangelogDatesTests(unittest.TestCase):
    def _git(self, repo: Path, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=repo,
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )

    def _commit(self, repo: Path, message: str, date: str) -> None:
        env = os.environ.copy()
        env["GIT_AUTHOR_DATE"] = date
        env["GIT_COMMITTER_DATE"] = date
        self._git(repo, "add", "CHANGELOG.md", env=env)
        self._git(repo, "commit", "-m", message, env=env)

    def test_backfill_uses_first_public_commit_date_per_release(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privalon-changelog-backfill-") as tmpdir:
            repo = Path(tmpdir)
            self._git(repo, "init")
            self._git(repo, "config", "user.name", "Test User")
            self._git(repo, "config", "user.email", "test@example.com")

            changelog = repo / "CHANGELOG.md"
            changelog.write_text(
                textwrap.dedent(
                    """\
                    # Changelog

                    ## [Unreleased]

                    ## [1.0.0] — 2099-01-01

                    ### Added
                    - Initial release.
                    """
                ),
                encoding="utf-8",
            )
            self._commit(repo, "Introduce 1.0.0", "2026-04-12T16:45:50Z")

            changelog.write_text(
                textwrap.dedent(
                    """\
                    # Changelog

                    ## [Unreleased]

                    ## [1.0.1] — 2099-01-02

                    ### Fixed
                    - Public release fix.

                    ## [1.0.0] — 2099-01-03

                    ### Added
                    - Initial release.
                    """
                ),
                encoding="utf-8",
            )
            self._commit(repo, "Introduce 1.0.1", "2026-04-17T20:53:37Z")

            subprocess.run(
                ["python3", str(HELPER_PATH), "--repo", str(repo)],
                check=True,
                capture_output=True,
                text=True,
            )

            updated = changelog.read_text(encoding="utf-8")
            self.assertIn("## [1.0.1] — 2026-04-17", updated)
            self.assertIn("## [1.0.0] — 2026-04-12", updated)

            check_result = subprocess.run(
                ["python3", str(HELPER_PATH), "--repo", str(repo), "--check"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(check_result.returncode, 0)


if __name__ == "__main__":
    unittest.main()