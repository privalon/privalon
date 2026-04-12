#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${REPO_ROOT}/scripts/helpers/recovery_bundle.py"
RESTORE_SCRIPT="${REPO_ROOT}/scripts/restore.sh"
HELPER_DIR="${REPO_ROOT}/scripts/helpers"

log() { printf '[test] %s\n' "$*" >&2; }
die() { printf '[test][FAIL] %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

assert_file() {
  [[ -f "$1" ]] || die "Expected file to exist: $1"
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
current_repo_version="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"

temp_root="$(mktemp -d -t recovery-test-XXXXXX)"
trap 'rm -rf "${temp_root}"' EXIT

workspace="${temp_root}/fixture-repo"
env_name="drill"
env_dir="${workspace}/environments/${env_name}"
primary_root="${temp_root}/primary-store"
secondary_root="${temp_root}/secondary-store"
restore_target="${temp_root}/restored-workspace"
tmp_restore_dir="${temp_root}/tmp"

mkdir -p "${workspace}/environments/${env_name}/group_vars" "${workspace}/environments/${env_name}/inventory" "${workspace}/environments/${env_name}/.ui-logs"
mkdir -p "${primary_root}" "${secondary_root}" "${tmp_restore_dir}"

printf '%s\n' "${current_repo_version}" > "${workspace}/VERSION"
cat > "${env_dir}/secrets.env" <<EOF
TF_VAR_tfgrid_mnemonic="alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
SERVICES_ADMIN_PASSWORD=example-admin-password
RESTIC_PASSWORD=restic-master-password
EOF

cat > "${env_dir}/terraform.tfvars" <<EOF
tfgrid_network = "test"
name = "portable-recovery-test"
EOF

cat > "${env_dir}/group_vars/all.yml" <<EOF
backup_enabled: true
backup_backends:
  - name: primary
    type: s3
    endpoint: file://${primary_root}
    bucket: primary-bucket
    access_key: ignored-primary-access
    secret_key: ignored-primary-secret
  - name: secondary
    type: s3
    endpoint: file://${secondary_root}
    bucket: secondary-bucket
    access_key: ignored-secondary-access
    secret_key: ignored-secondary-secret
base_domain: example.com
EOF

printf '{"control_public_ip":{"value":"203.0.113.9"}}\n' > "${env_dir}/inventory/terraform-outputs.json"
printf 'statefile-placeholder\n' > "${env_dir}/terraform.tfstate"
printf 'grid-state-placeholder\n' > "${env_dir}/tf-grid-state.json"
printf 'deploy-tag-placeholder\n' > "${env_dir}/deployment-tag"
printf 'must-not-be-bundled\n' > "${env_dir}/.ui-logs/terminal.log"
printf '%s\n' "${current_data_model_version}" > "${env_dir}/.data-model-version"
printf 'must-not-be-bundled\n' > "${env_dir}/.data-model-version-pre-2.tar.gz"

log "Refreshing the portable recovery bundle into file-backed storage"
set +e
python3 "${HELPER}" refresh --repo-root "${workspace}" --env "${env_name}" > "${temp_root}/refresh.json"
refresh_rc=$?
set -e
[[ "${refresh_rc}" -eq 0 ]] || die "Expected helper refresh to succeed, got ${refresh_rc}"

assert_file "${env_dir}/.recovery/latest-recovery-line"
assert_file "${env_dir}/.recovery/status.json"

recovery_line="$(head -n1 "${env_dir}/.recovery/latest-recovery-line")"
[[ "${recovery_line}" == bp1.* ]] || die "Recovery line did not have the expected bp1 prefix"

python3 "${HELPER}" decode-line --recovery-line "${recovery_line}" > "${temp_root}/decoded.json"
assert_contains '"environment": "drill"' "${temp_root}/decoded.json"
assert_contains '"endpoint": "file://' "${temp_root}/decoded.json"

latest_primary="$(find "${primary_root}" -name latest.json | head -n1)"
latest_secondary="$(find "${secondary_root}" -name latest.json | head -n1)"
assert_file "${latest_primary}"
assert_file "${latest_secondary}"

manifest_primary="$(python3 - <<PYTHON
import json
with open(${latest_primary@Q}, 'r', encoding='utf-8') as handle:
    print(json.load(handle)['manifest_key'])
PYTHON
)"
assert_file "${primary_root}/primary-bucket/${manifest_primary}"
assert_contains 'environments/drill/secrets.env' "${primary_root}/primary-bucket/${manifest_primary}"
assert_contains 'environments/drill/terraform.tfvars' "${primary_root}/primary-bucket/${manifest_primary}"
assert_contains 'environments/drill/group_vars/all.yml' "${primary_root}/primary-bucket/${manifest_primary}"
assert_contains 'environments/drill/inventory/terraform-outputs.json' "${primary_root}/primary-bucket/${manifest_primary}"
assert_contains 'environments/drill/.data-model-version' "${primary_root}/primary-bucket/${manifest_primary}"
assert_contains '"data_model_version": 2' "${primary_root}/primary-bucket/${manifest_primary}"

if grep -Fq '.ui-logs' "${primary_root}/primary-bucket/${manifest_primary}"; then
  die "Manifest should not include .ui-logs paths"
fi

if grep -Fq '.data-model-version-pre-' "${primary_root}/primary-bucket/${manifest_primary}"; then
  die "Manifest should not include pre-migration rollback tarballs"
fi

log "Simulating primary latest-pointer loss to force restore fallback to secondary"
rm -f "${latest_primary}"

TMPDIR="${tmp_restore_dir}" bash "${RESTORE_SCRIPT}" \
  --recovery-line "${recovery_line}" \
  --target-dir "${restore_target}" \
  --yes > "${temp_root}/restore-output.txt"

assert_contains 'Source backend: secondary' "${temp_root}/restore-output.txt"
assert_file "${restore_target}/environments/${env_name}/secrets.env"
assert_file "${restore_target}/environments/${env_name}/terraform.tfvars"
assert_file "${restore_target}/environments/${env_name}/group_vars/all.yml"
assert_file "${restore_target}/environments/${env_name}/inventory/terraform-outputs.json"
assert_file "${restore_target}/environments/${env_name}/.data-model-version"

assert_contains 'RESTIC_PASSWORD=restic-master-password' "${restore_target}/environments/${env_name}/secrets.env"
assert_contains 'backup_enabled: true' "${restore_target}/environments/${env_name}/group_vars/all.yml"
assert_contains "${current_data_model_version}" "${restore_target}/environments/${env_name}/.data-model-version"

if find "${tmp_restore_dir}" -maxdepth 1 -type d -name 'blueprint-restore-*' | grep -q .; then
  die "Restore temporary working directories were not cleaned up"
fi

log "Portable recovery bundle verification complete"