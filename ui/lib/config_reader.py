"""Config reader/writer for Blueprint Web UI.

Handles reading and writing:
  - environments/<env>/terraform.tfvars  (HCL subset)
  - environments/<env>/secrets.env       (shell KEY=VALUE pairs)
  - environments/<env>/group_vars/all.yml (YAML key-value overrides)

Security contract:
  - Secret values are NEVER returned to the caller.
    All secret-related public API returns only a boolean presence flag.
  - write_secret() requires the value to be non-empty.
  - Writes are atomic at the field level (regex substitution or dotenv
    set_key), never full-file rewrites except for YAML overrides.
"""

import os
import re
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml
from dotenv import dotenv_values, set_key

try:
    import hcl2
    _HCL2 = True
except ImportError:
    _HCL2 = False

REPO_ROOT = Path(__file__).resolve().parents[2]


def environments_root() -> Path:
    override = os.environ.get("BLUEPRINT_ENVIRONMENTS_DIR", "").strip()
    if override:
        return Path(override)
    return REPO_ROOT / "environments"

# ── terraform.tfvars ──────────────────────────────────────────────────────────

def read_tfvars(env: str) -> Dict[str, Any]:
    """Parse terraform.tfvars for the given environment using python-hcl2."""
    path = _tfvars_path(env)
    if not path.exists():
        return {}
    if _HCL2:
        try:
            with open(path, encoding="utf-8") as fh:
                return hcl2.load(fh)
        except Exception:
            pass
    return _parse_tfvars_simple(path)


def write_tfvars_simple_field(env: str, key: str, value: Any) -> None:
    """Update a single scalar field (string / bool / int) in terraform.tfvars.

    Raises ValueError if the field is not found.
    """
    path = _tfvars_path(env)
    content = path.read_text(encoding="utf-8")

    if isinstance(value, bool):
        pattern = rf'^({re.escape(key)}\s*=\s*)(true|false)\b'
        replacement = rf'\g<1>{"true" if value else "false"}'
    elif isinstance(value, int):
        pattern = rf'^({re.escape(key)}\s*=\s*)\d+'
        replacement = rf'\g<1>{value}'
    elif isinstance(value, str):
        pattern = rf'^({re.escape(key)}\s*=\s*)"[^"]*"'
        replacement = rf'\g<1>"{_esc(value)}"'
    else:
        raise ValueError(f"Unsupported type for {key}: {type(value).__name__}")

    new_content, count = re.subn(pattern, replacement, content, flags=re.MULTILINE)
    if count == 0:
        raise ValueError(f"Field '{key}' not found in terraform.tfvars for env '{env}'")
    path.write_text(new_content, encoding="utf-8")


def write_ssh_keys(env: str, keys: List[str]) -> None:
    """Replace the ssh_public_keys array in terraform.tfvars."""
    path = _tfvars_path(env)
    content = path.read_text(encoding="utf-8")

    clean_keys = [k.strip() for k in keys if k.strip()]
    inner = "\n".join(f'  "{k}",' for k in clean_keys)
    new_block = f"ssh_public_keys = [\n{inner}\n]"

    # Match the whole multi-line block: ssh_public_keys = [ ... ]
    pattern = r'ssh_public_keys\s*=\s*\[.*?\]'
    new_content, count = re.subn(pattern, new_block, content, flags=re.DOTALL)
    if count == 0:
        new_content = content.rstrip() + "\n\n" + new_block + "\n"

    path.write_text(new_content, encoding="utf-8")


# ── secrets.env ───────────────────────────────────────────────────────────────

# Keys that are considered secrets — these are NEVER returned as values.
_SECRET_KEYS = frozenset({
    "TF_VAR_tfgrid_mnemonic",
    "SERVICES_ADMIN_PASSWORD",
    "RESTIC_PASSWORD",
    "BACKUP_S3_PRIMARY_ACCESS_KEY",
    "BACKUP_S3_PRIMARY_SECRET_KEY",
    "BACKUP_S3_SECONDARY_ACCESS_KEY",
    "BACKUP_S3_SECONDARY_SECRET_KEY",
    "NAMECHEAP_API_USER",
    "NAMECHEAP_API_KEY",
})


def secret_is_set(env: str, key: str) -> bool:
    """Return True if the secret key exists in secrets.env and is non-empty."""
    path = _secrets_path(env)
    if not path.exists():
        return False
    vals = dotenv_values(str(path))
    val = vals.get(key)
    return bool(val and val.strip())


def secrets_presence(env: str) -> Dict[str, bool]:
    """Return {key: is_set} for all known secret keys. No values exposed."""
    path = _secrets_path(env)
    if not path.exists():
        return {k: False for k in _SECRET_KEYS}
    vals = dotenv_values(str(path))
    return {
        k: bool(vals.get(k, "").strip())
        for k in _SECRET_KEYS
    }


def write_secret(env: str, key: str, value: str) -> None:
    """Write a single key to secrets.env using python-dotenv set_key.

    Raises ValueError if value is empty (use clear_secret to remove).
    Raises FileNotFoundError if secrets.env does not exist.
    """
    if not value or not value.strip():
        raise ValueError("Secret value must be non-empty. Use clear_secret() to remove.")
    path = _secrets_path(env)
    if not path.exists():
        raise FileNotFoundError(f"secrets.env not found for environment '{env}'")
    set_key(str(path), key, value, quote_mode="auto")


# ── group_vars/all.yml (env-level overrides) ──────────────────────────────────

def read_group_vars(env: str) -> Dict[str, Any]:
    """Read env-level group_vars/all.yml; returns empty dict if absent."""
    path = _gv_path(env)
    if not path.exists():
        return {}
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError:
        return {}


def write_group_vars(env: str, updates: Dict[str, Any]) -> None:
    """Merge updates into env-level group_vars/all.yml."""
    path = _gv_path(env)
    path.parent.mkdir(parents=True, exist_ok=True)

    existing: Dict[str, Any] = {}
    if path.exists():
        try:
            existing = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            existing = {}

    existing.update(updates)
    path.write_text(
        yaml.safe_dump(existing, default_flow_style=False, allow_unicode=True),
        encoding="utf-8",
    )


# ── Combined view for the UI ──────────────────────────────────────────────────

def get_config_view(env: str) -> dict:
    """Return a sanitised read-only config snapshot for the Configure screen.

    Secret values are redacted — only presence booleans are included.
    """
    tfvars = read_tfvars(env)
    gv     = read_group_vars(env)
    sp     = secrets_presence(env)

    return {
        "grid": {
            "tfgrid_network": tfvars.get("tfgrid_network", ""),
            "name":           tfvars.get("name", ""),
            "use_scheduler":  tfvars.get("use_scheduler", True),
        },
        "vms": tfvars.get("workloads", {}),
        "ssh": {
            "public_keys": tfvars.get("ssh_public_keys", []),
        },
        "credentials": {
            "mnemonic_set":       sp.get("TF_VAR_tfgrid_mnemonic", False),
            "admin_password_set": sp.get("SERVICES_ADMIN_PASSWORD", False),
        },
        "dns": {
            "base_domain":          gv.get("base_domain", ""),
            "headscale_subdomain":  gv.get("headscale_subdomain", ""),
            "magic_dns_base_domain": gv.get("headscale_magic_dns_base_domain", ""),
            "public_service_tls_mode": gv.get("public_service_tls_mode", "letsencrypt"),
            "internal_service_tls_mode": gv.get("internal_service_tls_mode", "internal"),
            "admin_email":          gv.get("admin_email", ""),
            "namecheap_user_set":   sp.get("NAMECHEAP_API_USER", False),
            "namecheap_key_set":    sp.get("NAMECHEAP_API_KEY", False),
        },
        "backup": {
            "backup_enabled":           gv.get("backup_enabled", False),
            "restic_password_set":      sp.get("RESTIC_PASSWORD", False),
            "s3_primary_access_set":    sp.get("BACKUP_S3_PRIMARY_ACCESS_KEY", False),
            "s3_primary_secret_set":    sp.get("BACKUP_S3_PRIMARY_SECRET_KEY", False),
            "s3_secondary_access_set":  sp.get("BACKUP_S3_SECONDARY_ACCESS_KEY", False),
            "s3_secondary_secret_set":  sp.get("BACKUP_S3_SECONDARY_SECRET_KEY", False),
        },
    }


# ── Private helpers ───────────────────────────────────────────────────────────

def _tfvars_path(env: str) -> Path:
    return environments_root() / env / "terraform.tfvars"


def _secrets_path(env: str) -> Path:
    return environments_root() / env / "secrets.env"


def _gv_path(env: str) -> Path:
    return environments_root() / env / "group_vars" / "all.yml"


def _parse_tfvars_simple(path: Path) -> Dict[str, Any]:
    """Minimal HCL parser for when python-hcl2 is unavailable."""
    result: Dict[str, Any] = {}
    content = path.read_text(encoding="utf-8")
    for m in re.finditer(r'^(\w+)\s*=\s*"([^"]*)"', content, re.MULTILINE):
        result[m.group(1)] = m.group(2)
    for m in re.finditer(r'^(\w+)\s*=\s*(true|false)\b', content, re.MULTILINE):
        result[m.group(1)] = m.group(2) == "true"
    for m in re.finditer(r'^(\w+)\s*=\s*(\d+)\b', content, re.MULTILINE):
        if m.group(1) not in result:
            result[m.group(1)] = int(m.group(2))
    return result


def _esc(value: str) -> str:
    """Escape double-quotes and backslashes for embedding in HCL string literals."""
    return value.replace("\\", "\\\\").replace('"', '\\"')
