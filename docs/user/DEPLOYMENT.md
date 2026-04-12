# Deployment And Configuration

This document covers environment configuration, deploy scopes and flags, node selection, TLS choices, and manual device-join behavior.

## Deploy script reference

```bash
./scripts/deploy.sh <scope> --env <name> [flags]
```

### Scopes

| Scope | What it does |
|-------|--------------|
| `full` | Terraform plus Ansible for the full deployment |
| `gateway` | Redeploy the gateway VM only |
| `control` | Redeploy the control VM and workload VMs |
| `dns` | Update DNS A records only when Namecheap automation is configured |
| `join-local` | Join this machine to the tailnet without changing infrastructure |

### Flags

| Flag | Effect |
|------|--------|
| `--env <name>` | Required environment name |
| `--join-local` | Join this machine to Headscale after deploy |
| `--rejoin-local` | Force re-auth when joining |
| `--no-destroy` | Converge in place instead of destroy and recreate |
| `--no-restore` | Skip automatic service-data restore on a fresh deploy |
| `--fresh-tailnet` | Reset Headscale node registrations and per-VM Tailscale identities during destructive redeploy |
| `--yes` | Auto-confirm prompts |
| `--allow-ssh-from <cidr>` | Temporarily allow bootstrap SSH from a CIDR |
| `--allow-ssh-from-my-ip` | Detect the current public IP and allow SSH from it temporarily |
| `--keep-ssh-allowlist` | Leave the temporary SSH allowlist in place after deploy |

### Examples

```bash
./scripts/deploy.sh full --env prod --allow-ssh-from-my-ip --join-local
./scripts/deploy.sh full --env prod --no-destroy
./scripts/deploy.sh full --env prod --yes --fresh-tailnet
./scripts/deploy.sh gateway --env prod
./scripts/deploy.sh join-local --env prod
```

## Node selection

ThreeFold Grid can use its auto-scheduler to place nodes based on resource requirements. That is the default with `use_scheduler = true`.

If deploy reliability matters more than flexibility, pinning nodes can be safer because the scheduler may place VMs on distant physical machines and make `grid_network` creation slower or less predictable.

Find node IDs at [dashboard.grid.tf](https://dashboard.grid.tf/) under **Nodes**.

```hcl
use_scheduler   = false
gateway_node_id = 6968
control_node_id = 1

workloads = {
  monitoring = {
    node_id   = 1
    cpu       = 2
    memory_mb = 4096
    rootfs_mb = 16384
  }
}
```

When `use_scheduler = false`, every workload must also have its own `node_id`.

## Headscale URL and TLS

By default, Headscale can use `https://<control_public_ip>.sslip.io` with a self-signed Caddy CA. That works for bootstrap, but it is not the preferred long-term control-plane identity.

For production, use a stable DNS name and browser-trusted certificates:

```yaml
headscale_url: "https://headscale.yourdomain.com"
headscale_tls_mode: letsencrypt
headscale_acme_email: "you@yourdomain.com"
```

DNS records must resolve before Ansible runs. You can configure them manually or let Namecheap automation update them after `terraform apply` when the required API credentials are present in `secrets.env`.

See [Domain configuration](../technical/OPERATIONS.md#domain-configuration) for the operator runbook.

## Certificate behavior

The blueprint has three separate certificate paths.

### Public Headscale certificate

- `headscale_tls_mode: letsencrypt` uses the normal ACME / Let's Encrypt flow on the control VM.
- Issuance and renewal are automatic once DNS points to the control VM and ACME validation can succeed.
- This is a per-host certificate, not a wildcard certificate.

### Public application certificates on the gateway

- `public_service_tls_mode: letsencrypt` keeps the default per-host Let's Encrypt flow.
- `public_service_tls_mode: namecheap` switches public service hostnames to a wildcard certificate for `*.base_domain` using Namecheap DNS-01.
- In Namecheap mode, the first wildcard issuance is a two-pass flow if the current gateway public IP was not already allowlisted in the Namecheap API settings.

Preferred public service schema:

```yaml
gateway_services:
  - name: app
    upstream_host: app-vm
    upstream_port: 3000
  - name: matrix
    upstream_host: matrix-vm
    upstream_port: 8448
```

Each entry serves `<name>.<base_domain>`.

### Internal monitoring aliases over MagicDNS

- `internal_service_tls_mode: internal` keeps `grafana.*`, `prometheus.*`, and `backrest.*` on the monitoring VM using Caddy's private CA.
- `internal_service_tls_mode: namecheap` moves those aliases to the gateway Tailscale IP and uses a wildcard public certificate for `*.headscale_magic_dns_base_domain` through Namecheap DNS-01.

Example:

```yaml
headscale_magic_dns_base_domain: "in.yourdomain.com"
public_service_tls_mode: "letsencrypt"
internal_service_tls_mode: "internal"
```

In Namecheap mode, renewal remains automatic only while the gateway public IP stays allowlisted and the API credentials remain valid.

## Joining devices to the tailnet

Install Tailscale on a device and point it at your Headscale URL:

```bash
sudo tailscale up --login-server "https://<headscale_url>"
```

`./scripts/deploy.sh join-local --env <env>` does this automatically for the local workstation.

If the local machine needs a forced re-auth, use:

```bash
./scripts/deploy.sh join-local --env <env> --rejoin-local
```

The helper also normalizes the machine hostname before `tailscale up` so that invalid DNS-style labels do not become broken node names.