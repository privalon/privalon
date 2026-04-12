"""Structured log section parsing for the Blueprint UI.

The UI renders deploy logs as ordered sections. Section identity must be stable
across SSE reconnects and full-log replay, while still allowing the same play
title to appear multiple times in a single run.
"""

from __future__ import annotations

import re
from typing import Dict, List, Optional

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_PLAY_RE = re.compile(r"^PLAY \[(.+?)\]")


def _slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "section"


def _strip_ansi(value: str) -> str:
    return _ANSI_RE.sub("", value)


class LogSectionParser:
    """Parse raw deploy log lines into structured section and line events."""

    def __init__(self) -> None:
        self._current: Optional[Dict[str, str]] = None
        self._section_seq = 0

    def feed_line(self, line_num: int, text: str) -> List[Dict[str, object]]:
        events: List[Dict[str, object]] = []
        candidate = self._classify_line(text)

        if self._current is None:
            candidate = candidate or {
                "kind": "init",
                "title": "Starting…",
                "signature": "init",
            }
            events.append(self._start_section(candidate))
        elif candidate is not None and self._should_start_new_section(candidate):
            events.append(self._end_current(failed=False))
            events.append(self._start_section(candidate))

        if self._current is None:
            raise RuntimeError("log section parser lost current section state")

        events.append({
            "event": "line",
            "data": {
                "line_num": line_num,
                "text": text,
                "section_id": self._current["id"],
                "section_kind": self._current["kind"],
                "section_signature": self._current["signature"],
            },
            "id": line_num,
        })
        return events

    def finish(self, failed: bool) -> List[Dict[str, object]]:
        if self._current is None:
            return []
        return [self._end_current(failed=failed)]

    def _should_start_new_section(self, candidate: Dict[str, str]) -> bool:
        if self._current is None:
            return True
        if candidate["kind"] == "play":
            return True
        return candidate["signature"] != self._current["signature"]

    def _start_section(self, candidate: Dict[str, str]) -> Dict[str, object]:
        slug = _slugify(candidate["signature"].split(":", 1)[-1])
        section = {
            "id": f"{candidate['kind']}-{self._section_seq:04d}-{slug}",
            "kind": candidate["kind"],
            "title": candidate["title"],
            "signature": candidate["signature"],
        }
        self._section_seq += 1
        self._current = section
        return {
            "event": "section-start",
            "data": section.copy(),
        }

    def _end_current(self, failed: bool) -> Dict[str, object]:
        if self._current is None:
            raise RuntimeError("no current section to end")
        current = self._current
        self._current = None
        return {
            "event": "section-end",
            "data": {
                **current,
                "failed": failed,
            },
        }

    def _classify_line(self, text: str) -> Optional[Dict[str, str]]:
        plain = _strip_ansi(text)

        if re.match(r"^\[env\]|^\[deploy\]|^Detected existing|^Destroy and recreate", plain):
            return {"kind": "preflight", "title": "Pre-flight", "signature": "preflight"}
        if re.match(r"^\[terraform\]", plain):
            return {"kind": "terraform", "title": "Terraform", "signature": "terraform"}
        if re.match(r"^\[dns\]", plain):
            return {"kind": "dns", "title": "DNS setup", "signature": "dns"}
        if re.match(r"^\[ssh-wait\]", plain):
            return {"kind": "ssh-wait", "title": "SSH reachability", "signature": "ssh-wait"}
        if re.match(r"^PLAY RECAP", plain):
            return {"kind": "recap", "title": "Ansible recap", "signature": "recap"}
        if re.match(r"^[\u2550]{5,}|DEPLOYMENT SUMMARY", plain):
            return {"kind": "summary", "title": "Deployment summary", "signature": "summary"}

        match = _PLAY_RE.match(plain)
        if match:
            title = match.group(1)
            return {
                "kind": "play",
                "title": title,
                "signature": f"play:{_slugify(title)}",
            }

        return None