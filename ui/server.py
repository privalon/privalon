"""Blueprint Web UI — FastAPI server.

Serves:
  GET  /                              → index.html
  GET  /environments                  → list environments + config status
  GET  /config/{env}                  → sanitised config view (no secret values)
  PUT  /config/{env}/grid             → update tfgrid_network / name / use_scheduler
  PUT  /config/{env}/ssh              → update ssh_public_keys
  PUT  /config/{env}/credentials      → write mnemonic / admin password to secrets.env
  PUT  /config/{env}/dns              → update DNS fields in group_vars + secrets.env
  PUT  /config/{env}/backup           → update backup fields in group_vars + secrets.env
  POST /jobs                          → start a deploy job
  GET  /jobs                          → list all known jobs
  GET  /jobs/{job_id}                 → single job state
  GET  /jobs/{job_id}/stream          → SSE live log stream (Last-Event-ID replay)
  GET  /jobs/{job_id}/log             → full log as plain text (download)
    GET  /timing/{env}                  → rebuild and return the environment timing profile
  DELETE /jobs/{job_id}               → cancel a running job (SIGTERM)

Run from the ui/ directory:
  uvicorn server:app --host 0.0.0.0 --port 8080
"""

import asyncio
import json
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import sys
sys.path.insert(0, str(Path(__file__).parent))

from lib.job_runner import registry, start_job
from lib.log_sections import LogSectionParser
from lib.config_reader import (
    get_config_view,
    environments_root,
    write_tfvars_simple_field,
    write_ssh_keys,
    write_secret,
    write_group_vars,
)
from lib.timing import load_timing_profile

REPO_ROOT = Path(__file__).resolve().parents[1]
STATIC_DIR = Path(__file__).parent / "static"
STATIC_VERSION = (REPO_ROOT / "VERSION").read_text(encoding="utf-8").strip()

app = FastAPI(title="Blueprint UI", docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.on_event("startup")
async def _startup() -> None:
    registry.rebuild_from_disk()


# ── Static shell ─────────────────────────────────────────────────────────────

@app.get("/", include_in_schema=False)
async def index() -> HTMLResponse:
    html = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
    html = html.replace("__STATIC_VERSION__", STATIC_VERSION)
    return HTMLResponse(
        html,
        headers={
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Pragma": "no-cache",
            "Expires": "0",
        },
    )


# ── Environments ──────────────────────────────────────────────────────────────

@app.get("/environments")
async def list_environments() -> list:
    envs_dir = environments_root()
    result = []
    for d in sorted(envs_dir.iterdir()):
        if not d.is_dir() or d.name == "example":
            continue
        has_tfvars = (d / "terraform.tfvars").exists()
        has_secrets = (d / "secrets.env").exists()

        last_job = None
        logs_dir = d / ".ui-logs"
        if logs_dir.is_dir():
            meta_files = sorted(logs_dir.glob("*.json"))
            if meta_files:
                try:
                    data = json.loads(meta_files[-1].read_text())
                    last_job = {
                        "job_id": data.get("job_id"),
                        "scope": data.get("scope"),
                        "start_time": data.get("start_time"),
                        "status": data.get("status"),
                        "exit_code": data.get("exit_code"),
                    }
                except Exception:
                    pass

        result.append({
            "name": d.name,
            "config_complete": has_tfvars and has_secrets,
            "has_tfvars": has_tfvars,
            "has_secrets": has_secrets,
            "last_job": last_job,
        })
    return result


class NewEnvRequest(BaseModel):
    name: str


@app.post("/environments", status_code=201)
async def create_environment(req: NewEnvRequest) -> dict:
    """Create a new environment from the example template."""
    import re as _re
    import shutil
    name = req.name.strip()
    if not _re.match(r'^[a-z0-9_-]+$', name):
        raise HTTPException(status_code=400, detail="Name must be lowercase alphanumeric/dash/underscore")
    env_dir = environments_root() / name
    if env_dir.exists():
        raise HTTPException(status_code=409, detail=f"Environment '{name}' already exists")
    example_dir = environments_root() / "example"
    if example_dir.exists():
        shutil.copytree(str(example_dir), str(env_dir))
    else:
        env_dir.mkdir(parents=True)
        (env_dir / "group_vars").mkdir()
        (env_dir / "inventory").mkdir()
    return {"name": name, "created": True}


# ── Status (Phase 3) ─────────────────────────────────────────────────────────

@app.get("/status/{env}")
async def get_status(env: str) -> dict:
    _require_env(env)

    # Read terraform outputs
    outputs_path = environments_root() / env / "inventory" / "terraform-outputs.json"
    outputs: Dict[str, Any] = {}
    if outputs_path.exists():
        try:
            raw = json.loads(outputs_path.read_text())
            # Terraform output format: {key: {value: ..., type: ..., sensitive: ...}}
            outputs = {
                key: value.get("value") if isinstance(value, dict) and "value" in value else value
                for key, value in raw.items()
            }
        except Exception:
            pass

    # Read env-level group_vars for URL construction
    from lib.config_reader import read_group_vars as _gv
    gv = _gv(env)
    base_domain    = gv.get("base_domain", "")
    headscale_sub  = gv.get("headscale_subdomain", "headscale")

    # Build service URLs
    control_ip  = outputs.get("control_public_ip", "")
    gateway_ip  = outputs.get("gateway_public_ip", "")

    headscale_url = (
        f"https://{headscale_sub}.{base_domain}" if base_domain
        else (f"https://{control_ip}.sslip.io" if control_ip else "")
    )
    grafana_url = f"https://grafana.{base_domain}" if base_domain else ""
    prometheus_url = f"https://prometheus.{base_domain}" if base_domain else ""

    tailscale_ips_path = environments_root() / env / "inventory" / "tailscale-ips.json"
    tailscale_ips: Dict[str, Any] = {}
    if tailscale_ips_path.exists():
        try:
            tailscale_ips = json.loads(tailscale_ips_path.read_text())
        except Exception:
            tailscale_ips = {}

    magic_dns_base = gv.get("headscale_magic_dns_base_domain", "")
    control_ts_ip = tailscale_ips.get("control-vm", "") if isinstance(tailscale_ips, dict) else ""
    headplane_url = (
        f"http://control-vm.{magic_dns_base}:3000" if magic_dns_base
        else (f"http://{control_ts_ip}:3000" if control_ts_ip else "")
    )

    has_outputs = bool(outputs)

    return {
        "has_outputs": has_outputs,
        "gateway": {
            "public_ip":    gateway_ip,
            "private_ip":   outputs.get("gateway_private_ip", ""),
            "mycelium_ip":  outputs.get("gateway_mycelium_ip", ""),
            "console_url":  outputs.get("gateway_console_url", ""),
        },
        "control": {
            "public_ip":    control_ip,
            "private_ip":   outputs.get("control_private_ip", ""),
            "mycelium_ip":  outputs.get("control_mycelium_ip", ""),
            "console_url":  outputs.get("control_console_url", ""),
        },
        "workloads": {
            "private_ips":   outputs.get("workloads_private_ips", {}),
            "mycelium_ips":  outputs.get("workloads_mycelium_ips", {}),
            "console_urls":  outputs.get("workloads_console_urls", {}),
        },
        "urls": {
            "headscale":   headscale_url,
            "headplane":   headplane_url,
            "grafana":     grafana_url,
            "prometheus":  prometheus_url,
        },
        "network_ip_range": outputs.get("network_ip_range", ""),
    }


# ── Config API (Phase 2) ──────────────────────────────────────────────────────

def _require_env(env: str) -> None:
    if not (environments_root() / env).is_dir():
        raise HTTPException(status_code=404, detail=f"Environment '{env}' not found")


@app.get("/config/{env}")
async def get_config(env: str) -> dict:
    _require_env(env)
    try:
        return get_config_view(env)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


class GridUpdate(BaseModel):
    tfgrid_network: Optional[str] = None
    name: Optional[str] = None
    use_scheduler: Optional[bool] = None


@app.put("/config/{env}/grid")
async def update_grid(env: str, body: GridUpdate) -> dict:
    _require_env(env)
    errors: Dict[str, str] = {}
    if body.tfgrid_network is not None:
        try:
            write_tfvars_simple_field(env, "tfgrid_network", body.tfgrid_network)
        except Exception as e:
            errors["tfgrid_network"] = str(e)
    if body.name is not None:
        try:
            write_tfvars_simple_field(env, "name", body.name)
        except Exception as e:
            errors["name"] = str(e)
    if body.use_scheduler is not None:
        try:
            write_tfvars_simple_field(env, "use_scheduler", body.use_scheduler)
        except Exception as e:
            errors["use_scheduler"] = str(e)
    if errors:
        raise HTTPException(status_code=422, detail=errors)
    return {"ok": True}


class SshUpdate(BaseModel):
    public_keys: List[str]


@app.put("/config/{env}/ssh")
async def update_ssh(env: str, body: SshUpdate) -> dict:
    _require_env(env)
    try:
        write_ssh_keys(env, body.public_keys)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    return {"ok": True}


class CredentialsUpdate(BaseModel):
    mnemonic: Optional[str] = None
    admin_password: Optional[str] = None


@app.put("/config/{env}/credentials")
async def update_credentials(env: str, body: CredentialsUpdate) -> dict:
    _require_env(env)
    errors: Dict[str, str] = {}
    if body.mnemonic:
        try:
            write_secret(env, "TF_VAR_tfgrid_mnemonic", body.mnemonic)
        except Exception as e:
            errors["mnemonic"] = str(e)
    if body.admin_password:
        try:
            write_secret(env, "SERVICES_ADMIN_PASSWORD", body.admin_password)
        except Exception as e:
            errors["admin_password"] = str(e)
    if errors:
        raise HTTPException(status_code=422, detail=errors)
    return {"ok": True}


class DnsUpdate(BaseModel):
    base_domain: Optional[str] = None
    headscale_subdomain: Optional[str] = None
    magic_dns_base_domain: Optional[str] = None
    public_service_tls_mode: Optional[str] = None
    internal_service_tls_mode: Optional[str] = None
    admin_email: Optional[str] = None
    namecheap_user: Optional[str] = None
    namecheap_key: Optional[str] = None


@app.put("/config/{env}/dns")
async def update_dns(env: str, body: DnsUpdate) -> dict:
    _require_env(env)
    gv_updates: Dict[str, Any] = {}
    errors: Dict[str, str] = {}

    if body.base_domain is not None:
        gv_updates["base_domain"] = body.base_domain
    if body.headscale_subdomain is not None:
        gv_updates["headscale_subdomain"] = body.headscale_subdomain
    if body.magic_dns_base_domain is not None:
        gv_updates["headscale_magic_dns_base_domain"] = body.magic_dns_base_domain
    if body.public_service_tls_mode is not None:
        gv_updates["public_service_tls_mode"] = body.public_service_tls_mode
    if body.internal_service_tls_mode is not None:
        gv_updates["internal_service_tls_mode"] = body.internal_service_tls_mode
    if body.admin_email is not None:
        gv_updates["admin_email"] = body.admin_email

    if gv_updates:
        try:
            write_group_vars(env, gv_updates)
        except Exception as exc:
            raise HTTPException(status_code=422, detail=str(exc))

    if body.namecheap_user:
        try:
            write_secret(env, "NAMECHEAP_API_USER", body.namecheap_user)
        except Exception as e:
            errors["namecheap_user"] = str(e)
    if body.namecheap_key:
        try:
            write_secret(env, "NAMECHEAP_API_KEY", body.namecheap_key)
        except Exception as e:
            errors["namecheap_key"] = str(e)

    if errors:
        raise HTTPException(status_code=422, detail=errors)
    return {"ok": True}


class BackupUpdate(BaseModel):
    backup_enabled: Optional[bool] = None
    restic_password: Optional[str] = None
    s3_primary_access_key: Optional[str] = None
    s3_primary_secret_key: Optional[str] = None
    s3_secondary_access_key: Optional[str] = None
    s3_secondary_secret_key: Optional[str] = None


@app.put("/config/{env}/backup")
async def update_backup(env: str, body: BackupUpdate) -> dict:
    _require_env(env)
    errors: Dict[str, str] = {}

    if body.backup_enabled is not None:
        try:
            write_group_vars(env, {"backup_enabled": body.backup_enabled})
        except Exception as exc:
            raise HTTPException(status_code=422, detail=str(exc))

    secret_map = {
        "restic_password":         "RESTIC_PASSWORD",
        "s3_primary_access_key":   "BACKUP_S3_PRIMARY_ACCESS_KEY",
        "s3_primary_secret_key":   "BACKUP_S3_PRIMARY_SECRET_KEY",
        "s3_secondary_access_key": "BACKUP_S3_SECONDARY_ACCESS_KEY",
        "s3_secondary_secret_key": "BACKUP_S3_SECONDARY_SECRET_KEY",
    }
    for field, secret_key in secret_map.items():
        val = getattr(body, field)
        if val:
            try:
                write_secret(env, secret_key, val)
            except Exception as e:
                errors[field] = str(e)

    if errors:
        raise HTTPException(status_code=422, detail=errors)
    return {"ok": True}


# ── Jobs ──────────────────────────────────────────────────────────────────────

_VALID_SCOPES = {"full", "gateway", "control", "dns", "join-local", "service-x"}


class StartJobRequest(BaseModel):
    env: str
    scope: str
    extra_args: List[str] = []


class ProgressLogRequest(BaseModel):
    event_type: str
    event_ts_ms: int
    pct: int
    label: str
    eta_text: str
    eta_seconds: Optional[int] = None
    has_plan: bool
    units_done: int
    units_total: int
    estimate_mode: Optional[str] = None
    elapsed_ms: Optional[int] = None
    current_step_id: Optional[str] = None
    current_play: str = ""
    event_payload: Optional[Dict[str, Any]] = None


def _validate_job_args(scope: str, extra_args: List[str]) -> None:
    if "--yes" in extra_args and "--no-destroy" in extra_args:
        raise HTTPException(
            status_code=422,
            detail="Conflicting deploy flags: --yes and --no-destroy cannot be used together",
        )
    if "--fresh-tailnet" in extra_args and "--no-destroy" in extra_args:
        raise HTTPException(
            status_code=422,
            detail="Conflicting deploy flags: --fresh-tailnet requires destructive redeploy behavior and cannot be used with --no-destroy",
        )
    if "--fresh-tailnet" in extra_args and scope not in {"full", "gateway", "control"}:
        raise HTTPException(
            status_code=422,
            detail="Invalid deploy flags: --fresh-tailnet is only supported with full, gateway, or control scopes",
        )


@app.post("/jobs", status_code=201)
async def create_job(req: StartJobRequest) -> dict:
    env_dir = environments_root() / req.env
    if not env_dir.is_dir():
        raise HTTPException(status_code=404, detail=f"Environment '{req.env}' not found")
    if req.scope not in _VALID_SCOPES:
        raise HTTPException(status_code=400, detail=f"Invalid scope '{req.scope}'")

    _validate_job_args(req.scope, req.extra_args)

    job = await start_job(req.env, req.scope, req.extra_args)
    return job.to_dict()


@app.get("/jobs")
async def list_jobs() -> list:
    registry.rebuild_from_disk()
    return [j.to_dict() for j in registry.list_all()]


@app.get("/timing/{env}")
async def get_timing_profile(env: str) -> dict:
    _require_env(env)
    return load_timing_profile(env, env_root=environments_root())


@app.get("/jobs/{job_id}")
async def get_job(job_id: str) -> dict:
    registry.rebuild_from_disk()
    job = registry.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job.to_dict()


@app.get("/jobs/{job_id}/log")
async def get_job_log(job_id: str) -> PlainTextResponse:
    registry.rebuild_from_disk()
    job = registry.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    try:
        content = job.log_file.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        content = ""
    return PlainTextResponse(content)


@app.post("/jobs/{job_id}/progress-log")
async def append_job_progress_log(job_id: str, body: ProgressLogRequest) -> dict:
    job = registry.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job.status != "running":
        raise HTTPException(status_code=409, detail="Job is not running")

    payload = {
        "type": "ui-progress-snapshot",
        "event_type": body.event_type,
        "event_ts_ms": body.event_ts_ms,
        "server_ts_ms": time.time_ns() // 1_000_000,
        "pct": body.pct,
        "label": body.label,
        "eta_text": body.eta_text,
        "eta_seconds": body.eta_seconds,
        "has_plan": body.has_plan,
        "units_done": body.units_done,
        "units_total": body.units_total,
        "estimate_mode": body.estimate_mode,
        "elapsed_ms": body.elapsed_ms,
        "current_step_id": body.current_step_id,
        "current_play": body.current_play,
        "event_payload": body.event_payload or {},
    }
    await job.append_line(f"[bp-progress-ui] {json.dumps(payload, separators=(',', ':'))}")
    return {"ok": True}


# ── Cancel job ───────────────────────────────────────────────────────────────

@app.delete("/jobs/{job_id}")
async def cancel_job(job_id: str):
    job = registry.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job.status != "running":
        raise HTTPException(status_code=409, detail="Job is not running")
    sent = job.cancel()
    return {"ok": sent, "detail": "SIGTERM sent" if sent else "process already exited"}


# ── SSE stream ───────────────────────────────────────────────────────────────

@app.get("/jobs/{job_id}/stream")
async def stream_job_sse(job_id: str, request: Request) -> StreamingResponse:
    registry.rebuild_from_disk()
    job = registry.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    last_id_header = request.headers.get("last-event-id")
    try:
        from_line = int(last_id_header) + 1 if last_id_header else 0
    except (ValueError, TypeError):
        from_line = 0

    async def generate():
        if job.status == "running" and job._process is None:
            async for chunk in _stream_external_job(job_id, from_line):
                yield chunk
            return

        snapshot, q, already_done = await job.subscribe()
        parser = LogSectionParser()

        # Prime parser state so reconnects keep section ids stable.
        for _, line in _iter_log_lines(job, end_line=from_line):
            parser.feed_line(_, line)

        if already_done:
            # Stream structured events reconstructed from the saved log, then done.
            for line_num, line in _iter_log_lines(job, start_line=from_line):
                for chunk in _encode_log_events(parser.feed_line(line_num, line)):
                    yield chunk
            for chunk in _encode_log_events(parser.finish(failed=(job.exit_code or 0) != 0)):
                yield chunk
            yield _done_event(job)
            return

        try:
            # Catch-up: lines already on disk before we subscribed [from_line, snapshot)
            for line_num, line in _iter_log_lines(job, start_line=from_line, end_line=snapshot):
                for chunk in _encode_log_events(parser.feed_line(line_num, line)):
                    yield chunk

            # Live tail
            while True:
                try:
                    item = await asyncio.wait_for(q.get(), timeout=25.0)
                except asyncio.TimeoutError:
                    yield ": heartbeat\n\n"
                    continue

                if item is None:
                    # Sentinel: process has ended
                    for chunk in _encode_log_events(parser.finish(failed=(job.exit_code or 0) != 0)):
                        yield chunk
                    yield _done_event(job)
                    break

                line_num, line = item
                for chunk in _encode_log_events(parser.feed_line(line_num, line)):
                    yield chunk
        finally:
            await job.unsubscribe(q)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


def _iter_log_lines(job, start_line: int = 0, end_line: Optional[int] = None):
    """Yield raw log lines from the job's log file."""
    try:
        with open(job.log_file, "r", encoding="utf-8", errors="replace") as fh:
            for i, raw in enumerate(fh):
                if i < start_line:
                    continue
                if end_line is not None and i >= end_line:
                    break
                yield i, raw.rstrip(chr(10) + chr(13))
    except FileNotFoundError:
        pass


def _encode_log_events(events: List[Dict[str, object]]):
    for event in events:
        event_name = event["event"]
        data = json.dumps(event["data"])
        event_id = event.get("id")
        if event_id is not None:
            yield f"id: {event_id}\nevent: {event_name}\ndata: {data}\n\n"
        else:
            yield f"event: {event_name}\ndata: {data}\n\n"


async def _stream_external_job(job_id: str, from_line: int):
    parser = LogSectionParser()
    current_line = from_line
    heartbeat_counter = 0

    job = registry.get(job_id)
    if not job:
        return

    for line_num, line in _iter_log_lines(job, end_line=from_line):
        parser.feed_line(line_num, line)

    while True:
        job = registry.get(job_id)
        if not job:
            return

        emitted = False
        for line_num, line in _iter_log_lines(job, start_line=current_line):
            emitted = True
            current_line = line_num + 1
            for chunk in _encode_log_events(parser.feed_line(line_num, line)):
                yield chunk

        registry.rebuild_from_disk()
        job = registry.get(job_id)
        if not job:
            return

        if job.status != "running":
            failed = job.status != "done"
            for chunk in _encode_log_events(parser.finish(failed=failed)):
                yield chunk
            yield _done_event(job)
            break

        if emitted:
            heartbeat_counter = 0
        else:
            heartbeat_counter += 1
            if heartbeat_counter >= 25:
                heartbeat_counter = 0
                yield ": heartbeat\n\n"

        await asyncio.sleep(1.0)


def _done_event(job) -> str:
    payload = {
        "exit_code": job.exit_code,
        "status": job.status,
    }
    return f"event: done\ndata: {json.dumps(payload)}\n\n"
