#!/usr/bin/env python3

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


HEADER_RE = re.compile(
    r"^## \[(?P<version>[^\]]+)\](?:\s+(?P<separator>[—-])\s+(?P<date>\d{4}-\d{2}-\d{2}))?\s*$",
    re.MULTILINE,
)


@dataclass(frozen=True)
class Section:
    version: str
    separator: str | None
    date: str | None
    body: str


def parse_sections(text: str) -> dict[str, Section]:
    matches = list(HEADER_RE.finditer(text))
    sections: dict[str, Section] = {}

    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        version = match.group("version")
        sections[version] = Section(
            version=version,
            separator=match.group("separator"),
            date=match.group("date"),
            body=text[start:end],
        )

    return sections


def _load_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def rewrite_text(text: str, header_map: dict[str, tuple[str, str]]) -> str:
    def replace(match: re.Match[str]) -> str:
        version = match.group("version")
        if version == "Unreleased":
            return match.group(0)

        mapped = header_map.get(version)
        if not mapped:
            return match.group(0)

        separator, date = mapped
        return f"## [{version}] {separator} {date}"

    return HEADER_RE.sub(replace, text)


def stamp_public_dates(current_path: str, previous_path: str | None, push_date: str) -> None:
    current_text = _load_text(current_path)
    current_sections = parse_sections(current_text)
    previous_sections = parse_sections(_load_text(previous_path)) if previous_path else {}

    header_map: dict[str, tuple[str, str]] = {}
    for version, current_section in current_sections.items():
        if version == "Unreleased":
            continue

        previous_section = previous_sections.get(version)
        separator = current_section.separator or "—"

        if previous_section and previous_section.body == current_section.body and previous_section.date:
            header_map[version] = (previous_section.separator or separator, previous_section.date)
            continue

        header_map[version] = (separator, push_date)

    Path(current_path).write_text(rewrite_text(current_text, header_map), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["stamp-public-dates"])
    parser.add_argument("--current", required=True)
    parser.add_argument("--push-date", required=True)
    parser.add_argument("--previous")

    args = parser.parse_args()
    stamp_public_dates(args.current, args.previous, args.push_date)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())