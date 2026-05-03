#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path


_SUFFIX_RE = re.compile(r"-(?:[a-z0-9]{8})$")


def canonical_inventory_name(raw_name: str) -> str:
    name = (raw_name or "").strip().rstrip(".")
    if not name:
        return ""
    short_name = name.split(".", 1)[0]
    return _SUFFIX_RE.sub("", short_name)


def _load_existing_map(path: str | None) -> dict[str, str]:
    if not path:
        return {}
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}

    result: dict[str, str] = {}
    for raw_name, raw_ip in data.items():
        name = canonical_inventory_name(str(raw_name))
        ip = str(raw_ip).strip()
        if name and ip:
            result[name] = ip
    return result


def _peer_entries(status: dict) -> list[tuple[dict, bool]]:
    entries = [
        ((status.get("Peer") or {}).get(key) or {}, False)
        for key in (status.get("Peer") or {})
    ]
    self_peer = status.get("Self")
    if isinstance(self_peer, dict):
        entries.append((self_peer, True))
    return entries


def build_local_ip_map(status: dict, existing: dict[str, str] | None = None) -> dict[str, str]:
    result = dict(existing or {})
    offline_names: set[str] = set()
    online_names: set[str] = set()
    online_ips: set[str] = set()

    for peer, is_self in _peer_entries(status):
        dns_name = peer.get("DNSName") or ""
        host_name = peer.get("HostName") or ""
        name = canonical_inventory_name(dns_name or host_name)
        if not name:
            continue

        ips = peer.get("TailscaleIPs") or []
        if not is_self and peer.get("Online") is False:
            offline_names.add(name)
            continue

        if ips:
            result[name] = ips[0]
            online_names.add(name)
            online_ips.add(ips[0])

    for name in offline_names - online_names:
        result.pop(name, None)

    # Drop stale carried-forward entries whose IPs collide with a currently
    # online peer at a different name. This prevents a previously-persisted
    # mapping (e.g. control-vm -> 100.64.0.2) from surviving after the IP has
    # been reassigned to another peer (e.g. the local controller "Self") in
    # the live tailnet view.
    stale_collisions = [
        name
        for name, ip in result.items()
        if name not in online_names and ip in online_ips
    ]
    for name in stale_collisions:
        result.pop(name, None)

    return result


def first_online_ip_by_name(status: dict, inventory_name: str) -> str:
    target = canonical_inventory_name(inventory_name)
    for peer, is_self in _peer_entries(status):
        if is_self:
            continue
        dns_name = peer.get("DNSName") or ""
        host_name = peer.get("HostName") or ""
        name = canonical_inventory_name(dns_name or host_name)
        if name != target or not peer.get("Online"):
            continue
        ips = peer.get("TailscaleIPs") or []
        if ips:
            return ips[0]
    return ""


def _read_status_from_stdin() -> dict:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    write_map_parser = subparsers.add_parser("write-map")
    write_map_parser.add_argument("--existing")

    first_ip_parser = subparsers.add_parser("first-online-ip")
    first_ip_parser.add_argument("--name", required=True)

    args = parser.parse_args()
    status = _read_status_from_stdin()

    if args.command == "write-map":
        result = build_local_ip_map(status, _load_existing_map(args.existing))
        json.dump(result, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    if args.command == "first-online-ip":
        result = first_online_ip_by_name(status, args.name)
        if result:
            sys.stdout.write(result + "\n")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())