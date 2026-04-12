"""Timing-profile helpers for Blueprint deployment progress estimation."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, Optional


PROFILE_VERSION = 1
EMA_ALPHA = 0.3


def environments_root() -> Path:
    override = os.environ.get("BLUEPRINT_ENVIRONMENTS_DIR", "").strip()
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[2] / "environments"


@dataclass(frozen=True)
class JobRecord:
    job_id: str
    scope: str
    start_time: str
    end_time: str
    meta_file: Path
    log_file: Path


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _read_json(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None


def _iter_successful_jobs(logs_dir: Path) -> Iterable[JobRecord]:
    jobs = []

    for meta_file in sorted(logs_dir.glob("*.json")):
        if meta_file.name == "timing-profile.json":
            continue

        payload = _read_json(meta_file)
        if not payload or payload.get("status") != "done":
            continue

        job_id = payload.get("job_id")
        scope = payload.get("scope")
        end_time = payload.get("end_time")
        start_time = payload.get("start_time") or end_time
        if not job_id or not scope or not start_time or not end_time:
            continue

        log_file = logs_dir / f"{job_id}.log"
        if not log_file.exists():
            continue

        jobs.append(
            JobRecord(
                job_id=job_id,
                scope=scope,
                start_time=start_time,
                end_time=end_time,
                meta_file=meta_file,
                log_file=log_file,
            )
        )

    jobs.sort(key=lambda job: (_parse_iso(job.end_time), job.job_id))
    return jobs


def _update_ema(entry: dict, field: str, observed: float) -> None:
    runs = int(entry.get("runs", 0) or 0)
    if runs <= 0 or field not in entry:
        entry[field] = float(observed)
        return
    entry[field] = ((1.0 - EMA_ALPHA) * float(entry[field])) + (EMA_ALPHA * float(observed))


def _parse_progress_log(log_file: Path) -> Optional[dict]:
    try:
        lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None

    plan = None
    plan_steps: Dict[str, dict] = {}
    ansible_counts: Dict[str, int] = {}
    step_durations: Dict[str, int] = {}

    for line in lines:
        if not line.startswith("[bp-progress] "):
            continue

        try:
            payload = json.loads(line[len("[bp-progress] "):])
        except json.JSONDecodeError:
            continue

        marker_type = payload.get("type")
        if marker_type == "plan":
            plan = payload
            plan_steps = {step["id"]: step for step in payload.get("steps", []) if step.get("id")}
            continue

        if marker_type == "ansible-task":
            step_id = payload.get("step_id")
            if step_id:
                ansible_counts[step_id] = ansible_counts.get(step_id, 0) + 1
            continue

        if marker_type == "step-done":
            step_id = payload.get("step_id")
            step_elapsed_ms = payload.get("step_elapsed_ms")
            if step_id and isinstance(step_elapsed_ms, int):
                step_durations[step_id] = step_elapsed_ms

    if not step_durations:
        return None

    return {
        "plan": plan or {"steps": []},
        "plan_steps": plan_steps,
        "ansible_counts": ansible_counts,
        "step_durations": step_durations,
    }


def build_timing_profile(env: str, *, env_root: Optional[Path] = None) -> dict:
    root = (env_root or environments_root()).resolve()
    logs_dir = root / env / ".ui-logs"
    profile = {
        "version": PROFILE_VERSION,
        "env": env,
        "updated": _iso_now(),
        "alpha": EMA_ALPHA,
        "job_count": 0,
        "scopes": {},
    }

    if not logs_dir.is_dir():
        return profile

    for job in _iter_successful_jobs(logs_dir):
        parsed = _parse_progress_log(job.log_file)
        if not parsed:
            continue

        scope_entry = profile["scopes"].setdefault(job.scope, {"runs": 0, "steps": {}, "summary": {}})
        scope_entry["runs"] += 1
        profile["job_count"] += 1

        for step_id, observed_ms in parsed["step_durations"].items():
            plan_step = parsed["plan_steps"].get(step_id, {})
            kind = plan_step.get("kind") or ("ansible" if step_id.startswith("ansible") else "script")
            label = plan_step.get("label") or step_id
            plan_weight = int(plan_step.get("weight") or 1)

            step_entry = scope_entry["steps"].setdefault(
                step_id,
                {
                    "label": label,
                    "kind": kind,
                    "runs": 0,
                    "avg_ms": float(observed_ms),
                    "avg_weight": float(plan_weight),
                },
            )

            step_entry["label"] = label
            step_entry["kind"] = kind
            _update_ema(step_entry, "avg_ms", observed_ms)
            _update_ema(step_entry, "avg_weight", plan_weight)

            if kind == "ansible":
                observed_units = max(1, int(parsed["ansible_counts"].get(step_id, plan_weight or 1)))
                _update_ema(step_entry, "avg_units", observed_units)
                _update_ema(step_entry, "avg_unit_ms", observed_ms / observed_units)

            step_entry["runs"] = int(step_entry.get("runs", 0) or 0) + 1

    for scope_entry in profile["scopes"].values():
        script_ms_per_weight = []
        ansible_unit_ms = []
        total_avg_ms = 0.0

        for step in scope_entry["steps"].values():
            avg_ms = float(step.get("avg_ms", 0.0) or 0.0)
            total_avg_ms += avg_ms

            if step.get("kind") == "ansible":
                avg_unit_ms = float(step.get("avg_unit_ms", 0.0) or 0.0)
                if avg_unit_ms > 0:
                    ansible_unit_ms.append(avg_unit_ms)
                continue

            avg_weight = max(1.0, float(step.get("avg_weight", 1.0) or 1.0))
            if avg_ms > 0:
                script_ms_per_weight.append(avg_ms / avg_weight)

        scope_entry["summary"] = {
            "avg_total_ms": total_avg_ms,
            "avg_script_ms_per_weight": sum(script_ms_per_weight) / len(script_ms_per_weight) if script_ms_per_weight else None,
            "avg_ansible_unit_ms": sum(ansible_unit_ms) / len(ansible_unit_ms) if ansible_unit_ms else None,
        }

    return profile


def refresh_timing_profile(env: str, *, env_root: Optional[Path] = None) -> dict:
    root = (env_root or environments_root()).resolve()
    profile = build_timing_profile(env, env_root=root)
    logs_dir = root / env / ".ui-logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    target = logs_dir / "timing-profile.json"
    tmp = target.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(profile, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, target)
    return profile


def load_timing_profile(env: str, *, env_root: Optional[Path] = None) -> dict:
    return refresh_timing_profile(env, env_root=env_root)