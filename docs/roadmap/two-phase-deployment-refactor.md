# Two-Phase Deployment Refactor

Status: **proposed (not yet implemented)**
Owner: blueprint maintainers
Audience: human engineers and AI coding agents tasked with the refactor.

This document is the authoritative implementation plan for splitting the
deployment flow into two strict phases:

- **Phase 1 — Network and network security.** Bring up Headscale, install
  Tailscale on every host, switch the operational transport to the tailnet,
  then harden public interfaces (close public SSH on every host, remove
  bootstrap allowlists). Phase 1 ends with a hard gate: every inventory host
  must be reachable from the Ansible controller over its live tailnet IP.
- **Phase 2 — Everything else.** Gateway/Caddy public services, observability,
  backup, workloads (Forgejo, Vaultwarden, future services). Phase 2 assumes a
  stable tailnet and uses tailnet IPs only.

The same two-phase flow is used for **destructive** redeploys and for
**converge** (in-place) redeploys. The only difference is the starting state
of the infrastructure; the playbooks, the inventory contract for phase 2, and
the controller behavior are identical.

> [!IMPORTANT]
> This is an **architectural change** under the rules in
> [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).
> Do not start implementing without an explicit go-ahead from the maintainer.
> Once approved, follow this document end-to-end. Do not invent additional
> transport heuristics, fallbacks, or "smart" recovery paths beyond what is
> described here. The whole point of the refactor is to **reduce** the input
> space, not to add to it.

---

## 1. Why this refactor

The current deployment flow interleaves provisioning, tailnet bring-up, and
public-interface hardening across a single Ansible run with `serial: 1` over
`all`. Reachability of any given host at any given moment is a function of:

- Terraform-derived public/private/Mycelium IPs.
- Live `tailscale status` on the controller.
- Persisted `tailscale-ips.json`.
- Heuristics in `ansible/inventory/tfgrid.py` (validated persisted IPs, jump
  candidates, reachability probes, `IGNORE_TAILSCALE_HOSTS`,
  `PREFER_TAILSCALE`, `JUMP_HOST` overrides).
- Per-play `set_fact` rewrites in [`ansible/playbooks/site.yml`](../../ansible/playbooks/site.yml).
- Order in which roles open or close ports on the gateway / control VM.

This produces a recurring family of failures where a transport that worked
during play N stops working during play N+1 because hardening on host A closed
the path that the controller was using to reach host B. Each fix expands the
input space and uncovers the next edge case (see CHANGELOG entries
1.13.49 → 1.14.1 for the trail).

The two-phase model collapses this to a single invariant:

> **At the boundary between phase 1 and phase 2, every inventory host is
> reachable from the controller over exactly one transport (tailnet) and over
> no other transport. Phase 2 may assume that and nothing else.**

Once that invariant holds, phase 2 inventory is "tailnet IP per host, fail if
missing", and the entire transport-selection complexity disappears.

---

## 2. Scope

### In scope
- Splitting [`ansible/playbooks/site.yml`](../../ansible/playbooks/site.yml)
  into `phase1.yml`, `phase1_gate.yml`, and `phase2.yml`.
- Moving the firewall hardening role invocation to the **end of phase 1**.
- Adding a controller-side phase-1 gate that hard-fails if any host is not
  reachable over its tailnet IP.
- Drastically simplifying [`ansible/inventory/tfgrid.py`](../../ansible/inventory/tfgrid.py)
  along a clear provider boundary (bootstrap inventory vs operational
  inventory).
- Rewriting [`scripts/deploy.sh`](../../scripts/deploy.sh) so that destructive
  and converge flows share the same phase 1 / phase 2 sequence.
- Updating tests, documentation, and CHANGELOG.

### Out of scope (do not touch in this refactor)
- The choice of Tailscale + Headscale as the tailnet implementation.
- The Restic + dual-backend backup model.
- Caddy + Let's Encrypt for the public Headscale endpoint.
- The set of services currently deployed (Forgejo, monitoring stack, etc.).
- TFGrid as the current provider implementation. Multi-provider readiness is a
  goal of the refactor (see §6) but **adding** a second provider is a separate
  follow-up.

---

## 3. Architectural invariants the refactor must enforce

These are the contracts the new code must guarantee. Reviewers should reject
any change that violates them.

### I1. Transport phases are strictly ordered
1. **Bootstrap transport** is whatever the provider plugin gives the controller
   to reach a freshly provisioned host so Tailscale can be installed. It is
   only used during phase 1 and only until that host is on the tailnet.
2. **Operational transport** is the tailnet. It is used by phase 1 starting
   from the moment a host has joined the tailnet, and by all of phase 2.

There is no "mixed" mode. The controller does not switch back to bootstrap
transport once it has switched to the tailnet for a given host.

### I2. Hardening is the terminal step of phase 1
Closing public SSH (and any other public-facing lockdown that affects
controller-to-host reachability) happens **only after** the controller has
been confirmed to reach that host over the tailnet. A host is never hardened
via a transport that the hardening would invalidate. This is the rule that
prevents the "we just locked ourselves out" class of bug.

Concretely: the firewall `hardening.yml` task list runs **after** the
controller-side proof of tailnet reachability (see I4) for that host.

### I3. Phase 2 has one transport per host
Phase 2 inventory returns, for each host, exactly one `ansible_host`: its
live tailnet IP. No `ProxyCommand`, no `tfgrid_proxy_*` vars, no
`IGNORE_TAILSCALE_HOSTS`, no `JUMP_HOST` env override, no persisted-IP
fallback. If the live tailnet IP is unknown for a host at phase-2 start,
phase 2 does not run.

### I4. Phase 1 ends with a hard gate
Phase 1 ends with a controller-local play (`phase1_gate.yml`) that, for every
inventory host:
- Resolves the host's live tailnet IPv4 from `tailscale status --json` on the
  controller.
- Runs an SSH probe (`ssh -o ConnectTimeout=5 root@<tailnet-ip> true`) over
  that IP.
- Asserts both succeed.

If any host fails, the gate fails the run with a clear, actionable error. No
fallback, no degraded mode. See §4.5 for the failure UX in converge.

### I5. The same playbooks run for destructive and converge
`phase1.yml`, `phase1_gate.yml`, and `phase2.yml` are identical between
flows. The deploy script differs only in whether it runs `terraform destroy`
before `terraform apply`. Differences in starting state are absorbed by role
idempotency and the inventory's bootstrap-transport selection, not by branches
inside the playbooks.

### I6. Provider neutrality
Anything provider-specific lives in the **provider plugin** (today:
[`ansible/inventory/tfgrid.py`](../../ansible/inventory/tfgrid.py) and the
`terraform/` module). The playbooks must not reference TFGrid-specific
concepts (private CIDR routing through gateway, Mycelium IPs, ThreeFold
console URLs). After phase 1, the playbooks must work unchanged on any
provider that delivers an SSH-reachable host with a public key trusted by the
controller.

---

## 4. The refactor in detail

### 4.1 Playbook structure

#### `ansible/playbooks/phase1.yml`
Goal: bring every host onto the tailnet, then harden public interfaces.

Plays, in order:

1. **Base OS configuration** (`hosts: all`, `serial: <safe-parallel>`)
   - The minimum required to install and run Tailscale: package cache update,
     base packages (`ca-certificates`, `curl`, `iproute2`, `iputils-ping`,
     `sudo`, `vim`, `ufw`, `iptables`, `cron`), `ops` user creation, SSH
     hardening of `sshd_config` (disable password / KbdInteractive auth).
   - **No firewall rule changes here** beyond installing `ufw`. The bootstrap
     firewall rules (open public 22, allow tailnet UDP, allow private CIDR if
     the provider exposes one) are applied by the provider's bootstrap step
     (terraform-time cloud-init or first-contact play), not by this play.
   - Pin Headscale FQDN in `/etc/hosts` (existing logic).
   - Validate `service_catalog` schema and entries (existing logic).
2. **Headscale control plane** (`hosts: control`)
   - Install Headscale, Caddy, and the **minimum** set of control-plane
     pieces required for hosts to join the tailnet. Concretely: Headscale
     server, Caddy with internal CA *or* Let's Encrypt depending on
     `headscale_tls_mode`, the noise-key persistence helpers, and the
     auth-key issuance flow.
   - **Headplane** is included here only to the extent that the *server* is
     needed for tailnet operations. The web UI portion may be deferred to
     phase 2; see §4.6.
   - Backup of the Caddy data dir (so a destructive redeploy can restore the
     LE cert and avoid ACME rate limits) stays here, unchanged.
3. **Tailscale install + join** (`hosts: all`, parallel where safe)
   - Install Tailscale, configure tailscaled, run `tailscale up` against the
     local Headscale, persist `tailscale-ips.json` atomically on the
     controller.
   - This play targets every host **including** `gateway-vm` and
     `control-vm`. The order between control and the rest is enforced by
     play ordering, not by `serial`.
   - Inside this play, after each host is up on the tailnet, the play
     **switches the controller's view of that host to the tailnet IP** (see
     §4.3 for how).
4. **Controller joins the tailnet** (controller-local task)
   - `scripts/deploy.sh` runs `tailscale up` on the controller against the
     deployment's Headscale, before phase-1 hardening runs. (Idempotent — if
     the controller is already joined and the noise key matches, no-op.)
5. **Firewall hardening** (`hosts: all`, parallel where safe)
   - Close public 22 except for `firewall_allow_public_ssh_from_cidrs`.
   - Restrict any other public-facing ports per existing hardening rules.
   - This play is the **terminal step** of phase 1. It runs over the tailnet,
     not over public SSH (per I1 + I2).

> [!IMPORTANT]
> Step ordering is the safety property of the entire model.
> **Tailscale is activated on every host and the controller, the controller's
> connection to every host is switched to tailnet, and only then does the
> firewall hardening play run.** Implementations that close public SSH while
> the controller is still using public SSH for any host violate I2 and must
> be rejected in review.

#### `ansible/playbooks/phase1_gate.yml`
Goal: prove the phase-1 invariant before phase 2 starts.

Single play, `hosts: localhost`, `connection: local`. For every inventory host
(including gateway and control):

1. Read live tailnet IPv4 from `tailscale status --json` on the controller.
2. Fail if the host has no live tailnet IPv4 or if its peer record reports
   `Online: false`.
3. SSH probe over the tailnet IP with a short timeout (`ConnectTimeout=5`,
   `BatchMode=yes`, no agent forwarding). Fail if the probe fails.

On failure, the gate emits:
- The host name(s) that failed.
- The reason (no IP / offline peer / SSH probe failed with stderr).
- The exact remediation command, which is **a scoped destructive redeploy**
  for the offending host(s) (see §4.5).

#### `ansible/playbooks/phase2.yml`
Goal: everything that is not strictly required for tailnet reachability.

Plays (existing roles, mostly unchanged, just relocated here):

- Gateway (Caddy public ingress, public-facing services).
- Observability (Prometheus, Loki/Alloy, Grafana, node_exporter).
- Backup deploy (per-service Restic configs, cron, drill scripts).
- Workloads (Forgejo today; Vaultwarden and others later).
- Headplane web UI, if not strictly required by phase 1.
- Recovery bundle refresh.

Phase 2 plays use `hosts: <group>` directly. They never reference
`tfgrid_proxy_*` vars, public IPs, or private CIDRs. Their inventory is
"tailnet IP, fail if missing" (see §4.3).

#### Tag strategy
The current single-playbook `--tags` model is replaced by separate playbook
files. Existing tags (`headscale`, `tailscale`, `firewall`, `backup`,
`gateway`, etc.) stay on individual roles for fine-grained re-runs (e.g.
`ansible-playbook phase1.yml --tags firewall` to re-apply hardening), but
**deploy.sh always runs the full phase playbooks in order**. Selective tag
runs are an operator escape hatch, not part of the normal flow.

### 4.2 Deploy script flow

[`scripts/deploy.sh`](../../scripts/deploy.sh) becomes:

```text
deploy.sh <scope> --env <name> [--yes | --no-destroy] [other flags]
  load env
  terraform init
  if destructive (--yes accepted on the destroy prompt):
    pre-destroy backup hook (best-effort, bounded timeout — current behavior)
    terraform destroy
    terraform apply
  else (converge):
    terraform apply
  refresh inventory + DNS (existing)
  wait for bootstrap SSH on hosts that need it (provider plugin's job)

  ansible-playbook phase1.yml
  controller_join_tailnet                # idempotent
  ansible-playbook phase1_gate.yml       # hard fail on any host failure
  ansible-playbook phase2.yml

  recovery bundle refresh
  deployment summary
```

Notes:
- `controller_join_tailnet` runs **after** phase 1 has installed Tailscale on
  control-vm and Headscale is healthy. It must run **before** `phase1_gate.yml`
  (the gate uses the controller's `tailscale status` to validate hosts).
- Hardening of `control-vm` happens inside `phase1.yml` step 5, **after** the
  controller has joined the tailnet and switched its transport to control's
  tailnet IP. This eliminates the current `auto_post_destroy_join_local` and
  controller-IP-allowlist dance in `scripts/deploy.sh`.
- Scope handling (`full` / `gateway` / `control`) is preserved as `--limit`
  passed to phase 1 / phase 2 invocations. The same two-phase ordering applies
  to scoped runs.

### 4.3 Inventory plugin: bootstrap vs operational mode

[`ansible/inventory/tfgrid.py`](../../ansible/inventory/tfgrid.py) is reworked
along a clean boundary:

- A new env var `BLUEPRINT_INVENTORY_MODE` selects mode:
  - `bootstrap` — used by `phase1.yml`. Returns whatever transport the
    provider needs to reach freshly provisioned hosts: public IPs for hosts
    that have one, ProxyJump through gateway for hosts that don't, etc. This
    is the **only** mode where provider-specific routing logic lives.
  - `operational` — used by `phase1_gate.yml` and `phase2.yml`. Returns
    `ansible_host = <live tailnet IPv4>` per host. If a host has no live
    tailnet IP, the host is **omitted** from inventory (so `phase2.yml` will
    fail fast with "host not in inventory" rather than silently route over a
    fallback). The phase-1 gate is responsible for catching this earlier with
    a better error message.
- `BLUEPRINT_INVENTORY_MODE` defaults to `bootstrap` for backward
  compatibility with operator-side `ansible-inventory` calls; `deploy.sh`
  always sets it explicitly per phase.
- Operational mode has **no** dependencies on `terraform-outputs.json`,
  `tailscale-ips.json` cache, `_validated_persisted_tailscale_ips`,
  `_load_local_tailscale_candidate_ips`, `IGNORE_TAILSCALE_HOSTS`,
  `JUMP_HOST`, or `PREFER_TAILSCALE`. It calls `tailscale status --json`
  once and emits inventory.
- Bootstrap mode keeps the current TFGrid-specific routing knowledge but is
  never used after phase 1.

This deletes the majority of the heuristic logic in `tfgrid.py`. The deletions
are intentional and required — leaving the heuristics behind for "safety"
defeats the invariant.

### 4.4 Switching the controller's per-host transport during phase 1

Phase 1 step 3 (`Tailscale install + join`) installs Tailscale on a host and
brings it onto the tailnet. From that point on, the controller should reach
that host over its tailnet IP, even though phase 1 is still running.

Implementation:
- After `tailscale up` succeeds on a host, the role:
  - Runs `tailscale ip -4` on the host to capture the tailnet IPv4.
  - Persists it to `tailscale-ips.json` on the controller (atomic write,
    existing helper).
  - **Does not** rewrite `ansible_host` mid-play. Mid-play transport rewrites
    have been a recurring source of bugs and are removed.
- The firewall hardening play (step 5) runs with a fresh
  `ansible-inventory` invocation: `BLUEPRINT_INVENTORY_MODE=operational`,
  which returns tailnet IPs only. This is achieved by splitting step 5 into
  its own `ansible-playbook` call from `deploy.sh`, between step 4
  (controller joins) and `phase1_gate.yml`.

So the actual `deploy.sh` sequence becomes:

```text
ansible-playbook phase1_bootstrap_and_join.yml   # steps 1–3, BOOTSTRAP mode
controller_join_tailnet                           # step 4
ansible-playbook phase1_harden.yml                # step 5, OPERATIONAL mode
ansible-playbook phase1_gate.yml                  # OPERATIONAL mode
ansible-playbook phase2.yml                       # OPERATIONAL mode
```

`phase1.yml` is a thin wrapper that imports `phase1_bootstrap_and_join.yml`
and `phase1_harden.yml` for operators who want to run "all of phase 1" by
hand — but `deploy.sh` calls the sub-playbooks individually so it can run the
controller-join in between under the correct inventory mode.

### 4.5 Converge failure UX

If `phase1_gate.yml` fails during a converge (`--no-destroy`) run, the gate
must:

1. Print the unreachable host(s) and the probe output.
2. Print the exact remediation command, e.g.:

   ```
   [phase1-gate] forgejo-vm is not reachable over tailscale (peer Online=false).
   [phase1-gate] Converge cannot proceed without a healthy tailnet for every host.
   [phase1-gate] To recover this single node from backup, run:
   [phase1-gate]   scripts/deploy.sh forgejo --env <name> --yes
   [phase1-gate] (Scoped destructive redeploy of forgejo-vm only; control-plane and
   [phase1-gate]  other workloads are untouched. Latest backup will be restored.)
   ```

3. Exit non-zero. Phase 2 does not run.

There is **no** `--allow-degraded` flag and **no** automatic fallback to
public SSH. The whole point of the gate is that converge runs on a partially
broken tailnet are not safe to proceed — making them succeed silently is what
got us here.

The scoped-destructive scope (`scripts/deploy.sh forgejo --env <name> --yes`)
must already exist or be added; the per-workload-VM destructive flow is an
orthogonal but small addition that this refactor depends on.

### 4.6 What lives in phase 1 vs phase 2 (tight rule)

> [!IMPORTANT]
> **A component belongs in phase 1 if and only if it is required for the
> controller to reach every inventory host over the tailnet.** If you can
> remove it and the tailnet still works for all hosts, it belongs in phase 2.

Phase 1 (required for tailnet reachability):
- Base OS packages needed by Tailscale and SSH.
- Headscale server (control plane).
- Caddy serving Headscale (TLS termination required by `tailscale up` against
  public Headscale URL).
- Tailscale daemon + `tailscale up` on every host.
- Controller joining the tailnet.
- Firewall rules that allow tailnet traffic in and shut public SSH down.

Phase 2 (everything else):
- Headplane web UI (the *server* is not required for `tailscale up`;
  Headscale gRPC is what nodes talk to).
- Gateway Caddy public-services config (forgejo.example.com etc.).
- Prometheus, Grafana, Loki, Alloy log shipping.
- node_exporter on workload VMs (it's measured, not measuring).
- Backup configs, cron jobs, drills.
- Workload services (Forgejo, Vaultwarden, …).
- Recovery bundle refresh.
- Deployment summary.

When in doubt: phase 2.

---

## 5. Test plan

### 5.1 Tests to add
- `scripts/tests/test_phase1_gate.py`: unit-test the gate's parsing of
  `tailscale status --json` and its decision logic. Cover: missing host,
  offline peer, SSH probe failure, all-online happy path.
- `scripts/tests/test_inventory_modes.py`: assert that
  `BLUEPRINT_INVENTORY_MODE=operational` returns tailnet-IP-only inventory
  with no `tfgrid_proxy_*` vars, and **omits** hosts without a live tailnet
  IP. Assert that `bootstrap` mode preserves current behavior.
- `scripts/tests/test_deploy_phase_order.py`: static-grep
  [`scripts/deploy.sh`](../../scripts/deploy.sh) to assert the literal call
  order: phase1_bootstrap_and_join → controller_join_tailnet →
  phase1_harden → phase1_gate → phase2. Regression guard for I2.
- `scripts/tests/static-phase-boundary.sh`: static check that `phase2.yml`
  and any role it imports never reference `tfgrid_proxy_*`,
  `tf_public_ip`, `tf_private_ip`, `JUMP_HOST`, or
  `IGNORE_TAILSCALE_HOSTS`. Regression guard for I3 and I6.
- `scripts/tests/static-firewall-hardening-position.sh`: static check that
  `phase1_harden.yml` is referenced from `deploy.sh` strictly between
  `controller_join_tailnet` and `phase1_gate`. Regression guard for I2.

### 5.2 Tests to remove or migrate
- `scripts/tests/test_inventory_tailscale_transport.py`,
  `test_tailnet_refresh_serial.py`,
  `test_join_local_tailscale_map_preserved.py`,
  `test_tailscale_status_helper.py`: review each test. Behavior asserted by
  the test that **moves to bootstrap mode** stays. Behavior that depended on
  mid-run transport flips, persisted-IP fallbacks, or `IGNORE_TAILSCALE_HOSTS`
  is deleted along with the code it covers. Replace with the new tests above.
- `scripts/tests/17_verify_observability_guard_static.sh`: keep, but the
  underlying guard in the observability role can be relaxed — phase 2 always
  has a healthy tailnet by definition, so the soft-fail-on-missing-monitoring
  branch can be tightened to a hard fail.

### 5.3 End-to-end validation
The refactor is "done" when, on the `test` environment:
1. `scripts/deploy.sh full --env test --yes --fresh-tailnet` (destructive)
   completes with exit 0 and `scripts/tests/run.sh` passes.
2. `scripts/deploy.sh full --env test --no-destroy` (converge, immediately
   after #1) completes with exit 0 and `scripts/tests/run.sh` passes.
3. Repeating #2 a second time changes nothing meaningful (idempotency).
4. Manually breaking tailscale on a workload VM and re-running #2 produces
   the failure UX described in §4.5 and exits non-zero **without** running
   any phase-2 tasks.

All four must hold before the refactor is merged.

---

## 6. Provider-neutrality boundary

The refactor explicitly preserves and clarifies the provider boundary so a
second provider (e.g. Hetzner, AWS, bare-metal) can be added without
re-touching playbooks.

- **Provider plugin contract (per provider):**
  - Provision the requested set of VMs.
  - Deliver, in `terraform-outputs.json` and the bootstrap inventory:
    - A unique inventory hostname per VM.
    - Some way for the controller to SSH to each VM **at least once** with
      the deployment's root key. Whether that is "public IP", "ProxyJump
      through a bastion", "private network reachable from the controller", or
      "cloud-init pre-installs Tailscale and the VM is already on the
      tailnet" is up to the provider. The bootstrap inventory expresses the
      choice.
  - Optionally pre-install Tailscale via cloud-init for providers that
    support it; the Tailscale role must be idempotent against this.

- **What playbooks may assume after phase 1:**
  - Every host has a live tailnet IPv4.
  - The controller is on the tailnet.
  - Public SSH on every host is closed (or restricted to the operator
    allowlist).

- **What playbooks must not assume:**
  - That a flat private CIDR exists.
  - That `gateway-vm` has a public IPv4 (the gateway role itself depends on
    this; other roles must not).
  - That Mycelium IPs exist.
  - That hosts share a /16 / VPC / availability zone.

This is the abstraction we want long-term. The current TFGrid plugin will be
the first concrete implementation; the second provider added later will
prove the boundary holds.

---

## 7. Documentation updates required

When the refactor lands:

- [`docs/technical/ARCHITECTURE.md`](../technical/ARCHITECTURE.md): add the
  two-phase model and the I1–I6 invariants. This is the primary architecture
  doc and must be the source of truth.
- [`docs/technical/OPERATIONS.md`](../technical/OPERATIONS.md): update the
  deployment walkthrough to reflect phase 1 / phase 2. Add the converge
  failure UX (§4.5) and the scoped destructive recovery procedure.
- [`docs/user/DEPLOYMENT.md`](../user/DEPLOYMENT.md) and
  [`docs/user/TROUBLESHOOTING.md`](../user/TROUBLESHOOTING.md): user-facing
  description of "phase 1 = network, phase 2 = services" and the recovery
  command for converge failures.
- [`README.md`](../../README.md) and [`docs/README.md`](../README.md): update
  the one-paragraph description of the deploy flow.
- [`CHANGELOG.md`](../../CHANGELOG.md): a single major-version entry
  describing the refactor with a link back to this document.

---

## 8. Versioning and rollout

- Version bump: **major** (current `1.14.x` → `2.0.0`). The deploy flow,
  playbook structure, and inventory contract change in user-visible ways.
- No backward-compatibility shim for the old single-playbook flow. The
  transition is clean.
- Roll out only after all four end-to-end checks in §5.3 pass on `test`.
- Update [`environments/example/`](../../environments/example/) where needed
  (no functional change expected; document any new env vars).

---

## 9. Implementation order (suggested for the AI agent)

Follow this order. Do not jump ahead — each step's tests are required to pass
before the next.

1. Add the two new inventory modes to `tfgrid.py` (`bootstrap` and
   `operational`). Add `test_inventory_modes.py`. Existing behavior stays
   reachable via `BLUEPRINT_INVENTORY_MODE=bootstrap` (the new default during
   the transition).
2. Split `site.yml` into `phase1_bootstrap_and_join.yml`, `phase1_harden.yml`,
   `phase1_gate.yml`, and `phase2.yml`. Do **not** delete `site.yml` yet —
   keep it as a thin import wrapper for the duration of the transition so
   nothing else breaks.
3. Implement `phase1_gate.yml` and `test_phase1_gate.py`.
4. Update `scripts/deploy.sh` to call the new phase sequence (§4.2). Add
   `test_deploy_phase_order.py`.
5. Run end-to-end checks §5.3 #1 and #2. Fix issues. Do not "fix" by adding
   transport heuristics — fix by tightening role idempotency or phase
   ordering.
6. Delete the heuristic transport code from `tfgrid.py` (validated persisted
   IPs, candidate IPs, jump-host logic in operational mode, etc.). Remove
   `IGNORE_TAILSCALE_HOSTS`, `JUMP_HOST`, `PREFER_TAILSCALE` from
   `deploy.sh`. Migrate or delete the related tests per §5.2.
7. Run end-to-end checks §5.3 #1, #2, #3, #4. All four must pass.
8. Update documentation (§7).
9. Bump version, update CHANGELOG, commit, push.

---

## 10. Non-goals (explicit)

The following are **not** part of this refactor, even though they may seem
related. Do not bundle them in:

- Adding a second provider.
- Changing the backup model.
- Changing the service catalog or adding new services.
- Changing the UI (`ui/`) other than the minimum needed if it parses deploy
  output. **Exception:** the legacy deploy.sh flags removed in §11 are part
  of the UI surface today (the web UI passes them through). Those flag
  removals **must** be reflected in `ui/server.py`, `ui/lib/deploy_progress.py`
  and the UI tests as part of this refactor — that is not an "improvement",
  it is required to keep the UI consistent with the new CLI.
- "Improving" tasks that are not directly relevant to phase boundaries.

If, while implementing, you find a real bug unrelated to the refactor,
**file it** (CHANGELOG note + roadmap entry) rather than fixing it inline.
The point of the refactor is reduction; mixing in unrelated changes
re-introduces the noise we are trying to eliminate.

---

## 11. Cleanup of legacy artifacts (mandatory)

The refactor is **not done** until every artifact below is either deleted or
rewritten. Leaving any of these behind silently re-introduces the input space
the refactor exists to remove. Implementers must work this list literally and
tick each item; reviewers must reject the PR if anything in §11.7 still
matches.

This section is exhaustive on purpose. If you find another artifact tied to
the old transport heuristics that is not listed here, delete it and add it to
this list in the same change-set.

### 11.1 `scripts/deploy.sh` — flags, env vars, code blocks to remove

Remove all of the following from [`scripts/deploy.sh`](../../scripts/deploy.sh).
None survive the refactor; do not "deprecate" them, do not keep them as
no-ops, **delete the code paths**.

CLI flags to remove from the parser, usage text, and every call site:
- `--fresh-tailnet`
- `--join-local`
- `--rejoin-local`
- `--allow-ssh-from <cidr>`
- `--allow-ssh-from-my-ip`

Env vars to remove from the script and from anywhere it exports them to
Ansible:
- `IGNORE_TAILSCALE_HOSTS`
- `PREFER_TAILSCALE`
- `JUMP_HOST`
- `FRESH_TAILNET` (internal flag mirroring `--fresh-tailnet`)
- any `controller_ip_allowlist` shell variable

Functions / blocks to remove (search by name):
- `prefer_tailscale_for_ansible`
- `auto_post_destroy_join_local` and the surrounding logic that conditionally
  joins the controller, sets `IGNORE_TAILSCALE_HOSTS`, flips
  `PREFER_TAILSCALE`, or rewrites the inventory between sub-phases. The
  controller-join is now a single, unconditional, idempotent step in the
  phase order from §4.2.
- Any `case "${PREFER_TAILSCALE:-}" in …` switches.
- Any code that constructs `IGNORE_TAILSCALE_HOSTS` from "fresh VM" detection
  (e.g. `IGNORE_TAILSCALE_HOSTS="gateway,gateway-vm"`,
  `IGNORE_TAILSCALE_HOSTS="control,control-vm"`).
- The pre-flight "controller IP allowlist" injection that was needed because
  the controller was not yet on the tailnet when hardening ran.

Replacement: a single linear sequence as defined in §4.2. The script does
not branch on transport.

### 11.2 `ansible/playbooks/site.yml` — facts, rewrites, and waits to remove

[`ansible/playbooks/site.yml`](../../ansible/playbooks/site.yml) is split
per §4.1. During the transition it may stay as a thin import wrapper; it
**must be deleted** at the end of step 9.6 (see §11.8 termination criterion).
While splitting, the following constructs must not be carried into any of
the new playbooks:

Mid-play `ansible_host` rewrites — delete every occurrence:
- `set_fact: ansible_host: "{{ tfgrid_inventory_ansible_host | default(tfgrid_proxy_ansible_host) }}"`
- `set_fact: ansible_host: "{{ tailscale_refresh_ansible_host }}"` and the
  paired `ansible_ssh_common_args` / `ansible_ssh_transfer_method` rewrites.
- Any other `set_fact` that mutates `ansible_host`, `ansible_ssh_common_args`,
  `ansible_ssh_transfer_method`, `ansible_user`, or
  `ansible_ssh_extra_args` mid-run.

Variables that must be removed from playbooks, roles, and group_vars:
- `tfgrid_inventory_ansible_host`
- `tfgrid_proxy_ansible_host`
- `tfgrid_proxy_target_host`
- `tfgrid_proxy_*` (any)
- `tailscale_refresh_ansible_host`
- `tailscale_refresh_ansible_ssh_common_args`
- `tailscale_refresh_ansible_ssh_transfer_method`

Cross-host TFGrid leaks in playbooks — relocate or delete:
- `hostvars['control-vm']['tf_public_ip']` references in the `/etc/hosts`
  pinning task. The pinning logic moves into the headscale role, sourced
  from a tailnet-side fact (control-vm's tailnet IP after phase-1 step 3),
  not from a TFGrid output. The phase 2 playbooks must contain **zero**
  references to `tf_public_ip`, `tf_private_ip`, `tf_mycelium_ip`.

`wait_for_connection` retry blocks that exist solely to absorb transport
flapping — remove. With one transport per phase this is dead weight. The
specific blocks at site.yml lines ~9-17, ~190, ~405, ~418, and ~531
(comments mentioning "jump host was just reconfigured", "tailscale refresh",
"transport recovery") all go. Implicit fact-gathering is fine because the
inventory is stable.

`serial: 1` on top-level plays — replaced by per-phase parallelism. Phase 1
step 1, step 3, and step 5 should run in parallel across hosts (with the
provider plugin's bootstrap concurrency limits respected). Only the
control-plane play is implicitly serialized by host count = 1.

### 11.3 `ansible/inventory/tfgrid.py` — heuristics to delete

After §9 step 6, the operational mode is the only post-phase-1 inventory.
Delete from [`ansible/inventory/tfgrid.py`](../../ansible/inventory/tfgrid.py):

- `_validated_persisted_tailscale_ips` and any helpers that probe persisted
  IPs to decide whether to use them.
- `_load_local_tailscale_candidate_ips` and any "candidate IP" merge logic.
- `IGNORE_TAILSCALE_HOSTS`, `JUMP_HOST`, `PREFER_TAILSCALE` env-var parsing
  and every code path gated on them.
- Reachability probes (TCP/SSH probing of public IPs to choose a transport).
- Jump-host selection logic in **operational mode** (it stays only in
  bootstrap mode, and only if a provider needs it).
- `tfgrid_proxy_*` host variables emitted by the plugin (gone in operational
  mode; bootstrap mode may still emit them but only the bootstrap-and-join
  playbook consumes them).
- `tailscale-ips.json` consumption as a transport source. The file remains
  as a **write-only** record produced by phase-1 step 3 for diagnostics and
  for the recovery bundle; the inventory plugin must not read it back to
  decide reachability. Operational mode reads `tailscale status --json`
  directly.

After deletion, the operational-mode code path should fit comfortably in
under ~150 lines: load `terraform-outputs.json` for the host list and
groups, call `tailscale status --json`, emit `ansible_host = <tailnet IP>`
per host, omit hosts with no live tailnet IP.

### 11.4 Roles — bootstrap-firewall and identity-reset cleanup

In [`ansible/roles/firewall/`](../../ansible/roles/firewall/):
- Remove the "open bootstrap rules" tasks. Bootstrap firewall posture is now
  the responsibility of the provider plugin (cloud-init or terraform-time
  `remote-exec`). The role's responsibility shrinks to: **hardening only**.
  The role is invoked exactly once in the deploy flow, as the terminal step
  of phase 1.
- Remove any tasks/templates that reference
  `firewall_allow_public_ssh_from_cidrs` being populated dynamically from
  controller-IP detection. The variable stays as a static operator
  allowlist; the dynamic injection is gone with §11.1.

In [`ansible/roles/tailscale/`](../../ansible/roles/tailscale/):
- Remove any `--fresh-tailnet`-driven branches (e.g. `tailscale_force_logout`,
  `tailscale_reset_state`, `tailscale_persist_identity` toggles that exist
  only to support that flag). Identity reset is now expressed by destructive
  redeploy scope (§4.5), not a flag.
- Remove comments in
  [`ansible/roles/tailscale/defaults/main.yml`](../../ansible/roles/tailscale/defaults/main.yml)
  that reference `--fresh-tailnet`.

In [`ansible/roles/headscale/`](../../ansible/roles/headscale/):
- If the role consumes `tf_public_ip` to pin its own FQDN (or for any
  cross-host purpose), replace with tailnet-derived facts after phase 1.
  The role itself may still receive its own public IP as a role var for
  Caddy's `bind` directive (gateway and control-vm are the only roles
  allowed to know about public IPs after the refactor).

### 11.5 Tests — explicit migration / deletion list

In addition to §5.2, take the following actions. Each test is named so the
implementer cannot miss any.

**Delete** (covered functionality goes away):
- [`scripts/tests/test_inventory_tailscale_transport.py`](../../scripts/tests/test_inventory_tailscale_transport.py)
- [`scripts/tests/test_tailnet_refresh_serial.py`](../../scripts/tests/test_tailnet_refresh_serial.py)
- [`scripts/tests/test_join_local_tailscale_map_preserved.py`](../../scripts/tests/test_join_local_tailscale_map_preserved.py)
- [`scripts/tests/test_tailscale_status_helper.py`](../../scripts/tests/test_tailscale_status_helper.py) — only if its assertions are about
  transport selection. If it covers `tailscale status --json` parsing
  generically, migrate the parsing tests into `test_phase1_gate.py`.
- Any references to the deleted helper in `test_deploy_retry_patterns.py`.

**Rewrite** (still meaningful, but assertions change):
- [`scripts/tests/40_break_and_recover_headscale_container.sh`](../../scripts/tests/40_break_and_recover_headscale_container.sh):
  recovery now uses scoped destructive redeploy (§4.5). Update.
- [`scripts/tests/50_redeploy_broken_headscale_vm.sh`](../../scripts/tests/50_redeploy_broken_headscale_vm.sh):
  must not reference `--fresh-tailnet`. Recovery is `deploy.sh control --env
  <name> --yes`.
- [`scripts/tests/70_lockdown_public_ssh.sh`](../../scripts/tests/70_lockdown_public_ssh.sh):
  becomes a phase-1-end assertion (every host lockdown is verified after
  phase 1, before phase 2).
- [`scripts/tests/common.sh`](../../scripts/tests/common.sh): remove any
  helpers that set `IGNORE_TAILSCALE_HOSTS`, `PREFER_TAILSCALE`, or
  `JUMP_HOST`.

**Add** (per §5.1):
- `test_phase1_gate.py`
- `test_inventory_modes.py`
- `test_deploy_phase_order.py`
- `static-phase-boundary.sh`
- `static-firewall-hardening-position.sh`
- `static-no-legacy-tokens.sh` — see §11.7, this is the cleanup gate.

### 11.6 UI, helpers, hooks, env templates, defaults

Search and rewrite each of the following so they no longer reference removed
flags/vars:

- [`ui/server.py`](../../ui/server.py)
- [`ui/lib/deploy_progress.py`](../../ui/lib/deploy_progress.py)
- [`ui/tests/test_deploy_cli.py`](../../ui/tests/test_deploy_cli.py)
- [`ui/tests/test_deploy_recording.py`](../../ui/tests/test_deploy_recording.py)
- [`ui/tests/test_job_runner.py`](../../ui/tests/test_job_runner.py)
- [`scripts/helpers/deployment-summary.sh`](../../scripts/helpers/deployment-summary.sh)
- [`scripts/hooks/backup.sh`](../../scripts/hooks/backup.sh)
- [`environments/example/group_vars/all.yml`](../../environments/example/group_vars/all.yml)
- [`environments/example/secrets.env.example`](../../environments/example/secrets.env.example)
- [`environments/example/terraform.tfvars.example`](../../environments/example/terraform.tfvars.example)
- [`environments/test/group_vars/all.yml`](../../environments/test/group_vars/all.yml)
- `Makefile` (any targets that forward removed flags)

For env templates and group_vars, prefer **deletion** of legacy options over
"comment them out". Comments with the old flag names will rot.

### 11.7 Static cleanup gate (the only objective "done" criterion)

Add [`scripts/tests/static-no-legacy-tokens.sh`](../../scripts/tests/static-no-legacy-tokens.sh)
that runs `git grep -nE` for the literal token list below across the entire
working tree (excluding `CHANGELOG.md`, `docs/roadmap/`, and
`environments/*/.ui-logs/`) and exits non-zero on any match:

```
IGNORE_TAILSCALE_HOSTS
PREFER_TAILSCALE
JUMP_HOST
tfgrid_proxy_
tailscale_refresh_ansible_host
tailscale_refresh_ansible_ssh_common_args
auto_post_destroy_join_local
_validated_persisted_tailscale_ips
_load_local_tailscale_candidate_ips
prefer_tailscale_for_ansible
controller_ip_allowlist
--fresh-tailnet
--join-local
--rejoin-local
--allow-ssh-from
--allow-ssh-from-my-ip
FRESH_TAILNET
```

The CHANGELOG and roadmap directory are excluded because they describe
historical behavior. The `.ui-logs/` directory is excluded because it stores
literal historical command lines from past runs.

This script is part of `scripts/tests/run.sh`. The refactor is not mergeable
while it fails.

### 11.8 Termination of the transition wrapper

`ansible/playbooks/site.yml` may stay as a thin wrapper during steps 9.1–9.5
to keep external callers working. It must be **deleted** at step 9.6 (the
same step that deletes the transport heuristics). After that step:

- No file in the repo is named `site.yml`.
- `deploy.sh` invokes only `phase1_bootstrap_and_join.yml`,
  `phase1_harden.yml`, `phase1_gate.yml`, `phase2.yml`.
- Any documentation that referenced `site.yml` is updated (see §11.10).

### 11.9 Per-environment runtime artifacts

The following files in `environments/<name>/inventory/` are produced/consumed
by the deploy flow and need explicit handling:

- `terraform-outputs.json` — schema unchanged (still the source of host list
  and groups). Keep.
- `tailscale-ips.json` and `tailscale-ips.json.lock` — demoted to
  write-only diagnostics per §11.3. Keep produced, never read by inventory.
  Add a one-line header comment in the writer that says "diagnostics only,
  not consulted by inventory".
- `headscale-noise-key.sha256`, `headscale-authkeys.json`,
  `headplane-api-key.txt`, `headscale-root-ca.crt`,
  `service-catalog.json` — unchanged.
- Any other file in `environments/<name>/inventory/` that was created by
  removed code paths must be removed from the writer **and** from
  `.gitignore` (so future strays are caught).

Provide an explicit one-time migration note in `CHANGELOG.md`: existing
operators upgrading across the 2.0.0 boundary should delete
`environments/<name>/inventory/tailscale-ips.json*` to force regeneration
under the new write-only contract. No automated migration.

### 11.10 Documentation cleanup

In addition to the updates in §7, **delete** the following from existing
docs (do not edit in place — the old text is misleading):

- Any user-facing doc paragraph that explains `--fresh-tailnet`,
  `--join-local`, `--rejoin-local`, or operator workflows that depend on
  them. They are replaced by the single recovery command in §4.5.
- Any "transport selection" or "jump host" explanation in
  [`docs/technical/OPERATIONS.md`](../technical/OPERATIONS.md) — phase 2 has
  one transport, there is nothing to explain.
- Any troubleshooting entry in
  [`docs/user/TROUBLESHOOTING.md`](../user/TROUBLESHOOTING.md) that walks the
  operator through `IGNORE_TAILSCALE_HOSTS` / `PREFER_TAILSCALE` overrides.

In [`docs/roadmap/`](../roadmap/), mark superseded:
- Any entries (e.g. transport-related notes in `blueprint-improvement.md`,
  `perimeter-links.md`, `dns-and-visibility.md`) that describe the
  pre-refactor model. Add a one-line "Superseded by
  `two-phase-deployment-refactor.md` (2.0.0)." header at the top of each.

### 11.11 CHANGELOG hygiene

- Add a single 2.0.0 entry that links to this document and lists the
  removed flags / env vars / files (operators searching old release notes
  will land here).
- Annotate the trail of 1.13.49 → 1.14.1 entries with a footnote
  "Workarounds removed by 2.0.0 refactor; see
  `docs/roadmap/two-phase-deployment-refactor.md`." Do not rewrite history,
  just append the footnote.

### 11.12 Cleanup acceptance checklist (reviewer-facing)

The PR description must include a checked list:

- [ ] `scripts/tests/static-no-legacy-tokens.sh` passes locally.
- [ ] `scripts/tests/run.sh` passes on `test`.
- [ ] §5.3 end-to-end checks 1–4 all pass.
- [ ] `git ls-files | xargs grep -lE "<token list from §11.7>"` returns
      only `CHANGELOG.md`, `docs/roadmap/`, `environments/*/.ui-logs/`.
- [ ] `ansible/playbooks/site.yml` does not exist.
- [ ] Operational-mode `tfgrid.py` code path is < ~150 lines.
- [ ] UI flag plumbing matches the new CLI (no removed flags reachable from
      the web UI).
- [ ] Roadmap entries describing pre-refactor workarounds carry the
      "Superseded by 2.0.0" header.

If any box is unchecked, the refactor is not done.
