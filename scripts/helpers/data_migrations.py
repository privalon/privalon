#!/usr/bin/env python3
"""Incremental data-model migrations for environments/<env>/ state."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional

from data_model_version import DATA_MODEL_VERSION, read_data_model_version, write_data_model_version


class DataMigrationError(RuntimeError):
    pass


MigrationApply = Callable[[Path], None]


@dataclass(frozen=True)
class Migration:
    version: int
    description: str
    apply: MigrationApply


def migrate_v1_to_v2(env_dir: Path) -> None:
    """Add the top-level provider field to inventory/terraform-outputs.json."""
    outputs_path = env_dir / "inventory" / "terraform-outputs.json"
    if not outputs_path.exists():
        return

    try:
        data = json.loads(outputs_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON in {outputs_path}: {exc}") from exc

    if not isinstance(data, dict):
        raise RuntimeError(f"Expected top-level JSON object in {outputs_path}")

    provider = data.get("provider")
    if isinstance(provider, str) and provider.strip():
        return

    data["provider"] = "threefold"
    outputs_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


MIGRATIONS: List[Migration] = [
    Migration(
        version=2,
        description="Add provider field to inventory/terraform-outputs.json",
        apply=migrate_v1_to_v2,
    ),
]


def validate_registry() -> None:
    expected_versions = list(range(2, DATA_MODEL_VERSION + 1))
    actual_versions = [migration.version for migration in MIGRATIONS]
    if actual_versions != expected_versions:
        raise DataMigrationError(
            "Migration registry is inconsistent with DATA_MODEL_VERSION: "
            f"expected {expected_versions}, got {actual_versions}"
        )


def archive_root_for_env_dir(env_dir: Path) -> Path:
    if env_dir.parent.name == "environments":
        return Path("environments") / env_dir.name
    return Path(env_dir.name)


def should_skip_backup_path(path: Path, backup_path: Path) -> bool:
    if path == backup_path:
        return True
    return bool(re.fullmatch(r"\.data-model-version-pre-\d+\.tar\.gz", path.name))


def create_pre_migration_backup(env_dir: Path, first_version: int) -> Path:
    backup_path = env_dir / f".data-model-version-pre-{first_version}.tar.gz"
    archive_root = archive_root_for_env_dir(env_dir)

    with tarfile.open(backup_path, "w:gz") as archive:
        archive.add(env_dir, arcname=str(archive_root), recursive=False)
        for path in sorted(env_dir.rglob("*")):
            if should_skip_backup_path(path, backup_path):
                continue
            archive.add(path, arcname=str(archive_root / path.relative_to(env_dir)), recursive=False)

    return backup_path


def current_version_for_env(env_dir: Path, from_version: Optional[int]) -> int:
    if from_version is not None:
        return from_version

    detected = read_data_model_version(env_dir)
    if detected is None:
        return DATA_MODEL_VERSION
    return detected


def pending_migrations(current_version: int) -> List[Migration]:
    return [migration for migration in MIGRATIONS if migration.version > current_version]


def migrate_command(args: argparse.Namespace) -> int:
    validate_registry()

    env_dir = Path(args.env_dir).resolve()
    if not env_dir.is_dir():
        raise DataMigrationError(f"Environment directory not found: {env_dir}")

    if args.from_version is not None and args.from_version < 1:
        raise DataMigrationError("--from-version must be >= 1")

    try:
        detected_version = read_data_model_version(env_dir)
        current_version = args.from_version if args.from_version is not None else (detected_version or DATA_MODEL_VERSION)
    except ValueError as exc:
        raise DataMigrationError(f"Invalid {env_dir / '.data-model-version'}: {exc}") from exc

    if current_version > DATA_MODEL_VERSION:
        raise DataMigrationError(
            f"Environment data model version {current_version} is newer than this code's supported version {DATA_MODEL_VERSION}."
        )

    version_file_exists = detected_version is not None
    migrations = pending_migrations(current_version)

    if not migrations:
        if args.dry_run:
            print(f"[migrate] Data model already at version {DATA_MODEL_VERSION}.")
            return 0

        if not version_file_exists or args.from_version is not None:
            write_data_model_version(env_dir, DATA_MODEL_VERSION)
            if not version_file_exists:
                print(f"[migrate] Initialized data model version file at {DATA_MODEL_VERSION}.")
        print(f"[migrate] Data model already up to date at version {DATA_MODEL_VERSION}.")
        return 0

    if args.dry_run:
        print(f"[migrate] Planned migrations for {env_dir}:")
        for migration in migrations:
            print(f"[migrate]   {migration.version}: {migration.description}")
        return 0

    backup_path = create_pre_migration_backup(env_dir, migrations[0].version)
    print(f"[migrate] Creating pre-migration backup: {backup_path.name}")

    for migration in migrations:
        print(f"[migrate] Applying migration {migration.version}: {migration.description}")
        migration.apply(env_dir)
        write_data_model_version(env_dir, migration.version)
        print(f"[migrate] Migration {migration.version} complete")

    print(
        f"[migrate] Applied {len(migrations)} migration(s). Data model is now at version {DATA_MODEL_VERSION}."
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Data-model migrations for environments/<env>")
    subparsers = parser.add_subparsers(dest="command", required=True)

    migrate_parser = subparsers.add_parser("migrate", help="Apply pending data-model migrations")
    migrate_parser.add_argument("--env-dir", required=True)
    migrate_parser.add_argument("--dry-run", action="store_true")
    migrate_parser.add_argument("--from-version", type=int)
    migrate_parser.set_defaults(func=migrate_command)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except DataMigrationError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())