# Operations runbook (ThreeFold + Terraform + Ansible + Headscale)

This is **technical** documentation (operator runbooks and recovery procedures).

For a user-facing overview and deploy flow, see:
- Docs index: [../README.md](../README.md)
- Main guide: [../user/GUIDE.md](../user/GUIDE.md)

This document is a **step-by-step** runbook for common lifecycle scenarios.

## Environments

You’ll run commands in one of these places:

### A) Your workstation (recommended)

Where you have this repo checked out and can run Terraform/Ansible.

### B) A tailnet-connected device

A laptop/desktop that can reach VM Tailscale IPs (after the playbook finishes).

### C) Break-glass reality (no console)

ThreeFold does **not** provide SSH access to the underlying *nodes*, and you should assume there is **no VM console** available for recovery.

Implication: if a VM is unreachable over SSH and you’re not on the tailnet, the practical recovery is usually to **replace (destroy + recreate)** the affected deployment (gateway or core) via Terraform.

If you want a temporary safety net during initial bootstrap, allow public SSH only from your workstation public IP/CIDR using `firewall_allow_public_ssh_from_cidrs` (documented below).

---

## Pre-flight (applies to all scenarios)

On your workstation, from the repo root:

```bash
cd terraform
terraform init
```

Terminal-triggered deployments launched via `./scripts/deploy.sh ...` are recorded automatically into `environments/<env>/.ui-logs/` so the local Web UI History tab can replay them later.

Those same per-job logs now include progress-estimation diagnostics for post-run analysis. Raw deploy markers appear as `[bp-progress]` JSON lines with timestamps and elapsed timing, while UI-triggered runs also append throttled `[bp-progress-ui]` JSON snapshots that record the browser-visible percent, ETA, label, current step, and triggering event payload. These markers are meant for offline estimation debugging and are intentionally hidden from the normal live log pane.

This blueprint uses two gitignored config files per environment:

```bash
# 1. Secrets (mnemonic, passwords, S3 keys):
cp environments/prod/secrets.env.example environments/prod/secrets.env
$EDITOR environments/prod/secrets.env

# 2. Non-secret Terraform config (node selection, SSH keys, workloads):
cp environments/prod/terraform.tfvars.example environments/prod/terraform.tfvars
$EDITOR environments/prod/terraform.tfvars
```

After Terraform changes, refresh Ansible’s inventory inputs:

```bash
cd ../ansible
terraform -chdir=../terraform output -json > inventory/terraform-outputs.json
chmod +x inventory/tfgrid.py
```
---

## Deployment Summary (automatic after each deploy)

After every deployment (`./scripts/deploy.sh full/control/gateway`), a **deployment summary** is automatically printed showing:

- **Infrastructure**: Public/private IPs, hostnames
- **Services**: URLs, ports, access methods for Headscale, Prometheus, Grafana, and the main observability dashboards
- **Portable recovery**: recovery-bundle refresh status for primary and secondary storage, plus the latest opaque recovery line when configured
- **Relay fallback**: embedded DERP status on the control VM for difficult client/private-node paths
- **Tailnet Status**: Registered nodes and their Tailscale IPs
- **Next Steps**: Connection instructions for various scenarios (join tailnet, SSH, access dashboards)

### What the summary provides

The summary is designed to be a **quick reference** after deployment, replacing the need to hunt through logs for IPs and URLs:

- Long values (API keys, auth keys, recovery lines, and long commands) are wrapped to terminal width so the output stays readable without horizontal scrolling.

```
▶ Infrastructure Overview
  Control (Headscale + API)
    Public IP: 185.69.166.157
    Public URL (sslip.io): https://185.69.166.157.sslip.io
    Private IP: 10.10.0.2
  
  Gateway (Reverse Proxy)
    Public IP: 178.251.27.30
    Private IP: 10.10.0.3
  
  Monitoring
    Host: monitoring-vm
    Access Method: Tailscale IP (services bound to tailnet0)

▶ Services & Access
  Headscale (Self-hosted Tailscale)
    Public URL: https://185.69.166.157.sslip.io
    Login Server: --login-server https://185.69.166.157.sslip.io
    DERP fallback: https://185.69.166.157.sslip.io/derp
    Headplane (tailnet-only): http://control-vm.in.example.com:3000
    Public admin path disabled; use a tailnet-connected device or SSH to control VM
  
  Prometheus Metrics
    URL (from tailnet): http://100.64.0.2:9090
    Access: From Tailscale-connected device only
  
  Grafana Dashboards
    URL (from tailnet): http://100.64.0.2:3000
    Default Creds: admin / admin (change immediately)
    Access: From Tailscale-connected device only
    Primary dashboards: Infrastructure Health, Service Health, Logs Overview, Backup Overview

▶ Tailnet Status
  Registered Nodes
    control-vm: 100.64.0.1
    gateway-vm: 100.64.0.3
    monitoring-vm: 100.64.0.2

▶ Next Steps for Connection
  Option 1: Join Your Device to the Tailnet (Recommended)
    □ Install Tailscale on your device: https://tailscale.com/download
    □ Connect: tailscale up --login-server https://185.69.166.157.sslip.io
    □ Prefer a preauth key so the first join does not depend on a public admin UI
    □ If manual approval is needed, open Headplane from an already tailnet-connected admin device
    □ Then verify: tailscale status
  
  Option 2: SSH over Tailscale (requires tailnet)
    □ SSH to control: ssh ops@100.64.0.1
    □ Test availability: ping -c 1 100.64.0.1
  
  Option 3: Local Test/Troubleshooting (workstation with repo)
    □ Run smoke tests: PREFER_TAILSCALE=1 ./scripts/tests/run.sh bootstrap-smoke
    □ Full diagnostics: PREFER_TAILSCALE=1 ./scripts/tests/run.sh tailnet-management
  
  Option 4: Access Services from Tailnet
    □ Grafana dashboards: Open http://100.64.0.2:3000 in your browser
    □ Grafana logs: Use Explore or the Logs Overview dashboard from Grafana
    □ Prometheus queries: Open http://100.64.0.2:9090 in your browser
    □ Default Grafana creds: admin / admin (change in UI after first login)
```

### Running the summary manually

If you need to see the summary again after deployment, or if you want to refresh the information:

```bash
# Automatically called at end of deploy.sh, but can be run manually:
./scripts/helpers/deployment-summary.sh
```

### Future additions: keeping the summary user-friendly

**Design principle:** Every new feature (service, configuration, node type) added to the blueprint should automatically flow into the deployment summary, so users always have a complete picture without hunting through logs.

**When adding new services/configuration:**

1. **Add it to `ansible/roles/`** (as you normally would)
2. **Update `scripts/helpers/deployment-summary.sh`** to display:
   - IP/hostname where the service runs
   - Port/URL how to access it
   - Default credentials (if any)
   - Which network it's bound to (public/private/tailnet)
   - Connection examples
3. **Update this runbook (`docs/technical/OPERATIONS.md`)** if the access pattern is new or unusual
4. **Add test coverage** in `scripts/tests/` so the summary reflects real state

**Adding a new service example:**

If you add a new service (e.g., VaultWarden), the minimal changes are:

- **deployment-summary.sh**: Add a `print_subsection` for it in `print_services()` function
- **docs/technical/OPERATIONS.md**: Document the expected `print_vaultden()` section
- **ansible role**: Ensure the service's IP/port are stored in Terraform outputs or dynamic inventory

This ensures:
- New deployments immediately show users how to access the service
- No "where is the service?" questions after deployment
- Runbook stays up-to-date without manual edits per-service

When backup storage is configured, the same summary now prints the break-glass recovery line and stores the latest generated copy locally in `environments/<env>/.recovery/latest-recovery-line`.

### Troubleshooting the summary

If the summary shows warnings or missing data:

- **No Terraform outputs**: Run `terraform -chdir=terraform output -json > ansible/inventory/terraform-outputs.json`
- **No Tailscale IPs**: Ansible hasn't run yet; run `ansible-playbook -i inventory/tfgrid.py playbooks/site.yml`
- **Services not accessible**: Check Tailscale connectivity and firewall ACLs; not all services are exposed publicly by design

When `internal_service_tls_mode: namecheap` is enabled, the deployment summary checks whether
the gateway wildcard certificate is already active. If the current gateway public IP was
allowlisted in Namecheap before the deploy started, the first deploy should complete wildcard
activation in the same run. A follow-up `./scripts/deploy.sh gateway --env <env>` is only needed
when the deploy could not activate wildcard TLS yet, most commonly because that gateway IP was not
allowlisted at deploy time.

When `headscale_magic_dns_base_domain` is set, the monitoring host also exposes
private service aliases such as `https://grafana.<magic_dns_base>` and
`https://prometheus.<magic_dns_base>` over the tailnet.

- In the default `internal_service_tls_mode: internal`, these aliases terminate on the
  monitoring VM's Tailscale address using Caddy's private CA.
- In `internal_service_tls_mode: namecheap`, Headscale points the aliases at the gateway
  VM's Tailscale address instead. Gateway Caddy then serves a browser-trusted wildcard
  certificate for `*.headscale_magic_dns_base_domain` via the Namecheap DNS plugin and
  reverse proxies the requests to the monitoring VM over Tailscale. On the first
  deployment, finish the deploy, add the gateway public IP to the Namecheap API
  allowlist, then run `./scripts/deploy.sh gateway --env <env>` once so the gateway
  can complete the first wildcard issuance.

Embedded DERP is enabled by default on the control VM. This gives private-only
nodes such as `monitoring-vm` a standard relay fallback when direct client-to-node
WireGuard paths cannot be established. The relay is published on the same public
Headscale hostname at `/derp`, and UDP `3478` is opened for STUN.

When validating tailnet reachability from a workstation, prefer real service probes
or `tailscale ping --tsmp` over the default `tailscale ping`. In the current
Blueprint deployment, ordinary `tailscale ping` can still time out for some peers
even when direct tailnet TCP and HTTP access to Grafana and Prometheus is healthy.
During deploys, all already-joined nodes now refresh their `tailscaled` session
after Headscale updates so stale peer state does not linger between internal
cluster nodes after a control-plane restart.

Managed blueprint nodes now also persist the applied Headscale noise-key
fingerprint locally (`/var/lib/tailscale/headscale-noise-key.sha256`). If a
future control-plane restore/rebuild rotates `noise_private.key`, the next
converge automatically forces `tailscale up --reset` on those managed nodes so
their control-plane crypto state is re-established without manual intervention.

Loki query scheduling is now explicitly tuned for this single-node monitoring
topology (`split_queries_by_interval`, frontend/scheduler outstanding limits,
and querier concurrency). This reduces `too many outstanding requests` and
related scheduler cancellation bursts that could appear when broad dashboards or
large Explore queries were run concurrently. On current Loki releases,
`split_queries_by_interval` must live under `limits_config`; placing it under
`query_range` will keep Loki in a restart loop during deploy or recovery.

Targeted recovery runs can now also re-derive the local Tailscale IPv4 address
inside both the monitoring and gateway roles. That keeps partial `--limit`
Ansible runs usable even when transient `tailscale_ip` facts were only created
by an earlier full-play invocation.

### Certificate lifecycle and renewal

This section describes what is automatic today and what operational assumptions each path still depends on.

| Path | Current implementation | Issue / renewal behavior | Main dependency |
|------|------------------------|--------------------------|-----------------|
| Public Headscale hostname | Caddy ACME / Let's Encrypt on control VM | Automatic per-host issuance and renewal | Public DNS must keep resolving to control VM and ACME must stay reachable |
| Public application hostnames on gateway | `public_service_tls_mode: letsencrypt` uses per-host ACME; `public_service_tls_mode: namecheap` uses one wildcard for `*.base_domain` | Automatic issuance and renewal after first activation | Public DNS must keep resolving to gateway VM; Namecheap mode also requires gateway IP allowlisting |
| Internal monitoring aliases in `internal` mode | Monitoring VM Caddy private CA | No public ACME path; private CA remains the trust model | Clients must trust the private CA |
| Internal monitoring aliases in `namecheap` mode | Gateway wildcard DNS-01 via Namecheap | Automatic wildcard issuance and renewal after first activation | Gateway public IP must stay allowlisted in Namecheap and API credentials must remain valid |

Important distinctions:

- Headscale stays on its own exact-host certificate path on the control VM.
- Public gateway services can now use either per-host ACME or one wildcard public certificate on the gateway.
- The internal wildcard path still exists only for the packaged monitoring aliases in `internal_service_tls_mode: namecheap`.
- The first gateway-side Namecheap wildcard issuance is one-pass when the current gateway IP is already allowlisted in Namecheap before deploy start. It becomes a two-pass operator flow only when that external allowlist step is still pending.
- After the first Namecheap wildcard activation, Caddy handles renewals automatically, but renewal will fail if a later gateway IP change is not reflected in the Namecheap allowlist.

---
### Headscale URL behavior

- Default: the dynamic inventory sets `headscale_url` to `https://<control_public_ip>.sslip.io`.
- For long-term deployments, prefer a stable DNS hostname you control. The `sslip.io` fallback is bootstrap-friendly but couples the login-server URL to a volatile control IP.
- When `base_domain` is configured, the playbook now auto-switches Headscale to `headscale_tls_mode: letsencrypt` by default. Set `headscale_tls_mode_auto: false` in the environment only when you intentionally want to keep the control plane on the internal Caddy CA.
- Override (optional):

```bash
export HEADSCALE_URL="https://headscale.example.com"
```

---

### Domain configuration

See: [Architecture — DNS and Service Visibility](../technical/ARCHITECTURE.md#dns-and-service-visibility)

Before Ansible can issue real Let's Encrypt certificates, DNS must already resolve the service
hostnames to the correct VM IPs. Get the IPs immediately after `terraform apply`:

```bash
terraform -chdir=terraform output -raw control_public_ip
terraform -chdir=terraform output -raw gateway_public_ip
```

#### Option A: Manual (any registrar)

Add A records in your registrar's DNS control panel:

| Record | Value | Notes |
|--------|-------|-------|
| `headscale.yourdomain.com` | `<control_public_ip>` | Required before Ansible/control runs |
| `<service>.yourdomain.com` | `<gateway_public_ip>` | One per public service; all point to gateway |

Confirm propagation before running Ansible:

```bash
dig +short headscale.yourdomain.com    # should return the control VM IP
```

Typical propagation: 5–30 minutes (Namecheap default TTL 1799s).

#### Option B: Namecheap API automation

The script `scripts/helpers/dns-setup.sh` automates A record upserts after `terraform apply`.
It runs automatically inside `scripts/deploy.sh full`, `scripts/deploy.sh gateway`, and
`scripts/deploy.sh control` when `NAMECHEAP_API_KEY` is set in
`environments/<env>/secrets.env`. When the key is not set, the step is silently skipped
(fully backwards-compatible).

**How it works:**

1. Reads fresh `control_public_ip` and `gateway_public_ip` from
   `environments/<env>/inventory/terraform-outputs.json`
2. Calls `namecheap.domains.dns.getHosts` to fetch the current record set (preserves
   unrelated records)
3. Merges the headscale and gateway A records into the set
4. Calls `namecheap.domains.dns.setHosts` to atomically replace all host records
5. Polls authoritative and public DNS, and replays the merged `setHosts` payload if Namecheap's management state updates but the authoritative nameservers stay stale
6. Fails the deploy if public DNS still does not converge before the timeout

**Required environment variables** (in `environments/<env>/secrets.env`):

| Variable | Description |
|----------|-------------|
| `NAMECHEAP_API_USER` | Namecheap account username |
| `NAMECHEAP_API_KEY` | API key (Profile → Tools → API Access) |

These same credentials are also reused when `public_service_tls_mode: namecheap`
and/or `internal_service_tls_mode: namecheap` are enabled on the gateway.
In that wildcard-TLS mode, the gateway VM is the only host that needs those Namecheap
credentials; the backend monitoring VM continues serving plain HTTP over Tailscale behind
the gateway proxy.

**Required Ansible variables** (in `environments/<env>/group_vars/all.yml`):

| Variable | Description | Example |
|----------|-------------|--------|
| `base_domain` | Root domain | `yourdomain.com` |
| `headscale_subdomain` | Subdomain for control VM | `headscale` (default) |
| `gateway_subdomains` | Optional explicit list of subdomains pointing to gateway | `[]` (default) |

**One-time Namecheap setup:**

1. Profile → Tools → API Access → Enable API Access
2. Add your workstation's public IP to the allowlist (Namecheap allows max 10 IPs)
3. If you use `public_service_tls_mode: namecheap` or `internal_service_tls_mode: namecheap`, also add the gateway VM public IP
  because that VM performs the wildcard DNS-01 renewals.

**Ad-hoc usage:**

```bash
./scripts/deploy.sh dns --env prod
```

This runs only the DNS update step without touching Terraform or Ansible.

The repo also ships a local, fully stubbed regression suite for this helper:

```bash
./scripts/tests/run.sh dns-helper-local
```

That suite does not touch live DNS. It verifies two safety properties:
- stale Namecheap records are updated
- already-correct Namecheap records still cause a failure when public DNS remains stale

**Known friction:** Namecheap API requires IP-allowlisting the calling host. If your
workstation has a rotating public IP (dynamic ISP), you must keep the allowlist current
or run deploys from a host with a static IP. This is a Namecheap API constraint.

#### Set Ansible variables

In `environments/<env>/group_vars/all.yml`:

```yaml
headscale_url: "https://headscale.yourdomain.com"
headscale_tls_mode: letsencrypt
headscale_acme_email: "you@example.com"
# Optional — enables private names like grafana.in.yourdomain.com and monitoring-vm.in.yourdomain.com:
headscale_magic_dns_base_domain: "in.yourdomain.com"
public_service_tls_mode: "letsencrypt"  # or "namecheap" for gateway wildcard TLS on *.base_domain
internal_service_tls_mode: "internal"   # or "namecheap" for Namecheap-backed wildcard TLS
```

---

### Adding a new public service

1. **Add a DNS A record** pointing the new subdomain to the gateway public IP:
   ```
   myapp.yourdomain.com  A  <gateway_public_ip>
   ```

2. **Add the gateway routing entry** in `environments/<env>/group_vars/gateway.yml`:
   ```yaml
   gateway_services:
     - name: myapp
       upstream_host: myapp-vm    # Ansible inventory hostname
       upstream_port: 3000
   ```
   The resulting public hostname is `myapp.<base_domain>`. Legacy `gateway_domains` plus
   one global upstream are still accepted for older environments, but new configs should use
   `gateway_services`.

3. **Deploy:**
   ```bash
   ./scripts/deploy.sh gateway --env prod
   ```
  In the default `public_service_tls_mode: letsencrypt`, Caddy will auto-issue the
  Let's Encrypt cert on the first request. In `public_service_tls_mode: namecheap`, the
  gateway instead uses one wildcard certificate for `*.base_domain` after the initial
  Namecheap allowlist + follow-up gateway converge.

---

### Adding a new private (tailnet-only) service

No DNS or gateway configuration needed.

1. Add the VM to `terraform/terraform.tfvars`:
   ```hcl
   workloads = {
     myapp = { cpu = 2, memory_mb = 4096, rootfs_mb = 16384 }
   }
   ```

2. Run:
   ```bash
   ./scripts/deploy.sh full --no-destroy
   ```
  The new VM joins the tailnet and is immediately reachable:
   - By Tailscale IP: `http://100.64.x.y:<port>`
    - By MagicDNS VM name (if enabled): `http://myapp-vm.in.yourdomain.com:<port>`

   No gateway config. No public DNS record. No certificate to manage.

If you want browser-trusted HTTPS for `grafana.in.<domain>`, `prometheus.in.<domain>`,
and `backrest.in.<domain>`, set `internal_service_tls_mode: namecheap`. That mode is
currently implemented for the packaged monitoring stack and terminates on the gateway's
Tailscale address instead of directly on the monitoring VM.

Direct host/admin access does not move behind the gateway. Continue using the canonical
`-vm` MagicDNS names such as `monitoring-vm.in.<domain>` for SSH and other host-level tasks.
Headscale remains on its own public `headscale_url` hostname on the control VM, while Headplane
is now tailnet-only on `control-vm` port `3000`. Only the packaged internal monitoring aliases
currently use the gateway-side wildcard path.

---

### If you need temporary public SSH access

This blueprint locks down public SSH by default (UFW allows SSH only on `tailscale0`, plus an optional allowlist).

If you need a temporary public SSH path (for example, to run `headscale nodes register ...` on the control VM), use one of:

```bash
./scripts/deploy.sh control --allow-ssh-from-my-ip
# or
./scripts/deploy.sh control --allow-ssh-from "203.0.113.10/32"
```

Locking it back down:

- If you used `--allow-ssh-from*` and also used `--join-local`, `scripts/deploy.sh` will automatically re-apply the firewall role at the end with an empty allowlist (tailnet-only SSH).
- If `--join-local` was not used (or the local join failed), the script intentionally leaves the allowlist in place to avoid locking you out.

Manual lockdown (run from a tailnet-connected machine):

```bash
cd ansible
terraform -chdir=../terraform output -json > inventory/terraform-outputs.json
PREFER_TAILSCALE=1 ansible-playbook -i inventory/tfgrid.py playbooks/site.yml --tags firewall --extra-vars '{"firewall_allow_public_ssh_from_cidrs":[]}'
```

### Joining the machine running deployments to the tailnet (recommended)

If you enable `--join-local`, the deploy script will (best-effort) join the machine you’re running it from to Headscale after the Ansible run, so future Ansible runs can happen over Tailscale even after public SSH is locked down:

```bash
./scripts/deploy.sh full --join-local
```

If your deploy machine is already on a tailnet, `--join-local` will detect an existing Tailscale IP and skip re-auth by default. Use `--rejoin-local` only if you explicitly want to switch this machine to this Headscale network.

---

---

# Working with Environments

See: [Architecture — Multi-Environment Model](../technical/ARCHITECTURE.md#multi-environment-model)

The `--env <name>` flag tells `deploy.sh` to use `environments/<name>/` for all Terraform
state, variables, and runtime inventory outputs. `--env` is required for all deploy
scopes except `--help`.

---

## Web UI (local deployment dashboard)

As an alternative to running `deploy.sh` and editing config files directly, the blueprint ships a locally-hosted web UI under `ui/`.

### Starting the UI

```bash
make ui-install   # install Python deps once
make ui           # start on http://localhost:8090
```

### What it provides

| Screen | What you can do |
|--------|----------------|
| **Deploy** | Select scope and env, choose the existing-infrastructure policy (`--no-destroy` converge vs `--yes` destroy/recreate), trigger `deploy.sh`, watch live ANSI-coloured logs plus a generic top-level progress/ETA bar; reconnect-safe — closing and re-opening the tab replays from the last line |
| **Configure** | Edit `terraform.tfvars` (network, name, scheduler, SSH keys), `secrets.env` (mnemonic, passwords, backup/DNS API keys), env-level `group_vars/all.yml` (DNS, backup settings) |
| **Status** | View IPs, clickable service URLs (Headscale, Headplane, Grafana, Prometheus) |
| **Environments** | List all environments with config completeness, last-deploy status; create new environments |
| **History** | Browse all past deploy logs; replay any log in the Deploy tab |

### Log persistence

Every deploy job writes its output to:

```
environments/<env>/.ui-logs/<job-id>.log    # raw log with ANSI codes
environments/<env>/.ui-logs/<job-id>.json   # job metadata (status, exit code, timing)
environments/<env>/.ui-logs/<job-id>.deploy.sh   # UI-only immutable deploy.sh snapshot used for that run
environments/<env>/.ui-logs/timing-profile.json   # EMA timing profile rebuilt from successful runs
```

These files survive server restarts. On startup, the server rebuilds its job registry from disk — finished jobs are visible in History without re-running.

For UI-triggered runs, the server now snapshots `scripts/deploy.sh` into the job log directory, validates that snapshot before launch, and passes the original repo root into the subprocess environment. This avoids a class of race conditions where a long-running deploy could otherwise start from one repo copy, later hit a live-edited line from a different copy of the script, or resolve paths relative to the snapshot directory instead of the repository root.

The top-level deploy progress bar is not driven by a hardcoded per-scope frontend map. `deploy.sh` now emits a structured progress plan for the selected scope after it resolves destroy/recreate branching, Ansible task totals are counted from the real `ansible-playbook --list-tasks` output with the active env overrides, and a small Ansible callback plugin emits machine-readable task-start markers during the run. The UI also rebuilds `environments/<env>/.ui-logs/timing-profile.json` from successful historical jobs using an exponential moving average, then uses that profile to estimate remaining time per step and to adjust the visible percent/ETA when the current step is running faster or slower than its historical norm. When no history exists yet, the UI falls back to the live unit-rate estimator.

### API reference (for operators scripting around the UI)

```
GET  /environments              list envs + config completeness
GET  /config/{env}              read sanitised config (no secret values)
PUT  /config/{env}/grid         update tfgrid_network, name, use_scheduler
PUT  /config/{env}/ssh          update ssh_public_keys
PUT  /config/{env}/credentials  write mnemonic / admin password to secrets.env
PUT  /config/{env}/dns          update DNS fields in group_vars + secrets.env
PUT  /config/{env}/backup       update backup fields in group_vars + secrets.env
POST /jobs                      start a deploy job; returns job_id
GET  /jobs/{job_id}/stream      SSE stream with Last-Event-ID replay
GET  /jobs/{job_id}/log         full log as plain text (download)
GET  /timing/{env}              rebuild and return the environment timing profile
GET  /status/{env}              VM IPs and service URLs from terraform-outputs.json
POST /environments              create a new environment directory from the example template
DELETE /jobs/{job_id}          cancel a running job (SIGTERM)
```

The UI launches `deploy.sh` as a non-interactive subprocess, so the Deploy screen preselects the existing-infrastructure response up front. For `full`, `gateway`, and `control`, choosing **Converge in place** sends `--no-destroy`; choosing **Destroy and recreate first** sends `--yes`.

---

## Creating a new environment

```bash
# 1. Create the directory structure
mkdir -p environments/family/group_vars environments/family/inventory

# 2. Create Terraform vars (gitignored — never committed)
cp environments/prod/terraform.tfvars.example environments/family/terraform.tfvars
$EDITOR environments/family/terraform.tfvars
# Set: name="family", node IDs, mnemonic, SSH keys

# 3. Set Ansible overrides (committed)
cp environments/prod/group_vars/all.yml environments/family/group_vars/all.yml
$EDITOR environments/family/group_vars/all.yml
# Set: headscale_url, domain, passwords

cp environments/prod/group_vars/gateway.yml environments/family/group_vars/gateway.yml
```

## Deploying an environment

```bash
# Full deploy (first time or rebuild)
./scripts/deploy.sh full --env prod

# Full deploy + join workstation to prod tailnet
./scripts/deploy.sh full --env prod --join-local

# In-place converge (no destroy prompt)
./scripts/deploy.sh full --env prod --no-destroy

# Test environment
./scripts/deploy.sh full --env test --no-destroy

# Single-scope deploys
./scripts/deploy.sh gateway --env prod
./scripts/deploy.sh control --env prod
```

## Key constraint: unique TFGrid resource names

Each environment’s `terraform.tfvars` must use a different `name` value. TFGrid
globally enforces uniqueness on deployment names:

```hcl
# environments/prod/terraform.tfvars
name = "prod"

# environments/test/terraform.tfvars
name = "test"

# environments/family/terraform.tfvars
name = "family"
```

If two environments use the same `name`, Terraform apply will fail with a name conflict
error (the retry logic in `deploy.sh` already handles this with exponential backoff).

## Runtime files (gitignored)

After each deploy, `environments/<env>/inventory/` is populated with:

| File | Contents |
|------|----------|
| `terraform-outputs.json` | Public/private IPs from Terraform outputs |
| `tailscale-ips.json` | Tailscale IP mapping for Ansible inventory |
| `headscale-authkeys.json` | Preauth key + login server URL (for `--join-local`) |
| `headscale-root-ca.crt` | Caddy internal CA cert (only when `headscale_tls_mode: internal`) |

These are gitignored. Re-running `deploy.sh` regenerates them.

## Switching tailnets on your workstation

Each environment is an independent Headscale tailnet. To switch:

```bash
# Check current env
tailscale status | head -3

# Switch to prod tailnet
sudo tailscale up --login-server "$(cat environments/prod/inventory/headscale-authkeys.json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"headscale_url\"])')" --force-reauth

# Or simply re-run join-local for an env
./scripts/deploy.sh join-local --env prod
```

Normal redeploys preserve tailnet identity: Headscale restores `/opt/headscale/data`
and each VM restores `/var/lib/tailscale`, so registered nodes survive routine rebuilds.

If you intentionally run a destructive redeploy with `--fresh-tailnet`, the deploy
overrides the restore behavior for tailnet identity only: Headscale drops the node
database and rebuilt VMs skip local Tailscale state restore. In that mode, all devices
must register again. Re-run:

```bash
./scripts/deploy.sh join-local --env <env> --rejoin-local
```

The post-deploy summary now prints the client reset flow for this case as well. It
prefers `join-local --rejoin-local` so the local helper reuses the sanitized hostname
path and only falls back to a manual `tailscale logout` plus
`tailscale up ... --reset --force-reauth --hostname ...` sequence when the helper is
unavailable. The summary also includes a resolver verification step and platform-specific
DNS cache flush fallbacks for macOS, Linux, Windows, and mobile clients when hostname
lookups are still stale after reconnect.

The deploy helper now detects stale local sessions and forces a re-auth automatically
when the workstation still has an old Tailscale IP but can no longer synchronize with
the rebuilt Headscale control plane.

---

# Scenario 1) Deploy from scratch

# Scenario 1.5) Full network deploy (destroy + recreate)

Use this when you want a clean slate or you’ve lost access and need break-glass recovery.

Quick command (repo root):

```bash
./scripts/deploy.sh full --env prod
```

What it does:

- Sources `environments/prod/secrets.env`
- When running Terraform, Ansible, or test commands manually, source secrets with `set -a; source environments/<env>/secrets.env; set +a` so `lookup('env', ...)` sees admin passwords, backup keys, and other credentials.
- Destroys the current Terraform-managed deployments (if any)
- Re-applies Terraform with environment-scoped state and vars
- Refreshes Ansible inventory outputs to `environments/prod/inventory/`
- Re-runs the full Ansible playbook with env-specific group_vars

## 1.1 Terraform (workstation)

```bash
cd terraform
terraform apply

# Helpful outputs
terraform output -raw gateway_public_ip
terraform output -raw control_public_ip
```

## 1.2 Ansible bootstrap/configure (workstation)

```bash
cd ../ansible
terraform -chdir=../terraform output -json > inventory/terraform-outputs.json

# Optional override:
# export HEADSCALE_URL="https://headscale.example.com"

ansible-playbook -i inventory/tfgrid.py playbooks/site.yml
```

What this does:

- Deploys Headscale + Caddy on the control VM
- Joins all VMs to the tailnet
- Deploys node-exporter on all VMs (bound to Tailscale IP)
- Deploys Prometheus + Grafana on the monitoring VM (bound to Tailscale IP)
- Deploys gateway Caddy reverse proxy template + optional exit-node NAT
- Approves the gateway's advertised Headscale default routes when exit-node mode is enabled
- Applies firewall baseline (locks down public SSH)

## 1.3 Access services (tailnet-connected device)

1) Join your device to Headscale:

```bash
sudo tailscale up --login-server "https://<control_public_ip>.sslip.io"
```

2) Find Tailscale IPs:

```bash
tailscale status
```

3) Access:

- SSH: `ssh ops@<vm_tailscale_ip>` (or `ssh root@<vm_tailscale_ip>`)
- Grafana: `http://<monitoring_tailscale_ip>:3000`
- Prometheus: `http://<monitoring_tailscale_ip>:9090`

### Gateway exit-node troubleshooting

If a Tailscale client shows `No Exit Nodes Available`, check the route approval state on the
control VM:

```bash
ssh root@<control_public_ip> \
  'docker exec headscale headscale nodes list --output json | jq ".[] | select(.name==\"gateway-vm\") | {available_routes, approved_routes}"'
```

Expected state:

- `available_routes` contains `0.0.0.0/0` and `::/0`
- `approved_routes` contains the same two routes

If the routes are available but not approved, re-run the gateway converge so the blueprint
re-applies approval automatically:

```bash
./scripts/deploy.sh gateway --env <env> --no-destroy
```

Manual fallback on the control VM:

```bash
docker exec headscale headscale nodes approve-routes -i <gateway-node-id> -r 0.0.0.0/0,::/0
```

If the client can select `gateway-vm` as an exit node but internet traffic stops working, check
the effective Headscale ACL and the gateway forwarding path next.

The ACL must allow exit-node traffic to `autogroup:internet:*`. The shipped policy now includes
that destination for the admin user, admin group, ordinary members, and `tag:servers` so both
user devices and managed servers can use the gateway as a full-tunnel VPN.

The gateway must also keep both forwarding and routed-firewall rules in place:

```bash
ssh root@gateway-vm '
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
  ufw status verbose
'
```

Expected state:

- `net.ipv4.ip_forward = 1`
- `net.ipv6.conf.all.forwarding = 1`
- `ufw status verbose` includes `ALLOW FWD` rules from `tailscale0` to the public interface and back

For an end-to-end verification, run:

```bash
./scripts/tests/run.sh tailnet-management
```

That suite now performs a guarded exit-node egress test on `control-vm`: it enables the gateway
exit node briefly, verifies public IPv4 and IPv6 egress match the gateway, and then clears the
exit-node setting before the script exits.

---

# Scenario 2) Update server configuration (Ansible changes)

Once the firewall role has run, **public SSH is intentionally blocked**.

## 2.1 If you are on the tailnet (recommended)

Run Ansible from any machine that can reach VM Tailscale IPs.

If the machine you use for Ansible is not on the tailnet yet, join it first:

```bash
sudo apt-get update && sudo apt-get install -y tailscale
sudo systemctl enable --now tailscaled || true

# Point to your Headscale login server
sudo tailscale up --login-server "https://<control_public_ip>.sslip.io" --force-reauth
```

Typical patterns:

- Update everything:

```bash
cd ansible
terraform -chdir=../terraform output -json > inventory/terraform-outputs.json
ansible-playbook -i inventory/tfgrid.py playbooks/site.yml
```

- Update only one host:

```bash
ansible-playbook -i inventory/tfgrid.py playbooks/site.yml --limit monitoring-vm
```

- Update only a group:

```bash
ansible-playbook -i inventory/tfgrid.py playbooks/site.yml --limit workloads
```

## 2.2 If you are NOT on the tailnet (break-glass)

If you are not on the tailnet, there is no console fallback. Your options are:

1) **If you pre-configured the public SSH allowlist**: SSH from your workstation and re-run Ansible.
2) **Otherwise**: Terraform replace (destroy + recreate) is the break-glass recovery.

Public SSH allowlist (temporary safety net during bootstrap):

- Set `firewall_allow_public_ssh_from_cidrs` in `environments/<env>/group_vars/all.yml` (example: `["203.0.113.10/32"]`) and run the playbook.
- After the tailnet is stable, set it back to `[]` and re-run the firewall role (or full playbook).

---

# Scenario 3) Replace ONLY the gateway VM

Use this if the gateway is hung, destroyed, or you want to rotate it.

Quick command (repo root):

```bash
./scripts/deploy.sh gateway --env prod
```

This replaces `grid_deployment.gateway`, refreshes Ansible inventory to `environments/prod/inventory/`, then runs the playbook limited to the `gateway` group.

## 3.1 Replace the gateway deployment (workstation)

Preferred (Terraform v1.1+):

```bash
cd terraform
terraform apply -replace=grid_deployment.gateway
```

Alternative (more disruptive):

```bash
terraform destroy -target=grid_deployment.gateway
terraform apply
```

Then refresh outputs:

```bash
cd ../ansible
terraform -chdir=../terraform output -json > inventory/terraform-outputs.json
```

## 3.2 Reconfigure gateway + ensure tailnet is healthy

If you can reach the new gateway over SSH (before firewall lock-down), you can limit the run:

```bash
ansible-playbook -i inventory/tfgrid.py playbooks/site.yml --limit gateway
```

If the rest of the fleet is fine and you only want gateway config, this is usually enough.

Notes:

- Gateway replacement may change its host SSH key; the inventory is configured to avoid `known_hosts` issues.
- If the gateway public IP changes, your DNS (if any) must be updated.

---

# Scenario 4) Replace ONLY the control VM (Headscale)

This is the most sensitive scenario because Headscale is the coordination/control-plane.

Quick command (repo root):

```bash
./scripts/deploy.sh control --env prod
```

This replaces `grid_deployment.core`, refreshes Ansible inventory to `environments/prod/inventory/`, then re-runs the full Ansible playbook.

## 4.0 Control VM corrupted/destroyed: recreate + restore from backup

If the control VM is corrupted/destroyed, you can recreate it and (optionally) restore Headscale state from backup so that:

- Tailnet identity and node registrations survive
- You avoid having to re-enroll every device/node (as long as the Headscale state is restored)

What to back up (control VM):

- Headscale persistent state: `/opt/headscale/data/` (includes the SQLite DB, noise key, and other identity-critical keys)
- Headscale config/ACLs: `/opt/headscale/config/` (includes the ACL policy and control-plane config)
- Caddy TLS state: `/opt/caddy/data/` (preserves the control-plane certificate state and avoids ACME churn)
- Headplane config/state: `/opt/headplane/` (admin UI config, cookie secret, and local state)

Notes:

- If you use a stable DNS name for `headscale_url` (recommended), you can repoint DNS to the new control public IP and keep the same login-server URL.
- If you rely on `https://<control_public_ip>.sslip.io`, a control public IP change implies a login-server URL change; clients/devices may need to update/re-auth even if you restore the Headscale DB.

The repo now has two separate recovery paths:

- Service data: Restic snapshots per service, restored by the existing backup/auto-restore logic
- Operator workspace: portable recovery bundle restored with `./scripts/restore.sh --recovery-line '<opaque-line>'`

## 4.1 Replace the core deployment (workstation)

The control VM is inside `grid_deployment.core`, so replacing core will replace control + workloads.

If you truly need *only* control replaced, the current Terraform model does not support that because control and workloads are in the same deployment (this was done to avoid duplicate private IP problems on some nodes).

So you have two options:

### Option A (recommended): Replace the whole core deployment

```bash
cd terraform
terraform apply -replace=grid_deployment.core
```

### Option B: Full destroy + recreate

```bash
terraform destroy
terraform apply
```

Then refresh outputs:

```bash
cd ../ansible
terraform -chdir=../terraform output -json > inventory/terraform-outputs.json
```

## 4.2 Re-run Ansible to restore Headscale + re-join nodes

```bash
cd ansible
ansible-playbook -i inventory/tfgrid.py playbooks/site.yml
```

Key points:

- If you did not set a custom `headscale_url`, the inventory defaults to `https://<control_public_ip>.sslip.io`.
- If you use a custom `headscale_url` (stable DNS recommended), keep it the same and repoint DNS to the new control public IP.
- Devices must re-point to the new login server only if the login-server URL they use changed:

```bash
sudo tailscale up --login-server "https://<new_control_public_ip>.sslip.io" --force-reauth
```

### 4.3 (Optional) Restore Headscale from backup (manual)

If you have a backup of Headscale state, the simplest pattern is:

1) Replace the core deployment (as above).
2) Run Ansible once to ensure Docker, directories, and base config exist.
3) Restore the backed up directories onto the new control VM.
4) Re-run Ansible to converge.

Tip: stop the containers before restoring data, then start them again:

```bash
ssh ops@<control_tailscale_ip> -- docker stop headscale caddy || true
```

The exact restore mechanics depend on how you store backups, but the paths to restore on the control VM are:

- `/opt/headscale/data/`
- `/opt/caddy/data/` (optional)

After restore, verify Headscale health and that nodes still appear:

```bash
ssh ops@<control_tailscale_ip> -- docker exec headscale headscale health
ssh ops@<control_tailscale_ip> -- docker exec headscale headscale nodes list
```

---

## Troubleshooting quick commands

### Show inventory (workstation)

```bash
cd ansible
./inventory/tfgrid.py --list | jq '.all.vars, .gateway.hosts, .control.hosts, .workloads.hosts'
```

### Show Terraform resources (workstation)

```bash
cd terraform
terraform state list
terraform state show grid_network.net
```

---

## Verification tests (recommended)

From the repo root:

```bash
PREFER_TAILSCALE=1 ./scripts/tests/run.sh bootstrap-smoke
PREFER_TAILSCALE=1 REQUIRE_TS_SSH=1 ./scripts/tests/run.sh tailnet-management
```

`tailnet-management` now includes a public control-plane reachability assertion (`tcp/443` and `GET /health` on `https://<control_public_ip>.sslip.io`).

### Console URLs (intentionally unused)

ThreeFold console URLs are intentionally not part of this runbook because you should assume console access is unavailable.

---

# Portable Recovery Bundle And Restore

This is the control-plane recovery path for losing the original deploy machine.

It is separate from the per-service Restic backup system.

## Security boundary

The recovery line printed after deploy is wrong-eye fool-protection, not a standalone cryptographic trust anchor.

- The line is intentionally opaque so a casual observer does not immediately recognize storage endpoints, credentials, and the bundle password.
- Anyone with the codebase and the recovery line may still be able to decode it.
- Real confidentiality comes from encrypting the recovery bundle before upload.

## What the bundle contains

For one environment, the bundle includes:

- `environments/<env>/secrets.env`
- `environments/<env>/terraform.tfvars`
- `environments/<env>/.data-model-version`
- `environments/<env>/group_vars/`
- `environments/<env>/inventory/`
- local Terraform-related state files when present
- bundle metadata and a machine-readable recovery manifest

The bundle does not include local pre-migration rollback tarballs such as `.data-model-version-pre-*.tar.gz`. Those are local safety artifacts, not part of the canonical portable workspace state.

## Normal deploy behavior

After a successful `full`, `gateway`, or `control` deploy, the repo now:

1. Assembles the current environment files and local state into an encrypted bundle
2. Embeds the current `data_model_version` in the bundle metadata
3. Uploads that bundle to the primary and secondary S3-compatible backup storages under `control-recovery/<env>/...`
4. Refreshes `latest.json` on each successful backend
5. Prints one opaque `bp1...` recovery line in the deployment summary

If the primary upload fails, the recovery step is treated as failed. If the secondary upload fails, the deploy completes in a degraded state and the summary says so explicitly.

## Restore from a fresh machine

From any macOS or Linux machine with this repo checked out:

```bash
./scripts/restore.sh --recovery-line '<opaque-line>'
```

Restore behavior:

1. Decode the recovery line
2. Try primary storage first, then fail over to secondary
3. Download the latest bundle metadata and encrypted bundle
4. Decrypt and unpack into a temporary working directory
5. Recreate a usable workspace checkout and restore the environment files locally
6. Run the data-model migration engine against `environments/<env>/`
7. Print the next `deploy.sh` command, but stop before deployment

After restore, review and edit the environment files in the restored workspace before running `deploy.sh` — particularly if you are rotating credentials, changing node selections, or updating DNS settings.

Scope boundary: the automatic data-model migration step only updates blueprint-managed environment files under `environments/<env>/`. It does not migrate service-internal application data. Service data remains the responsibility of the per-service backup/restore or application-specific upgrade path.

The restore script cleans up its temporary working directory on normal exit and best effort on failure. It does not promise forensic-grade wipe semantics.

---

# Backup Operations

The blueprint includes an automated backup system using Restic with encrypted, deduplicated, incremental backups to S3-compatible storage.

This section covers service-data backups only. The portable recovery bundle above is the separate path for reconstructing the local operator workspace.

## Configuration

Backup is controlled by a per-environment secrets file (`environments/<env>/secrets.env`, gitignored):

```bash
# One-time setup:
cp environments/prod/secrets.env.example environments/prod/secrets.env
$EDITOR environments/prod/secrets.env
```

Fill in the backup-related values (all other secrets are in the same file):

```bash
# environments/prod/secrets.env  (excerpt — see file for full list)
RESTIC_PASSWORD=your-master-password
BACKUP_S3_PRIMARY_ACCESS_KEY=AKIA...          # AWS S3 (primary backend)
BACKUP_S3_PRIMARY_SECRET_KEY=...
BACKUP_S3_SECONDARY_ACCESS_KEY=...            # Hetzner Object Storage (secondary)
BACKUP_S3_SECONDARY_SECRET_KEY=...
```

Enable backup in your environment's `group_vars/all.yml`:

```yaml
backup_enabled: true
```

## What gets backed up

| Service | VM | Data |
|---------|-----|------|
| Headscale | control | SQLite DB, config, TLS certs, Headplane config |
| Gateway | gateway | Caddy TLS certs and config |
| Monitoring | monitoring | Prometheus data, Grafana dashboards |
| Tailscale | all | Node identity and keys |

## Backup schedule

- **Default**: Daily at 02:00 UTC with 30-minute random stagger
- **Retention**: 24 hourly / 7 daily / 4 weekly / 12 monthly / 2 yearly
- Overridable per-service in the backup manifest

## Manual backup commands

```bash
# Trigger immediate backup for a service (on the VM)
/opt/backup/bin/backup-headscale.sh

# List snapshots
export RESTIC_PASSWORD="your-master-password"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
restic -r s3:s3.amazonaws.com/<bucket>/prod/headscale snapshots

# Check backup integrity
restic -r s3:s3.amazonaws.com/<bucket>/prod/headscale check
```

## Manual restore

```bash
# Restore latest snapshot for a service
export RESTIC_PASSWORD="your-master-password"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
restic -r s3:s3.amazonaws.com/<bucket>/prod/headscale restore latest --target /

# Restore specific snapshot
restic -r s3:s3.amazonaws.com/<bucket>/prod/headscale snapshots  # find ID
restic -r s3:s3.amazonaws.com/<bucket>/prod/headscale restore <snapshot-id> --target /
```

## Auto-restore on deploy

When a service is deployed on a fresh/rebuilt VM:
- If a backup snapshot exists AND the data directory is empty → auto-restore
- Use `--no-restore` flag to skip: `./scripts/deploy.sh full --env prod --no-restore`

## Monitoring backup health

- **Grafana**: Backup Overview dashboard at `http://<monitoring-tailscale-ip>:3000`
- **Backrest**: Snapshot browser at `http://<monitoring-tailscale-ip>:9898` (Tailnet-only)
- **Prometheus alerts**: BackupFailed, BackupStale, BackupSizeAnomaly
- **Weekly summary**: Generated Monday 08:00 UTC, logged to `/var/log/backup-summary.log`

## Service observability

- **Grafana dashboards**: Infrastructure Health, Service Health, Logs Overview, and Backup Overview are provisioned automatically on the monitoring VM.
- **Centralized logs**: Every managed VM ships declared service logs to Loki through Grafana Alloy. Use Grafana Explore or the Logs Overview dashboard instead of reaching Loki directly.
- **Remote probes**: Prometheus scrapes Blackbox exporter on the monitoring VM for HTTP and TCP reachability checks.
- **Local service health**: Each node writes `blueprint_service_health` metrics into the node exporter textfile collector.
- **Archive retention**: Loki keeps searchable logs for `30d` by default. When S3-compatible backup storage is configured, the monitoring VM also exports daily compressed log archives and deletes archive objects after `90d`.

### What is currently covered

The shipped observability manifests already cover the current built-in services:

* gateway: `caddy`
* control: `headscale`, `headplane` when enabled, `caddy`
* monitoring: `grafana`, `prometheus`, `loki`, `blackbox-exporter`, `backrest` when backups are enabled
* backup logs and backup health checks

The default stack does not collect `tailscaled` logs or generic host log trees.

### How to use the dashboards

* **Infrastructure Health**: VM reachability, CPU, memory, and filesystem health.
* **Service Health**: Local `blueprint_service_health` results plus Blackbox HTTP/TCP probes, filterable by `env`, `node`, `role`, and `service`.
* **Logs Overview**: A fast triage view for log volume, critical/error lines, noisy services, and backup failures. The provisioned critical panels still key off `error`, but now explicitly drop `level=info`, `level=debug`, and `level=trace` noise so Loki query logs do not pollute the incident view.
* **Backup Overview**: Backup status, age, size, and restore-drill results.

### Grafana Explore query presets

Grafana Explore is the main ad-hoc workflow. The current stack does not provision saved Explore queries, so use these documented presets instead:

```logql
{service="headscale"}
{service="headplane"} |= "error"
{service="caddy",role="gateway"} |= "fail"
{service="grafana"} |= "error"
{service="prometheus"} |= "timeout"
{service="backrest"}
{service="backup"}
```

Useful refinements:

* add `,node="monitoring-vm"` to isolate one host
* add `,env="prod"` to isolate one environment
* switch the free-text filter to `|= "error"`, `|= "fail"`, or `|= "timeout"` for incident triage

If Headscale shows repeated `noise handshake failed: decrypting machine key` entries after a
control-plane restore or rebuild, that indicates an unmanaged client still using the pre-rotation
control-plane state. Managed blueprint VMs already reset themselves on the next converge when the
persisted `noise_private.key` fingerprint changes. For laptops and other user devices, rejoin the
affected device with `./scripts/deploy.sh join-local --env <env> --rejoin-local`, or manually run
`tailscale logout` and then `tailscale up --login-server ... --reset --force-reauth` on that device.

### Manual verification commands

```bash
# Prometheus: local service-health metrics
curl -u admin:"${SERVICES_ADMIN_PASSWORD}" "http://<monitoring-tailscale-ip>:9090/api/v1/query?query=blueprint_service_health{scope=\"local\"}"

# Prometheus: remote HTTP probe metrics
curl -u admin:"${SERVICES_ADMIN_PASSWORD}" "http://<monitoring-tailscale-ip>:9090/api/v1/query?query=probe_success{job=\"service_probe_http\"}"

# Loki: ready check from a tailnet-connected machine
curl "http://<monitoring-tailscale-ip>:3100/ready"

# Loki: example direct query for backup log lines
curl -G "http://<monitoring-tailscale-ip>:3100/loki/api/v1/query" \
  --data-urlencode 'query={service="backup"} |= "fail"'
```

### Relevant configuration knobs

These defaults live in `ansible/group_vars/all/main.yml` and can be overridden in `environments/<env>/group_vars/all.yml`:

* `logging_enabled`
* `logging_loki_retention_days`
* `logging_archive_enabled`
* `logging_archive_retention_days`
* `logging_archive_prefix`
* `service_observability_enabled`
* `service_health_checks_enabled`
* `service_log_collection_enabled`

## Checking backup status on a VM

```bash
# List backup cron jobs
crontab -l | grep backup

# Check last backup status
cat /var/lib/node_exporter/textfile/backup_*.prom

# View backup logs
cat /var/log/backup-headscale.log | tail -50
```

## Credential rotation

1. Generate a new Restic password
2. Use `restic key add` on each repo, then `restic key remove` the old key
3. Update `RESTIC_PASSWORD` in `environments/<env>/secrets.env`
4. Update the Owner Recovery Card

## Verification

```bash
# Run backup verification tests
./scripts/tests/run.sh backup-verify
./scripts/tests/run.sh portable-recovery
```
