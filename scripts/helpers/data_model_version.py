#!/usr/bin/env python3
"""Shared data-model version metadata helpers.

This module is intentionally tiny so bundle handling and migration logic can
share the same version contract without importing each other.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional


DATA_MODEL_VERSION = 2
DATA_MODEL_VERSION_FILE_NAME = ".data-model-version"
BUNDLE_METADATA_DATA_MODEL_VERSION_FIELD = "data_model_version"


def data_model_version_path(env_dir: Path | str) -> Path:
    return Path(env_dir) / DATA_MODEL_VERSION_FILE_NAME


def parse_data_model_version(raw: str) -> int:
    value = int(str(raw).strip())
    if value < 1:
        raise ValueError("data model version must be >= 1")
    return value


def read_data_model_version(env_dir: Path | str) -> Optional[int]:
    path = data_model_version_path(env_dir)
    if not path.exists():
        return None
    return parse_data_model_version(path.read_text(encoding="utf-8"))


def write_data_model_version(env_dir: Path | str, version: int) -> None:
    path = data_model_version_path(env_dir)
    path.write_text(f"{version}\n", encoding="utf-8")
