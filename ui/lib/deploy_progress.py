#!/usr/bin/env python3
"""Runtime deployment progress planning for the Blueprint UI.

Builds a weighted execution plan for a deploy scope and estimates Ansible work
from the real playbook via ``ansible-playbook --list-tasks`` with the active
environment overrides. The resulting plan is emitted as a structured log marker
that the Web UI can consume while the job is running.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional


LIST_TASK_PLAY_RE = re.compile(r"^play\s+#\d+\s*\(", re.IGNORECASE)


def count_listed_tasks(output: str) -> int:
    count = 0
    play_count = 0
    in_tasks_block = False

    for raw_line in output.splitlines():
        stripped = raw_line.strip()

        if LIST_TASK_PLAY_RE.match(stripped):
            play_count += 1
            in_tasks_block = False
            continue

        if stripped == "tasks:":
            in_tasks_block = True
            continue

        if not in_tasks_block:
            continue

        if not stripped:
            continue

        if not raw_line.startswith("      "):
            in_tasks_block = False
            continue

        if "TAGS:" in stripped:
            count += 1

    return count + play_count


@dataclass(frozen=True)
class PlanContext:
    repo_root: Path
    env_name: str
    scope: str
    destroy_first: bool = False
    join_local: bool = False
    converge_join_local: bool = False
    no_restore: bool = False
    fresh_tailnet: bool = False
    allow_ssh_from: tuple[str, ...] = ()

    @property
    def env_dir(self) -> Path:
        return self.repo_root / "environments" / self.env_name

    @property
    def inventory_dir(self) -> Path:
        return self.env_dir / "inventory"

    @property
    def ansible_dir(self) -> Path:
        return self.repo_root / "ansible"


@dataclass(frozen=True)
class PlanStep:
    step_id: str
    label: str
    kind: str
    weight: int
    limit: str = ""
    tags: str = ""

    def to_dict(self) -> dict:
        return {
            "id": self.step_id,
            "label": self.label,
            "kind": self.kind,
            "weight": self.weight,
        }


def _script(step_id: str, label: str, weight: int) -> PlanStep:
    return PlanStep(step_id=step_id, label=label, kind="script", weight=weight)


def _ansible(step_id: str, label: str, *, limit: str = "", tags: str = "") -> PlanStep:
    return PlanStep(step_id=step_id, label=label, kind="ansible", weight=0, limit=limit, tags=tags)


def build_step_blueprint(ctx: PlanContext) -> List[PlanStep]:
    if ctx.scope == "full":
        steps = [_script("tf-init", "Initialize Terraform", 1)]
        if ctx.destroy_first:
            steps.extend(
                [
                    _script("pre-destroy-backup", "Back up existing deployment", 2),
                    _script("terraform-destroy", "Destroy existing infrastructure", 8),
                ]
            )
        steps.extend(
            [
                _script("deployment-tag", "Prepare deployment tag", 1),
                _script("terraform-apply", "Apply Terraform", 12),
                _script("refresh-inventory", "Refresh inventory outputs", 1),
                _script("data-migrations", "Apply data migrations", 1),
                _script("clear-host-keys", "Clear stale SSH host keys", 1),
                _script("dns-setup", "Update DNS", 2),
            ]
        )
        if ctx.converge_join_local:
            steps.append(_script("join-local", "Join this machine to the tailnet", 3))
        steps.append(_script("wait-ssh", "Wait for SSH reachability", 3))
        if ctx.join_local:
            steps.extend(
                [
                    _ansible("ansible-bootstrap", "Bootstrap control plane", limit="control"),
                    _script("join-local", "Join this machine to the tailnet", 3),
                ]
            )
        steps.append(_ansible("ansible-main", "Run Ansible", limit=""))
        if ctx.converge_join_local and not ctx.join_local:
            steps.append(_script("join-local", "Re-join this machine after Ansible", 3))
        steps.extend(
            [
                _script("recovery-refresh", "Refresh recovery bundle", 2),
                _script("deployment-summary", "Render deployment summary", 1),
            ]
        )
        return steps

    if ctx.scope == "gateway":
        steps = [_script("tf-init", "Initialize Terraform", 1), _script("deployment-tag", "Prepare deployment tag", 1)]
        if ctx.destroy_first:
            steps.append(_script("pre-destroy-backup", "Back up existing gateway", 2))
        steps.extend(
            [
                _script("terraform-apply", "Apply Terraform", 12),
                _script("refresh-inventory", "Refresh inventory outputs", 1),
                _script("data-migrations", "Apply data migrations", 1),
                _script("clear-host-keys", "Clear stale SSH host keys", 1),
                _script("dns-setup", "Update DNS", 2),
            ]
        )
        if ctx.converge_join_local:
            steps.append(_script("join-local", "Join this machine to the tailnet", 3))
        steps.extend(
            [
                _script("wait-ssh", "Wait for SSH reachability", 3),
                _ansible("ansible-main", "Run Ansible", limit="control:gateway:monitoring-vm"),
            ]
        )
        if ctx.join_local or ctx.converge_join_local:
            steps.append(_script("join-local", "Re-join this machine after Ansible", 3))
        steps.extend(
            [
                _script("recovery-refresh", "Refresh recovery bundle", 2),
                _script("deployment-summary", "Render deployment summary", 1),
            ]
        )
        return steps

    if ctx.scope == "control":
        steps = [_script("tf-init", "Initialize Terraform", 1), _script("deployment-tag", "Prepare deployment tag", 1)]
        if ctx.destroy_first:
            steps.append(_script("pre-destroy-backup", "Back up existing control plane", 2))
        steps.extend(
            [
                _script("terraform-apply", "Apply Terraform", 12),
                _script("refresh-inventory", "Refresh inventory outputs", 1),
                _script("data-migrations", "Apply data migrations", 1),
                _script("clear-host-keys", "Clear stale SSH host keys", 1),
                _script("dns-setup", "Update DNS", 2),
            ]
        )
        if ctx.converge_join_local:
            steps.append(_script("join-local", "Join this machine to the tailnet", 3))
        steps.append(_script("wait-ssh", "Wait for SSH reachability", 3))
        steps.append(_ansible("ansible-main", "Run Ansible", limit=""))
        if ctx.converge_join_local and not ctx.destroy_first:
            steps.append(_script("join-local", "Re-join this machine after Ansible", 3))
        steps.extend(
            [
                _script("recovery-refresh", "Refresh recovery bundle", 2),
                _script("deployment-summary", "Render deployment summary", 1),
            ]
        )
        return steps

    if ctx.scope == "dns":
        return [_script("dns-setup", "Update DNS", 2)]

    if ctx.scope in {"join-local", "join_local"}:
        return [_script("join-local", "Join this machine to the tailnet", 3)]

    return [_script("unknown-scope", f"Run {ctx.scope}", 1)]


def _ansible_extra_args(ctx: PlanContext) -> List[str]:
    args: List[str] = [
        "--extra-vars",
        f"headscale_local_inventory_dir={ctx.inventory_dir} tailscale_local_inventory_dir={ctx.inventory_dir} blueprint_env={ctx.env_name}",
    ]

    for name in ("all", "gateway", "control", "monitoring"):
        path = ctx.env_dir / "group_vars" / f"{name}.yml"
        if path.is_file():
            args.extend(["--extra-vars", f"@{path}"])

    if ctx.no_restore:
        args.extend(["--extra-vars", json.dumps({"backup_restore_enabled": False})])

    if ctx.fresh_tailnet:
        args.extend(
            [
                "--extra-vars",
                json.dumps({
                    "headscale_restore_database": False,
                    "tailscale_restore_state": False,
                }),
            ]
        )

    if ctx.allow_ssh_from:
        args.extend(
            [
                "--extra-vars",
                json.dumps({"firewall_allow_public_ssh_from_cidrs": list(ctx.allow_ssh_from)}),
            ]
        )

    return args


def count_ansible_tasks(ctx: PlanContext, step: PlanStep) -> int:
    env = os.environ.copy()
    env["TF_OUTPUTS_JSON"] = str(ctx.inventory_dir / "terraform-outputs.json")
    env["TAILSCALE_IPS_JSON"] = str(ctx.inventory_dir / "tailscale-ips.json")

    cmd = ["ansible-playbook", "-i", "inventory/tfgrid.py", "playbooks/site.yml"]
    if step.limit:
        cmd.extend(["--limit", step.limit])
    if step.tags:
        cmd.extend(["--tags", step.tags])
    cmd.extend(_ansible_extra_args(ctx))
    cmd.append("--list-tasks")

    try:
        proc = subprocess.run(
            cmd,
            cwd=ctx.ansible_dir,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return 1

    output = f"{proc.stdout}\n{proc.stderr}"
    count = count_listed_tasks(output)
    return max(count, 1)


def build_plan(ctx: PlanContext, task_counter: Optional[Callable[[PlanContext, PlanStep], int]] = None) -> dict:
    counter = task_counter or count_ansible_tasks
    resolved_steps: List[PlanStep] = []
    units_total = 0

    for step in build_step_blueprint(ctx):
        if step.kind == "ansible":
            weight = counter(ctx, step)
            step = replace(step, weight=max(weight, 1))
        resolved_steps.append(step)
        units_total += step.weight

    return {
        "type": "plan",
        "ts_ms": time.time_ns() // 1_000_000,
        "scope": ctx.scope,
        "env": ctx.env_name,
        "units_total": units_total,
        "steps": [step.to_dict() for step in resolved_steps],
    }


def emit_plan_marker(ctx: PlanContext) -> None:
    payload = build_plan(ctx)
    print(f"[bp-progress] {json.dumps(payload, separators=(',', ':'))}")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Blueprint deploy progress planner")
    subparsers = parser.add_subparsers(dest="command", required=True)

    emit = subparsers.add_parser("emit-plan", help="emit a progress plan marker")
    emit.add_argument("--repo-root", required=True)
    emit.add_argument("--env", required=True)
    emit.add_argument("--scope", required=True)
    emit.add_argument("--destroy-first", action="store_true")
    emit.add_argument("--join-local", action="store_true")
    emit.add_argument("--converge-join-local", action="store_true")
    emit.add_argument("--no-restore", action="store_true")
    emit.add_argument("--fresh-tailnet", action="store_true")
    emit.add_argument("--allow-ssh-from", action="append", default=[])

    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.command == "emit-plan":
        ctx = PlanContext(
            repo_root=Path(args.repo_root).resolve(),
            env_name=args.env,
            scope=args.scope,
            destroy_first=args.destroy_first,
            join_local=args.join_local,
            converge_join_local=args.converge_join_local,
            no_restore=args.no_restore,
            fresh_tailnet=args.fresh_tailnet,
            allow_ssh_from=tuple(args.allow_ssh_from or ()),
        )
        emit_plan_marker(ctx)
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())