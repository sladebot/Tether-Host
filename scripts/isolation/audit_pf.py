#!/usr/bin/env python3
"""Read-only host PF evidence collector. Does not authenticate or change state."""
import argparse
import json
import subprocess


COMMANDS = {
    "pf_status": ["/sbin/pfctl", "-s", "info"],
    "root_rules": ["/sbin/pfctl", "-vvsr"],
    "anchor_rules": ["/sbin/pfctl", "-a", "*", "-vvsr"],
    "anchor_nat": ["/sbin/pfctl", "-a", "*", "-vvsn"],
    "anchor_inventory": ["/sbin/pfctl", "-a", "*", "-s", "Anchors"],
    "interfaces": ["/sbin/ifconfig", "-a"],
    "application_firewall": ["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"],
}
GATES = [
    "Exclusive VM attachment ownership and actual packet-hook coverage",
    "Guest IPv4, IPv6 (including link-local) and address-change enforcement",
    "Early anchor evaluation before conflicting quick-pass rules",
    "Controlled existing-state and fresh-connection tests",
    "Atomic VM/network startup and PF reload fail-closed boundary",
    "Non-admin guest session and trusted Tailscale socket UID separation",
    "Approved application TLS proxy and restricted resolver implementation",
    "Validated cloud policy and authenticated phone ingress regression tests",
]


def collect(run=subprocess.run):
    results = {}
    for name, command in COMMANDS.items():
        try:
            result = run(command, capture_output=True, text=True, timeout=15, check=False)
            results[name] = {"command": command, "returncode": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr}
        except (OSError, subprocess.TimeoutExpired) as exc:
            results[name] = {"command": command, "returncode": None, "error": str(exc)}
    return {"deployment_ready": False,
            "notice": "Read-only evidence; absent permissions are UNKNOWN, never proof PF is disabled.",
            "unverified_gates": GATES, "checks": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    report = collect()
    print(json.dumps(report, indent=2))
    return 0 if all(v["returncode"] == 0 for v in report["checks"].values()) else 2


if __name__ == "__main__":
    raise SystemExit(main())
