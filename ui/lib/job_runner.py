"""Job runner for Blueprint Web UI.

Each Job represents one invocation of scripts/deploy.sh.
Output is fanned to:
  1. An append-only log file: environments/<env>/.ui-logs/<job-id>.log
  2. An in-memory line buffer (capped at MAX_BUFFER lines) for fast delivery
     to new SSE subscribers, and a per-subscriber asyncio.Queue for live tail.

Thread-safety model: all mutation is serialised through self._lock (asyncio.Lock).
File writes happen before _total_lines is incremented so that any subscriber who
snapshots _total_lines inside the lock can safely read the file for [0, snapshot).
"""

import asyncio
import hashlib
import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    from .timing import refresh_timing_profile
except ImportError:  # pragma: no cover - script-style imports use this path
    from timing import refresh_timing_profile

REPO_ROOT = Path(__file__).resolve().parents[2]
MAX_BUFFER = 1000
_ALLOWED_PROGRESS_HELPERS = {"progress_step_start", "progress_step_done"}


def environments_root() -> Path:
    override = os.environ.get("BLUEPRINT_ENVIRONMENTS_DIR", "").strip()
    if override:
        return Path(override)
    return REPO_ROOT / "environments"


class Job:
    __slots__ = (
        "job_id", "env", "scope", "extra_args", "source", "pid",
        "start_time", "end_time", "exit_code", "status",
        "log_dir", "log_file", "meta_file",
        "_buffer", "_buffer_start", "_total_lines",
        "_waiters", "_lock", "_process",
    )

    def __init__(
        self,
        job_id: str,
        env: str,
        scope: str,
        extra_args: List[str],
        *,
        source: str = "ui",
        pid: Optional[int] = None,
    ) -> None:
        self.job_id = job_id
        self.env = env
        self.scope = scope
        self.extra_args = extra_args
        self.source = source
        self.pid = pid
        self.start_time: str = datetime.now(timezone.utc).isoformat()
        self.end_time: Optional[str] = None
        self.exit_code: Optional[int] = None
        self.status: str = "running"

        self.log_dir = environments_root() / env / ".ui-logs"
        self.log_file = self.log_dir / f"{job_id}.log"
        self.meta_file = self.log_dir / f"{job_id}.json"

        self._buffer: List[str] = []
        self._buffer_start: int = 0
        self._total_lines: int = 0
        self._waiters: List[asyncio.Queue] = []
        self._lock: asyncio.Lock = asyncio.Lock()
        self._process: Optional[asyncio.subprocess.Process] = None

    # ── Serialisation ────────────────────────────────────────────────────────

    def to_dict(self) -> dict:
        return {
            "job_id": self.job_id,
            "env": self.env,
            "scope": self.scope,
            "extra_args": self.extra_args,
            "source": self.source,
            "pid": self.pid,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "exit_code": self.exit_code,
            "status": self.status,
            "log_lines": self._total_lines,
        }

    def save_meta(self) -> None:
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.meta_file.write_text(json.dumps(self.to_dict(), indent=2), encoding="utf-8")

    # ── Output ingestion ─────────────────────────────────────────────────────

    async def append_line(self, line: str) -> None:
        """Persist a line to disk first, then update in-memory state."""
        # File write BEFORE lock — ensures file has line before _total_lines increments
        self.log_dir.mkdir(parents=True, exist_ok=True)
        with open(self.log_file, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")

        async with self._lock:
            self._buffer.append(line)
            if len(self._buffer) > MAX_BUFFER:
                excess = len(self._buffer) - MAX_BUFFER
                self._buffer_start += excess
                self._buffer = self._buffer[-MAX_BUFFER:]

            line_num = self._total_lines
            self._total_lines += 1

            for q in self._waiters:
                await q.put((line_num, line))

    def cancel(self) -> bool:
        """Send SIGTERM to the subprocess. Returns True if a signal was sent."""
        import signal
        p = self._process
        if p is not None and p.returncode is None:
            try:
                p.send_signal(signal.SIGTERM)
                return True
            except (ProcessLookupError, OSError):
                pass
        return False

    async def finish(self, exit_code: int) -> None:
        """Mark job done and wake all live subscribers with a sentinel."""
        self.end_time = datetime.now(timezone.utc).isoformat()
        async with self._lock:
            self.exit_code = exit_code
            self.status = "done" if exit_code == 0 else "failed"
            for q in self._waiters:
                await q.put(None)  # sentinel → process ended
        self.save_meta()
        if exit_code == 0:
            try:
                refresh_timing_profile(self.env)
            except Exception:
                pass

    # ── Subscriber management ─────────────────────────────────────────────────

    async def subscribe(self) -> Tuple[int, asyncio.Queue, bool]:
        """Register a live subscriber atomically.

        Returns:
            snapshot  -- total lines at subscription time
            queue     -- receives (line_num, text) then None sentinel when done
            already_done -- True if the job had already finished; queue NOT added
        """
        async with self._lock:
            snapshot = self._total_lines
            already_done = self.status != "running"
            q: asyncio.Queue = asyncio.Queue()
            if not already_done:
                self._waiters.append(q)
        return snapshot, q, already_done

    async def unsubscribe(self, q: asyncio.Queue) -> None:
        async with self._lock:
            try:
                self._waiters.remove(q)
            except ValueError:
                pass


# ── Job registry ──────────────────────────────────────────────────────────────

class JobRegistry:
    def __init__(self) -> None:
        self._jobs: Dict[str, Job] = {}

    def register(self, job: Job) -> None:
        self._jobs[job.job_id] = job

    def get(self, job_id: str) -> Optional[Job]:
        return self._jobs.get(job_id)

    def list_all(self) -> List[Job]:
        return sorted(self._jobs.values(), key=lambda j: j.start_time, reverse=True)

    def rebuild_from_disk(self) -> None:
        """Restore job metadata from disk and reconcile stale running jobs."""
        envs_dir = environments_root()
        if not envs_dir.exists():
            return
        for env_dir in sorted(envs_dir.iterdir()):
            logs_dir = env_dir / ".ui-logs"
            if not logs_dir.is_dir():
                continue
            for meta_file in sorted(logs_dir.glob("*.json")):
                try:
                    data = json.loads(meta_file.read_text(encoding="utf-8"))
                    job = job_from_dict(data)
                    _reconcile_recovered_job(job)
                    job._total_lines = _count_lines(job.log_file)

                    existing = self._jobs.get(job.job_id)
                    if existing and _has_live_managed_process(existing):
                        continue

                    self._jobs[job.job_id] = job
                except Exception:
                    pass


def _count_lines(path: Path) -> int:
    try:
        with open(path, "rb") as fh:
            return sum(1 for _ in fh)
    except FileNotFoundError:
        return 0


# ── Module-level singleton ────────────────────────────────────────────────────

registry = JobRegistry()


# ── Public API ────────────────────────────────────────────────────────────────

def create_job(
    env: str,
    scope: str,
    extra_args: List[str],
    *,
    source: str = "ui",
    pid: Optional[int] = None,
    job_id: Optional[str] = None,
) -> Job:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    resolved_job_id = job_id or f"{env}-{ts}" if source == "ui" else f"{env}-{ts}-terminal"
    job = Job(resolved_job_id, env, scope, extra_args, source=source, pid=pid)
    job.log_dir.mkdir(parents=True, exist_ok=True)
    job.save_meta()
    return job


def job_from_dict(data: dict) -> Job:
    job = Job(
        job_id=data["job_id"],
        env=data["env"],
        scope=data["scope"],
        extra_args=data.get("extra_args", []),
        source=data.get("source", "ui"),
        pid=data.get("pid"),
    )
    job.start_time = data.get("start_time", "")
    job.end_time = data.get("end_time")
    job.exit_code = data.get("exit_code")
    job.status = data.get("status", "done")
    return job


async def start_job(env: str, scope: str, extra_args: List[str]) -> Job:
    job = create_job(env, scope, extra_args)
    registry.register(job)
    asyncio.create_task(_run_job(job))
    return job


async def _run_job(job: Job) -> None:
    deploy_script = REPO_ROOT / "scripts" / "deploy.sh"

    # Inherit environment and make it non-interactive
    env_vars = os.environ.copy()
    env_vars["TERM"] = "xterm-256color"
    env_vars["BLUEPRINT_UI_JOB"] = "1"
    env_vars["BLUEPRINT_REPO_ROOT"] = str(REPO_ROOT)

    exit_code = 127
    snapshot_path: Optional[Path] = None
    try:
        snapshot_path, snapshot_sha256 = _create_deploy_snapshot(job, deploy_script)
        validation_error = await _validate_deploy_snapshot(snapshot_path)
        if validation_error is not None:
            await job.append_line(f"[ui-error] Deploy preflight failed: {validation_error}")
            await job.finish(exit_code)
            return

        await job.append_line(f"[ui] Deploy snapshot: {snapshot_path.name} sha256={snapshot_sha256}")

        cmd = ["bash", str(snapshot_path), job.scope, "--env", job.env] + job.extra_args
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(REPO_ROOT),
            env=env_vars,
        )
        job._process = process
        async for raw_line in process.stdout:
            text = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
            await job.append_line(text)
        await process.wait()
        exit_code = process.returncode or 0
    except Exception as exc:
        await job.append_line(f"[ui-error] Failed to launch deploy: {exc}")
        exit_code = 127
    finally:
        if snapshot_path is not None:
            try:
                snapshot_path.chmod(0o600)
            except OSError:
                pass

    await job.finish(exit_code)


def _create_deploy_snapshot(job: Job, deploy_script: Path) -> Tuple[Path, str]:
    job.log_dir.mkdir(parents=True, exist_ok=True)
    snapshot_path = job.log_dir / f"{job.job_id}.deploy.sh"
    shutil.copy2(deploy_script, snapshot_path)
    snapshot_path.chmod(0o700)
    snapshot_sha256 = hashlib.sha256(snapshot_path.read_bytes()).hexdigest()
    return snapshot_path, snapshot_sha256


async def _validate_deploy_snapshot(snapshot_path: Path) -> Optional[str]:
    helper_error = _validate_progress_helpers(snapshot_path)
    if helper_error is not None:
        return helper_error

    process = await asyncio.create_subprocess_exec(
        "bash",
        "-n",
        str(snapshot_path),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    output, _ = await process.communicate()
    if process.returncode == 0:
        return None

    detail = output.decode("utf-8", errors="replace").strip()
    if detail:
        return detail
    return "bash -n rejected the deploy script snapshot"


def _validate_progress_helpers(snapshot_path: Path) -> Optional[str]:
    text = snapshot_path.read_text(encoding="utf-8")
    helper_names = set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*_step_(?:start|done))\b", text))
    unknown_helpers = sorted(helper_names - _ALLOWED_PROGRESS_HELPERS)
    if not unknown_helpers:
        return None

    helper_list = ", ".join(unknown_helpers)
    return (
        "unexpected progress helper name(s) in deploy script snapshot: "
        f"{helper_list}"
    )


def _reconcile_recovered_job(job: Job) -> None:
    if job.status != "running":
        return

    if _pid_is_running(job.pid):
        return

    job.status = "interrupted"
    if job.exit_code is None:
        job.exit_code = -1
    if not job.end_time:
        job.end_time = datetime.now(timezone.utc).isoformat()
    job.save_meta()


def _pid_is_running(pid: Optional[int]) -> bool:
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _has_live_managed_process(job: Job) -> bool:
    process = job._process
    return process is not None and process.returncode is None
