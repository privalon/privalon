#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RECOVERY_HELPER="${REPO_ROOT}/scripts/helpers/recovery_bundle.py"
MIGRATION_HELPER_REL="scripts/helpers/data_migrations.py"
CURRENT_MIGRATION_HELPER="${REPO_ROOT}/${MIGRATION_HELPER_REL}"

RECOVERY_LINE=""
RECOVERY_LINE_FILE=""
TARGET_DIR=""
REUSE_CURRENT_CHECKOUT=0
ASSUME_YES=0
TEMP_WORK_DIR=""
FORCE_CURRENT_CHECKOUT=0
CHECKOUT_SOURCE="recorded"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/restore.sh --recovery-line '<opaque-line>' [--target-dir path] [--yes]
  ./scripts/restore.sh --recovery-line-file path/to/file [--target-dir path] [--reuse-current-checkout]

Options:
  --recovery-line <line>        Opaque recovery line printed by deploy.sh
  --recovery-line-file <path>   File containing the opaque recovery line
  --target-dir <path>           Directory for the restored workspace
  --reuse-current-checkout      Restore into the current repo checkout instead of creating a sibling workspace
  --yes                         Assume yes for interactive prompts where safe
  -h, --help                    Show this help text
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 127
  }
}

ask_yes_no() {
  local prompt="$1"
  local default_answer="${2:-n}"

  if [[ "${ASSUME_YES}" == "1" ]]; then
    [[ "${default_answer}" == "n" ]] && return 1
    return 0
  fi

  local suffix="[y/N]"
  [[ "${default_answer}" == "y" ]] && suffix="[Y/n]"

  local reply=""
  read -r -p "${prompt} ${suffix} " reply
  reply="${reply:-${default_answer}}"
  [[ "${reply,,}" == "y" ]]
}

read_recovery_line() {
  if [[ -n "${RECOVERY_LINE}" ]]; then
    printf '%s' "${RECOVERY_LINE}"
    return 0
  fi

  if [[ -n "${RECOVERY_LINE_FILE}" ]]; then
    if [[ ! -f "${RECOVERY_LINE_FILE}" ]]; then
      echo "Recovery line file not found: ${RECOVERY_LINE_FILE}" >&2
      exit 2
    fi
    head -n1 "${RECOVERY_LINE_FILE}" | tr -d '\r\n'
    return 0
  fi

  echo "Either --recovery-line or --recovery-line-file is required." >&2
  exit 2
}

json_field() {
  local json_file="$1"
  local field="$2"
  python3 - <<PYTHON
import json

with open(${json_file@Q}, 'r', encoding='utf-8') as handle:
    data = json.load(handle)

value = data
for part in ${field@Q}.split('.'):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break

if value is None:
    raise SystemExit(1)
print(value)
PYTHON
}

current_repo_version() {
  if [[ -f "${REPO_ROOT}/VERSION" ]]; then
    tr -d '[:space:]' < "${REPO_ROOT}/VERSION"
  fi
}

current_repo_commit() {
  git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || true
}

current_data_model_version() {
  PYTHONPATH="${REPO_ROOT}/scripts/helpers${PYTHONPATH:+:${PYTHONPATH}}" python3 - <<'PYTHON'
from data_model_version import DATA_MODEL_VERSION

print(DATA_MODEL_VERSION)
PYTHON
}

prepare_target_checkout() {
  local environment="$1"
  local repo_version="$2"
  local git_commit="$3"

  if [[ "${REUSE_CURRENT_CHECKOUT}" == "1" ]]; then
    TARGET_DIR="${REPO_ROOT}"
    return 0
  fi

  if [[ -z "${TARGET_DIR}" ]]; then
    TARGET_DIR="$(cd "${REPO_ROOT}/.." && pwd)/privalon-restore-${environment}-$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  if [[ -e "${TARGET_DIR}" && "$(find "${TARGET_DIR}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" -gt 0 ]]; then
    echo "Target directory already exists and is not empty: ${TARGET_DIR}" >&2
    exit 2
  fi
  mkdir -p "${TARGET_DIR}"

  if [[ "${FORCE_CURRENT_CHECKOUT}" == "1" ]]; then
    CHECKOUT_SOURCE="current"
    if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "${REPO_ROOT}" worktree add --force --detach "${TARGET_DIR}" HEAD >/dev/null 2>&1 && return 0
    fi
    cp -a "${REPO_ROOT}/." "${TARGET_DIR}/"
    return 0
  fi

  if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "${git_commit}" ]]; then
      if git -C "${REPO_ROOT}" fetch --depth 1 origin "${git_commit}" >/dev/null 2>&1; then
        git -C "${REPO_ROOT}" worktree add --force --detach "${TARGET_DIR}" FETCH_HEAD >/dev/null 2>&1 && return 0
      fi
    fi

    if [[ -n "${repo_version}" ]]; then
      if git -C "${REPO_ROOT}" fetch --depth 1 origin "refs/tags/v${repo_version}" >/dev/null 2>&1; then
        git -C "${REPO_ROOT}" worktree add --force --detach "${TARGET_DIR}" "refs/tags/v${repo_version}" >/dev/null 2>&1 && return 0
      fi
      if git -C "${REPO_ROOT}" fetch --depth 1 origin "refs/tags/${repo_version}" >/dev/null 2>&1; then
        git -C "${REPO_ROOT}" worktree add --force --detach "${TARGET_DIR}" "refs/tags/${repo_version}" >/dev/null 2>&1 && return 0
      fi
    fi
  fi

  if [[ "$(current_repo_commit)" == "${git_commit}" || "$(current_repo_version)" == "${repo_version}" ]]; then
    cp -a "${REPO_ROOT}/." "${TARGET_DIR}/"
    return 0
  fi

  if ask_yes_no "Could not fetch the recorded repo revision. Fall back to a copy of the current checkout?" "n"; then
    cp -a "${REPO_ROOT}/." "${TARGET_DIR}/"
    return 0
  fi

  echo "Restore cancelled because the required repo revision could not be fetched." >&2
  exit 1
}

restore_payload() {
  local extract_root="$1"
  local target_dir="$2"

  (cd "${extract_root}" && tar -cf - environments bundle-metadata.json recovery-manifest.json 2>/dev/null) | (cd "${target_dir}" && tar -xf -)
}

run_data_model_migrations() {
  local target_dir="$1"
  local environment="$2"
  local from_version="$3"

  local helper="${target_dir}/${MIGRATION_HELPER_REL}"
  if [[ ! -f "${helper}" ]]; then
    helper="${CURRENT_MIGRATION_HELPER}"
  fi

  if [[ ! -f "${helper}" ]]; then
    echo "Data migration helper not found in target checkout or current repo." >&2
    exit 1
  fi

  python3 "${helper}" migrate \
    --env-dir "${target_dir}/environments/${environment}" \
    --from-version "${from_version}"
}

prompt_edit_step() {
  : # edit step removed — open the restored workspace manually if needed
}

cleanup() {
  if [[ -n "${TEMP_WORK_DIR}" && -d "${TEMP_WORK_DIR}" ]]; then
    rm -rf "${TEMP_WORK_DIR}"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recovery-line)
        RECOVERY_LINE="$2"
        shift 2
        ;;
      --recovery-line-file)
        RECOVERY_LINE_FILE="$2"
        shift 2
        ;;
      --target-dir)
        TARGET_DIR="$2"
        shift 2
        ;;
      --reuse-current-checkout)
        REUSE_CURRENT_CHECKOUT=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  need_cmd bash
  need_cmd python3
  need_cmd tar
  need_cmd openssl

  if [[ ! -f "${RECOVERY_HELPER}" ]]; then
    echo "Recovery helper not found: ${RECOVERY_HELPER}" >&2
    exit 1
  fi

  local line
  line="$(read_recovery_line)"

  TEMP_WORK_DIR="$(mktemp -d -t blueprint-restore-XXXXXX)"
  trap cleanup EXIT

  local prepare_json="${TEMP_WORK_DIR}/prepare.json"
  python3 "${RECOVERY_HELPER}" prepare-restore \
    --recovery-line "${line}" \
    --work-dir "${TEMP_WORK_DIR}" > "${prepare_json}"

  local environment
  local repo_version
  local git_commit
  local bundle_data_model_version
  local current_model_version
  local extract_root
  local source_backend
  environment="$(json_field "${prepare_json}" environment)"
  repo_version="$(json_field "${prepare_json}" repo_version 2>/dev/null || true)"
  git_commit="$(json_field "${prepare_json}" git_commit 2>/dev/null || true)"
  bundle_data_model_version="$(json_field "${prepare_json}" data_model_version 2>/dev/null || printf '1')"
  extract_root="$(json_field "${prepare_json}" extract_root)"
  source_backend="$(json_field "${prepare_json}" source_backend)"

  current_model_version="$(current_data_model_version)"
  if [[ "${REUSE_CURRENT_CHECKOUT}" != "1" && "${bundle_data_model_version}" -lt "${current_model_version}" ]]; then
    FORCE_CURRENT_CHECKOUT=1
  fi

  if [[ "${REUSE_CURRENT_CHECKOUT}" == "1" ]]; then
    local current_commit
    local current_version
    current_commit="$(current_repo_commit)"
    current_version="$(current_repo_version)"
    if [[ -n "${git_commit}" && -n "${current_commit}" && "${git_commit}" != "${current_commit}" && "${repo_version}" != "${current_version}" ]]; then
      if ! ask_yes_no "The current checkout does not match the recorded bundle revision. Continue anyway with the current checkout?" "n"; then
        echo "Restore cancelled." >&2
        exit 1
      fi
    fi
  fi

  prepare_target_checkout "${environment}" "${repo_version}" "${git_commit}"
  restore_payload "${extract_root}" "${TARGET_DIR}"
  run_data_model_migrations "${TARGET_DIR}" "${environment}" "${bundle_data_model_version}"
  prompt_edit_step "${environment}" "${TARGET_DIR}"

  echo ""
  echo "Portable restore prepared successfully"
  echo "  Environment:    ${environment}"
  echo "  Source backend: ${source_backend}"
  echo "  Workspace:      ${TARGET_DIR}"
  if [[ -n "${repo_version}" ]]; then
    echo "  Repo version:   ${repo_version}"
  fi
  if [[ -n "${git_commit}" ]]; then
    echo "  Git commit:     ${git_commit}"
  fi
  echo "  Data model:     ${bundle_data_model_version} -> ${current_model_version}"
  if [[ "${CHECKOUT_SOURCE}" == "current" ]]; then
    echo "  Code checkout:  current checkout (bundle data required migration)"
  fi
}

main "$@"