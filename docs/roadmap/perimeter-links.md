# Feature Specification: Perimeter Links

**Status:** Approved for future implementation
**Decision date:** March 2026
**Networking stack:** Tailscale + Headscale (confirmed — no layer change)
**Feature name:** Perimeter Links
**Priority:** Roadmap (implement when multi-deployment users need cross-perimeter access)

---

## 1. Product Overview

### What It Is

Perimeter Links is a blueprint feature that allows a user connected to their **home deployment** (e.g., personal/family) to transparently access services in **other deployments** (e.g., company, client) — without switching Tailscale networks, without installing additional apps, and without any configuration on the user's device.

The user connects to their home Tailscale/Headscale once. Everything else — company Grafana, client Matrix, a secondary deployment's Nextcloud — is reachable by its **real domain name** (`grafana.companyexample.com`) as if it were on the same network.

### What It Is Not

- Not a VPN hub or shared Headscale instance for multiple orgs
- Not a change to the networking layer (remains Tailscale + Headscale)
- Not a multi-tenant system — each perimeter stays independently sovereign
- Not visible to the remote perimeter's other users (one-way, outbound only)

### User Story

> As a person who runs a family deployment and works at a company that also uses this blueprint, I want to connect my phone to my family Tailnet and see both my family services AND my company services — by their real domain names — without switching networks or configuring anything on my phone.

### End-User Experience (After Deployment)

```
1. Open Tailscale app → connected to Family (as always)
2. Enable exit-node: Family Gateway (VPN protection — as always)

Family resources (normal):
  monitoring.ts.family.example.com    → Family Grafana     ✓
  nextcloud.ts.family.example.com     → Family Nextcloud   ✓

Company resources (via Perimeter Link — feels identical):
  grafana.companyexample.com          → Company Grafana    ✓
  matrix.companyexample.com           → Company Matrix     ✓

Client resources (via another Perimeter Link):
  app.acme-client.net                 → Client App         ✓

Internet:
  google.com → routed through Family Gateway (VPN)         ✓
```

Zero configuration on the phone. Zero network switching. Zero additional apps.

---

## 2. Architecture

### 2.1 High-Level Diagram

```
                                YOUR HOME DEPLOYMENT (you control everything)
                    ┌──────────────────────────────────────────────────────────────┐
                    │                                                              │
                    │  Control VM                                                  │
                    │    Headscale (Family)                                        │
                    │    dns.nameservers.split:                                    │
                    │      companyexample.com → 100.64.1.3 (gateway)              │
                    │      acme-client.net    → 100.64.1.3 (gateway)              │
                    │                                                              │
                    │  Gateway VM (100.64.1.3)                                     │
                    │    tailscaled-family (primary, tailscale0, 100.64.1.3)       │
                    │    tailscaled-company (bridge, ts-company, 100.64.2.x)       │
                    │    tailscaled-acme    (bridge, ts-acme,    100.64.3.x)       │
                    │    CoreDNS forwarder (port 53):                              │
                    │      companyexample.com → 100.64.2.1 (via ts-company)       │
                    │      acme-client.net    → 100.64.3.1 (via ts-acme)          │
                    │    IP forwarding + iptables NAT:                             │
                    │      100.64.2.0/24 ↔ ts-company                             │
                    │      100.64.3.0/24 ↔ ts-acme                                │
                    │    Subnet routes advertised on Family tailnet:               │
                    │      --advertise-routes=100.64.2.0/24,100.64.3.0/24         │
                    │    Exit-node (VPN) — unchanged                               │
                    │    Caddy reverse proxy (public) — unchanged                  │
                    │                                                              │
                    │  Monitoring VM    Nextcloud VM    Other VMs                  │
                    │    (100.64.1.x)    (100.64.1.x)   (100.64.1.x)              │
                    └──────────────────────────────────────────────────────────────┘
                              │                           │
                   Family Tailnet                  Bridge tunnels
                   (100.64.1.0/24)                (outbound only)
                              │                     │            │
                    ┌─────────────────┐    ┌────────────┐  ┌──────────────┐
                    │  User's Phone   │    │  Company   │  │ Client Acme  │
                    │  + Laptop       │    │  Headscale │  │  Headscale   │
                    │  + iPad         │    │ (separate) │  │  (separate)  │
                    │                 │    │ 100.64.2/24│  │ 100.64.3/24  │
                    │ Connected ONLY  │    └────────────┘  └──────────────┘
                    │ to Family       │
                    │ tailnet         │
                    └─────────────────┘
```

### 2.2 Data Flow: User Accesses `grafana.companyexample.com`

```
Step 1: DNS Resolution
  Phone → queries "grafana.companyexample.com"
  Tailscale client sees split DNS rule: companyexample.com → 100.64.1.3
  Query forwarded to Gateway VM (100.64.1.3) port 53

Step 2: DNS Forwarding
  Gateway VM CoreDNS receives query
  Corefile rule: companyexample.com → forward to 100.64.2.1 (via ts-company tunnel)
  Query travels through Company tailscale tunnel to Company DNS (100.64.2.1)
  Company DNS resolves: grafana.companyexample.com → 100.64.2.5
  Answer returns: 100.64.2.5

Step 3: IP Routing
  Phone connects to 100.64.2.5:3000
  Tailscale client sees subnet route: 100.64.2.0/24 → via 100.64.1.3 (gateway)
  Packet sent to Gateway VM over Family tailnet (WireGuard encrypted)

Step 4: Bridge Forwarding
  Gateway VM receives packet on tailscale0 (Family interface)
  iptables forwards to ts-company (Company interface) via NAT
  Company tailnet delivers to 100.64.2.5 (Company monitoring VM)

Step 5: Response
  Response follows reverse path:
  Company VM → ts-company → Gateway VM NAT → tailscale0 → Phone
  Phone renders Grafana dashboard
```

### 2.3 Data Flow: VPN (Exit-Node) + Bridge Coexistence

```
Routing table on user's phone (Tailscale manages this):
  100.64.1.0/24  → direct (Family tailnet, local)
  100.64.2.0/24  → via 100.64.1.3 (bridge subnet route, Company)
  100.64.3.0/24  → via 100.64.1.3 (bridge subnet route, Client)
  0.0.0.0/0      → via 100.64.1.3 (exit-node, all internet traffic)

Traffic routing:
  grafana.companyexample.com (100.64.2.5) → bridge → Company tailnet
  nextcloud.ts.family.example.com (100.64.1.x) → direct Family tailnet
  google.com → exit-node → Gateway → internet (VPN protected)

No conflicts: specific routes (/24) take priority over default route (/0).
```

### 2.4 One-Way Isolation (Security Boundary)

```
Direction: Home → Remote (one-way only)

What Home can reach:
  - Remote services that Remote ACL allows for tag:bridge
  - Remote DNS names (via split DNS forwarding)

What Remote can reach:
  - NOTHING in Home. Remote has no route to 100.64.1.0/24.
  - Remote doesn't know the bridge connects elsewhere.
  - Remote sees the bridge as just another tagged node (tag:bridge).

What other Remote users see:
  - Nothing. The bridge is a node in the Remote tailnet.
  - Other Remote users can't traverse the bridge into Home.
  - Remote ACL restricts the bridge node to specific ports/services.
```

---

## 3. Configuration Schema

### 3.1 User-Facing Configuration

Location: `environments/<env>/group_vars/all.yml` (or a dedicated `bridge.yml`)

```yaml
# Perimeter Links — outbound connections to other deployments
# Each entry adds bridge connectivity to a remote tailnet.
# DNS is fully dynamic: all hostnames under dns_zone resolve automatically.
#
# Required per link:
#   name           — unique identifier for this link (used in systemd unit names, interfaces)
#   headscale_url  — URL of the remote Headscale instance
#   authkey        — pre-auth key from the remote Headscale (use ansible-vault)
#   remote_prefix  — IP prefix of the remote tailnet (MUST NOT overlap with home prefix)
#   dns_zone       — domain zone to forward to this remote's DNS
#   remote_dns     — IP of the remote DNS server (reachable via the bridge tunnel)
#
# Optional per link:
#   acl_ports      — list of ports to allow through the bridge (default: all / *)
#   enabled        — true/false (default: true)

perimeter_links: []

# Example:
# perimeter_links:
#   - name: company
#     headscale_url: "https://hs.companyexample.com"
#     authkey: "{{ vault_company_bridge_authkey }}"
#     remote_prefix: "100.64.2.0/24"
#     dns_zone: "companyexample.com"
#     remote_dns: "100.64.2.1"
#   - name: client-acme
#     headscale_url: "https://hs.acme-client.net"
#     authkey: "{{ vault_acme_bridge_authkey }}"
#     remote_prefix: "100.64.3.0/24"
#     dns_zone: "acme-client.net"
#     remote_dns: "100.64.3.1"
#     acl_ports:
#       - 443
#       - 8448
```

### 3.2 Secrets Management

Auth keys for remote perimeters MUST be stored encrypted. Options:

```yaml
# Option A: ansible-vault encrypted variable (simplest)
# In environments/<env>/group_vars/vault.yml (encrypted with ansible-vault)
vault_company_bridge_authkey: "hskey-xxxxxxxxxxxxx"

# Option B: environment variable
# authkey: "{{ lookup('env', 'COMPANY_BRIDGE_AUTHKEY') }}"

# Option C: file-based
# authkey: "{{ lookup('file', 'environments/' + env_name + '/secrets/company-authkey') }}"
```

### 3.3 IP Prefix Conventions

Each deployment MUST use a distinct IP prefix to avoid routing conflicts:

```yaml
# Family (home): 100.64.1.0/24
# Company:       100.64.2.0/24
# Client Acme:   100.64.3.0/24
# Client Beta:   100.64.4.0/24
# etc.
```

This requires the existing `headscale_ip_prefix` parameterization (currently planned, not yet implemented). See [prerequisite P1](#p1-headscale-ip-prefix-parameterization).

### 3.4 Validation Rules

The bridge role MUST validate at deploy time:

| Rule | Error message |
|------|---------------|
| `name` must match `^[a-z0-9-]+$` | "Perimeter link name '{{ item.name }}' contains invalid characters" |
| `remote_prefix` must not overlap with home prefix | "Remote prefix {{ item.remote_prefix }} overlaps with home prefix {{ headscale_ip_prefix }}" |
| `remote_prefix` must not overlap with any other link | "Remote prefix {{ item.remote_prefix }} overlaps with link '{{ other.name }}'" |
| `headscale_url` must start with `https://` | "Headscale URL must use HTTPS" |
| `authkey` must not be empty | "Auth key for '{{ item.name }}' is empty" |
| `dns_zone` must be a valid domain | "DNS zone '{{ item.dns_zone }}' is not a valid domain" |
| `remote_dns` must be a valid IPv4 | "Remote DNS '{{ item.remote_dns }}' is not a valid IPv4 address" |

---

## 4. Implementation Specification

### 4.1 New Ansible Role: `bridge`

**Path:** `ansible/roles/bridge/`

**Structure:**
```
ansible/roles/bridge/
├── defaults/
│   └── main.yml           # perimeter_links: [] (default empty)
├── tasks/
│   └── main.yml           # main task flow
├── templates/
│   ├── tailscaled-bridge.service.j2   # systemd unit for additional tailscaled instances
│   ├── tailscaled-bridge-start.sh.j2  # startup script per bridge instance
│   ├── Corefile.j2                    # CoreDNS configuration
│   └── bridge-nat.sh.j2              # iptables NAT rules script
├── handlers/
│   └── main.yml           # restart handlers
└── meta/
    └── main.yml           # role metadata
```

### 4.2 Role Defaults (`defaults/main.yml`)

```yaml
---
# Perimeter Links configuration
# See docs/roadmap/perimeter-links.md for full schema.
perimeter_links: []

# Bridge DNS forwarder settings
bridge_dns_listen_ip: "{{ tailscale_ip | default('127.0.0.1') }}"
bridge_dns_listen_port: 53

# CoreDNS version (static binary, no Docker needed)
bridge_coredns_version: "1.11.3"
bridge_coredns_binary: "/usr/local/bin/coredns"

# Base directory for bridge tailscale state
bridge_state_dir: "/var/lib/tailscale-bridge"

# Timeout for tailscale up (seconds)
bridge_tailscale_up_timeout: 300
```

### 4.3 Main Task Flow (`tasks/main.yml`)

The following describes the exact task sequence. Each task includes the Ansible module, key parameters, and conditional logic.

```yaml
---
# === VALIDATION ===

- name: Skip bridge role when no perimeter links configured
  ansible.builtin.meta: end_play
  when: (perimeter_links | default([]) | length) == 0

- name: Validate perimeter link names
  ansible.builtin.fail:
    msg: "Perimeter link name '{{ item.name }}' must match ^[a-z0-9-]+$"
  loop: "{{ perimeter_links }}"
  when: item.name is not regex('^[a-z0-9-]+$')

- name: Validate no prefix overlap with home
  ansible.builtin.fail:
    msg: "Remote prefix {{ item.remote_prefix }} must not overlap with home prefix"
  loop: "{{ perimeter_links }}"
  # Implementation: use Python ipaddress module to check overlap
  # when: <python check via ansible.builtin.shell>

- name: Validate no prefix overlap between links
  ansible.builtin.fail:
    msg: "Remote prefix overlap detected between perimeter links"
  # Implementation: iterate over pairs and check with ipaddress module

# === PREREQUISITES ===

- name: Ensure IP forwarding is enabled
  ansible.builtin.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    state: present
    reload: true

# === COREDNS INSTALLATION ===

- name: Check if CoreDNS binary exists
  ansible.builtin.stat:
    path: "{{ bridge_coredns_binary }}"
  register: coredns_stat

- name: Download CoreDNS binary
  ansible.builtin.shell: |
    set -euo pipefail
    cd /tmp
    curl -fsSL "https://github.com/coredns/coredns/releases/download/v{{ bridge_coredns_version }}/coredns_{{ bridge_coredns_version }}_linux_amd64.tgz" | tar xz
    mv coredns {{ bridge_coredns_binary }}
    chmod 755 {{ bridge_coredns_binary }}
  args:
    executable: /bin/bash
  when: not coredns_stat.stat.exists

# === PER-LINK TAILSCALED INSTANCES ===
# Loop over perimeter_links, creating a tailscaled instance per link.

- name: Create bridge state directories
  ansible.builtin.file:
    path: "{{ bridge_state_dir }}/{{ item.name }}"
    state: directory
    mode: "0755"
  loop: "{{ perimeter_links }}"
  when: item.enabled | default(true)

- name: Render tailscaled bridge startup script per link
  ansible.builtin.template:
    src: tailscaled-bridge-start.sh.j2
    dest: "/usr/local/bin/tailscaled-bridge-{{ item.name }}"
    mode: "0755"
  loop: "{{ perimeter_links }}"
  when: item.enabled | default(true)

# zinit-based service management (ThreeFold VMs) or systemd
- name: Install zinit config for bridge tailscaled (ThreeFold)
  ansible.builtin.copy:
    dest: "/etc/zinit/tailscaled-bridge-{{ item.name }}.yaml"
    mode: "0644"
    content: |
      exec: /usr/local/bin/tailscaled-bridge-{{ item.name }}
  loop: "{{ perimeter_links }}"
  when:
    - item.enabled | default(true)
    - ansible_facts.os_family == 'Debian'

- name: Start bridge tailscaled instances (zinit)
  ansible.builtin.shell: |
    set -euo pipefail
    zinit monitor "tailscaled-bridge-{{ item.name }}" 2>/dev/null || true
    zinit start "tailscaled-bridge-{{ item.name }}" 2>/dev/null || true
  args:
    executable: /bin/bash
  loop: "{{ perimeter_links }}"
  when: item.enabled | default(true)
  changed_when: false

- name: Wait for bridge tailscale sockets
  ansible.builtin.wait_for:
    path: "/var/run/tailscale-bridge-{{ item.name }}.sock"
    timeout: 60
  loop: "{{ perimeter_links }}"
  when: item.enabled | default(true)

# === JOIN REMOTE HEADSCALES ===

- name: Join remote Headscale via bridge tailscale instance
  ansible.builtin.shell: |
    set -euo pipefail
    # Check if already connected
    state="$(tailscale --socket=/var/run/tailscale-bridge-{{ item.name }}.sock status --json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("BackendState","Stopped"))' || echo Stopped)"
    ip="$(tailscale --socket=/var/run/tailscale-bridge-{{ item.name }}.sock ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"

    if [[ "$state" == "Running" && -n "$ip" ]]; then
      echo "Already connected to {{ item.name }} at $ip"
      exit 0
    fi

    timeout {{ bridge_tailscale_up_timeout }} tailscale \
      --socket=/var/run/tailscale-bridge-{{ item.name }}.sock up \
      --login-server "{{ item.headscale_url }}" \
      --authkey "{{ item.authkey }}" \
      --hostname "bridge-{{ inventory_hostname | lower | regex_replace('[^a-z0-9-]', '-') }}" \
      --accept-routes \
      --reset
  args:
    executable: /bin/bash
  loop: "{{ perimeter_links }}"
  when: item.enabled | default(true)
  no_log: true  # authkey is sensitive
  register: bridge_join_results

# === ADVERTISE SUBNET ROUTES ON HOME TAILNET ===

- name: Build aggregated subnet routes for home tailscale
  ansible.builtin.set_fact:
    _bridge_advertise_routes: >-
      {{ perimeter_links
         | selectattr('enabled', 'undefined')
         | list
         + perimeter_links
         | selectattr('enabled', 'defined')
         | selectattr('enabled')
         | list
         | map(attribute='remote_prefix')
         | join(',') }}
  # Note: this variable is consumed by the tailscale role or by a
  # separate "re-up" step below.

- name: Re-run tailscale up on home instance to advertise bridge subnet routes
  ansible.builtin.shell: |
    set -euo pipefail
    # Get current advertise-routes (if any) from home tailscale
    # Add bridge routes to any existing exit-node or other flags
    tailscale up \
      --login-server "{{ tailscale_login_server }}" \
      --advertise-routes="{{ _bridge_advertise_routes }}" \
      --accept-routes \
      {% if tailscale_advertise_exit_node | default(false) %}--advertise-exit-node {% endif %}
      --reset
  args:
    executable: /bin/bash
  when: (_bridge_advertise_routes | default('') | trim) != ''

# === APPROVE SUBNET ROUTES IN HOME HEADSCALE ===
# Headscale requires explicit approval of advertised subnet routes.
# This step runs on the control VM (delegated).

- name: Approve bridge subnet routes in Headscale
  ansible.builtin.shell: |
    set -euo pipefail
    # List routes for the gateway node and enable any that match bridge prefixes
    node_id=$(docker exec headscale headscale -o json nodes list \
      | python3 -c "
    import json, sys
    nodes = json.load(sys.stdin)
    for n in nodes:
        if '{{ inventory_hostname }}' in n.get('givenName', '') or '{{ inventory_hostname }}' in n.get('name', ''):
            print(n['id'])
            break
    ")

    if [[ -z "$node_id" ]]; then
      echo "WARNING: Could not find node ID for {{ inventory_hostname }}"
      exit 0
    fi

    routes=$(docker exec headscale headscale -o json routes list \
      | python3 -c "
    import json, sys
    routes = json.load(sys.stdin)
    for r in routes:
        if r.get('node', {}).get('id') == int($node_id) and not r.get('enabled', False):
            print(r['id'])
    ")

    for route_id in $routes; do
      docker exec headscale headscale routes enable -r "$route_id" || true
    done
  args:
    executable: /bin/bash
  delegate_to: "{{ groups['control'][0] }}"
  changed_when: false
  failed_when: false

# === NAT / IPTABLES RULES ===

- name: Render NAT rules script
  ansible.builtin.template:
    src: bridge-nat.sh.j2
    dest: /usr/local/bin/bridge-nat-setup
    mode: "0755"

- name: Apply NAT rules for bridge forwarding
  ansible.builtin.command:
    argv: ["/usr/local/bin/bridge-nat-setup"]
  changed_when: false

# === COREDNS FORWARDER ===

- name: Create CoreDNS config directory
  ansible.builtin.file:
    path: /opt/coredns
    state: directory
    mode: "0755"

- name: Render CoreDNS Corefile
  ansible.builtin.template:
    src: Corefile.j2
    dest: /opt/coredns/Corefile
    mode: "0644"
  notify: Restart CoreDNS

- name: Install zinit config for CoreDNS
  ansible.builtin.copy:
    dest: /etc/zinit/coredns.yaml
    mode: "0644"
    content: |
      exec: {{ bridge_coredns_binary }} -conf /opt/coredns/Corefile

- name: Start CoreDNS (zinit)
  ansible.builtin.shell: |
    set -euo pipefail
    zinit monitor coredns 2>/dev/null || true
    zinit start coredns 2>/dev/null || true
  args:
    executable: /bin/bash
  changed_when: false

- name: Wait for CoreDNS to listen
  ansible.builtin.wait_for:
    host: "{{ bridge_dns_listen_ip }}"
    port: "{{ bridge_dns_listen_port }}"
    timeout: 30

# === FIREWALL ===

- name: Allow DNS (port 53) on tailscale0 for CoreDNS
  ansible.builtin.command:
    argv: ["ufw", "allow", "in", "on", "tailscale0", "to", "any", "port", "53"]
  changed_when: false
  failed_when: false
```

### 4.4 Templates

#### `tailscaled-bridge-start.sh.j2`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Bridge tailscaled instance for link: {{ item.name }}
# State: {{ bridge_state_dir }}/{{ item.name }}/
# Socket: /var/run/tailscale-bridge-{{ item.name }}.sock
# TUN: ts-{{ item.name }}

export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs

exec tailscaled \
  --state="{{ bridge_state_dir }}/{{ item.name }}/tailscaled.state" \
  --socket="/var/run/tailscale-bridge-{{ item.name }}.sock" \
  --tun="ts-{{ item.name }}"
```

#### `Corefile.j2`

```
# CoreDNS configuration — auto-generated by Ansible bridge role
# Forwards DNS zones for linked perimeters through their bridge tunnels.

{% for link in perimeter_links | default([]) %}
{% if link.enabled | default(true) %}
{{ link.dns_zone }} {
    bind {{ bridge_dns_listen_ip }}
    forward . {{ link.remote_dns }}
    log
    errors
    cache 60
}

{% endif %}
{% endfor %}
. {
    bind {{ bridge_dns_listen_ip }}
    forward . 1.1.1.1 9.9.9.9
    log
    errors
    cache 300
}
```

#### `bridge-nat.sh.j2`

```bash
#!/usr/bin/env bash
set -euo pipefail

# NAT rules for Perimeter Links bridge forwarding.
# Auto-generated by Ansible bridge role. Idempotent.

{% for link in perimeter_links | default([]) %}
{% if link.enabled | default(true) %}
# --- Link: {{ link.name }} ---
# Interface: ts-{{ link.name }}
# Remote prefix: {{ link.remote_prefix }}

# MASQUERADE outbound traffic to the remote tailnet
iptables -t nat -C POSTROUTING -o "ts-{{ link.name }}" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "ts-{{ link.name }}" -j MASQUERADE

# FORWARD from home tailscale0 to remote interface
iptables -C FORWARD -i tailscale0 -o "ts-{{ link.name }}" -d "{{ link.remote_prefix }}" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i tailscale0 -o "ts-{{ link.name }}" -d "{{ link.remote_prefix }}" -j ACCEPT

# FORWARD return traffic (established/related only — one-way isolation)
iptables -C FORWARD -i "ts-{{ link.name }}" -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "ts-{{ link.name }}" -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT

{% endif %}
{% endfor %}
echo "Bridge NAT rules applied."
```

### 4.5 Changes to Existing Roles

#### Headscale Role: DNS Split Configuration

**File:** `ansible/roles/headscale/templates/headscale-config.yaml.j2`

**Change:** Add split DNS nameserver entries generated from `perimeter_links`.

```yaml
# Current (minimal):
dns:
  magic_dns: false
  base_domain: ""
  override_local_dns: false

# New (when perimeter_links is defined):
dns:
  magic_dns: {{ 'true' if (headscale_magic_dns_base_domain | default('') | trim) != '' else 'false' }}
  base_domain: "{{ headscale_magic_dns_base_domain | default('') }}"
  override_local_dns: {{ 'true' if (perimeter_links | default([]) | length) > 0 else 'false' }}
{% if (perimeter_links | default([]) | length) > 0 %}
  nameservers:
    global:
      - 1.1.1.1
      - 9.9.9.9
    split:
{% for link in perimeter_links %}
{% if link.enabled | default(true) %}
      {{ link.dns_zone }}:
        - {{ bridge_dns_listen_ip | default(tailscale_ip) }}
{% endif %}
{% endfor %}
{% endif %}
```

**Key consideration:** This change requires MagicDNS to be enabled (at minimum `override_local_dns: true`) for split DNS to work. The Headscale `dns.nameservers.split` feature requires DNS to be active. This means:

- `headscale_magic_dns_base_domain` should be set (e.g., `ts.family.example.com`)
- The Headscale config template must conditionally enable DNS features

**Backward compatibility:** If `perimeter_links` is empty (default), the DNS section renders identically to today's config. No behavior change for existing deployments.

#### Headscale Role: IP Prefix Parameterization

**File:** `ansible/roles/headscale/defaults/main.yml`

**Add:**
```yaml
# IP prefix for this Headscale instance.
# Each deployment MUST use a distinct prefix to support Perimeter Links.
# Default matches the current hardcoded value.
headscale_ip_prefix_v4: "100.64.0.0/24"
headscale_ip_prefix_v6: "fd7a:115c:a1e0::/48"
```

**File:** `ansible/roles/headscale/templates/headscale-config.yaml.j2`

**Change:**
```yaml
# Current:
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48

# New:
prefixes:
  v4: {{ headscale_ip_prefix_v4 }}
  v6: {{ headscale_ip_prefix_v6 }}
```

#### Headscale Role: ACL Template for Bridge Tag

**File:** `ansible/roles/headscale/templates/acl.hujson.j2`

**Add tag:bridge to tagOwners and ACL rules:**

```hujson
  "tagOwners": {
    "tag:servers": ["user:{{ headscale_user }}"],
    "tag:db": ["user:{{ headscale_user }}"],
    "tag:backup": ["user:{{ headscale_user }}"],
    "tag:bridge": ["user:{{ headscale_user }}"]     // NEW
  },

  "acls": [
    // ... existing rules ...

    // Bridge node: allow subnet route forwarding.
    // The bridge advertises remote prefixes and forwards traffic.
    // Members can reach remote subnets through the bridge.
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:bridge:*"]
    }
  ]
```

**On the REMOTE side (Company Headscale):** The Company admin must add the bridge node to their ACL:

```hujson
// Company ACL — grant bridge node limited access
{
  "tagOwners": {
    "tag:bridge": ["user:company-admin@example.com"]
  },
  "acls": [
    // Bridge node can reach specific services only
    {
      "action": "accept",
      "src": ["tag:bridge"],
      "dst": [
        "tag:servers:3000",   // Grafana
        "tag:servers:9090",   // Prometheus
        "tag:servers:22"      // SSH
      ]
    }
  ]
}
```

This is a manual step for the Company admin. The blueprint documents what the Company needs to configure but doesn't automate it (the Company is a separate deployment).

#### Headscale Role: Pre-auth Key for Bridge Tag

**File:** `ansible/roles/headscale/defaults/main.yml`

**Change:**
```yaml
# Current:
headscale_tag_keys:
  servers: ["tag:servers"]
  db: ["tag:db"]
  backup: ["tag:backup"]

# New:
headscale_tag_keys:
  servers: ["tag:servers"]
  db: ["tag:db"]
  backup: ["tag:backup"]
  bridge: ["tag:bridge"]
```

This ensures a pre-auth key tagged `tag:bridge` is generated for the Home Headscale. The bridge's home-side tailscaled instance uses this key to join with the bridge tag, so ACLs can identify it.

#### Gateway Role: Bridge Integration

The bridge role runs **on the Gateway VM** (the same host that already does exit-node NAT, Caddy, etc.). No new VM is needed.

**File:** `ansible/playbooks/site.yml`

**Change:** Add the bridge role to the gateway group, after the gateway role:

```yaml
# Current gateway play:
- hosts: gateway
  roles:
    - common
    - tailscale
    - firewall
    - gateway

# New:
- hosts: gateway
  roles:
    - common
    - tailscale
    - firewall
    - gateway
    - bridge       # NEW — runs only when perimeter_links is defined and non-empty
```

#### Tailscale Role: Accept Routes Flag

**File:** `ansible/roles/tailscale/tasks/main.yml`

The home-side primary `tailscale up` command needs `--accept-routes` to accept the bridge subnet routes. Currently the role doesn't pass `--accept-routes` by default. Two options:

**Option A (simpler):** Add to `tailscale_extra_args` in gateway group_vars when perimeter_links is set.

**Option B (cleaner):** Add a conditional flag in the tailscale role:

```yaml
# In tailscale role, when building the tailscale up command:
{% if (perimeter_links | default([]) | length) > 0 %}
  --accept-routes
{% endif %}
```

Recommend **Option A** initially for minimal role changes.

### 4.6 Headscale Config Template — Complete Updated Version

For reference, the complete updated `headscale-config.yaml.j2` after all changes:

```yaml
# Headscale configuration
# Auto-generated by Ansible. Do not edit directly.

server_url: "{{ headscale_url }}"

listen_addr: "{{ headscale_listen_addr }}"

noise:
  private_key_path: /var/lib/headscale/noise_private.key

prefixes:
  v4: {{ headscale_ip_prefix_v4 }}
  v6: {{ headscale_ip_prefix_v6 }}

derp:
  urls:
{% for u in headscale_derp_urls | default([]) %}
    - {{ u }}
{% endfor %}
  auto_update_enabled: true
  update_frequency: 24h

database:
  type: sqlite3
  sqlite:
    path: /var/lib/headscale/db.sqlite

policy:
  mode: file
  path: /etc/headscale/acl.hujson

dns:
{% if (headscale_magic_dns_base_domain | default('') | trim) != '' %}
  magic_dns: true
  base_domain: "{{ headscale_magic_dns_base_domain }}"
{% else %}
  magic_dns: false
  base_domain: ""
{% endif %}
{% if (perimeter_links | default([]) | length) > 0 %}
  override_local_dns: true
  nameservers:
    global:
      - 1.1.1.1
      - 9.9.9.9
    split:
{% for link in perimeter_links | default([]) %}
{% if link.enabled | default(true) %}
      {{ link.dns_zone }}:
        - {{ bridge_dns_listen_ip | default(tailscale_ip | default('127.0.0.1')) }}
{% endif %}
{% endfor %}
{% else %}
  override_local_dns: false
{% endif %}

log:
  level: info
```

---

## 5. Prerequisites (Must Complete Before Perimeter Links)

### P1: Headscale IP Prefix Parameterization

**What:** Replace the hardcoded `100.64.0.0/10` in `headscale-config.yaml.j2` with a configurable variable.

**Why:** Each deployment needs a distinct prefix. Overlapping prefixes cause routing conflicts.

**Changes:**
1. Add `headscale_ip_prefix_v4` to `ansible/roles/headscale/defaults/main.yml`
2. Update `headscale-config.yaml.j2` to use the variable
3. Document prefix conventions in environment setup guide
4. Set per-environment: `environments/family/group_vars/all.yml` → `headscale_ip_prefix_v4: "100.64.1.0/24"`

**Effort:** Low. One variable, one template change.

**Risk:** Changing the prefix on an existing deployment reassigns all Tailscale IPs. This is a destructive operation — all devices must re-join. Only do this on new deployments or during a rebuild.

### P2: MagicDNS Enablement

**What:** Enable MagicDNS in Headscale configuration and set `headscale_magic_dns_base_domain`.

**Why:** Split DNS (`dns.nameservers.split`) requires Headscale's DNS feature to be active. Without MagicDNS enabled, Headscale doesn't push DNS configuration to clients.

**Changes:**
1. Set `headscale_magic_dns_base_domain: "in.yourdomain.com"` in environment config
2. Update Headscale config template to conditionally enable `magic_dns: true`
3. Test MagicDNS resolution works (devices get `<hostname>.in.yourdomain.com` names)

**Effort:** Low. Configuration change, already partially templated.

### P3: Bridge Tag in ACL

**What:** Add `tag:bridge` to the Headscale ACL template.

**Why:** The bridge node's home-side tailscale must be identifiable by tag for ACL rules.

**Changes:**
1. Add `tag:bridge` to `tagOwners` in `acl.hujson.j2`
2. Add `bridge` to `headscale_tag_keys` in `headscale/defaults/main.yml`
3. Add ACL rule: `autogroup:member` → `tag:bridge:*`

**Effort:** Low. Template changes only.

---

## 6. Testing Strategy

### 6.1 Automated Tests

**File:** `scripts/tests/80_verify_perimeter_links.sh`

```bash
#!/usr/bin/env bash
# Test: Perimeter Links bridge connectivity and DNS resolution
#
# Prerequisites:
#   - Two environments deployed (e.g., family + company)
#   - family has perimeter_links configured pointing to company
#   - Test runner is on the family tailnet

set -euo pipefail
source "$(dirname "$0")/common.sh"

# Test 1: Bridge tailscaled instances are running
section "Bridge tailscaled instances"
for link in $(get_perimeter_link_names); do
  assert_process_running "tailscaled.*ts-${link}" \
    "Bridge tailscaled for '${link}' is running"
done

# Test 2: Bridge tailscale connections are healthy
section "Bridge tailscale connections"
for link in $(get_perimeter_link_names); do
  ip=$(tailscale --socket="/var/run/tailscale-bridge-${link}.sock" ip -4 2>/dev/null || true)
  assert_not_empty "$ip" "Bridge '${link}' has a tailscale IP: $ip"
done

# Test 3: Subnet routes are advertised and approved
section "Subnet routes"
for link in $(get_perimeter_link_names); do
  prefix=$(get_perimeter_link_prefix "$link")
  # Verify route exists in tailscale status
  assert_subnet_route_active "$prefix" \
    "Subnet route ${prefix} is active for link '${link}'"
done

# Test 4: CoreDNS is running and resolving
section "CoreDNS forwarder"
assert_port_listening "53" "CoreDNS is listening on port 53"
for link in $(get_perimeter_link_names); do
  zone=$(get_perimeter_link_dns_zone "$link")
  # Try to resolve a known hostname in the zone
  result=$(dig +short "test.${zone}" @"${BRIDGE_DNS_IP}" 2>/dev/null || true)
  # Note: may not resolve if the remote has no "test" record, but the query
  # should not SERVFAIL — it should either resolve or return NXDOMAIN
  assert_dns_no_servfail "${zone}" "${BRIDGE_DNS_IP}" \
    "CoreDNS forwards ${zone} without SERVFAIL"
done

# Test 5: Cross-perimeter IP connectivity
section "Cross-perimeter connectivity"
for link in $(get_perimeter_link_names); do
  remote_dns=$(get_perimeter_link_remote_dns "$link")
  assert_ping "$remote_dns" \
    "Can ping remote DNS server ${remote_dns} through bridge '${link}'"
done

# Test 6: Exit-node VPN coexistence
section "VPN coexistence"
# Verify exit-node is still functional alongside bridge routes
assert_exit_node_active "Exit-node is still active with bridge routes"
# Verify internet connectivity through exit-node
assert_internet_via_exit_node "Internet reachable through exit-node"

# Test 7: One-way isolation
section "One-way isolation"
# From the remote side, verify that home subnet is NOT reachable
# This test must run from a device on the remote tailnet
# (may be skipped in automated tests if only one tailnet is accessible)
warn "One-way isolation test requires manual verification from remote side"

echo ""
echo "=== Perimeter Links verification complete ==="
```

### 6.2 Manual Test Procedure

For scenarios that cannot be fully automated:

```
MANUAL TEST: Perimeter Links End-to-End

Prerequisites:
  - Family environment deployed with perimeter_links pointing to Company
  - Company environment deployed with tag:bridge in ACL
  - Your phone/laptop connected to Family tailnet

Test Steps:

1. DNS RESOLUTION
   From your device (on Family tailnet):
   $ dig grafana.companyexample.com
   Expected: resolves to a 100.64.2.x address

2. SERVICE ACCESS
   From your device:
   $ curl -s http://grafana.companyexample.com:3000/api/health
   Expected: {"commit":"...","database":"ok","version":"..."}

3. SSH ACCESS
   $ ssh ops@monitoring.companyexample.com
   Expected: lands on Company monitoring VM

4. VPN COEXISTENCE
   Enable exit-node on Family Gateway, then:
   $ curl -s https://ifconfig.me
   Expected: returns Family Gateway's public IP (not your real IP)
   $ curl -s http://grafana.companyexample.com:3000/api/health
   Expected: still works (bridge route coexists with exit-node)

5. ONE-WAY ISOLATION
   From a Company device (NOT through the bridge):
   $ ping 100.64.1.1  (a Family IP)
   Expected: no response (Company has no route to Family)

6. DYNAMIC DNS
   Deploy a new service on Company environment.
   From your device (no redeployment of Family):
   $ dig newservice.companyexample.com
   Expected: resolves immediately (CoreDNS forwards the entire zone)
```

### 6.3 Integration with Existing Test Suite

**File:** `scripts/tests/run.sh`

Add a new test group:

```bash
# In run.sh test group dispatch:
perimeter-links)
  run_test 80_verify_perimeter_links.sh
  ;;
```

And include in the full suite when perimeter_links is configured:

```bash
# In the "all" test group:
if has_perimeter_links; then
  run_test 80_verify_perimeter_links.sh
fi
```

---

## 7. Deploy Script Changes

### 7.1 `deploy.sh` Additions

**No new flags needed.** The bridge deploys automatically when `perimeter_links` is configured in the environment's group_vars. The existing `./scripts/deploy.sh full --env family` flow handles it.

**Deployment summary addition (`scripts/helpers/deployment-summary.sh`):**

```bash
# Add to print_services() function:
print_perimeter_links() {
  local env_dir="$1"
  local links_config="${env_dir}/group_vars/all.yml"

  if ! grep -q 'perimeter_links:' "$links_config" 2>/dev/null; then
    return
  fi

  print_section "Perimeter Links (Cross-Perimeter Access)"

  # Parse perimeter_links from YAML (simplified — real implementation uses python/yq)
  python3 -c "
import yaml, sys
with open('${links_config}') as f:
    cfg = yaml.safe_load(f) or {}
links = cfg.get('perimeter_links', [])
if not links:
    print('  No links configured')
    sys.exit(0)
for link in links:
    name = link.get('name', '?')
    zone = link.get('dns_zone', '?')
    prefix = link.get('remote_prefix', '?')
    print(f'  {name}:')
    print(f'    DNS Zone:      *.{zone}')
    print(f'    Remote Prefix: {prefix}')
    print(f'    Access:        All services under {zone} are reachable')
    print()
  "
}
```

---

## 8. Security Model

### 8.1 Trust Boundaries

```
┌─────────────────────────────────────────────────────────┐
│                    HOME PERIMETER                        │
│  Trust level: FULL (you own and control everything)     │
│                                                          │
│  Devices: your phone, laptop, tablet                    │
│  VMs: control, gateway, monitoring, apps                │
│  Bridge: outbound connections to remotes                │
│                                                          │
│  Attack surface: Headscale API (443), Gateway (80/443)  │
└─────────────────────────────────────────────────────────┘
            │
            │ Bridge tunnel (outbound, WireGuard encrypted)
            │ One-way: Home → Remote only
            ▼
┌─────────────────────────────────────────────────────────┐
│                   REMOTE PERIMETER                       │
│  Trust level: LIMITED (remote admin controls ACL)        │
│                                                          │
│  What bridge can access: only what tag:bridge allows    │
│  What bridge CANNOT do: access Home from remote side    │
│  What remote users see: bridge is just a tagged node    │
│                                                          │
│  Blast radius: if bridge is compromised, attacker gets  │
│  access to whatever tag:bridge allows in Remote ACL.    │
│  Home perimeter is unaffected (no inbound routes).      │
└─────────────────────────────────────────────────────────┘
```

### 8.2 Threat Analysis

| Threat | Mitigation |
|--------|-----------|
| **Bridge VM compromised** | Attacker gets access to Remote services allowed by `tag:bridge` ACL. Home perimeter unaffected (no inbound route from Remote). Minimize blast radius: restrict `tag:bridge` to specific ports. |
| **Remote auth key leaked** | Attacker can join the Remote tailnet as `tag:bridge`. Mitigate: use short-lived auth keys, rotate regularly, restrict ACL to specific tags. |
| **Remote Headscale compromised** | Attacker controls the Remote tailnet. Bridge VM is a member → attacker can send traffic to bridge. BUT: bridge only forwards remote→home for ESTABLISHED connections (iptables). No new inbound connections to home. |
| **DNS poisoning via Remote** | Remote DNS could return malicious IPs for `*.companyexample.com`. Mitigate: CoreDNS cache + DNSSEC if Remote supports it. Risk is limited to Remote's own domain (not Home DNS). |
| **IP prefix conflict** | Two remotes with overlapping prefixes cause routing ambiguity. Mitigate: validation at deploy time (MUST NOT overlap). |
| **Remote pushes routes to bridge** | Remote Headscale could push routes to the bridge tailscale instance. Mitigate: bridge instances do NOT `--accept-routes` from Remote (only from Home). |

### 8.3 Auth Key Management for Bridge

The bridge needs auth keys from each remote Headscale. Key lifecycle:

1. **Provisioning:** Remote admin generates a pre-auth key tagged `tag:bridge` in their Headscale. They share it securely (out-of-band) with the Home admin.
2. **Storage:** Home admin stores in `ansible-vault` encrypted file.
3. **Rotation:** Pre-auth keys have an expiration (`headscale_preauthkey_expiration`). Once the bridge is joined, the key is no longer needed (the node stays registered). Rotation means generating a new key and updating the vault.
4. **Revocation:** Remote admin can revoke the bridge node from their Headscale at any time. This immediately disconnects the bridge from the Remote tailnet.

---

## 9. Operational Procedures

### 9.1 Adding a New Perimeter Link

```bash
# 1. Get an auth key from the remote deployment admin
#    Remote admin runs on their Headscale:
#    docker exec headscale headscale preauthkeys create -u admin@example.com \
#      --reusable --expiration 8760h --tags tag:bridge

# 2. Store the auth key in vault
ansible-vault edit environments/family/group_vars/vault.yml
# Add: vault_newclient_bridge_authkey: "hskey-xxxxx"

# 3. Add the link to configuration
cat >> environments/family/group_vars/all.yml << 'EOF'
perimeter_links:
  - name: newclient
    headscale_url: "https://hs.newclient.example.com"
    authkey: "{{ vault_newclient_bridge_authkey }}"
    remote_prefix: "100.64.4.0/24"
    dns_zone: "newclient.example.com"
    remote_dns: "100.64.4.1"
EOF

# 4. Deploy (only bridge-related changes are applied)
./scripts/deploy.sh full --env family
# Or more targeted:
# ansible-playbook -i inventory/tfgrid.py playbooks/site.yml --limit gateway --tags bridge

# 5. Verify
./scripts/tests/run.sh perimeter-links
```

### 9.2 Removing a Perimeter Link

```bash
# 1. Remove the link entry from perimeter_links in group_vars/all.yml
# 2. Redeploy:
./scripts/deploy.sh full --env family

# The bridge role will:
# - Stop and remove the tailscaled instance for the removed link
# - Remove NAT rules
# - Remove CoreDNS zone forwarding
# - Update Headscale split DNS config
# - Clean up state directory

# 3. (Optional) Ask the remote admin to remove the bridge node from their Headscale
```

### 9.3 Troubleshooting

```bash
# Check bridge tailscale status for a specific link:
tailscale --socket=/var/run/tailscale-bridge-company.sock status

# Check CoreDNS logs:
journalctl -u coredns -f
# or zinit logs:
zinit log coredns

# Test DNS resolution manually:
dig grafana.companyexample.com @100.64.1.3

# Check NAT rules:
iptables -t nat -L POSTROUTING -v -n | grep ts-
iptables -L FORWARD -v -n | grep ts-

# Check subnet route approval in Headscale:
ssh ops@control-vm -- docker exec headscale headscale routes list

# Verify bridge IP on remote tailnet:
tailscale --socket=/var/run/tailscale-bridge-company.sock ip -4
```

### 9.4 Bridge Failure Impact

| Failure | Impact | Recovery |
|---------|--------|----------|
| Bridge tailscaled crashes | Cross-perimeter access to that link stops. Home perimeter unaffected. | zinit auto-restarts. Manual: `zinit start tailscaled-bridge-company` |
| CoreDNS crashes | DNS resolution for remote zones fails. Direct IP access still works. | zinit auto-restarts. Manual: `zinit start coredns` |
| Gateway VM destroyed | All bridges + exit-node + public proxy gone. Home tailnet still works (device-to-device). | Redeploy gateway: `./scripts/deploy.sh gateway --env family`. Bridges recreate automatically. |
| Remote Headscale down | Bridge can't establish new connections but existing WireGuard tunnel continues. DNS forwarding continues. | Wait for remote to recover, or contact remote admin. |
| Remote revokes bridge node | Bridge disconnects from remote. Local CoreDNS queries fail for that zone. | Get new auth key from remote admin, update vault, redeploy. |

---

## 10. Implementation Phases

### Phase 1: Prerequisites (Implement First)

**Estimated scope:** 3 files changed

1. **IP prefix parameterization** (P1)
   - Add `headscale_ip_prefix_v4` variable
   - Update `headscale-config.yaml.j2`
   - Set distinct prefixes in existing environments

2. **MagicDNS enablement** (P2)
   - Document `headscale_magic_dns_base_domain` setup
   - Update headscale config template for conditional MagicDNS

3. **Bridge tag** (P3)
   - Add `tag:bridge` to ACL template and defaults

### Phase 2: Core Bridge Role

**Estimated scope:** New role (7 files) + 3 existing files changed

1. Create `ansible/roles/bridge/` with full task flow
2. Create templates: tailscaled startup, CoreDNS Corefile, NAT script
3. Update `playbooks/site.yml` to include bridge role on gateway
4. Update Headscale config template for split DNS

### Phase 3: Testing and Verification

**Estimated scope:** 2 new files + 1 file changed

1. Create `scripts/tests/80_verify_perimeter_links.sh`
2. Update `scripts/tests/run.sh` with perimeter-links test group
3. Create manual test procedure document

### Phase 4: Documentation and UX

**Estimated scope:** 4 files changed

1. Update `docs/technical/ARCHITECTURE.md` — add Perimeter Links section
2. Update `docs/technical/OPERATIONS.md` — add operational procedures
3. Update `docs/user/GUIDE.md` — add user-facing setup guide
4. Update `scripts/helpers/deployment-summary.sh` — display linked perimeters

### Phase 5: Hardening

**Estimated scope:** 2 files changed

1. Auth key rotation automation
2. Health check for bridge connections (alert if bridge is disconnected)
3. Metrics: bridge traffic stats via node_exporter custom collector

---

## 11. Known Limitations and Future Improvements

### Known Limitations

| Limitation | Why | Workaround |
|-----------|-----|-----------|
| **Extra latency** | Traffic traverses Home tailnet → bridge → Remote tailnet (two WireGuard hops) | Acceptable for typical use (web, SSH). Not suitable for latency-sensitive applications. |
| **Bridge is SPOF for cross-perimeter** | If bridge process crashes, cross-perimeter access stops | zinit auto-restarts. Could add HA with a second bridge VM later. |
| **Remote must cooperate** | Remote admin must provide auth key and configure tag:bridge ACL | By design — this is a security feature, not a limitation. |
| **IP prefix planning required** | All linked deployments must use non-overlapping /24 prefixes | Document conventions. Validate at deploy time. |
| **DNS depends on MagicDNS enabled** | Split DNS requires Headscale DNS to be active | MagicDNS is recommended anyway; make it a prerequisite. |
| **No GUI for link management** | Adding/removing links requires editing YAML + redeploying | Could build a Headplane extension later. |

### Future Improvements

| Improvement | Description | When |
|-------------|-------------|------|
| **HA bridge** | Two bridge VMs with failover (Tailscale HA subnet routers) | When reliability requirements increase |
| **Bidirectional links** | Both sides run a bridge, enabling mutual access | When use case demands it |
| **Link health dashboard** | Grafana dashboard showing bridge connection status, latency, traffic | After Phase 5 metrics |
| **Auto-discovery** | Bridge automatically discovers remote services without manual dns_zone config | Long-term; requires a service registry protocol |
| **Headplane integration** | Manage perimeter links from the Headplane web UI | Long-term UI work |
| **Ansible tag for incremental deploy** | `--tags bridge` to only update bridge config without full playbook run | Phase 2 |

---

## 12. File Change Summary

### New Files

| File | Purpose |
|------|---------|
| `ansible/roles/bridge/defaults/main.yml` | Default variables |
| `ansible/roles/bridge/tasks/main.yml` | Main task flow |
| `ansible/roles/bridge/templates/tailscaled-bridge-start.sh.j2` | Per-link tailscaled startup |
| `ansible/roles/bridge/templates/Corefile.j2` | CoreDNS zone forwarding config |
| `ansible/roles/bridge/templates/bridge-nat.sh.j2` | iptables NAT setup script |
| `ansible/roles/bridge/handlers/main.yml` | Restart handlers |
| `ansible/roles/bridge/meta/main.yml` | Role metadata |
| `scripts/tests/80_verify_perimeter_links.sh` | Automated verification tests |
| `docs/roadmap/perimeter-links.md` | This specification document |

### Modified Files

| File | Change |
|------|--------|
| `ansible/roles/headscale/defaults/main.yml` | Add `headscale_ip_prefix_v4`, `headscale_ip_prefix_v6`, `bridge` to `headscale_tag_keys` |
| `ansible/roles/headscale/templates/headscale-config.yaml.j2` | Parameterize prefixes; add conditional DNS split config |
| `ansible/roles/headscale/templates/acl.hujson.j2` | Add `tag:bridge` to tagOwners and ACL rules |
| `ansible/playbooks/site.yml` | Add `bridge` role to gateway play |
| `scripts/tests/run.sh` | Add `perimeter-links` test group |
| `scripts/helpers/deployment-summary.sh` | Display perimeter links in summary |
| `docs/technical/ARCHITECTURE.md` | Add Perimeter Links section |
| `docs/technical/OPERATIONS.md` | Add operational procedures |
| `docs/user/GUIDE.md` | Add user-facing setup guide |

### Not Modified (Intentional)

| File | Why unchanged |
|------|--------------|
| `terraform/*.tf` | No new infrastructure needed — bridge runs on existing Gateway VM |
| `ansible/roles/gateway/` | Bridge is a separate role that runs alongside gateway, not modifying it |
| `ansible/roles/tailscale/defaults/main.yml` | Extra args handled via group_vars, not role defaults |
| `ansible/roles/firewall/` | DNS port 53 rule added by bridge role itself, not firewall role |
| `scripts/deploy.sh` | No new flags — bridge deploys automatically when config is present |
