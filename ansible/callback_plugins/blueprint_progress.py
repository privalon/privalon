"""Emit machine-readable progress markers for Blueprint Ansible runs."""

from __future__ import annotations

import json
import os
import sys
import time

from ansible.plugins.callback import CallbackBase


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "blueprint_progress"
    CALLBACK_NEEDS_WHITELIST = False

    def __init__(self) -> None:
        super().__init__()
        self._step_id = os.environ.get("BLUEPRINT_PROGRESS_STEP_ID", "ansible-main")
        self._current_play = ""

    def _emit(self, payload: dict) -> None:
        payload = {
            **payload,
            "ts_ms": time.time_ns() // 1_000_000,
        }
        sys.stdout.write(f"[bp-progress] {json.dumps(payload, separators=(',', ':'))}\n")
        sys.stdout.flush()

    def v2_playbook_on_play_start(self, play) -> None:
        self._current_play = (play.get_name() or "Unnamed play").strip()
        self._emit(
            {
                "type": "ansible-play",
                "step_id": self._step_id,
                "play": self._current_play,
            }
        )

    def v2_playbook_on_task_start(self, task, is_conditional) -> None:
        action = getattr(task, "action", "") or ""
        if action == "meta":
            return
        self._emit(
            {
                "type": "ansible-task",
                "step_id": self._step_id,
                "play": self._current_play,
                "task": (task.get_name() or action or "Unnamed task").strip(),
            }
        )

    def v2_playbook_on_handler_task_start(self, task) -> None:
        action = getattr(task, "action", "") or ""
        self._emit(
            {
                "type": "ansible-task",
                "step_id": self._step_id,
                "play": self._current_play,
                "task": (task.get_name() or action or "Unnamed handler").strip(),
                "handler": True,
            }
        )