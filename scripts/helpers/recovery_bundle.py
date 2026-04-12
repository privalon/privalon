#!/usr/bin/env python3
"""Portable control-plane recovery bundle helper.

This helper intentionally keeps the recovery-line codec isolated and replaces
manual S3 CLI dependencies with a minimal built-in transport.

Security note: the recovery line is wrong-eye fool-protection, not a standalone
cryptographic trust anchor. Real confidentiality still comes from encrypting the
bundle itself before upload.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from data_model_version import (
    BUNDLE_METADATA_DATA_MODEL_VERSION_FIELD,
    DATA_MODEL_VERSION,
    read_data_model_version,
)


BUNDLE_FORMAT_VERSION = 1
RECOVERY_LINE_VERSION = "bp1"
DEFAULT_REGION = "us-east-1"
DEFAULT_OBJECT_PREFIX = "control-recovery"
APP_KEY = b"privalon-recovery-line-v1"
SKIPPED_RC = 12
DEGRADED_RC = 10
FAILED_RC = 11


class RecoveryError(RuntimeError):
    pass


@dataclass
class BackendConfig:
    name: str
    endpoint: str
    bucket: str
    access_key: str
    secret_key: str
    region: str
    object_prefix: str = DEFAULT_OBJECT_PREFIX

    def key(self, environment: str, *parts: str) -> str:
        items = [self.object_prefix.strip("/"), environment.strip("/")]
        items.extend(part.strip("/") for part in parts if part)
        return "/".join(item for item in items if item)

    def set_region_endpoint(self, region: str) -> None:
        normalized = (region or "").strip()
        if not normalized:
            return
        self.region = normalized

        parsed = urllib.parse.urlparse(self.endpoint)
        if parsed.scheme not in {"https", "http"}:
            return

        host = parsed.netloc
        if host in {"s3.amazonaws.com", "s3-external-1.amazonaws.com"} or host.startswith("s3."):
            if normalized == "us-east-1":
                new_host = "s3.amazonaws.com"
            else:
                new_host = f"s3.{normalized}.amazonaws.com"
            self.endpoint = urllib.parse.urlunparse(
                (parsed.scheme, new_host, parsed.path, parsed.params, parsed.query, parsed.fragment)
            )

    def to_payload(self) -> Dict[str, str]:
        return {
            "name": self.name,
            "endpoint": self.endpoint,
            "bucket": self.bucket,
            "access_key": self.access_key,
            "secret_key": self.secret_key,
            "region": self.region or DEFAULT_REGION,
            "object_prefix": self.object_prefix or DEFAULT_OBJECT_PREFIX,
        }


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_timestamp() -> str:
    return utc_now().strftime("%Y%m%dT%H%M%SZ")


def iso_now() -> str:
    return utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_private_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(text, encoding="utf-8")
    os.chmod(tmp_path, 0o600)
    tmp_path.replace(path)


def run_command(args: List[str], *, cwd: Optional[Path] = None) -> str:
    completed = subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def require_openssl() -> None:
    if shutil.which("openssl"):
        return
    raise RecoveryError("openssl is required for recovery bundle encryption/decryption")


def parse_dotenv(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        values[key] = value
    return values


def simple_yaml_value(raw: str) -> Any:
    value = raw.strip()
    if not value:
        return ""
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]
    return value


def load_group_vars(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {}

    try:
        import yaml  # type: ignore

        loaded = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if isinstance(loaded, dict):
            return loaded
    except Exception:
        pass

    result: Dict[str, Any] = {}
    current_key: Optional[str] = None
    current_list: List[Dict[str, Any]] = []
    current_item: Optional[Dict[str, Any]] = None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        if not line.startswith(" ") and stripped.endswith(":"):
            if current_key == "backup_backends":
                result[current_key] = current_list
            current_key = stripped[:-1]
            current_list = []
            current_item = None
            continue

        if current_key == "backup_backends":
            if stripped.startswith("- "):
                current_item = {}
                current_list.append(current_item)
                remainder = stripped[2:].strip()
                if remainder and ":" in remainder:
                    key, value = remainder.split(":", 1)
                    current_item[key.strip()] = simple_yaml_value(value)
                continue
            if current_item is not None and ":" in stripped:
                key, value = stripped.split(":", 1)
                current_item[key.strip()] = simple_yaml_value(value)
                continue

        if not line.startswith(" ") and ":" in stripped:
            key, value = stripped.split(":", 1)
            result[key.strip()] = simple_yaml_value(value)

    if current_key == "backup_backends":
        result[current_key] = current_list
    return result


ENV_LOOKUP_RE = re.compile(
    r"^\{\{\s*lookup\(\s*['\"]env['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\)\s*\}\}$"
)


def resolve_env_lookup(value: Any, env_values: Dict[str, str]) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    match = ENV_LOOKUP_RE.fullmatch(text)
    if match:
        return env_values.get(match.group(1), os.environ.get(match.group(1), ""))
    return text


def derive_backends(repo_root: Path, environment: str) -> Tuple[List[BackendConfig], Dict[str, Any], Dict[str, str]]:
    env_dir = repo_root / "environments" / environment
    group_vars = load_group_vars(env_dir / "group_vars" / "all.yml")
    secrets_env = parse_dotenv(env_dir / "secrets.env")

    if not group_vars.get("backup_enabled"):
        return [], group_vars, secrets_env

    raw_backends = group_vars.get("backup_backends") or []
    if not isinstance(raw_backends, list):
        raise RecoveryError("backup_backends must be a YAML list in environments/<env>/group_vars/all.yml")

    backends: List[BackendConfig] = []
    for raw_backend in raw_backends[:2]:
        if not isinstance(raw_backend, dict):
            continue
        endpoint = resolve_env_lookup(raw_backend.get("endpoint"), secrets_env)
        bucket = resolve_env_lookup(raw_backend.get("bucket"), secrets_env)
        access_key = resolve_env_lookup(raw_backend.get("access_key"), secrets_env)
        secret_key = resolve_env_lookup(raw_backend.get("secret_key"), secrets_env)
        region = resolve_env_lookup(raw_backend.get("region") or DEFAULT_REGION, secrets_env)
        name = resolve_env_lookup(raw_backend.get("name") or f"backend-{len(backends) + 1}", secrets_env)
        prefix = resolve_env_lookup(raw_backend.get("recovery_object_prefix") or DEFAULT_OBJECT_PREFIX, secrets_env)

        if not endpoint or not bucket:
            raise RecoveryError("Each recovery backend requires endpoint and bucket")

        backends.append(
            BackendConfig(
                name=name,
                endpoint=endpoint,
                bucket=bucket,
                access_key=access_key,
                secret_key=secret_key,
                region=region or DEFAULT_REGION,
                object_prefix=prefix or DEFAULT_OBJECT_PREFIX,
            )
        )

    return backends, group_vars, secrets_env


def bundle_metadata(repo_root: Path, environment: str) -> Dict[str, Any]:
    version = (repo_root / "VERSION").read_text(encoding="utf-8").strip()
    git_commit = ""
    try:
        git_commit = run_command(["git", "rev-parse", "HEAD"], cwd=repo_root)
    except Exception:
        git_commit = ""
    env_dir = repo_root / "environments" / environment
    try:
        data_model_version = read_data_model_version(env_dir)
    except ValueError as exc:
        raise RecoveryError(f"Invalid {env_dir / '.data-model-version'}: {exc}") from exc
    return {
        "bundle_format_version": BUNDLE_FORMAT_VERSION,
        "environment": environment,
        "created_at_utc": iso_now(),
        "repo_version": version,
        "git_commit": git_commit,
        BUNDLE_METADATA_DATA_MODEL_VERSION_FIELD: data_model_version or DATA_MODEL_VERSION,
    }


def should_skip_file(path: Path) -> bool:
    parts = set(path.parts)
    if "__pycache__" in parts:
        return True
    if path.name.endswith(".pyc") or path.name == ".DS_Store":
        return True
    if re.fullmatch(r"\.data-model-version-pre-\d+\.tar\.gz", path.name):
        return True
    if ".ui-logs" in parts or ".recovery" in parts:
        return True
    return False


def required_paths(repo_root: Path, environment: str) -> List[Path]:
    env_dir = repo_root / "environments" / environment
    return [
        env_dir / "secrets.env",
        env_dir / "terraform.tfvars",
        env_dir / ".data-model-version",
        env_dir / "group_vars",
        env_dir / "inventory",
        env_dir / "terraform.tfstate",
        env_dir / "tf-grid-state.json",
        env_dir / "deployment-tag",
    ]


def copy_tree_file(src: Path, dest_root: Path, repo_root: Path, included: List[Dict[str, str]]) -> None:
    rel_path = src.relative_to(repo_root)
    dest_path = dest_root / rel_path
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest_path)
    included.append(
        {
            "path": rel_path.as_posix(),
            "sha256": sha256_file(dest_path),
            "size_bytes": str(dest_path.stat().st_size),
        }
    )


def stage_payload(repo_root: Path, environment: str, payload_root: Path) -> List[Dict[str, str]]:
    included: List[Dict[str, str]] = []
    for candidate in required_paths(repo_root, environment):
        if not candidate.exists():
            continue
        if candidate.is_file():
            if should_skip_file(candidate):
                continue
            copy_tree_file(candidate, payload_root, repo_root, included)
            continue
        for path in sorted(candidate.rglob("*")):
            if not path.is_file() or should_skip_file(path):
                continue
            copy_tree_file(path, payload_root, repo_root, included)
    return included


def encrypt_file(input_path: Path, output_path: Path, password: str) -> None:
    require_openssl()
    subprocess.run(
        [
            "openssl",
            "enc",
            "-aes-256-cbc",
            "-pbkdf2",
            "-salt",
            "-in",
            str(input_path),
            "-out",
            str(output_path),
            "-pass",
            f"pass:{password}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def decrypt_file(input_path: Path, output_path: Path, password: str) -> None:
    require_openssl()
    subprocess.run(
        [
            "openssl",
            "enc",
            "-d",
            "-aes-256-cbc",
            "-pbkdf2",
            "-in",
            str(input_path),
            "-out",
            str(output_path),
            "-pass",
            f"pass:{password}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def create_archive(payload_root: Path, tar_path: Path) -> None:
    with tarfile.open(tar_path, "w:gz") as archive:
        for path in sorted(payload_root.rglob("*")):
            archive.add(path, arcname=path.relative_to(payload_root))


def json_dumps(data: Dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True) + "\n"


def keystream(key_material: bytes, nonce: bytes, length: int) -> bytes:
    output = bytearray()
    counter = 0
    while len(output) < length:
        counter_bytes = counter.to_bytes(4, "big")
        output.extend(hashlib.sha256(key_material + nonce + counter_bytes).digest())
        counter += 1
    return bytes(output[:length])


def encode_recovery_line(payload: Dict[str, Any]) -> str:
    plaintext = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    nonce = secrets.token_bytes(16)
    stream = keystream(APP_KEY, nonce, len(plaintext))
    ciphertext = bytes(a ^ b for a, b in zip(plaintext, stream))
    mac = hmac.new(APP_KEY, nonce + ciphertext, hashlib.sha256).digest()[:16]
    blob = base64.urlsafe_b64encode(nonce + mac + ciphertext).decode("ascii").rstrip("=")
    return f"{RECOVERY_LINE_VERSION}.{blob}"


def decode_recovery_line(line: str) -> Dict[str, Any]:
    prefix, dot, encoded = line.partition(".")
    if prefix != RECOVERY_LINE_VERSION or not dot or not encoded:
        raise RecoveryError("Unsupported recovery-line format")
    padded = encoded + "=" * ((4 - len(encoded) % 4) % 4)
    blob = base64.urlsafe_b64decode(padded.encode("ascii"))
    if len(blob) < 32:
        raise RecoveryError("Recovery line is truncated")
    nonce = blob[:16]
    mac = blob[16:32]
    ciphertext = blob[32:]
    expected = hmac.new(APP_KEY, nonce + ciphertext, hashlib.sha256).digest()[:16]
    if not hmac.compare_digest(mac, expected):
        raise RecoveryError("Recovery line failed integrity validation")
    stream = keystream(APP_KEY, nonce, len(ciphertext))
    plaintext = bytes(a ^ b for a, b in zip(ciphertext, stream))
    return json.loads(plaintext.decode("utf-8"))


class ObjectStoreClient:
    def __init__(self, backend: BackendConfig):
        self.backend = backend
        self.parsed = urllib.parse.urlparse(backend.endpoint)
        if self.parsed.scheme not in {"https", "http", "file"}:
            raise RecoveryError(f"Unsupported backend endpoint scheme: {backend.endpoint}")

    def put_bytes(self, key: str, payload: bytes, content_type: str) -> None:
        if self.parsed.scheme == "file":
            self._file_path(key).parent.mkdir(parents=True, exist_ok=True)
            self._file_path(key).write_bytes(payload)
            return
        headers = {"Content-Type": content_type}
        self._signed_request("PUT", key, payload, headers)

    def get_bytes(self, key: str) -> bytes:
        if self.parsed.scheme == "file":
            path = self._file_path(key)
            if not path.exists():
                raise RecoveryError(f"Missing file backend object: {path}")
            return path.read_bytes()
        return self._signed_request("GET", key, b"", {})

    def _file_path(self, key: str) -> Path:
        endpoint_path = urllib.request.url2pathname(self.parsed.path)
        return Path(endpoint_path) / self.backend.bucket / key

    def _signed_request(self, method: str, key: str, payload: bytes, extra_headers: Dict[str, str], *, allow_retry: bool = True) -> bytes:
        now = utc_now()
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = now.strftime("%Y%m%d")
        payload_hash = sha256_bytes(payload)
        self.parsed = urllib.parse.urlparse(self.backend.endpoint)
        canonical_uri = self._canonical_uri(key)
        host = self.parsed.netloc

        headers = {
            "host": host,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
        }
        headers.update({k.lower(): v for k, v in extra_headers.items()})

        canonical_headers = "".join(f"{name}:{headers[name]}\n" for name in sorted(headers))
        signed_headers = ";".join(sorted(headers))
        canonical_request = "\n".join(
            [
                method,
                canonical_uri,
                "",
                canonical_headers,
                signed_headers,
                payload_hash,
            ]
        )
        credential_scope = f"{date_stamp}/{self.backend.region or DEFAULT_REGION}/s3/aws4_request"
        string_to_sign = "\n".join(
            [
                "AWS4-HMAC-SHA256",
                amz_date,
                credential_scope,
                sha256_bytes(canonical_request.encode("utf-8")),
            ]
        )
        signing_key = self._signing_key(date_stamp)
        signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

        auth_header = (
            "AWS4-HMAC-SHA256 "
            f"Credential={self.backend.access_key}/{credential_scope},"
            f"SignedHeaders={signed_headers},Signature={signature}"
        )
        request_headers = {**extra_headers, "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date, "Authorization": auth_header}
        url = self._object_url(key)
        request = urllib.request.Request(url=url, data=payload if method != "GET" else None, method=method)
        for name, value in request_headers.items():
            request.add_header(name, value)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            if allow_retry and exc.code in {301, 307, 400}:
                retry_region = (exc.headers.get("x-amz-bucket-region") or "").strip()
                if retry_region:
                    self.backend.set_region_endpoint(retry_region)
                    self.parsed = urllib.parse.urlparse(self.backend.endpoint)
                    return self._signed_request(method, key, payload, extra_headers, allow_retry=False)
            raise RecoveryError(f"{self.backend.name} {method} {key} failed: HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise RecoveryError(f"{self.backend.name} {method} {key} failed: {exc.reason}") from exc

    def _object_url(self, key: str) -> str:
        base_path = self.parsed.path.rstrip("/")
        quoted_key = urllib.parse.quote(key, safe="/")
        path = f"{base_path}/{urllib.parse.quote(self.backend.bucket, safe='')}/{quoted_key}"
        return urllib.parse.urlunparse(
            (
                self.parsed.scheme,
                self.parsed.netloc,
                path,
                "",
                "",
                "",
            )
        )

    def _canonical_uri(self, key: str) -> str:
        base_path = self.parsed.path.rstrip("/")
        quoted_bucket = urllib.parse.quote(self.backend.bucket, safe="")
        quoted_key = urllib.parse.quote(key, safe="/")
        return f"{base_path}/{quoted_bucket}/{quoted_key}" or "/"

    def _signing_key(self, date_stamp: str) -> bytes:
        k_date = hmac.new(("AWS4" + self.backend.secret_key).encode("utf-8"), date_stamp.encode("utf-8"), hashlib.sha256).digest()
        k_region = hmac.new(k_date, (self.backend.region or DEFAULT_REGION).encode("utf-8"), hashlib.sha256).digest()
        k_service = hmac.new(k_region, b"s3", hashlib.sha256).digest()
        return hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()


def build_status_record(
    *,
    environment: str,
    status: str,
    message: str,
    created_at: str,
    bundle: Dict[str, Any],
    primary: Dict[str, Any],
    secondary: Dict[str, Any],
) -> Dict[str, Any]:
    return {
        "environment": environment,
        "status": status,
        "message": message,
        "created_at_utc": created_at,
        "bundle": bundle,
        "primary": primary,
        "secondary": secondary,
    }


def refresh_bundle(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    environment = args.env
    env_dir = repo_root / "environments" / environment
    recovery_dir = env_dir / ".recovery"
    status_file = Path(args.state_file) if args.state_file else recovery_dir / "status.json"
    line_file = Path(args.line_file) if args.line_file else recovery_dir / "latest-recovery-line"

    backends, group_vars, _ = derive_backends(repo_root, environment)
    if not group_vars.get("backup_enabled") or len(backends) < 2:
        status = build_status_record(
            environment=environment,
            status="skipped",
            message="Portable recovery bundle is not configured. Enable backup_enabled and define two backup_backends.",
            created_at=iso_now(),
            bundle={},
            primary={"status": "skipped"},
            secondary={"status": "skipped"},
        )
        write_private_text(status_file, json_dumps(status))
        return SKIPPED_RC

    metadata = bundle_metadata(repo_root, environment)
    created_at = metadata["created_at_utc"]
    timestamp = utc_timestamp()
    bundle_password = secrets.token_urlsafe(32)
    primary_backend = backends[0]
    secondary_backend = backends[1]

    with tempfile.TemporaryDirectory(prefix=f"bundle-{environment}-") as tempdir_name:
        tempdir = Path(tempdir_name)
        payload_root = tempdir / "payload"
        payload_root.mkdir(parents=True, exist_ok=True)
        included_files = stage_payload(repo_root, environment, payload_root)
        if not any(item["path"].endswith("secrets.env") for item in included_files):
            raise RecoveryError(f"Missing required environment file: environments/{environment}/secrets.env")
        if not any(item["path"].endswith("terraform.tfvars") for item in included_files):
            raise RecoveryError(f"Missing required environment file: environments/{environment}/terraform.tfvars")

        (payload_root / "bundle-metadata.json").write_text(json_dumps(metadata), encoding="utf-8")
        included_files.append(
            {
                "path": "bundle-metadata.json",
                "sha256": sha256_file(payload_root / "bundle-metadata.json"),
                "size_bytes": str((payload_root / "bundle-metadata.json").stat().st_size),
            }
        )

        assembly_manifest = {
            **metadata,
            "files": included_files,
            "checksums": {"files_sha256": {item["path"]: item["sha256"] for item in included_files}},
            "storage_replication_status": {
                "primary": {"status": "planned"},
                "secondary": {"status": "planned"},
            },
        }
        (payload_root / "recovery-manifest.json").write_text(json_dumps(assembly_manifest), encoding="utf-8")
        included_files.append(
            {
                "path": "recovery-manifest.json",
                "sha256": sha256_file(payload_root / "recovery-manifest.json"),
                "size_bytes": str((payload_root / "recovery-manifest.json").stat().st_size),
            }
        )

        tar_path = tempdir / "bundle.tar.gz"
        enc_path = tempdir / "bundle.enc"
        create_archive(payload_root, tar_path)
        encrypt_file(tar_path, enc_path, bundle_password)
        bundle_sha = sha256_file(enc_path)
        manifest_key = primary_backend.key(environment, timestamp, "manifest.json")
        bundle_key = primary_backend.key(environment, timestamp, "bundle.enc")
        latest_key = primary_backend.key(environment, "latest.json")

        bundle_descriptor = {
            **metadata,
            "bundle_key": bundle_key,
            "manifest_key": manifest_key,
            "latest_key": latest_key,
            "bundle_sha256": bundle_sha,
            "line_file": str(line_file),
        }

        results: Dict[str, Dict[str, Any]] = {
            "primary": {
                "name": primary_backend.name,
                "bundle_key": primary_backend.key(environment, timestamp, "bundle.enc"),
                "manifest_key": primary_backend.key(environment, timestamp, "manifest.json"),
                "latest_key": primary_backend.key(environment, "latest.json"),
                "status": "failed",
            },
            "secondary": {
                "name": secondary_backend.name,
                "bundle_key": secondary_backend.key(environment, timestamp, "bundle.enc"),
                "manifest_key": secondary_backend.key(environment, timestamp, "manifest.json"),
                "latest_key": secondary_backend.key(environment, "latest.json"),
                "status": "failed",
            },
        }

        clients = {
            "primary": ObjectStoreClient(primary_backend),
            "secondary": ObjectStoreClient(secondary_backend),
        }

        for label, backend in (("primary", primary_backend), ("secondary", secondary_backend)):
            try:
                clients[label].put_bytes(results[label]["bundle_key"], enc_path.read_bytes(), "application/octet-stream")
                results[label]["bundle_upload"] = "ok"
                results[label]["status"] = "bundle_uploaded"
            except Exception as exc:
                results[label]["bundle_upload"] = "failed"
                results[label]["message"] = str(exc)

        manifest = {
            **metadata,
            "files": included_files,
            "checksums": {
                "files_sha256": {item["path"]: item["sha256"] for item in included_files},
                "bundle_sha256": bundle_sha,
            },
            "storage_replication_status": {
                "primary": results["primary"],
                "secondary": results["secondary"],
            },
        }

        latest_pointer = {
            **metadata,
            "bundle_key": "",
            "manifest_key": "",
            "bundle_sha256": bundle_sha,
        }

        for label in ("primary", "secondary"):
            if results[label].get("bundle_upload") != "ok":
                continue
            latest_pointer["bundle_key"] = results[label]["bundle_key"]
            latest_pointer["manifest_key"] = results[label]["manifest_key"]
            try:
                clients[label].put_bytes(
                    results[label]["manifest_key"],
                    json_dumps(manifest).encode("utf-8"),
                    "application/json",
                )
                clients[label].put_bytes(
                    results[label]["latest_key"],
                    json_dumps(latest_pointer).encode("utf-8"),
                    "application/json",
                )
                results[label]["manifest_upload"] = "ok"
                results[label]["latest_pointer_upload"] = "ok"
                results[label]["status"] = "ok"
            except Exception as exc:
                results[label]["manifest_upload"] = results[label].get("manifest_upload", "failed")
                results[label]["latest_pointer_upload"] = "failed"
                results[label]["status"] = "failed"
                results[label]["message"] = str(exc)

        manifest["storage_replication_status"] = {
            "primary": results["primary"],
            "secondary": results["secondary"],
        }
        for label in ("primary", "secondary"):
            if results[label].get("status") != "ok":
                continue
            try:
                clients[label].put_bytes(
                    results[label]["manifest_key"],
                    json_dumps(manifest).encode("utf-8"),
                    "application/json",
                )
                clients[label].put_bytes(
                    results[label]["latest_key"],
                    json_dumps({
                        **latest_pointer,
                        "bundle_key": results[label]["bundle_key"],
                        "manifest_key": results[label]["manifest_key"],
                    }).encode("utf-8"),
                    "application/json",
                )
            except Exception as exc:
                results[label]["status"] = "failed"
                results[label]["message"] = str(exc)

        primary_ok = results["primary"].get("status") == "ok"
        secondary_ok = results["secondary"].get("status") == "ok"

        line_payload = {
            "format_version": 1,
            "environment": environment,
            "bundle_password": bundle_password,
            "primary": primary_backend.to_payload(),
            "secondary": secondary_backend.to_payload(),
        }
        recovery_line = encode_recovery_line(line_payload)

        if primary_ok or secondary_ok:
            write_private_text(line_file, recovery_line + "\n")

        if primary_ok and secondary_ok:
            overall_status = "refreshed"
            message = "Recovery bundle refreshed to primary and secondary storage."
            rc = 0
        elif primary_ok and not secondary_ok:
            overall_status = "degraded"
            message = "Recovery bundle refreshed to primary storage, but secondary replication failed."
            rc = DEGRADED_RC
        elif not primary_ok and secondary_ok:
            overall_status = "failed"
            message = "Recovery bundle reached secondary storage, but primary refresh failed. Deploy should be treated as failed until primary storage is healthy again."
            rc = FAILED_RC
        else:
            overall_status = "failed"
            message = "Recovery bundle refresh failed for both backup storages."
            rc = FAILED_RC

        status_record = build_status_record(
            environment=environment,
            status=overall_status,
            message=message,
            created_at=created_at,
            bundle={**bundle_descriptor, "bundle_sha256": bundle_sha},
            primary=results["primary"],
            secondary=results["secondary"],
        )
        write_private_text(status_file, json_dumps(status_record))

        if args.print_json:
            print(json_dumps({"status": status_record, "line": recovery_line if primary_ok or secondary_ok else ""}), end="")
        return rc


def prepare_restore(args: argparse.Namespace) -> int:
    work_dir = Path(args.work_dir).resolve()
    work_dir.mkdir(parents=True, exist_ok=True)
    payload = decode_recovery_line(args.recovery_line)
    environment = payload["environment"]
    password = payload["bundle_password"]

    attempts: List[Dict[str, str]] = []
    chosen: Optional[Tuple[str, Dict[str, Any], Dict[str, Any], Path]] = None
    for label in ("primary", "secondary"):
        backend_payload = payload[label]
        backend = BackendConfig(
            name=backend_payload.get("name") or label,
            endpoint=backend_payload["endpoint"],
            bucket=backend_payload["bucket"],
            access_key=backend_payload.get("access_key", ""),
            secret_key=backend_payload.get("secret_key", ""),
            region=backend_payload.get("region") or DEFAULT_REGION,
            object_prefix=backend_payload.get("object_prefix") or DEFAULT_OBJECT_PREFIX,
        )
        client = ObjectStoreClient(backend)
        try:
            latest_key = backend.key(environment, "latest.json")
            latest = json.loads(client.get_bytes(latest_key).decode("utf-8"))
            manifest = json.loads(client.get_bytes(latest["manifest_key"]).decode("utf-8"))
            bundle_bytes = client.get_bytes(latest["bundle_key"])
            bundle_sha = sha256_bytes(bundle_bytes)
            expected_sha = str(latest.get("bundle_sha256") or manifest.get("checksums", {}).get("bundle_sha256") or "")
            if expected_sha and bundle_sha != expected_sha:
                raise RecoveryError(f"Bundle checksum mismatch for {label}")
            enc_path = work_dir / f"{label}-bundle.enc"
            enc_path.write_bytes(bundle_bytes)
            tar_path = work_dir / f"{label}-bundle.tar.gz"
            decrypt_file(enc_path, tar_path, password)
            extract_root = work_dir / f"extract-{label}"
            extract_root.mkdir(parents=True, exist_ok=True)
            with tarfile.open(tar_path, "r:gz") as archive:
                archive.extractall(extract_root)
            chosen = (label, latest, manifest, extract_root)
            break
        except Exception as exc:
            attempts.append({"backend": label, "error": str(exc)})

    if chosen is None:
        raise RecoveryError("Restore failed on both backup storages: " + "; ".join(f"{item['backend']}: {item['error']}" for item in attempts))

    label, latest, manifest, extract_root = chosen
    output = {
        "environment": environment,
        "source_backend": label,
        "bundle_key": latest["bundle_key"],
        "manifest_key": latest["manifest_key"],
        "repo_version": manifest.get("repo_version", ""),
        "git_commit": manifest.get("git_commit", ""),
        "data_model_version": int(manifest.get(BUNDLE_METADATA_DATA_MODEL_VERSION_FIELD, 1) or 1),
        "created_at_utc": manifest.get("created_at_utc", ""),
        "extract_root": str(extract_root),
        "attempts": attempts,
    }
    print(json_dumps(output), end="")
    return 0


def command_decode_line(args: argparse.Namespace) -> int:
    print(json_dumps(decode_recovery_line(args.recovery_line)), end="")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Portable recovery bundle helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    refresh = subparsers.add_parser("refresh", help="Build and publish the control-plane recovery bundle")
    refresh.add_argument("--repo-root", required=True)
    refresh.add_argument("--env", required=True)
    refresh.add_argument("--state-file")
    refresh.add_argument("--line-file")
    refresh.add_argument("--print-json", action="store_true")
    refresh.set_defaults(func=refresh_bundle)

    decode = subparsers.add_parser("decode-line", help="Decode an opaque recovery line")
    decode.add_argument("--recovery-line", required=True)
    decode.set_defaults(func=command_decode_line)

    prepare = subparsers.add_parser("prepare-restore", help="Download and unpack the recovery bundle")
    prepare.add_argument("--recovery-line", required=True)
    prepare.add_argument("--work-dir", required=True)
    prepare.set_defaults(func=prepare_restore)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except RecoveryError as exc:
        print(str(exc), file=sys.stderr)
        return FAILED_RC


if __name__ == "__main__":
    sys.exit(main())