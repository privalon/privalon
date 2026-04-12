#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"
CHANGELOG_FILE="${REPO_ROOT}/CHANGELOG.md"
TODAY="$(date +%F)"

usage() {
  cat <<'USAGE'
Usage:
  scripts/release.sh current
  scripts/release.sh next <major|minor|patch>
  scripts/release.sh set <version>
  scripts/release.sh bump <major|minor|patch>

Commands:
  current              Print the current repo version from VERSION.
  next <part>          Print the next semantic version without modifying files.
  set <version>        Set VERSION to an explicit semantic version and scaffold CHANGELOG.md.
  bump <part>          Increment VERSION and snapshot the current Unreleased changelog section.
USAGE
}

need_file() {
  local path="$1"
  [[ -f "$path" ]] || {
    echo "Missing required file: $path" >&2
    exit 1
  }
}

current_version() {
  need_file "$VERSION_FILE"
  tr -d '[:space:]' < "$VERSION_FILE"
}

validate_semver() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

increment_version() {
  local version="$1"
  local part="$2"
  local major minor patch

  IFS=. read -r major minor patch <<< "$version"

  case "$part" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch)
      patch=$((patch + 1))
      ;;
    *)
      echo "Unknown version part: $part" >&2
      exit 2
      ;;
  esac

  printf '%s\n' "${major}.${minor}.${patch}"
}

write_version() {
  local version="$1"
  printf '%s\n' "$version" > "$VERSION_FILE"
}

scaffold_changelog_release() {
  local version="$1"
  VERSION="$version" TODAY="$TODAY" CHANGELOG_FILE="$CHANGELOG_FILE" python3 - <<'PY'
import os
import re
from pathlib import Path

version = os.environ["VERSION"]
today = os.environ["TODAY"]
path = Path(os.environ["CHANGELOG_FILE"])
text = path.read_text(encoding="utf-8")

if f"## [{version}]" in text:
    raise SystemExit(0)

section_re = re.compile(r"^## \[(?P<name>[^\]]+)\]\n", re.MULTILINE)
match = section_re.search(text)
if not match or match.group("name") != "Unreleased":
    raise SystemExit("CHANGELOG.md must start with an [Unreleased] section")

next_match = section_re.search(text, match.end())
unreleased_body = text[match.end():next_match.start() if next_match else len(text)]
clean_body = unreleased_body.strip("\n")

if not clean_body:
    clean_body = "### Added\n- No documented changes yet."

replacement = (
    "## [Unreleased]\n\n"
    "### Added\n"
    "- No documented changes yet.\n\n"
    f"## [{version}] - {today}\n\n"
    f"{clean_body}\n\n"
)

text = text[:match.start()] + replacement + text[next_match.start() if next_match else len(text):]
path.write_text(text, encoding="utf-8")
PY
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  local command="$1"
  shift

  case "$command" in
    current)
      printf '%s\n' "$(current_version)"
      ;;
    next)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      increment_version "$(current_version)" "$1"
      ;;
    set)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      validate_semver "$1" || {
        echo "Version must be semantic (X.Y.Z): $1" >&2
        exit 2
      }
      write_version "$1"
      scaffold_changelog_release "$1"
      printf 'Updated VERSION to %s\n' "$1"
      ;;
    bump)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      local next
      next="$(increment_version "$(current_version)" "$1")"
      write_version "$next"
      scaffold_changelog_release "$next"
      printf 'Updated VERSION to %s\n' "$next"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: $command" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
