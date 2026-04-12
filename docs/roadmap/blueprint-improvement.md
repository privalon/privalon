**Sovereign Cloud Blueprint**

Infrastructure Improvement Roadmap

Without AI --- Core Blueprint, Security, Services, Backup

March 2026 · Working Document v1.0

**Overview**

This document outlines the improvements needed to bring the sovereign
cloud blueprint from proof-of-concept to a production-grade,
community-shareable infrastructure. It covers four layers: the core
deployment blueprint, the security perimeter, the services catalogue,
and backup. The AI configurator layer is treated separately.

The goal of this phase is a solid foundation that works reliably, is
well-documented, and can be safely deployed by a technically-aware
person following the runbook --- with or without AI assistance.

+-----------------------------------------------------------------------+
| **Definition of Done for this phase**                                 |
|                                                                       |
| A person with basic Linux familiarity can read the runbook, run the   |
| deploy command, get a working multi-VM sovereign setup on a supported |
| provider, and restore from backup. No improvisation required.         |
+-----------------------------------------------------------------------+

**1. Core Blueprint**

**1.1 Current State**

The blueprint currently handles provisioning and basic VM configuration
on ThreeFold Grid. The core architecture decisions (mesh VPN, no public
SSH, reverse proxy, backup/recovery, and observability) are implemented
in the current baseline. Hetzner support is still future work. This
document should be treated as a forward-looking roadmap, while current
shipped behavior is documented in technical architecture and operations
docs plus the changelog.

**1.2 Required Improvements**

**Multi-provider Terraform modules**

The Terraform layer must be refactored into provider-specific modules
with a shared interface. Each provider module must expose identical
outputs (VM IPs, node IDs, provider name) so that higher layers
(Ansible, backup config) require zero changes when switching providers.

-   Complete ThreeFold Grid module --- full lifecycle: provision,
    replace, destroy

-   Add Hetzner module --- highest priority second provider (lowest
    cost, best EU DPA compliance)

-   Add DigitalOcean module --- third provider (widely familiar, good
    docs)

-   Shared output interface contract: all modules must export identical
    variable names

-   Parameterize everything: region, VM size, count, node names --- no
    hardcoded values

**VM count and role architecture**

The blueprint assumes a specific VM topology but this is not yet
codified as a reusable pattern. Define explicit roles and make the
topology configurable.

-   Gateway node: reverse proxy (Caddy), Headscale server, public
    ingress --- 1 required

-   Services node(s): all user-facing services --- 1 minimum, expandable

-   Backup node: dedicated offsite backup target --- optional but
    strongly recommended

-   Each role must be independently replaceable without touching other
    nodes

**Lifecycle operations**

Currently only initial deploy is supported. Production-ready means the
full lifecycle works.

-   deploy: initial provisioning + configuration

-   replace-node: destroy and reprovision single VM, rejoin mesh
    automatically

-   add-service: deploy new service to existing setup without full
    redeploy

-   destroy: clean teardown with confirmation prompt

-   Each operation must be idempotent --- running twice must produce
    same result

**Configuration schema**

All user-facing configuration must live in a single well-documented file
with validation. No surprises at deploy time.

-   Single terraform.tfvars or equivalent as the only file a user needs
    to edit

-   JSON schema or equivalent validation --- catch invalid values before
    deployment starts

-   Clear comments on every parameter explaining what it does and what
    values are valid

-   Sensible defaults for everything non-critical

  --------------------- -------------- -------------- -------------------------
  **Component**         **Current      **Priority**   **What\'s Needed**
                        State**                       

  Terraform modules     TFGrid only,   Critical       Add Hetzner + shared
                        partial                       interface

  VM role architecture  Implicit,      Critical       Codify 3 roles explicitly
                        undocumented                  

  Lifecycle ops         Deploy only    High           Add replace, add-service,
                                                      destroy

  Config schema         No validation  High           Single file + validation

  Idempotency           Not guaranteed High           Test all operations twice
  --------------------- -------------- -------------- -------------------------

**2. Security Perimeter**

**2.1 Current State**

Headscale (self-hosted WireGuard mesh) is the foundation and the right
architectural choice. Basic mesh setup works. However: SSH is still
reachable on public IPs, firewall rules are not fully hardened,
certificate management is manual, and the security model is not formally
documented.

**2.2 Required Improvements**

**Zero public attack surface**

The defining security property of this blueprint is: no service is
reachable from the public internet except through Caddy (HTTPS) and
Headscale (WireGuard UDP). Everything else must be firewalled off.

-   Close SSH on all public IPs --- all SSH access via Headscale mesh
    only

-   Cloud firewall rules (Terraform-managed): allow only 80/443/tcp and
    41641/udp outbound

-   All inter-VM communication exclusively over Headscale mesh IPs

-   Verify: nmap scan from external host must show zero open ports
    except 80/443/41641

**Certificate management**

Caddy handles automatic TLS via Let\'s Encrypt by default, which is
correct. But DNS setup and domain validation need to be tested
end-to-end and documented clearly.

-   Caddy auto-TLS must work on first deploy without manual intervention

-   Document DNS requirements --- exactly which records the user must
    create before running deploy

-   Test: wildcard subdomains if service count grows beyond manual DNS
    management

-   Document renewal process --- confirm it is fully automatic

**Headscale hardening**

Headscale is the trust anchor of the entire perimeter. It needs to be
production-hardened.

-   Pre-auth keys with expiry --- rotate on each deploy, never reuse

-   Node registration must be explicit --- no auto-approval

-   ACL policy: define explicit allow rules between nodes, default deny

-   Headscale admin access: only from mesh, never from public IP

-   Backup Headscale state as part of standard backup --- losing it
    means rebuilding mesh

**Secrets management**

Currently secrets are handled manually or stored in plaintext config
files. This must be fixed before public release.

-   No secrets in version control --- .gitignore must cover all
    generated secrets

-   Secrets generated at deploy time, stored locally in encrypted form

-   Document exactly which secrets are generated, where they live, and
    how to rotate them

-   Consider: age or sops for secrets at rest in the config directory

+-----------------------------------------------------------------------+
| **Security audit goal**                                               |
|                                                                       |
| Before public release, run a basic security audit: nmap from          |
| external, check for open ports, verify no secrets in git history,     |
| confirm Headscale ACLs are restrictive. Document the results as a     |
| baseline.                                                             |
+-----------------------------------------------------------------------+

  --------------------- ------------ -------------- -------------------------
  **Component**         **Current    **Priority**   **What\'s Needed**
                        State**                     

  Public attack surface SSH still    Critical       Close SSH, mesh-only
                        exposed                     access

  Certificate           Manual steps Critical       Fully automated on deploy
  management            needed                      

  Headscale hardening   Basic setup  High           ACLs, pre-auth keys,
                        only                        explicit registration

  Secrets management    Ad-hoc, some Critical       No secrets in repo,
                        plaintext                   generated at deploy

  Security              Not written  High           Document the security
  documentation                                     model explicitly
  --------------------- ------------ -------------- -------------------------

**3. Services Catalogue**

**3.1 Current State**

No standardized service layer exists yet. Services are deployed ad-hoc.
The goal is a curated catalogue of validated services, each with a
standard Ansible role interface, tested on the target VM topology.

**3.2 Architecture**

**Standard service interface**

Every service in the catalogue must follow the same interface so that
adding a new service is a one-line change in configuration, not a new
integration project.

-   Each service: one Ansible role in /roles/services/\<name\>/

-   Required variables: service_name, service_domain, service_port,
    service_enabled

-   Optional variables: service_data_dir, service_version,
    service_extra_config

-   Caddy config generated automatically from service inventory --- no
    manual proxy rules

-   Each service writes its data to a defined directory used by the
    backup layer

**Tier 1: Core services --- ship with blueprint**

These are the most common replacements for commercial services. They
must work out of the box and be thoroughly tested.

  ---------------- ------------------ ---------------- ----------------------
  **Service**      **Replaces**       **Complexity**   **Status needed**

  Nextcloud        Google Drive /     Medium           Full Ansible role +
                   Dropbox                             test

  Matrix + Element Slack / Teams      Medium-High      Full Ansible role +
                                                       test

  Vaultwarden      1Password /        Low              Full Ansible role +
                   Bitwarden                           test

  Stalwart Mail    Gmail / ProtonMail High             Full Ansible role +
                                                       DNS docs

  Forgejo          GitHub (private)   Low              Full Ansible role +
                                                       test

  Immich           Google Photos      Medium           Full Ansible role +
                                                       test
  ---------------- ------------------ ---------------- ----------------------

**Tier 2: Extended services --- community catalogue**

These are valuable but less universally needed. They serve as the seed
for the blueprint marketplace --- each one a standalone certified role.

-   Jitsi Meet --- self-hosted video calls

-   Gitea Actions --- CI/CD for Forgejo

-   Paperless-ngx --- document management

-   Mealie --- recipe and meal planning

-   Actual Budget --- personal finance

-   Uptime Kuma --- self-hosted monitoring

-   n8n --- workflow automation

**Service dependency resolution**

Some services depend on others (e.g. Element depends on Matrix, mail
services may depend on shared SMTP config). This must be handled
automatically.

-   Define service dependencies in role metadata

-   Deployment order must respect dependencies

-   Removing a service must warn if other services depend on it

  --------------------- ------------- -------------- -------------------------
  **Component**         **Current     **Priority**   **What\'s Needed**
                        State**                      

  Standard service      Does not      Critical       Define and document the
  interface             exist                        interface

  Tier 1 core services  None fully    Critical       6 services with full
                        implemented                  Ansible roles

  Auto Caddy config     Manual        High           Generate from service
                                                     inventory

  Service dependencies  Not handled   Medium         Dependency metadata in
                                                     roles

  Tier 2 extended       None          Medium         5-10 community-seed roles
  services                                           
  --------------------- ------------- -------------- -------------------------

**4. Backup**

**4.1 Current State**

No backup implementation exists. This is the highest-risk gap in the
current blueprint --- everything else can be rebuilt, but data loss is
permanent. Backup must be treated as a first-class feature, not an
afterthought.

+-----------------------------------------------------------------------+
| **Non-negotiable requirement**                                        |
|                                                                       |
| No service should be deployed without backup configured and tested.   |
| The blueprint must refuse to deploy Tier 1 services without a working |
| backup target. Backup is not optional.                                |
+-----------------------------------------------------------------------+

**4.2 Architecture**

**Backup tool: Restic**

Restic is the correct choice: open source, encrypted by default,
supports multiple backends, fast, well-maintained. All backups must be
encrypted before leaving the host.

-   Restic for all backup operations --- consistent tooling across all
    services

-   Encryption key generated at deploy time, stored locally, documented
    clearly

-   Backup key must be included in the user\'s keys handover
    documentation

**What gets backed up**

-   All service data directories --- defined by each service role

-   Headscale state --- critical for mesh rebuild

-   Caddy certificates and config

-   Ansible inventory and group_vars --- the config that built this
    setup

-   Backup encryption key (encrypted with user passphrase, stored
    separately)

**Backup targets**

Support at least two different backup destinations from day one. The
best practice recommendation must be two targets on different providers.

-   Hetzner Object Storage (S3-compatible) --- cheapest, co-located
    option

-   Backblaze B2 --- different provider, good for disaster recovery

-   Local backup node --- optional third target for on-premises setups

-   Restic supports all three natively --- no custom code required

**Schedule and retention**

-   Hourly snapshots of critical services (Vaultwarden, mail)

-   Daily snapshots of all services

-   Weekly full backup with 4-week retention minimum

-   Monthly backup with 12-month retention minimum

-   Retention policy configured in Ansible, enforced automatically

**Restore testing --- mandatory**

A backup that has never been tested is not a backup. The runbook must
include a mandatory restore drill.

-   restore-test command: spins up a test environment, restores latest
    backup, verifies service health

-   Document expected restore time for each service

-   Include restore drill as part of initial setup checklist --- must be
    done within 24h of deployment

-   Quarterly restore drill recommended --- document this in the runbook

**Backup monitoring**

-   Last successful backup timestamp visible in dashboard

-   Alert (email or Matrix message) if backup has not run in 24 hours

-   Backup size history --- detect unexpected growth or shrinkage

  --------------------- ------------ -------------- -------------------------
  **Component**         **Current    **Priority**   **What\'s Needed**
                        State**                     

  Backup implementation Does not     Critical       Restic + Ansible
                        exist                       automation

  Multi-target support  Does not     Critical       Hetzner + Backblaze from
                        exist                       day 1

  Restore testing       Does not     Critical       restore-test command +
                        exist                       runbook drill

  Encryption            Does not     Critical       Restic native encryption,
                        exist                       key in handover doc

  Schedule + retention  Does not     High           Ansible-managed cron +
                        exist                       retention policy

  Backup monitoring     Does not     Medium         Dashboard + alert on
                        exist                       failure
  --------------------- ------------ -------------- -------------------------

**5. Documentation and Runbook**

**5.1 Scope**

The runbook is not supplementary documentation --- it is a core
deliverable. A blueprint without a runbook is a blueprint that only
works for its author. The runbook must be written for a
technically-aware non-DevOps reader: someone comfortable with a terminal
and following instructions, but not an Ansible or Terraform expert.

**5.2 Required Sections**

1.  Prerequisites --- what you need before starting (domain, API keys,
    SSH key, approximate cost)

2.  Architecture overview --- what gets deployed and why (1-page
    diagram + explanation)

3.  First deploy --- step by step with expected output at each step

4.  Keys handover --- complete list of credentials generated and where
    they are stored

5.  Adding a service --- how to add a new service to an existing
    deployment

6.  Replacing a node --- what to do when a VM fails

7.  Restore from backup --- step by step restore drill

8.  Security baseline --- what the firewall rules are, how to verify
    them

9.  Troubleshooting --- the 10 most common failure modes and how to
    resolve them

10. Cost reference --- expected monthly cost per provider per setup size

**5.3 Runbook Quality Standard**

Before the blueprint is considered ready for community release, the
runbook must pass this test: hand it to someone who has not seen the
blueprint before and ask them to deploy it. If they need to ask more
than two questions not answered in the runbook, the runbook is not done.

**6. Implementation Priority**

Not everything can be done at once. This is the recommended sequence
based on what blocks what.

  ----------- --------------- ---------------------------------- ---------------
  **Phase**   **Timeline**    **Deliverable**                    **Unblocks**

  1           Weeks 1-2       Secrets management + close public  Safe to share
                              SSH + Headscale ACLs               publicly

  2           Weeks 3-4       Hetzner Terraform module + shared  Second
                              output interface                   provider, wider
                                                                 testing

  3           Weeks 5-6       Restic backup with Hetzner +       Data safety for
                              Backblaze targets                  real users

  4           Weeks 7-9       Tier 1 services: Nextcloud,        Core value
                              Vaultwarden, Matrix                proposition

  5           Weeks 10-11     Caddy auto-config from service     Replace,
                              inventory + lifecycle ops          add-service,
                                                                 destroy

  6           Week 12         Runbook + restore drill            Community
                              documentation                      release
  ----------- --------------- ---------------------------------- ---------------

+-----------------------------------------------------------------------+
| **Public release timing**                                             |
|                                                                       |
| Publish the roadmap update after Phase 1 is complete. You will have a |
| working, public GitHub repo with real security hardening and clear    |
| verification evidence. Do not wait for Phase 6 to publish progress.   |
+-----------------------------------------------------------------------+

*End of Document*
