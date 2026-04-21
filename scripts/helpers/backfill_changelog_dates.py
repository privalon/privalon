#!/usr/bin/env python3

import argparse
import re
import subprocess
from pathlib import Path


HEADER_RE = re.compile(
    r"^(## \[(?P<version>[^\]]+)\]\s*)(?P<separator>[—-])\s*(?P<date>\d{4}-\d{2}-\d{2})\s*$",
    re.MULTILINE,
)


def release_versions(changelog_text: str) -> list[str]:
    versions = []
    for match in HEADER_RE.finditer(changelog_text):
        version = match.group("version")
        if version == "Unreleased":
            continue
        versions.append(version)
    return versions


def first_commit_date_for_version(repo_root: Path, changelog_path: Path, version: str) -> str | None:
    pattern = rf"^## \[{re.escape(version)}\]"
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "log",
            "--reverse",
            "--format=%cs",
            "-G",
            pattern,
            "--",
            str(changelog_path.relative_to(repo_root)),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return lines[0] if lines else None


def build_version_date_map(repo_root: Path, changelog_path: Path) -> dict[str, str]:
    changelog_text = changelog_path.read_text(encoding="utf-8")
    version_dates: dict[str, str] = {}
    for version in release_versions(changelog_text):
        commit_date = first_commit_date_for_version(repo_root, changelog_path, version)
        if commit_date:
            version_dates[version] = commit_date
    return version_dates


def rewrite_changelog_dates(changelog_text: str, version_dates: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        version = match.group("version")
        replacement_date = version_dates.get(version)
        if not replacement_date:
            return match.group(0)
        return f"{match.group(1)}{match.group('separator')} {replacement_date}"

    return HEADER_RE.sub(replace, changelog_text)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--changelog", default="CHANGELOG.md")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    repo_root = Path(args.repo).resolve()
    changelog_path = (repo_root / args.changelog).resolve()

    version_dates = build_version_date_map(repo_root, changelog_path)
    original_text = changelog_path.read_text(encoding="utf-8")
    updated_text = rewrite_changelog_dates(original_text, version_dates)

    if args.check:
        if updated_text != original_text:
            print("CHANGELOG.md release dates do not match public commit history.")
            return 1
        return 0

    if updated_text != original_text:
        changelog_path.write_text(updated_text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())