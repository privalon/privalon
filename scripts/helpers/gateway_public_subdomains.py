#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


def _clean(value):
    return str(value).strip().strip('"').strip("'")


def _uniq(items):
    seen = set()
    ordered = []
    for item in items:
        if item and item not in seen:
            seen.add(item)
            ordered.append(item)
    return ordered


def _parse_inline_list(line):
    match = re.search(r"\[([^\]]*)\]", line)
    if not match:
        return []
    return [_clean(item) for item in match.group(1).split(",") if _clean(item)]


def _parse_simple_yaml(content):
    data = {
        "gateway_subdomains": [],
        "gateway_domains": [],
        "gateway_services": [],
    }

    lines = content.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue

        if re.match(r"^gateway_subdomains:\s*\[", stripped):
            data["gateway_subdomains"] = _parse_inline_list(stripped)
            i += 1
            continue

        if re.match(r"^gateway_domains:\s*\[", stripped):
            data["gateway_domains"] = _parse_inline_list(stripped)
            i += 1
            continue

        if stripped == "gateway_subdomains:" or stripped == "gateway_domains:":
            key = stripped[:-1]
            items = []
            i += 1
            while i < len(lines):
                entry = lines[i]
                entry_stripped = entry.strip()
                if not entry_stripped or entry_stripped.startswith("#"):
                    i += 1
                    continue
                match = re.match(r"^\s+-\s+(.+)$", entry)
                if not match:
                    break
                items.append(_clean(match.group(1)))
                i += 1
            data[key] = items
            continue

        if stripped == "gateway_services:" or re.match(r"^gateway_services:\s*\[\s*\]\s*$", stripped):
            services = []
            i += 1
            current = None
            while i < len(lines):
                entry = lines[i]
                entry_stripped = entry.strip()
                if not entry_stripped or entry_stripped.startswith("#"):
                    i += 1
                    continue
                if re.match(r"^[^\s#].*:", entry):
                    break

                item_match = re.match(r"^\s+-\s+name:\s*(.+)$", entry)
                if item_match:
                    if current:
                        services.append(current)
                    current = {"name": _clean(item_match.group(1))}
                    i += 1
                    continue

                bare_item_match = re.match(r"^\s+-\s*$", entry)
                if bare_item_match:
                    if current:
                        services.append(current)
                    current = {}
                    i += 1
                    continue

                field_match = re.match(r"^\s+([A-Za-z0-9_]+):\s*(.+)$", entry)
                if field_match and current is not None:
                    current[field_match.group(1)] = _clean(field_match.group(2))
                    i += 1
                    continue

                break

            if current:
                services.append(current)
            data["gateway_services"] = services
            continue

        i += 1

    return data


def load_gateway_config(path):
    content = Path(path).read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        loaded = yaml.safe_load(content) or {}
        if isinstance(loaded, dict):
            return loaded
    except Exception:
        pass
    return _parse_simple_yaml(content)


def _derive_from_service_name(name, base_domain):
    service_name = _clean(name)
    if not service_name:
        return ""
    if "." not in service_name:
        return service_name
    if base_domain and service_name.endswith("." + base_domain):
        prefix = service_name[: -(len(base_domain) + 1)]
        if prefix and "." not in prefix:
            return prefix
    return ""


def collect_gateway_subdomains(config, base_domain):
    explicit = [_clean(item) for item in config.get("gateway_subdomains", []) if _clean(item)]
    if explicit:
        return _uniq(explicit)

    services = []
    for service in config.get("gateway_services", []) or []:
        if isinstance(service, dict):
            derived = _derive_from_service_name(service.get("name", ""), base_domain)
            if derived:
                services.append(derived)
    if services:
        return _uniq(services)

    legacy = []
    for domain in config.get("gateway_domains", []) or []:
        derived = _derive_from_service_name(domain, base_domain)
        if derived:
            legacy.append(derived)
    return _uniq(legacy)


def main():
    parser = argparse.ArgumentParser(description="Print derived gateway public subdomains as comma-separated output.")
    parser.add_argument("--file", required=True, help="Path to environments/<env>/group_vars/gateway.yml")
    parser.add_argument("--base-domain", default="", help="Configured base_domain")
    args = parser.parse_args()

    config = load_gateway_config(args.file)
    print(",".join(collect_gateway_subdomains(config, args.base_domain.strip())))


if __name__ == "__main__":
    main()