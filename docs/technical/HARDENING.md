# Security Hardening — Step-by-Step Reference

This is **technical** documentation covering every hardening and security step
the blueprint applies, the order they execute, and how the deployment flow
orchestrates them across fresh, destructive, and non-destructive scenarios.

For deployment instructions see [../user/DEPLOYMENT.md](../user/DEPLOYMENT.md).
For architecture overview see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Guiding Principles

1. **Services first, hardening last.** All services must be functional before
   any ports are closed or public SSH is removed. This prevents deadlocks
   where a service needs a port that the firewall already blocked.
2. **Tailscale is the primary transport.** After the initial bootstrap, all
   admin and inter-node traffic flows over the encrypted Tailscale mesh.
   Public SSH is a temporary bootstrap path only.
3. **Minimal public exposure.** Only the gateway exposes ports 80/443 to the
   internet. The control VM exposes 80/443 solely for Headscale ACME + API.
   Everything else is internal-only.
4. **Idempotent and safe to re-run.** Every hardening step can be re-applied
   without breaking a running deployment.

---

## Security Layers

| Layer | What | How |
|-------|------|-----|
| 1 | Public exposure | Only gateway (80/443) + control (80/443 Headscale) face the internet |
| 2 | Private mesh network | Headscale + Tailscale (WireGuard) for all internal traffic |
| 3 | Identity-based ACL | Headscale ACL policy: groups, tags, per-port rules |
| 4 | Host firewall (UFW) | Per-VM rules: deny all inbound except explicit allows |
| 5 | SSH hardening | Key-only auth, no passwords, no public SSH after hardening |
| 6 | TLS everywhere | Caddy auto-TLS (Let's Encrypt or internal CA) for all HTTPS |
| 7 | Encrypted backups | Restic with encryption at rest, stored off-node |

---

## Deployment Flow by Scenario

### A. Fresh deploy (no pre-existing state)

```
1. Terraform apply        → Create VMs with public IPs
2. Wait for public SSH    → All VMs reachable on port 22 (open by default on new VMs)
3. Phase 1 bootstrap      → ALL VMs (via public SSH, bootstrap inventory mode):
   a. Common role         → SSH hardening (key-only), system packages
   b. Headscale role      → Start Headscale + Caddy (ACME cert on control)
   c. Tailscale role      → All VMs join the tailnet
   d. Backup role         → Snapshot TLS cert immediately
4. Controller join tailnet → Local dev machine joins tailnet via Headscale
5. Phase 1 harden         → ALL VMs (via tailnet, operational inventory mode):
   a. Firewall role       → Lock down all VMs (close public SSH)
6. Phase 1 gate           → Validate all hosts reachable via tailnet IPs
7. Phase 2                → ALL VMs (via tailnet, operational inventory mode):
   a. Services            → Monitoring, Forgejo, Gateway reverse proxy, etc.
   b. Backup role         → Full backup configuration
8. Recovery bundle        → Generate/refresh recovery artifacts
```

### B. Destructive redeploy (pre-existing state, destroy + recreate)

```
1. Best-effort backup     → Try to backup via Tailscale; skip if unreachable
2. Terraform destroy      → Remove all VMs
3. Clear stale state      → Delete old tailscale-ips.json, SSH host keys
4. Terraform apply        → Create fresh VMs
5. DNS setup              → Point headscale.domain.tld to new control IP
6. Wait for public SSH    → New VMs reachable on port 22
7. Phase 1 bootstrap      → Base OS, Headscale, Tailscale join
8. Controller join tailnet → Deploy machine joins the tailnet
9. Phase 1 harden         → Firewall hardening (operational mode, all via tailnet)
10. Phase 1 gate           → Validate all hosts reachable via tailnet
11. Phase 2                → Services, monitoring, backup (operational mode)
12. Recovery bundle        → Generate fresh recovery artifacts
```

**Scoped destructive deploys** (e.g., only gateway or only control replaced):
- All VMs follow the same phase 1 → phase 2 sequence with appropriate `--limit`
- Firewall hardening runs as part of phase 1

### C. Non-destructive converge (existing running infrastructure)

```
1. Verify Tailscale       → Local machine must be connected to tailnet
   - If Tailscale healthy → Use tailnet transport for Ansible
   - If NOT healthy       → FAIL with clear error:
     "Tailscale connection failed. For a non-destructive converge
      the tailnet must be reachable. If the servers are broken,
      use a destructive deploy."
2. Ansible phase 2        → ALL VMs via Tailscale SSH:
   a. Common role         → Idempotent SSH hardening
   b. Headscale role      → Update configuration, restart if needed
   c. Tailscale role      → Heal any stale connections
   d. Services            → Apply configuration changes
   e. Backup role         → Update backup schedule
   f. Firewall role       → Re-apply baseline (idempotent)
3. Recovery bundle        → Refresh recovery artifacts
```

---

## Firewall Rules (UFW)

Applied by `ansible/roles/firewall/tasks/main.yml` in `phase1_harden.yml` (phase 1 hardening step).

### Reset Phase
All pre-existing UFW rules are cleared with `ufw --force reset` to ensure an
authoritative baseline. This prevents rule drift from manual changes.

### Rules Applied (in order)

| # | Rule | Port | Proto | From/Interface | Applies to | Purpose |
|---|------|------|-------|----------------|------------|---------|
| 1 | Allow SSH bootstrap | 22 | tcp | `tf_private_cidr` | All VMs | Terraform jump-host access |
| 2 | Default deny incoming | — | — | — | All VMs | Block all unless explicitly allowed |
| 3 | Default allow outgoing | — | — | — | All VMs | Outbound unrestricted |
| 4 | Allow all on tailscale0 | any | any | tailscale0 iface | All VMs | All tailnet traffic trusted |
| 5 | Allow SSH on tailscale0 | 22 | tcp | tailscale0 iface | All VMs | Explicit SSH over tailnet |
| 6 | Allow Tailscale UDP | 41641 | udp | any | All VMs | WireGuard peer discovery |
| 7 | Allow public SSH allowlist | 22 | tcp | specific CIDRs | All VMs | Temporary recovery (empty by default) |
| 8 | Allow web ports (gateway) | 80, 443 | tcp | any | Gateway only | Public reverse proxy |
| 9 | Allow exit-node routing | route | — | tailscale0 ↔ eth0 | Gateway only | NAT for full-tunnel VPN |
| 10 | Allow Headscale HTTP+HTTPS | 80, 443 | tcp | any | Control only | ACME challenge + Headscale API |
| 11 | Allow DERP STUN | 3478 | udp | any | Control only | P2P relay fallback |
| 12 | Enable UFW | — | — | — | All VMs | Activate all rules |

### Post-deploy SSH lockdown
Firewall hardening runs as phase 1 step 5, before any services are deployed.
Public SSH is locked down automatically; no manual flags are needed.

---

## SSH Hardening

Applied by `ansible/roles/common/tasks/main.yml` on all VMs:

| Setting | Value | Effect |
|---------|-------|--------|
| `PasswordAuthentication` | `no` | Only key-based auth accepted |
| `KbdInteractiveAuthentication` | `no` | No interactive prompts |
| Root SSH keys | Copied from Terraform | Authorized keys from `tf_authorized_keys` |
| `ops` user | Created with NOPASSWD sudo | Non-root admin account |

---

## TLS Certificate Provisioning

Managed by `ansible/roles/headscale/tasks/main.yml` via Caddy reverse proxy:

### Internal mode (default)
- Caddy generates a private root CA on the control VM
- CA cert distributed to all VMs and the local machine
- `update-ca-certificates` installs into system trust store
- No internet dependency, instant provisioning

### Let's Encrypt mode (auto-enabled when `base_domain` is set)
- Caddy performs ACME HTTP-01 challenge on port 80
- Requires port 80 open on control VM (firewall rule #10)
- Requires DNS `headscale.{base_domain}` → control VM public IP
- Takes 5–60 seconds for cert issuance
- Rate limit: 5 certs per 7 days per exact hostname
- Cert immediately backed up after issuance to avoid rate limit waste

### Readiness checks
- Ansible: Polls `${headscale_url}/health` with up to 90 retries × 10s = 15 min
- deploy.sh: Polls `${login_server}/health` with up to 60 retries × 10s = 10 min
- Both must pass before any `tailscale up` attempt

---

## Transport Switching Logic

Deployment uses a two-phase model:

| Phase | Transport | Reason |
|-------|-----------|--------|
| Phase 1 bootstrap | Public IP SSH (bootstrap mode) | VMs have no Tailscale yet |
| Phase 1 harden, gate | Tailscale (operational mode) | All VMs joined tailnet in bootstrap |
| Phase 2 services | Tailscale (operational mode) | All traffic over tailnet |

The dynamic inventory (`tfgrid.py`) supports two modes:
- `bootstrap`: Uses public IPs, ProxyCommand for workloads via gateway
- `operational`: Uses live tailnet IPs from `tailscale status --json`

---

## Headscale ACL Policy

Central ACL file controls which tailnet nodes can reach which services:

- `group:admins` — Full access to all servers
- `tag:servers` — Inter-server communication on monitoring ports
- `tag:backup` — Backup service access
- Default: deny all other traffic

---

## Security Invariants

These must hold true at all times after a successful deployment:

1. **No public SSH** — Port 22 unreachable from the internet (only via tailscale0)
2. **No password auth** — SSH key-only across all VMs
3. **Firewall active** — UFW enabled with deny-all-inbound default
4. **Tailscale running** — All VMs connected to the Headscale mesh
5. **TLS valid** — Headscale HTTPS serving with valid cert (internal CA or LE)
6. **Backups configured** — Recovery bundle freshly generated after deploy
7. **Gateway ports only** — Only ports 80/443 open on gateway; 80/443/3478 on control
8. **No IP forwarding** — Except gateway (exit-node routing)
