#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER_DIR="${REPO_ROOT}/scripts/helpers"
MIGRATIONS_HELPER="${HELPER_DIR}/data_migrations.py"
RESTORE_SCRIPT="${REPO_ROOT}/scripts/restore.sh"

log() { printf '[test] %s\n' "$*" >&2; }
die() { printf '[test][FAIL] %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

assert_file() {
  [[ -f "$1" ]] || die "Expected file to exist: $1"
}

assert_not_file() {
  [[ ! -f "$1" ]] || die "Expected file to be absent: $1"
}

assert_contains() {
  local needle="$1"
  local haystack_file="$2"
  grep -Fq -- "$needle" "$haystack_file" || die "Expected '${needle}' in ${haystack_file}"
}

need_cmd bash
need_cmd python3
need_cmd openssl
need_cmd tar

current_data_model_version="$(PYTHONPATH="${HELPER_DIR}${PYTHONPATH:+:${PYTHONPATH}}" python3 - <<'PY'
from data_model_version import DATA_MODEL_VERSION

print(DATA_MODEL_VERSION)
PY
)"

temp_root="$(mktemp -d -t data-migrations-test-XXXXXX)"
trap 'rm -rf "${temp_root}"' EXIT

fresh_env_dir="${temp_root}/fresh/environments/fresh"
legacy_env_dir="${temp_root}/legacy/environments/legacy"
restore_target="${temp_root}/restored-workspace"
primary_root="${temp_root}/primary-store"
secondary_root="${temp_root}/secondary-store"

mkdir -p "${fresh_env_dir}/group_vars" "${legacy_env_dir}/group_vars" "${legacy_env_dir}/inventory"
mkdir -p "${primary_root}" "${secondary_root}"

printf 'base_domain: example.com\n' > "${fresh_env_dir}/group_vars/all.yml"
printf 'base_domain: example.com\nbackup_enabled: false\n' > "${legacy_env_dir}/group_vars/all.yml"
printf 'example = true\n' > "${fresh_env_dir}/terraform.tfvars"
printf 'example = true\n' > "${legacy_env_dir}/terraform.tfvars"
printf 'SERVICES_ADMIN_PASSWORD=dummy\n' > "${fresh_env_dir}/secrets.env"
printf 'SERVICES_ADMIN_PASSWORD=dummy\n' > "${legacy_env_dir}/secrets.env"
printf 'state-placeholder\n' > "${legacy_env_dir}/terraform.tfstate"
printf 'grid-state-placeholder\n' > "${legacy_env_dir}/tf-grid-state.json"
printf 'tag-placeholder\n' > "${legacy_env_dir}/deployment-tag"
cat > "${legacy_env_dir}/inventory/terraform-outputs.json" <<'EOF'
{
  "control_public_ip": {
    "sensitive": false,
    "type": "string",
    "value": "203.0.113.10"
  }
}
EOF

log "Dry-run lists the pending migration for a v1 environment"
PYTHONPATH="${HELPER_DIR}${PYTHONPATH:+:${PYTHONPATH}}" python3 "${MIGRATIONS_HELPER}" migrate \
  --env-dir "${legacy_env_dir}" \
  --from-version 1 \
  --dry-run > "${temp_root}/dry-run.txt"
assert_contains '2: Add provider field to inventory/terraform-outputs.json' "${temp_root}/dry-run.txt"
assert_not_file "${legacy_env_dir}/.data-model-version"

log "Fresh environments without a version file are initialized to the current version"
PYTHONPATH="${HELPER_DIR}${PYTHONPATH:+:${PYTHONPATH}}" python3 "${MIGRATIONS_HELPER}" migrate \
  --env-dir "${fresh_env_dir}" > "${temp_root}/fresh-migrate.txt"
assert_file "${fresh_env_dir}/.data-model-version"
assert_contains "${current_data_model_version}" "${fresh_env_dir}/.data-model-version"
assert_not_file "${fresh_env_dir}/.data-model-version-pre-2.tar.gz"

log "Legacy v1 environments migrate to v2 and get a rollback tarball"
PYTHONPATH="${HELPER_DIR}${PYTHONPATH:+:${PYTHONPATH}}" python3 "${MIGRATIONS_HELPER}" migrate \
  --env-dir "${legacy_env_dir}" \
  --from-version 1 > "${temp_root}/legacy-migrate.txt"
assert_file "${legacy_env_dir}/.data-model-version"
assert_file "${legacy_env_dir}/.data-model-version-pre-2.tar.gz"
assert_contains '"provider": "threefold"' "${legacy_env_dir}/inventory/terraform-outputs.json"
assert_contains 'Migration 2 complete' "${temp_root}/legacy-migrate.txt"

log "Crafting an older v1 portable bundle and restoring it through restore.sh"
PYTHONPATH="${HELPER_DIR}${PYTHONPATH:+:${PYTHONPATH}}" PRIMARY_ROOT="${primary_root}" SECONDARY_ROOT="${secondary_root}" TEMP_ROOT="${temp_root}" python3 - <<'PY' > "${temp_root}/legacy-recovery-line.txt"
import json
import os
from pathlib import Path

from recovery_bundle import create_archive, encode_recovery_line, encrypt_file, json_dumps, sha256_file

temp_root = Path(os.environ["TEMP_ROOT"])
primary_root = Path(os.environ["PRIMARY_ROOT"])
secondary_root = Path(os.environ["SECONDARY_ROOT"])
environment = "legacy-restore"
timestamp = "20260330T000000Z"
bundle_password = "migration-test-password"

payload_root = temp_root / "legacy-payload"
env_root = payload_root / "environments" / environment
(env_root / "group_vars").mkdir(parents=True, exist_ok=True)
(env_root / "inventory").mkdir(parents=True, exist_ok=True)

(env_root / "secrets.env").write_text("SERVICES_ADMIN_PASSWORD=dummy\n", encoding="utf-8")
(env_root / "terraform.tfvars").write_text('name = "legacy-restore"\n', encoding="utf-8")
(env_root / "group_vars" / "all.yml").write_text("base_domain: example.com\n", encoding="utf-8")
(env_root / "inventory" / "terraform-outputs.json").write_text(
    json.dumps(
        {
            "control_public_ip": {
                "sensitive": False,
                "type": "string",
                "value": "203.0.113.12",
            }
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
(env_root / "terraform.tfstate").write_text("state-placeholder\n", encoding="utf-8")
(env_root / "tf-grid-state.json").write_text("grid-state-placeholder\n", encoding="utf-8")
(env_root / "deployment-tag").write_text("tag-placeholder\n", encoding="utf-8")

metadata = {
    "bundle_format_version": 1,
    "environment": environment,
    "created_at_utc": "2026-03-30T00:00:00Z",
    "repo_version": "1.10.0",
    "git_commit": "",
    "data_model_version": 1,
}
(payload_root / "bundle-metadata.json").write_text(json_dumps(metadata), encoding="utf-8")

manifest = {
    **metadata,
    "files": [
        {"path": f"environments/{environment}/secrets.env", "sha256": "", "size_bytes": "0"},
        {"path": f"environments/{environment}/terraform.tfvars", "sha256": "", "size_bytes": "0"},
        {"path": f"environments/{environment}/group_vars/all.yml", "sha256": "", "size_bytes": "0"},
        {"path": f"environments/{environment}/inventory/terraform-outputs.json", "sha256": "", "size_bytes": "0"},
    ],
    "checksums": {"files_sha256": {}, "bundle_sha256": ""},
}
(payload_root / "recovery-manifest.json").write_text(json_dumps(manifest), encoding="utf-8")

tar_path = temp_root / "legacy-bundle.tar.gz"
enc_path = temp_root / "legacy-bundle.enc"
create_archive(payload_root, tar_path)
encrypt_file(tar_path, enc_path, bundle_password)
bundle_sha = sha256_file(enc_path)

manifest_key = f"control-recovery/{environment}/{timestamp}/manifest.json"
bundle_key = f"control-recovery/{environment}/{timestamp}/bundle.enc"
latest_key = f"control-recovery/{environment}/latest.json"
manifest["checksums"]["bundle_sha256"] = bundle_sha

for root, bucket in ((primary_root, "primary-bucket"), (secondary_root, "secondary-bucket")):
    latest = {
        **metadata,
        "bundle_key": bundle_key,
        "manifest_key": manifest_key,
        "bundle_sha256": bundle_sha,
    }
    (root / bucket / Path(bundle_key)).parent.mkdir(parents=True, exist_ok=True)
    (root / bucket / Path(manifest_key)).parent.mkdir(parents=True, exist_ok=True)
    (root / bucket / Path(latest_key)).parent.mkdir(parents=True, exist_ok=True)
    (root / bucket / Path(bundle_key)).write_bytes(enc_path.read_bytes())
    (root / bucket / Path(manifest_key)).write_text(json_dumps(manifest), encoding="utf-8")
    (root / bucket / Path(latest_key)).write_text(json_dumps(latest), encoding="utf-8")

line = encode_recovery_line(
    {
        "format_version": 1,
        "environment": environment,
        "bundle_password": bundle_password,
        "primary": {
            "name": "primary",
            "endpoint": f"file://{primary_root}",
            "bucket": "primary-bucket",
            "access_key": "ignored",
            "secret_key": "ignored",
            "region": "us-east-1",
            "object_prefix": "control-recovery",
        },
        "secondary": {
            "name": "secondary",
            "endpoint": f"file://{secondary_root}",
            "bucket": "secondary-bucket",
            "access_key": "ignored",
            "secret_key": "ignored",
            "region": "us-east-1",
            "object_prefix": "control-recovery",
        },
    }
)
print(line)
PY

legacy_recovery_line="$(cat "${temp_root}/legacy-recovery-line.txt")"
TMPDIR="${temp_root}" bash "${RESTORE_SCRIPT}" \
  --recovery-line "${legacy_recovery_line}" \
  --target-dir "${restore_target}" \
  --yes > "${temp_root}/restore-output.txt"

assert_contains 'Code checkout:  current checkout (bundle data required migration)' "${temp_root}/restore-output.txt"
assert_contains "Data model:     1 -> ${current_data_model_version}" "${temp_root}/restore-output.txt"
assert_file "${restore_target}/environments/legacy-restore/.data-model-version"
assert_contains '"provider": "threefold"' "${restore_target}/environments/legacy-restore/inventory/terraform-outputs.json"
assert_contains "${current_data_model_version}" "${restore_target}/environments/legacy-restore/.data-model-version"

log "Data-model migration verification complete"