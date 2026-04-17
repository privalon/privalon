#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys


def _inventory_hostname_for_workload(workload_name: str) -> str:
    return workload_name if workload_name.endswith("-vm") else f"{workload_name}-vm"


def _load_outputs(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    # Terraform output -json format:
    # {"output_name": {"sensitive": bool, "type": ..., "value": ...}, ...}
    outputs = {}
    for key, value in data.items():
        if isinstance(value, dict) and "value" in value:
            outputs[key] = value.get("value")
        else:
            outputs[key] = value
    return outputs


def _load_json_file(path: str) -> dict:
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f) or {}
    except Exception:
        return {}


def _load_local_tailscale_ips() -> dict:
    try:
        result = subprocess.run(
            ["tailscale", "status", "--json"],
            check=True,
            capture_output=True,
            text=True,
        )
        data = json.loads(result.stdout)
    except Exception:
        return {}

    local_ips = {}
    for peer in (data.get("Peer") or {}).values():
        hostname = (peer.get("HostName") or "").strip()
        if not hostname:
            dns_name = (peer.get("DNSName") or "").strip()
            hostname = dns_name.split(".", 1)[0] if dns_name else ""

        tailscale_ips = peer.get("TailscaleIPs") or []
        if hostname and tailscale_ips:
            local_ips[hostname] = tailscale_ips[0]

    return local_ips


def _merge_tailscale_ips(persisted_ips: dict, inventory_hosts: list[str]) -> dict:
    merged_ips = dict(persisted_ips or {})
    local_ips = _load_local_tailscale_ips()
    ignored_hosts = {
        host.strip()
        for host in (os.environ.get("IGNORE_TAILSCALE_HOSTS", "").split(","))
        if host.strip()
    }

    for inventory_host in inventory_hosts:
        if inventory_host in ignored_hosts:
            continue
        if inventory_host in local_ips:
            merged_ips[inventory_host] = local_ips[inventory_host]

    return merged_ips


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--host")
    args = parser.parse_args()

    outputs_path = os.environ.get(
        "TF_OUTPUTS_JSON",
        os.path.join(os.path.dirname(__file__), "terraform-outputs.json"),
    )

    # Optional: persisted Tailscale IPs written by the tailscale role.
    # If present and the Ansible controller is on the tailnet, this enables
    # managing hosts even after public SSH is locked down.
    tailscale_ips_path = os.environ.get(
        "TAILSCALE_IPS_JSON",
        os.path.join(os.path.dirname(__file__), "tailscale-ips.json"),
    )
    tailscale_ips = _load_json_file(tailscale_ips_path)

    prefer_tailscale = os.environ.get("PREFER_TAILSCALE", "").strip().lower() in (
        "1",
        "true",
        "yes",
    )

    if not os.path.exists(outputs_path):
        sys.stderr.write(
            f"Missing terraform outputs JSON at {outputs_path}.\n"
            "Create it with: terraform -chdir=../terraform output -json > ansible/inventory/terraform-outputs.json\n"
        )
        return 1

    o = _load_outputs(outputs_path)
    gateway_public_ip = o.get("gateway_public_ip")
    gateway_private_ip = o.get("gateway_private_ip")
    control_public_ip = o.get("control_public_ip")
    control_private_ip = o.get("control_private_ip")
    network_ip_range = o.get("network_ip_range")
    workloads_private_ips = o.get("workloads_private_ips") or {}
    workloads_mycelium_ips = o.get("workloads_mycelium_ips") or {}

    inventory_hosts = ["gateway-vm", "control-vm"]
    for workload_name in workloads_private_ips:
        inventory_hosts.append(_inventory_hostname_for_workload(workload_name))

    tailscale_ips = _merge_tailscale_ips(tailscale_ips, inventory_hosts)

    headscale_url_override = os.environ.get("HEADSCALE_URL", "").strip()

    private_ip_values = [ip for ip in workloads_private_ips.values() if ip]
    private_ips_unique = len(set(private_ip_values)) == len(private_ip_values)

    inventory = {
        "_meta": {"hostvars": {}},
        "gateway": {"hosts": []},
        "control": {"hosts": []},
        "workloads": {"hosts": []},
        "monitoring": {"hosts": []},
        "all": {"vars": {"ansible_user": "root"}},
    }

    for workload_name in workloads_private_ips:
        if workload_name not in inventory:
            inventory[workload_name] = {"hosts": []}

    # Make (re)deploys smoother: ThreeFold public IPs can be reused, which changes SSH host keys.
    # Explicitly disable known_hosts enforcement so ProxyJump doesn't fail with "REMOTE HOST IDENTIFICATION HAS CHANGED".
    inventory["all"]["vars"]["ansible_ssh_common_args"] = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    if network_ip_range:
        inventory["all"]["vars"]["tf_private_cidr"] = network_ip_range

    # Headscale public URL used by clients and VMs.
    # Default behavior: use sslip.io based on the current control public IP.
    # Override behavior: set HEADSCALE_URL in the environment.
    if headscale_url_override:
        inventory["all"]["vars"]["headscale_url"] = headscale_url_override
    elif control_public_ip:
        inventory["all"]["vars"]["headscale_url"] = f"https://{control_public_ip}.sslip.io"

    def _prefer_ts(hostname: str, default_ip):
        if not prefer_tailscale:
            return default_ip
        ignored_hosts = {
            host.strip()
            for host in (os.environ.get("IGNORE_TAILSCALE_HOSTS", "").split(","))
            if host.strip()
        }
        if hostname in ignored_hosts:
            return default_ip
        ts_ip = tailscale_ips.get(hostname)
        return ts_ip or default_ip

    # Gateway: prefer Tailscale IP (if known), else public, else private
    if gateway_public_ip or gateway_private_ip:
        host = "gateway-vm"
        inventory["gateway"]["hosts"].append(host)
        inventory["_meta"]["hostvars"][host] = {
            "ansible_host": _prefer_ts(host, gateway_public_ip or gateway_private_ip),
            "tf_private_ip": gateway_private_ip,
            "tf_public_ip": gateway_public_ip,
            "tailscale_tags": ["tag:servers"],
        }

    # Control plane (Headscale): prefer Tailscale IP (if known), else route via gateway ProxyJump.
    # When prefer_tailscale is False (e.g. Tailscale SSH is ACL-blocked from this controller),
    # control's public SSH may also be locked down by the firewall role, so we route through the
    # gateway (reachable via public IP) to control's private IP (always open from the private CIDR).
    if control_public_ip or control_private_ip:
        host = "control-vm"
        inventory["control"]["hosts"].append(host)
        hostvars_control: dict = {
            "tf_private_ip": control_private_ip,
            "tf_public_ip": control_public_ip,
            "tailscale_tags": ["tag:servers"],
        }
        if prefer_tailscale:
            # Use Tailscale IP directly (works when this controller is an ACL-allowed SSH peer).
            ts_ip = tailscale_ips.get(host) if isinstance(tailscale_ips, dict) else None
            hostvars_control["ansible_host"] = ts_ip or control_public_ip or control_private_ip
        elif control_public_ip:
            # Use control's public IP directly on initial deploys (before firewall locks it down).
            # This avoids routing through the gateway (ProxyJump), which can hit MaxStartups
            # limits when the gateway already has many SSH connections.
            # After the firewall play hardens control's public SSH, PREFER_TAILSCALE=1 takes
            # over for subsequent runs (tailscale-ips.json will have been written by then).
            hostvars_control["ansible_host"] = control_public_ip
        else:
            # No public IP available: route via gateway ProxyJump using control's private IP.
            # The firewall role allows port 22 from the private CIDR, so this always works.
            hostvars_control["ansible_host"] = control_private_ip
            if gateway_public_ip and control_private_ip:
                hostvars_control["ansible_ssh_common_args"] = (
                    "-o ProxyCommand=\"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
                    f"-W %h:%p root@{gateway_public_ip}\" "
                    "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
                )
        inventory["_meta"]["hostvars"][host] = hostvars_control

    # Workloads: keep ansible_host on private IPs and reach them via a jump host.
    # During bootstrap, the jump host is the gateway public IP. After bootstrap (and after public SSH is locked down),
    # prefer jumping via the gateway Tailscale IP when PREFER_TAILSCALE=1.
    # Override: set JUMP_HOST to force a specific jump host (useful when gateway is unreachable).
    proxyjump = None
    jump_ip = None

    jump_host_override = os.environ.get("JUMP_HOST", "").strip()
    if jump_host_override:
        jump_ip = jump_host_override
    elif prefer_tailscale and isinstance(tailscale_ips, dict):
        jump_ip = tailscale_ips.get("gateway-vm")

    if not jump_ip:
        jump_ip = gateway_public_ip

    # Fallback: if gateway is not available, route workloads through control.
    if not jump_ip and control_public_ip:
        jump_ip = control_public_ip

    if jump_ip:
        # Use ProxyCommand instead of ProxyJump to ensure host key options apply to the jump host.
        # Wrap %h in brackets so IPv6 mycelium addresses are passed correctly to -W.
        proxyjump = (
            "-o ProxyCommand=\"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
            f"-W '[%h]:%p' root@{jump_ip}\" "
            "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        )

    for name, ip in workloads_private_ips.items():
        mycelium_ip = workloads_mycelium_ips.get(name)
        ansible_host = ip if private_ips_unique else (mycelium_ip or ip)
        if not ansible_host:
            continue

        host = _inventory_hostname_for_workload(name)

        inventory["workloads"]["hosts"].append(host)
        hostvars = {
            "ansible_host": ansible_host,
            "tf_private_ip": ip,
            "tf_mycelium_ip": mycelium_ip,
            "tf_name": name,
        }
        # Always use the jump host for workloads (private IPs). Jump host selection changes based on prefer_tailscale.
        if proxyjump:
            hostvars["ansible_ssh_common_args"] = proxyjump

        # Convenience grouping: add to the workload-specific group.
        # The "monitoring" group is pre-created, so this covers both cases.
        if name in inventory and host not in inventory[name]["hosts"]:
            inventory[name]["hosts"].append(host)

        # Provide a suggested tag for Headscale ACLs
        if name in ("gateway", "control"):
            hostvars["tailscale_tags"] = ["tag:servers"]
        elif name == "db":
            hostvars["tailscale_tags"] = ["tag:db"]
        elif name == "backup":
            hostvars["tailscale_tags"] = ["tag:backup"]
        else:
            hostvars["tailscale_tags"] = ["tag:servers"]

        inventory["_meta"]["hostvars"][host] = hostvars

    if args.list:
        sys.stdout.write(json.dumps(inventory, indent=2))
        return 0

    if args.host:
        sys.stdout.write(json.dumps(inventory["_meta"]["hostvars"].get(args.host, {})))
        return 0

    # Default behavior
    sys.stdout.write(json.dumps(inventory, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
