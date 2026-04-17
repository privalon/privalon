# Blueprint Web UI

A lightweight local web interface for the Privalon deployment workflow.

## Why the UI exists

The blueprint is trying to make digital sovereignty practical by default: private-by-default access, minimal public exposure, built-in recovery paths, and infrastructure that stays operable without turning every user into a full-time sysadmin.

The UI exists to support that goal from the operator side.

If digital sovereignty requires endless manual terminal work for every routine task, it stops being practical for most people. The UI exists to reduce that operator friction without weakening the platform's security, recovery, or tailnet-first model.

It already provides the lower-friction path for people who are not comfortable driving everything from the terminal, and that operator experience is expected to keep improving over time.

It is not a separate product layer with a different philosophy. It is the local control surface for the same operating model:

- safer defaults instead of ad hoc manual steps
- lower day-to-day operational friction
- visibility during deploys and recovery work
- a simpler path for people who are not comfortable driving every workflow directly from the terminal

In practice, that means the UI is meant to reduce routine operator effort while supporting the same larger goal as the rest of the project: a private service ecosystem that stays operable when backup, restore, DNS, TLS, monitoring, and day-2 work all matter at once.

For the broader product framing, see [../docs/user/CONCEPT.md](../docs/user/CONCEPT.md) and [../docs/user/GUIDE.md](../docs/user/GUIDE.md).

## Quick start

```bash
# Install dependencies (once)
make ui-install

# Start the server
make ui
```

Then open **http://localhost:8090** in your browser.

## Features

The UI is intentionally local-first. It helps operators configure environments, launch deploys, inspect status, and review history, while the actual infrastructure model still stays rooted in Terraform, Ansible, tailnet-first access, and the same recovery flows described in the main documentation.

### Deploy tab
- Select an environment and deployment scope
- Preselect how existing Terraform-managed infrastructure should be handled: converge in place (`--no-destroy`) or destroy and recreate (`--yes`)
- Optionally add a destructive `--fresh-tailnet` reset when you intentionally want new Headscale and per-VM Tailscale identities
- Trigger `deploy.sh` as a subprocess with live log streaming
- Show a generic top-level progress bar with percent and ETA derived from the actual selected deploy flow, correctly counted Ansible task totals, and an EMA timing profile rebuilt from successful runs, without spiking to near-complete before the full plan arrives
- Import terminal-triggered runs recorded automatically by `scripts/deploy.sh` and label them separately from Web UI jobs
- ANSI-coloured terminal output with phase indicators
- Structured sectioning survives repeated or reordered Ansible plays within the same run
- Reconnect-safe: closing and reopening the tab replays the full log
- Multiple deploys can run in parallel with independent log panes
- Download completed logs as plain text

### Configure tab
- Edit `terraform.tfvars` (network, deployment name, scheduler toggle, SSH keys)
- Edit `secrets.env` (mnemonic, admin password, backup credentials, DNS API keys)
- Edit environment `group_vars/all.yml` (DNS settings, backup toggles)
- Sensitive fields are write-only — the display shows "saved" / "not set" only

### Status tab
- Public IPs for gateway and control VMs
- Clickable service URLs: Headscale, tailnet-only Headplane admin, Grafana, Prometheus
- Reads from `environments/<env>/inventory/terraform-outputs.json`

### Environments tab
- Overview of all environments: config completeness, last deploy status
- Create a new environment from the example template
- Quick-links to Configure and Status for each environment

### History tab
- All past and current deployment jobs (from disk, survives server restart)
- Terminal-recorded jobs appear as `Terminal` runs and are picked up from disk while the UI is already running
- Interrupted terminal runs without final status metadata are recovered as `interrupted` during disk import
- Click any job to replay its log in the Deploy tab

## Architecture

```
ui/
  server.py         FastAPI app — routes, SSE endpoint, subprocess runner
  requirements.txt  fastapi, uvicorn, pyyaml, python-dotenv, aiofiles, python-hcl2
  static/
    index.html      Single-page app shell (no build step)
    app.js          EventSource log pane logic, ANSI parser, phase detection, progress/ETA tracking
    style.css       Dark theme
  lib/
    job_runner.py   Subprocess launch, output fan-out, job registry, log replay
    deploy_progress.py  Runtime plan builder for weighted top-level progress and ETA
    timing.py       Historical timing-profile builder used for duration-based progress/ETA
    config_reader.py  Parse/write terraform.tfvars, secrets.env, group_vars YAML

  ansible/
    callback_plugins/
      blueprint_progress.py  Emits machine-readable task markers during Ansible runs
```

## Log storage

Each job's output is stored under:
```
environments/<env>/.ui-logs/<job-id>.log   # raw log (ANSI preserved)
environments/<env>/.ui-logs/<job-id>.json  # job metadata
environments/<env>/.ui-logs/timing-profile.json  # EMA timing profile from successful jobs
```

If you launch a deployment from the terminal, it is recorded into History automatically:

```bash
./scripts/deploy.sh full --env <env> [deploy.sh options...]
```

`deploy.sh` mirrors the same combined terminal stdout/stderr stream into the `.log` file while recording metadata the UI can import and replay.

These files are `.gitignore`'d automatically (see `environments/` ignore pattern).

## SSE reconnect model

The SSE endpoint at `/jobs/{job_id}/stream` honours the `Last-Event-ID` header.
The browser's `EventSource` sends this automatically on reconnect, so closing and
re-opening the tab at any point gives an identical experience to watching live.
If the job has already finished when you connect, the full log is replayed from
disk and the final result banner is shown immediately.

The server emits structured `section-start`, `line`, `section-end`, and `done`
events. Section ids are assigned per occurrence in the stream, so repeated play
titles and different play orders still render as distinct log sections.

Deploy runs also emit hidden `[bp-progress]` markers into the same stream. The UI
uses those markers to calculate top-level progress and ETA from the actual scope,
flags, correctly counted Ansible task totals, weighted non-Ansible phases, and a
historical timing profile rebuilt from successful jobs instead of a hardcoded
frontend phase map. The browser holds the bar at `0%` until the full plan marker
arrives, then merges in any already-seen early step completions so the bar does
not jump to near-complete and reset during startup. When timing history exists,
the current step's elapsed time is also used to detect overruns and slow the ETA
down instead of pinning the bar at `99%` with a stale short estimate. Control-
scope plans also include the DNS update step because `deploy.sh control` now runs
it.

The HTML shell is served with `Cache-Control: no-store`, and the CSS/JS asset URLs
include the current repo version as a query string. That keeps browser caches from
serving stale UI code after an update.
