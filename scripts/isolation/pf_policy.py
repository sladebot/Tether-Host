#!/usr/bin/env python3
"""Offline source-scoped PF candidate generator. Never applies firewall changes."""
import argparse
import ipaddress
import json
import re
import sys


def address(value):
    if not isinstance(value, str) or "%" in value:
        raise ValueError("addresses must be unscoped IP literals")
    return ipaddress.ip_address(value)


def exact_keys(value, required):
    if not isinstance(value, dict) or set(value) != set(required):
        raise ValueError("expected exactly these fields: " + ", ".join(required))


def generate(config):
    exact_keys(config, ["interface", "guest_addresses", "proxy", "resolver", "transport_addresses"])
    interface = config["interface"]
    if not isinstance(interface, str) or not re.fullmatch(r"[a-z][a-z0-9]{0,14}", interface):
        raise ValueError("invalid interface name")
    guests = config["guest_addresses"]
    transports = config["transport_addresses"]
    if not isinstance(guests, list) or not guests or not isinstance(transports, list):
        raise ValueError("guest_addresses must be nonempty; transport_addresses must be a list")
    guests = sorted(set(map(address, guests)), key=lambda a: (a.version, int(a)))
    if any(a.is_unspecified or a.is_multicast or a.is_loopback for a in guests):
        raise ValueError("invalid guest address")
    if {a.version for a in guests} != {4, 6}:
        raise ValueError("explicit guest addresses for both IPv4 and IPv6 are required")
    transports = sorted(set(map(address, transports)), key=lambda a: (a.version, int(a)))
    if any(not a.is_global or a.is_multicast or getattr(a, "ipv4_mapped", None) is not None
           for a in transports):
        raise ValueError("transport destinations must be global unicast IP literals")
    services = []
    for name, allowed_ports in [("proxy", {3128}), ("resolver", {53})]:
        service = config[name]
        if service is None:
            continue
        exact_keys(service, ["address", "port"])
        target = address(service["address"])
        if target.is_unspecified or target.is_loopback or target.is_multicast or target in guests:
            raise ValueError("invalid infrastructure destination")
        if type(service["port"]) is not int or service["port"] not in allowed_ports:
            raise ValueError("unsupported infrastructure port")
        services.append((name, target, service["port"]))
    lines = [
        "# OFFLINE CANDIDATE ONLY; not an installed or deployment-ready policy.",
        "# Source-address scope does NOT cover spoofing, new addresses, or hook bypass.",
        "# Existing states survive; anchor order, IPv6 and lifecycle require live tests.",
        "# Host cannot distinguish guest process UIDs. Transport requires guest PF.",
        "# No bootstrap allowance is inferred. Missing services intentionally fail.",
    ]
    for guest in guests:
        family = "inet" if guest.version == 4 else "inet6"
        prefix = f"on {interface} {family}"
        for name, target, port in services:
            if target.version == guest.version:
                protocols = "{ tcp, udp }" if name == "resolver" else "tcp"
                lines.append(f'pass quick {prefix} proto {protocols} from {guest} to {target} port {port} keep state label "tether_{name}"')
        for target in transports:
            if target.version == guest.version:
                lines.append(f'pass quick {prefix} proto tcp from {guest} to {target} port 443 keep state label "tether_transport"')
        lines.append(f'block drop quick {prefix} from {guest} to any label "tether_default_deny"')
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="explicit JSON inventory; output goes to stdout")
    args = parser.parse_args()
    try:
        with open(args.config, encoding="utf-8") as handle:
            result = generate(json.load(handle))
    except (ValueError, OSError) as exc:
        parser.exit(2, f"Invalid inventory: {exc}\n")
    sys.stdout.write(result)


if __name__ == "__main__":
    main()
