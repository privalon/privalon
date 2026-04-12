# Research: Multi-Network Parallel Access for End Users

**Date:** March 2026 (v2 — revised)
**Status:** Research / pre-decision document
**Scope:** Allow end users to maintain simultaneous connections to multiple independent deployments (e.g., family + organization) without switching networks

---

## 1. Problem Statement

A user deploys the blueprint twice — once for their family (`family` environment) and once for their company (`org` environment). Today, each environment produces an independent Headscale instance with its own tailnet. The user's laptop or phone can only be joined to **one tailnet at a time** via `tailscale up --login-server <URL>`. Switching requires a full `tailscale up --reset --login-server <OTHER_URL>`, which:

- Tears down the current WireGuard tunnel
- Re-authenticates to the new Headscale
- Drops all active connections to the previous tailnet
- Requires re-establishing all sessions (SSH, open browser tabs to internal services)

Tailscale has "fast user switching" (since v1.60.0, all platforms) — but this is still **one tailnet at a time**. Tailscale's own docs confirm: *"A device is not able to transmit packets on multiple tailnets simultaneously."* Switching is faster, but it still disconnects from the previous tailnet.

This is the **single biggest UX obstacle** for anyone with more than one deployment.

---

## 2. The Mobile VPN Slot Constraint (Fundamental)

Before evaluating any solution, understand the platform-level constraint that shapes everything:

**iOS and Android allow exactly ONE active VPN tunnel at a time.** This is an OS-enforced restriction (the "VPN slot"). Consequences:

| Approach | Desktop (Linux/macOS/Windows) | Mobile (iOS/Android) |
|----------|------------------------------|---------------------|
| Multiple WireGuard tunnels | Possible (multiple TUN interfaces) | **Impossible** — one VPN slot |
| Multiple Tailscale daemons | Linux: yes. macOS/Win: marginal | **Impossible** |
| Multiple Netmaker networks | Yes (each gets a WG interface) | **No** — mobile uses WG configs → one VPN slot |
| Multiple Nebula instances | Possible but complex | **Impossible** — one VPN slot |
| ZeroTier multiple networks | Yes | **Yes** — multiplexes networks inside a single VPN slot |
| Single hub (one connection, ACL isolation) | N/A (architecturally different) | **Yes** — one tunnel, multiple orgs via policy |

**This constraint eliminates all "multiple parallel WireGuard tunnel" approaches for mobile.** Only two architectures survive:

1. **Multiplexed overlay** — One VPN slot, multiple virtual networks inside it (ZeroTier)
2. **Single mesh with policy isolation** — One VPN slot, one mesh, ACLs separate orgs (Hub Headscale)

---

## 3. Current Architecture Constraints

| Layer | How it works today | Why it limits parallelism |
|-------|-------------------|--------------------------|
| **Headscale** | One instance per environment, fully independent tailnets | Architecturally fine — isolation is correct |
| **Tailscale client** | One login server at a time; fast-switch exists but not parallel | Confirmed by Tailscale: no simultaneous multi-tailnet |
| **IP space** | All tailnets use `100.64.0.0/10` (CGNAT range) | Routing conflicts if two tailnets assign overlapping IPs |
| **WireGuard** | One `tailscale0` interface per daemon | Multiple interfaces possible on Linux/desktop; mobile: one VPN slot |
| **ACL/Identity** | Per-Headscale user namespace | No cross-tailnet federation |
| **Exit Node** | Gateway VM advertises as exit node; user enables on client | Works well — all traffic routes through gateway → internet |

---

## 4. Solution Analysis

### 4A. ZeroTier — True Multi-Network on All Platforms

**Architecture:** ZeroTier is a peer-to-peer virtual network layer. Unlike WireGuard-based solutions, it uses its own userspace networking stack. A single ZeroTier daemon manages multiple virtual networks simultaneously — even on mobile. On iOS/Android, it creates one VPN tunnel and multiplexes all joined networks through it.

**Multi-network model:** First-class. A device can join 5, 10, or more networks at once. Each network has its own IP space, rules, and membership.

**Self-hosted controller:** Every ZeroTier node includes a network controller. You can self-host entirely — no dependency on ZeroTier Inc's cloud. Controller API is REST-based, manages networks and members via JSON. A self-hosted controller can host up to 2^24 networks.

**Clients (verified):**

| Platform | App | Multi-network | Quality |
|----------|-----|--------------|---------|
| Linux | `zerotier-one` | Yes — simultaneous | Mature, stable |
| macOS | ZeroTier app | Yes — simultaneous | Mature, App Store |
| Windows | ZeroTier app | Yes — simultaneous | Mature, installer |
| iOS | ZeroTier One | Yes — simultaneous, inside single VPN slot | App Store, mature |
| Android | ZeroTier One | Yes — simultaneous, inside single VPN slot | Play Store, mature |

**Exit node / VPN routing:** Possible via managed routes (`0.0.0.0/0` through a gateway node). Requires manual route configuration and NAT setup on the gateway. Not as polished as Tailscale's `--advertise-exit-node` / `--exit-node` UX, but functionally equivalent.

**Admin UI options:**
- ZeroTier Central (SaaS) — polished dashboard, but cloud-hosted by ZeroTier Inc
- `ztncui` — community self-hosted web UI
- `zero-ui` — another community-maintained option
- None are as polished as Headplane, but functional

**DNS:** Built-in DNS for network members. Hostname resolution within networks. Less polished than Tailscale's MagicDNS but functional.

**ACL / Rules:** ZeroTier has a "Rules Engine" — a packet-level filtering language. More powerful than Headscale's ACLs for fine-grained traffic control, but more complex to write and maintain.

**NAT traversal:** Peer-to-peer with relay through ZeroTier root servers (or self-hosted "moons"). Similar concept to Tailscale's DERP relays.

**Performance:** Userspace networking — slightly slower than kernel WireGuard for high-throughput workloads. Negligible for typical use (web services, SSH, VPN browsing).

**License:** **BSL 1.1** (Business Source License). Key implications:
- Source code is openly available
- Self-hosting for your own infrastructure use: **allowed**
- Offering ZeroTier as a competing managed network service: **requires commercial license**
- Code converts to Apache 2.0 after the BSL change date (4 years from release)
- For the blueprint use case (users deploying for themselves): **clean**
- For a SaaS wrapper around ZeroTier networking: **needs legal review**

**Cloud-agnostic:** Fully. Works on any infrastructure with internet access. No dependency on ThreeFold or any specific provider.

**Verdict:** ZeroTier is the **only solution that provides true simultaneous multi-network on all platforms including iOS/Android**. The tradeoff: BSL license introduces commercial complexity, the admin UI ecosystem is less polished than Headplane, and exit-node VPN is less turnkey than Tailscale's.

---

### 4B. Headscale/Tailscale — Hub Model (ACL-Based Org Isolation)

**How it works:** Instead of deploying a separate Headscale per environment, deploy **one shared Headscale** that serves multiple organizations. Each org has isolated ACLs, separate IP subnets, and separate admin users. Users join once; ACLs enforce that family devices can't reach org servers and vice versa.

**Multi-network model:** Not native multi-network — it's one mesh with policy-based isolation. From the user's perspective: one connection = access to all orgs.

**Exit node / VPN routing:** **Excellent.** Tailscale's exit-node feature is the most polished in the industry. One command to advertise, one toggle to enable on the client. All traffic routes through the gateway → internet. Works on all platforms including mobile.

**Clients:**

| Platform | App | Quality | Exit-node UX |
|----------|-----|---------|-------------|
| Linux | `tailscale` CLI + `tailscaled` | Excellent | CLI toggle |
| macOS | Tailscale (Mac App Store) | Excellent, native | Menu bar toggle |
| Windows | Tailscale (Windows app) | Excellent | Tray toggle |
| iOS | Tailscale (App Store) | Very polished | In-app toggle |
| Android | Tailscale (Play Store) | Very polished | In-app toggle |

**Admin UI:** Headplane — already integrated in the blueprint. Single pane of glass for all orgs.

**DNS:** MagicDNS — automatic private hostname resolution. Devices get `<hostname>.<base_domain>` names. Very polished.

**ACL model for multi-org:**
```hujson
{
  "groups": {
    "group:family-admins": ["user:alice@hub.example.com"],
    "group:org-admins": ["user:bob@hub.example.com"],
    "group:alice-member": ["user:alice@hub.example.com"],
    "group:bob-member": ["user:bob@hub.example.com"]
  },
  "tagOwners": {
    "tag:family-servers": ["group:family-admins"],
    "tag:org-servers": ["group:org-admins"]
  },
  "acls": [
    // Family members → family servers only
    {"action": "accept", "src": ["group:family-admins"], "dst": ["tag:family-servers:*"]},
    // Org members → org servers only
    {"action": "accept", "src": ["group:org-admins"], "dst": ["tag:org-servers:*"]},
    // Family servers can talk to each other
    {"action": "accept", "src": ["tag:family-servers"], "dst": ["tag:family-servers:*"]},
    // Org servers can talk to each other
    {"action": "accept", "src": ["tag:org-servers"], "dst": ["tag:org-servers:*"]}
  ]
}
```

**Performance:** Kernel WireGuard — fastest possible encrypted tunnel performance.

**License:** Headscale: BSD. Tailscale client: BSD. Fully open. No commercial restrictions.

**Cloud-agnostic:** Yes. Works on any infrastructure.

**Risks:**
- Shared control plane = shared trust boundary. An ACL misconfiguration could leak between orgs.
- Single point of failure across all orgs. Hub Headscale going down blocks new connections to everything. (Existing connections continue — WireGuard tunnels are resilient.)
- Blueprint must generate ACLs from structured config; hand-editing a multi-org ACL file is error-prone.

**Verdict:** Solves multi-network problem for the personal/SMB target user via a single-connection architecture. Best exit-node VPN, best mobile clients, cleanest license, already partially integrated. The isolation is policy-based, not cryptographic — acceptable for same-owner orgs, not suitable for untrusted multi-tenant scenarios.

---

### 4C. Netmaker — Multi-Network by Design, Mobile Limitation

**Architecture:** WireGuard-based overlay with first-class multi-network management. A single Netmaker server manages multiple named networks. The `netclient` agent joins multiple networks simultaneously, each getting its own WireGuard interface.

**Multi-network on desktop:** Yes. The `netclient` runs on Linux, macOS, Windows. A device can be in "family-net" and "org-net" simultaneously.

**Multi-network on mobile:** **No.** Mobile devices connect via Remote Access Gateway — the gateway generates **WireGuard config files** that run in the standard WireGuard app. The WireGuard app on iOS/Android uses the system VPN slot → **one network at a time on mobile.** This is the same fundamental limitation as Tailscale.

**Exit node / VPN routing:** "Internet Gateways" feature — **but this is a Pro (paid) feature**, not in the open-source community edition. Egress routing (to specific IP ranges) is in open-source.

**Admin UI:** Built-in web dashboard. Manages networks, nodes, ACLs, DNS, enrollment keys. More mature admin experience than Headplane for multi-network scenarios.

**DNS:** CoreDNS integration. Automatic `<device-name>.<network-name>` resolution.

**License:** Apache-2.0 for the core. Anything under `pro/` has a separate commercial license. Internet Gateways, FailOver servers, advanced ACLs, metrics, tag management — all Pro features.

**Cloud-agnostic:** Yes.

**Verdict:** Great multi-network model on desktop. **Does not solve mobile multi-network** because mobile uses WireGuard configs (one VPN slot). The Pro license captures several features critical to the blueprint's needs (exit node VPN, metrics). On balance, Netmaker is **not a clear upgrade** over the Hub Headscale approach for the target use case.

---

### 4D. Nebula — Certificate-Based, No Multi-Network

**Multi-network:** Not first-class. Same limitation as Tailscale — one mesh per instance. Mobile: one VPN slot.

**Advantage:** MIT license, lightweight PKI, no coordination server needed (lighthouses are simple).

**Exit-node VPN:** Can be configured but requires manual iptables/NAT setup. No built-in UX.

**Mobile:** iOS and Android apps exist (via Defined Networking). Single-network only.

**Verdict:** Does not solve multi-network better than Headscale/Tailscale. No advantage for this use case. Skip.

---

### 4E. Mycelium (ThreeFold)

**Multi-network:** Supports private networks via `network name + PSK`. Multiple instances possible. IPv6-only (`400::/7`), avoids IPv4 conflicts.

**Mobile:** No mature mobile app. Linux and some platforms only.

**Admin UI:** None.

**ACLs:** Primitive.

**Exit-node VPN:** Not a feature.

**Unique value:** `--no-tun` message bus mode. Interesting for machine-to-machine communication (AI agent layer), not for user-facing networking.

**ThreeFold tie-in:** Strong alignment but tying the networking layer to ThreeFold limits cloud-agnosticism. The blueprint must work on Hetzner, DigitalOcean, AWS, etc.

**Verdict:** Not suitable as primary networking layer. Potential complementary channel for AI agent communication in the future. Do not tie the blueprint's networking to Mycelium.

---

### 4F. OpenZiti — Zero-Trust Service Mesh

**Architecture:** Not an IP overlay. Each service is individually published and authorized. Devices connect to specific services, not "networks." Architecturally eliminates the concept of network switching entirely.

**Multi-org access:** Natural — user accesses family services and org services simultaneously because they're registered as separate policies, not separate networks.

**Mobile:** Desktop and mobile tunneler apps exist. Steeper integration curve.

**Exit-node VPN:** Not the primary use case — OpenZiti is about service access, not IP routing.

**License:** Apache-2.0, clean.

**Verdict:** Architecturally elegant but a fundamentally different paradigm. Would require rethinking the entire blueprint around service-centric access rather than network-centric access. Too large a shift for the current project stage, but worth revisiting if the product evolves toward a managed-services platform.

---

## 5. Strategic Comparison Matrix

Evaluated from the perspective of "your own digital world" — a cloud-agnostic, multi-service sovereign deployment platform.

| Criterion | ZeroTier | Hub Headscale | Netmaker | Nebula | Mycelium |
|-----------|----------|---------------|----------|--------|----------|
| **Multi-network on desktop** | Native, simultaneous | One mesh, ACL isolation | Native, simultaneous | No | Limited |
| **Multi-network on mobile** | **Yes** (multiplexed VPN slot) | **Yes** (single connection) | **No** (WG config, one VPN slot) | No | No app |
| **Exit node / full-tunnel VPN** | Manual setup, functional | **Best in class** (one toggle) | Pro only (paid) | Manual | No |
| **Mobile client quality** | Good (mature apps) | **Excellent** (Tailscale apps) | Weak (WG configs) | Good | None |
| **Admin UI** | Community options (OK) | Headplane (good) | Built-in dashboard (good) | None | None |
| **DNS** | Built-in (OK) | MagicDNS (excellent) | CoreDNS (good) | Manual | None |
| **ACLs / isolation** | Rules engine (powerful, complex) | Groups + tags (simple, robust) | Networks + ACLs (good) | Groups (simple) | PSK (basic) |
| **Performance** | Userspace (good) | **Kernel WireGuard** (best) | Kernel WireGuard (best) | Userspace (good) | Userspace |
| **License** | **BSL 1.1** (complex) | **BSD** (cleanest) | Apache + Pro (mixed) | MIT (clean) | Apache (clean) |
| **Self-hosted** | Yes (embedded controller) | Yes (Headscale) | Yes | Yes | Yes |
| **Cloud-agnostic** | Yes | Yes | Yes | Yes | ThreeFold-aligned |
| **Existing blueprint integration** | None (full rewrite) | Partial (extend existing) | None (full rewrite) | None (full rewrite) | None |
| **Ecosystem maturity** | Very mature (10+ years) | Mature (3+ years) | Mature but shifting | Mature | Early |

---

## 6. Recommended Strategy

### Primary Recommendation: Headscale/Tailscale with Hub Architecture

**Why this wins for the "your own digital world" vision:**

1. **Best mobile UX bar none.** Tailscale's iOS/Android apps are the most polished VPN clients available. Users connect in one tap. This matters enormously for non-technical family members.

2. **Exit-node VPN is a first-class feature.** One checkbox to route all traffic through the gateway. Works on all platforms. No manual NAT/iptables setup. This is essential for "stay protected on public Wi-Fi."

3. **Cleanest license.** BSD (Headscale) + BSD (Tailscale client). No BSL concerns, no Pro feature paywalls. Full freedom to commercialize.

4. **Already integrated.** The blueprint already has Headscale, Tailscale, ACLs, DERP relay, Headplane, firewall rules, exit-node NAT. Extending to Hub mode is evolutionary, not revolutionary.

5. **Hub model solves multi-org for the target user.** The target is a person or small business with 2–5 deployments. Policy-based isolation within a shared mesh is excellent for this. Cryptographic network isolation (ZeroTier/Netmaker) is overkill when the same person controls all orgs.

6. **Kernel WireGuard performance.** The fastest encrypted tunnel available.

**What the Hub model looks like:**

```
                    ┌─────────────────────┐
                    │   Hub Headscale     │
                    │   Cloud-agnostic    │
                    │                     │
                    │  Org: family        │
                    │   prefix: 100.64.1/24
                    │   ACL: family-isolated
                    │   exit: family-gw   │
                    │                     │
                    │  Org: company       │
                    │   prefix: 100.64.2/24
                    │   ACL: company-isolated
                    │   exit: company-gw  │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────────────┐ ┌────────────┐  ┌──────────────┐
     │ Family GW      │ │ Family     │  │ Company GW   │
     │ exit-node      │ │ Services   │  │ exit-node    │
     │ Nextcloud      │ │ Grafana    │  │ Matrix       │
     │ Immich         │ │            │  │ Forgejo      │
     └────────────────┘ └────────────┘  └──────────────┘
              │                                  │
              └──────────┬───────────────────────┘
                         │
                  ┌──────────────┐
                  │ User Phone   │  ← one Tailscale connection
                  │   + Laptop   │  ← all orgs, all services
                  │   + Tablet   │  ← exit-node per org
                  └──────────────┘
```

---

### Alternative Worth Evaluating: ZeroTier (if multi-tenant isolation becomes critical)

**When to reconsider ZeroTier:**
- If the product evolves toward hosting **different customers'** infrastructure (not just same-owner orgs) and cryptographic network isolation is required
- If the BSL license terms are acceptable after legal review
- If the community admin UI ecosystem matures (or the project builds its own)

**ZeroTier's unique advantage** is that it's the only solution where a mobile device can truly be on multiple isolated networks simultaneously — not just policy-isolated within a shared mesh, but actual separate network membership. If brand-new Tailscale-like client quality apps existed for ZeroTier, it would be the clear winner. Today, Tailscale's client polish and exit-node UX are significantly better.

**ZeroTier migration cost** (if it becomes the right call later): Ansible roles for headscale/tailscale/gateway would need to be rewritten. Terraform unchanged. Firewall rules adapted. Test scripts rewritten. Documentation rewritten. The project is early enough that this is feasible — it's work, but not prohibitive.

---

### Do Not Pursue

| Option | Why not |
|--------|---------|
| **Netmaker** | Mobile multi-network doesn't work (WG configs, one VPN slot). Exit node is Pro-only. Mixed license. No clear advantage over Hub Headscale. |
| **Nebula** | Same single-mesh limitation as Tailscale. Trades coordination server for PKI management with no multi-network gain. |
| **Mycelium as primary layer** | No mobile apps, no admin UI, no DNS, no exit-node VPN. Ties the blueprint to ThreeFold. Only viable as a complementary back-channel for AI agents. |
| **OpenZiti** | Right architecture for the wrong project stage. Revisit if the product evolves to a service-mesh paradigm. |

---

## 7. Implementation Phases

### Phase 1: IP Prefix Parameterization (NOW — enables all future phases)

Even without the Hub model, parameterize IP prefixes per environment. This is needed for both the Hub model and the multi-instance desktop workaround.

**Changes:**
- Add `headscale_ip_prefix` variable to Headscale defaults (`100.64.0.0/24` default)
- Add configurable `headscale_ip_prefix` per environment in `group_vars/all.yml`
- Document that distinct prefixes are required for multi-environment users

---

### Phase 2: Exit Node Enhancement (NOW — high user value)

Ensure exit-node VPN is fully documented and tested as a core feature.

**Changes:**
- Verify gateway role already configures `tailscale_advertise_exit_node: true`
- Document end-user instructions for enabling exit node on every platform
- Test full-tunnel VPN flow: user enables exit node → all traffic routes through gateway → internet
- Add verification test to `scripts/tests/`

---

### Phase 3: Hub Headscale Architecture (MID-TERM)

**Changes:**
- New `hub` environment type with multi-org configuration
- ACL template generates per-org isolation rules from structured org definition
- Pre-auth key generation per org (separate tags/users per org)
- IP prefix partitioning per org
- Deploy script: `./scripts/deploy.sh full --env hub` provisions the hub control plane
- Org workload VMs join the hub Headscale instead of their own
- Documentation: multi-org setup guide

---

### Phase 4: Custom Client Exploration (LONG-TERM)

If the platform grows to hundreds of deployments, evaluate building a thin branded client app that wraps Tailscale/WireGuard with a multi-org-aware UX.

**What this would look like:**
- Mobile app (iOS/Android) that knows about the user's hub Headscale
- Shows services organized by org (family / company / ...)
- One-tap exit-node switching between org gateways
- Status view: which orgs are connected, service health
- Built on top of the existing Tailscale protocol — not a new networking stack

This is an expensive undertaking. Only pursue when the user base justifies a dedicated client.

---

### Phase 5: ZeroTier Evaluation Gate (FUTURE — decision trigger)

Evaluate switching to ZeroTier if ANY of the following become true:
- Multiple customers/tenants on shared infrastructure (need cryptographic isolation)
- BSL license converts to Apache 2.0 for the relevant ZeroTier version
- ZeroTier admin UI ecosystem reaches Headplane-level quality
- A major Headscale limitation blocks product development

---

## 8. Exit Node / Full-Tunnel VPN — Feature Comparison

This is critical for "stay protected on public Wi-Fi" and must work on all platforms.

| Feature | Headscale/Tailscale | ZeroTier | Netmaker |
|---------|-------------------|----------|----------|
| Advertise exit node (server side) | `tailscale up --advertise-exit-node` | Managed route `0.0.0.0/0 via <gw>` | Internet Gateway (Pro only) |
| Enable exit node (client side) | `tailscale up --exit-node=<host>` / GUI toggle | Manual route configuration on client | Automatic (Pro only) |
| iOS/Android toggle | In-app, one tap | Not native, requires config | Not available (OSS) |
| DNS while tunneled | MagicDNS works seamlessly | Manual DNS config needed | CoreDNS (Pro) |
| Split vs full tunnel | Both supported | Both supported | Both supported (Pro) |
| NAT/masquerade config | Blueprint already handles this | Must configure manually | Automatic (Pro) |

**Tailscale's exit-node UX is the benchmark.** It's the primary reason to stay with the Tailscale ecosystem for user-facing connectivity.

---

## 9. Cloud-Agnostic Architecture Notes

The blueprint must work on any cloud provider, not just ThreeFold. Multi-network considerations per provider:

| Provider | Public IPs | Hub Headscale placement | Notes |
|----------|-----------|------------------------|-------|
| ThreeFold | Dynamic (change on recreate) | Works, needs DNS update after IP change | Current primary, Mycelium available as underlying transport |
| Hetzner | Static (floating IPs available) | Ideal — stable IP = stable DNS = simple | Planned second provider |
| DigitalOcean | Static (floating IPs) | Good — similar to Hetzner | Planned third provider |
| AWS | Elastic IPs available | Works, needs security group config | Future |
| Any VM provider | Varies | Works if 443/TCP and 41641/UDP are reachable | Universal |

The Hub Headscale model is provider-agnostic. The hub itself can run on any provider. Org workload VMs can be on different providers — they connect to the hub over the internet, just like user devices.

The Mycelium networking layer that ThreeFold VMs have available is **not used as a security boundary** in the blueprint and should remain optional/supplementary. The blueprint's networking trust must depend only on Headscale/WireGuard, which works identically on all providers.

---

## 10. Decision Summary

| Approach | Platform coverage | Mobile multi-org | Exit-node VPN | License | Recommended? |
|----------|------------------|-----------------|---------------|---------|-------------|
| **Hub Headscale + Tailscale** | All platforms | Yes (ACL isolation) | Best in class | BSD (cleanest) | **Yes — primary** |
| **ZeroTier** | All platforms | Yes (native networks) | Manual setup | BSL 1.1 (complex) | **Evaluate later** |
| Desktop multi-instance hack | Linux only | No | N/A | N/A | Document as workaround |
| Netmaker | Desktop only (mobile: no) | No on mobile | Pro only | Mixed | No |
| Nebula | All platforms | No | Manual | MIT | No |
| Mycelium | Linux primarily | No | No | Apache | No (for primary layer) |
| OpenZiti | All platforms | Service-level | No | Apache | Not now |

---

## 11. Bridge Node Architecture — Cross-Perimeter Access Without Network Switching

### The Idea

Instead of the user connecting to multiple tailnets, deploy a **bridge node** — a server-side VM that is simultaneously a member of two (or more) independent tailnets. The user connects only to their "home" perimeter (e.g., personal/family). From there, the bridge node provides access to services in other perimeters (e.g., company) via reverse proxy, subnet routing, or SOCKS/HTTP proxy.

The user never switches networks. The bridge does the multi-network work server-side, where multiple `tailscaled` instances can run (Linux — no VPN slot constraint).

### How It Works Technically

```
                         ┌──────────────────────────────────────────┐
                         │           Bridge Node (Linux VM)         │
                         │                                          │
                         │  tailscaled-1                            │
                         │    → joined to Family Headscale          │
                         │    → tailscale0 (100.64.1.x)            │
                         │    → advertises-routes=100.64.2.0/24    │
                         │    → also: exit-node for VPN             │
                         │                                          │
                         │  tailscaled-2                            │
                         │    → joined to Company Headscale         │
                         │    → tailscale-company (100.64.2.x)     │
                         │    → receives company tailnet access     │
                         │                                          │
                         │  IP forwarding + iptables NAT            │
                         │    → forwards 100.64.2.0/24 traffic     │
                         │      from tailscale0 → tailscale-company │
                         └────────────┬─────────────┬───────────────┘
                                      │             │
                   Family Tailnet     │             │   Company Tailnet
                   (100.64.1.0/24)    │             │   (100.64.2.0/24)
                         ┌────────────┘             └────────────┐
                         │                                       │
              ┌──────────────────┐                    ┌──────────────────┐
              │  Family Gateway  │                    │ Company Gateway  │
              │  Family Services │                    │ Company Services │
              │  Nextcloud, etc  │                    │ Matrix, Forgejo  │
              └──────────────────┘                    └──────────────────┘
                         │
              ┌──────────────────┐
              │  User's Phone    │  ← connected ONLY to Family Tailnet
              │  + Laptop        │  ← reaches company services via
              │  + iPad          │     bridge's advertised routes
              └──────────────────┘
```

**Data flow for user accessing Company Grafana:**
1. User on phone, connected to Family Tailnet
2. Phone sends packet to `100.64.2.5:3000` (Company monitoring VM)
3. Family Tailnet routes it to bridge node (because bridge advertises `100.64.2.0/24`)
4. Bridge node receives on `tailscale0`, forwards to `tailscale-company` interface
5. Company Tailnet delivers to `100.64.2.5` (Company monitoring VM)
6. Response comes back the same way

**Data flow for VPN (exit-node, internet protection):**
1. User enables exit-node on Family Gateway (or bridge node itself)
2. All internet traffic routes through Family Gateway → internet
3. Unrelated to bridge — exit-node works as normal Tailscale feature
4. User is simultaneously VPN-protected AND has access to Company services

### Implementation Options

#### Option A: Subnet Router (IP-Level Bridge)

The bridge VM runs two `tailscaled` instances. The first (Family) advertises the Company tailnet's subnet (`100.64.2.0/24`) as a subnet route. IP forwarding + NAT handles the actual forwarding between interfaces.

**Pros:**
- All IP-level services work (SSH, HTTP, any protocol, any port)
- Transparent to the user — just access Company IPs directly
- Uses Tailscale's native subnet router feature (well-tested)

**Cons:**
- Requires distinct IP prefixes between tailnets (already planned — `headscale_ip_prefix`)
- User needs to know Company IP addresses (mitigated by DNS below)
- ACLs on both tailnets must permit the bridge node to forward traffic

**Technical requirements on the bridge VM:**
```bash
# Two tailscaled instances
tailscaled --state=/var/lib/tailscale-family \
           --socket=/var/run/tailscale-family.sock \
           --tun=tailscale0

tailscaled --state=/var/lib/tailscale-company \
           --socket=/var/run/tailscale-company.sock \
           --tun=tailscale-company

# Join each to its Headscale
tailscale --socket=/var/run/tailscale-family.sock up \
  --login-server=https://family-hs.example.com \
  --advertise-routes=100.64.2.0/24 \
  --accept-routes \
  --snat-subnet-routes=false

tailscale --socket=/var/run/tailscale-company.sock up \
  --login-server=https://company-hs.example.com \
  --accept-routes

# IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# NAT between interfaces
iptables -t nat -A POSTROUTING -o tailscale-company -j MASQUERADE
iptables -A FORWARD -i tailscale0 -o tailscale-company -j ACCEPT
iptables -A FORWARD -i tailscale-company -o tailscale0 \
         -m state --state RELATED,ESTABLISHED -j ACCEPT
```

#### Option B: Application-Level Reverse Proxy (Caddy/Nginx)

The bridge VM runs a Caddy instance on the Family Tailnet. It reverse proxies specific Company services by hostname to their Company Tailnet IPs.

```
# Caddy on bridge VM, listening on Family Tailnet IP
company-grafana.family.ts.example.com {
  reverse_proxy http://100.64.2.5:3000
}

company-matrix.family.ts.example.com {
  reverse_proxy http://100.64.2.5:8448
}
```

**Pros:**
- Hostname-based access — user types `company-grafana.family.ts.example.com`
- Can add auth middleware (require Tailscale identity check before proxying)
- Fine-grained — expose only specific services, not the entire Company subnet
- TLS termination / re-encryption possible

**Cons:**
- Only works for HTTP(S) services. SSH and other TCP protocols need separate handling.
- Each new Company service requires a proxy config entry
- Additional latency (extra hop + TLS overhead)

#### Option C: SOCKS5/HTTP Proxy

The bridge VM runs a SOCKS5 proxy (e.g., `dante`, `microsocks`) or HTTP proxy (e.g., `tinyproxy`) bound to its Family Tailnet IP. The user configures their browser or system proxy to use it.

```bash
# microsocks on bridge, listening on Family IP
microsocks -i 100.64.1.10 -p 1080
```

User sets SOCKS5 proxy to `100.64.1.10:1080` → all traffic through that proxy reaches the Company Tailnet.

**Pros:**
- Works for any TCP traffic (HTTP, SSH over SOCKS, etc.)
- User selects proxy per-application or per-browser-profile
- No DNS tricks needed — proxy resolves on the Company side

**Cons:**
- Requires user to configure proxy settings (less transparent than subnet routing)
- SOCKS5 doesn't work for all apps (some mobile apps don't support proxy)
- No native integration with Tailscale's ACL or identity model

#### Recommended: Option A (Subnet Router) as Primary + Option B (Reverse Proxy) for UX Polish

Use subnet routing for full connectivity (any protocol, any port). Layer reverse proxy on top for ergonomic hostname-based access to key services. This gives both power users (direct IP access) and casual users (bookmarkable URLs) what they need.

### DNS Integration — Dynamic Split DNS ("Mini Private Internet")

The goal: when you connect to your Family tailnet, you can resolve Company services by their **real domain names** (e.g., `grafana.companyexample.com`) — and when Company adds a new service, it's automatically available. No manual service lists, no aliased hostnames.

This is achieved with **split DNS forwarding** — a chain of three components:

#### Architecture

```
Phone (Family Tailscale client)
  │
  │ Headscale split DNS config:
  │   "companyexample.com → 100.64.1.3"  (bridge node Family IP)
  │
  ▼
Bridge Node DNS Forwarder (CoreDNS on 100.64.1.3:53)
  │
  │ Forward zone:
  │   "companyexample.com → 100.64.2.1"  (Company DNS, via Company tunnel)
  │
  ▼
Company DNS (100.64.2.1 — Company Headscale MagicDNS or internal DNS)
  │
  │ Resolves: grafana.companyexample.com → 100.64.2.5
  │
  ▼
Answer flows back → Phone connects to 100.64.2.5
  → Tailscale routes via bridge subnet route (100.64.2.0/24)
  → Arrives at Company Grafana
```

#### The Three Pieces

**1. Headscale split DNS (native feature)**

Headscale supports `dns.nameservers.split`, which tells Tailscale clients: "resolve `*.companyexample.com` using this specific nameserver." This is pushed to all clients automatically — no per-device config.

```yaml
# Family Headscale config (auto-generated by Ansible from perimeter_links)
dns:
  nameservers:
    global:
      - 1.1.1.1
    split:
      companyexample.com:
        - 100.64.1.3    # bridge node's Family tailnet IP
      acme-client.net:
        - 100.64.1.3    # same bridge, different zone
```

**2. Bridge DNS forwarder (CoreDNS or dnsmasq)**

A lightweight DNS forwarder on the bridge VM, listening on its Family tailnet IP. It forwards each linked perimeter's zone through the corresponding Company tailscale tunnel.

```
# CoreDNS Corefile (auto-generated by Ansible)
companyexample.com {
    forward . 100.64.2.1    # Company DNS, reachable via tailscale-company interface
    log
}

acme-client.net {
    forward . 100.64.3.1    # Acme Client DNS, via tailscale-acme interface
    log
}

. {
    forward . 1.1.1.1 9.9.9.9
}
```

**3. Company DNS (already exists)**

The Company deployment already has DNS — either Headscale MagicDNS (resolves `*.ts.companyexample.com`) or a real internal DNS server. The bridge forwarder simply queries it through the tunnel. Nothing to change on the Company side.

#### Why This Is Fully Dynamic

- Company deploys `new-app.companyexample.com` → adds it to their DNS
- Your bridge forwarder doesn't know or care — it forwards ALL `companyexample.com` queries
- You type `new-app.companyexample.com` on your phone → resolves → routed through bridge → works
- **Zero config changes on the Family side. Zero redeployment. Instant.**

#### Optional: Caddy Reverse Proxy Layer

For specific web services where you want TLS termination, custom auth, or hostname-based routing, you can still add Caddy entries on the bridge. But this becomes **optional polish**, not a requirement. Split DNS + subnet routing gives you full connectivity to everything by default.

### Security Model

| Aspect | How it's handled |
|--------|-----------------|
| **Who controls the bridge?** | The user who owns both perimeters. This is not multi-tenant — it's one person connecting their own deployments. |
| **Company Tailnet credentials** | The bridge VM is a pre-authenticated node on the Company Tailnet (pre-auth key). It's treated like any other server in the Company deployment. |
| **ACL enforcement** | Company Tailnet ACLs still apply. The bridge VM is tagged (e.g., `tag:bridge`) and ACLs control what it can access. If the Company ACL says the bridge can only reach Grafana, that's enforced. |
| **Family user access** | Family Tailnet's subnet route ACL controls which Family users can access the Company subnet via the bridge. Not all Family members need Company access. |
| **Data sovereignty** | No data is stored on the bridge. It's a stateless forwarder. Company data stays in Company Tailnet; the bridge is a transparent pipe. |
| **Blast radius** | Bridge compromise gives access to whatever the Company Tailnet ACL allows for `tag:bridge`. Minimize with least-privilege ACL (only specific ports/services). |

### Exit Node / VPN Compatibility

**Do exit-node (VPN) and bridge coexist?** Yes, with careful routing:

- **Exit node:** Routes `0.0.0.0/0` (all internet traffic) through the gateway
- **Subnet route:** Routes `100.64.2.0/24` (Company subnet) through the bridge
- **Tailscale routing precedence:** More specific routes (subnet /24) take priority over less specific (exit-node /0)

So when the user enables the Family Gateway as exit-node:
- Internet traffic → Family Gateway → internet (VPN protection)
- Company service traffic (`100.64.2.x`) → Bridge → Company Tailnet (cross-perimeter)
- Family service traffic (`100.64.1.x`) → direct Family Tailnet (local)

All three coexist. The user gets VPN protection AND cross-perimeter access simultaneously. No conflicts.

### Productization: "Perimeter Links" Feature

This pattern can be packaged as a first-class blueprint feature called **"Perimeter Links"** — configurable cross-perimeter connections that the deployment tooling sets up automatically.

**User-facing configuration:**

```yaml
# environments/family/group_vars/all.yml
perimeter_links:
  - name: company
    headscale_url: "https://hs.companyexample.com"
    authkey: "{{ vault_company_bridge_authkey }}"
    remote_prefix: "100.64.2.0/24"
    dns_zone: "companyexample.com"          # forward this zone to remote DNS
    remote_dns: "100.64.2.1"               # Company's DNS server (or Headscale MagicDNS IP)
  - name: client-acme
    headscale_url: "https://hs.acme-client.net"
    authkey: "{{ vault_acme_bridge_authkey }}"
    remote_prefix: "100.64.3.0/24"
    dns_zone: "acme-client.net"
    remote_dns: "100.64.3.1"
```

No `exposed_services` list — DNS is fully dynamic. Every hostname under `companyexample.com` and `acme-client.net` resolves automatically.

**What the blueprint does with this:**
1. Deploys bridge functionality on the gateway VM (or a dedicated bridge VM)
2. Runs a second `tailscaled` instance per linked perimeter
3. Joins each remote Headscale with the provided authkey
4. Advertises subnet routes for each remote prefix on the home tailnet
5. Deploys CoreDNS forwarder with zone forwarding rules for each `dns_zone`
6. Configures Family Headscale's `dns.nameservers.split` to point each zone to the bridge
7. Sets up ACL rules to control which home-tailnet users can access which links

**Deploy command:** `./scripts/deploy.sh full --env family` — bridge setup is part of the normal deploy, driven by `perimeter_links` config.

**End-user experience after deployment:**
- Connect phone to Family Tailnet (one connection, as always)
- Enable exit-node on Family Gateway (VPN protection)
- Open browser → `https://grafana.companyexample.com` → Company Grafana loads (real domain!)
- `ssh admin@monitoring.companyexample.com` → lands on Company monitoring VM
- Company deploys a new service tomorrow → you can access it immediately by its real name
- All transparent. No network switching. No second app. No configuration on the phone.
- **Your own mini private internet — family + company + clients, all addressable by their real domains.**

### Comparison: Bridge Node vs Hub Headscale

| Aspect | Bridge Node | Hub Headscale |
|--------|-------------|---------------|
| **Number of Headscale instances** | One per perimeter (existing) | One shared hub (new) |
| **Perimeter isolation** | Full (separate tailnets, separate crypto) | ACL-based (shared mesh) |
| **Setup complexity** | Medium (bridge VM + 2 tailscaled per link) | Medium (ACL template + shared control plane) |
| **User-side change** | None (still one Tailscale connection) | None (still one Tailscale connection) |
| **Exit-node VPN** | Works (coexists with subnet routes) | Works |
| **Admin UI** | Each perimeter has its own Headplane | One Headplane for all orgs |
| **Failure blast radius** | Bridge node down → cross-perimeter access lost, home perimeter fine | Hub Headscale down → all orgs lose new-connection ability |
| **Cross-perimeter latency** | Extra hop through bridge | Direct peer-to-peer |
| **Trust model** | Strongest — each perimeter is independently sovereign | Shared trust — hub controls all |
| **Works between different owners** | Yes — just need an authkey from the remote | No — requires shared Headscale ownership |
| **Scales to many perimeters** | Each link adds one `tailscaled` process | Each org adds ACL rules, stays in one mesh |

### When to Use Which

**Use Bridge Node (Perimeter Links) when:**
- Connecting perimeters owned by **different people/organizations** (consultant ↔ client)
- Maximum isolation is required (separate trust boundaries)
- You want to add cross-access to **existing** independent deployments without restructuring
- A perimeter already exists and you don't want to rebuild it as a hub-member

**Use Hub Headscale when:**
- All perimeters are owned by **the same person** (personal + family + hobby)
- You're deploying from scratch and want the simplest UX
- You want one admin panel for everything
- ACL-based isolation is acceptable

**Both approaches can coexist.** A user might have a Hub Headscale for personal/family orgs AND a bridge link to a client's separate infrastructure. They are complementary, not exclusive.

### Implementation Effort

| Component | What to build | Effort |
|-----------|--------------|--------|
| **Ansible role: `bridge`** | Manages N `tailscaled` instances, joins remote headscales, IP forwarding, NAT rules | Medium |
| **CoreDNS forwarder** | Corefile template generated from `perimeter_links[].dns_zone`, systemd service | Low |
| **Headscale DNS config** | Auto-generate `dns.nameservers.split` entries from `perimeter_links` | Low |
| **ACL template** | `tag:bridge` permissions for subnet-route forwarding | Low |
| **Deploy script** | Parse `perimeter_links` config, orchestrate bridge setup | Low |
| **Caddy entries (optional)** | Reverse proxy for specific services needing TLS/auth (not required for base connectivity) | Low |
| **Test** | Verify cross-perimeter connectivity, DNS resolution, VPN coexistence, ACL isolation | Medium |
| **Documentation** | Config reference, security model, user guide | Medium |

Total: **Medium effort** — smaller than the Hub Headscale rearchitecture because it layers on top of existing independent deployments without changing them.

---

## 12. Next Steps

1. **Immediate:** Parameterize `headscale_ip_prefix` per environment. Document and test exit-node VPN flow on all platforms.
2. **Near-term prototype:** Build a proof-of-concept bridge node with two `tailscaled` instances and subnet routing between two test environments. Validate VPN + cross-perimeter coexistence.
3. **Product design:** Define `perimeter_links` configuration schema. Design the bridge Ansible role.
4. **Near-term (parallel):** Design Hub Headscale multi-org ACL template for same-owner scenarios.
5. **Validate both:** Test bridge and hub approaches with real deployments. Compare UX, latency, reliability.
6. **Ship:** Implement whichever (or both) validates well. Bridge is likely faster to ship since it layers on existing deployments.
7. **Defer:** ZeroTier evaluation until a concrete decision trigger is met. No networking layer replacement now.
8. **Never:** Do not tie primary networking to Mycelium or any ThreeFold-specific protocol. Keep cloud-agnostic.
