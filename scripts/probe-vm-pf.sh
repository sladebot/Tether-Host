#!/bin/bash
# Run on the Studio. Never reload pf.conf or flush global rules/states.
set -euo pipefail
export LC_ALL=C
readonly pf=/sbin/pfctl
readonly script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
case "${1:-internet}" in
    internet)
        anchor=com.apple/000.tether-vm-probe
        rules="$script_dir/probe-vm-pf.rules"
        description='only VM IPv4 HTTPS to 1.1.1.1 is blocked'
        ;;
    host)
        anchor=com.apple/000.tether-vm-host-probe
        rules="$script_dir/probe-vm-host-pf.rules"
        description='only recorded VM IPv4/IPv6 traffic to Studio interface addresses is blocked'
        ;;
    *) echo 'Usage: probe-vm-pf.sh [internet|host]' >&2; exit 2 ;;
esac
readonly anchor rules description

if [[ $EUID -ne 0 ]]; then
    echo 'Run this script with sudo in the Studio Terminal.' >&2
    exit 1
fi
if ! "$pf" -s info | /usr/bin/grep -q 'Status: Enabled'; then
    echo 'PF is not enabled; stopped without changing anything.' >&2
    exit 1
fi
if ! "$pf" -sr | /usr/bin/grep -Fqx 'anchor "com.apple/*" all'; then
    echo 'Expected Apple anchor hook is absent; stopped without changes.' >&2
    exit 1
fi
bridge_state=$(/sbin/ifconfig bridge100)
if ! /usr/bin/grep -q 'member: vmenet0 ' <<< "$bridge_state" ||
   ! /usr/bin/grep -q '76:c3:f5:3:9c:44.*vmenet0' <<< "$bridge_state"; then
    echo 'VM interface/MAC no longer matches; stopped without changes.' >&2
    exit 1
fi
existing_rules=$("$pf" -a "$anchor" -sr)
existing_children=$("$pf" -a "$anchor" -s Anchors)
if [[ -n "$existing_rules" || -n "$existing_children" ]]; then
    echo 'Probe anchor is already occupied; stopped without changes.' >&2
    exit 1
fi
"$pf" -n -a "$anchor" -f "$rules"

cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    if "$pf" -a "$anchor" -f /dev/null; then
        echo 'Temporary probe rules removed; all other rules/states untouched.'
    else
        echo "CLEANUP FAILED. Run: sudo /sbin/pfctl -a $anchor -f /dev/null" >&2
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
"$pf" -a "$anchor" -f "$rules"
echo "PROBE ACTIVE for 60 seconds: $description."
if [[ "${1:-internet}" == internet ]]; then
    echo 'In the VM now run: curl -4 -I --connect-timeout 5 --max-time 8 https://1.1.1.1'
else
    echo 'The agent will compare controlled host IPv4/IPv6 probes and public HTTPS during this window.'
    echo 'This diagnostic does not block encrypted Tailscale paths or prove permanent isolation.'
fi
echo 'Keep this Terminal open. Ctrl-C also removes the probe rules.'
/bin/sleep 60
"$pf" -a "$anchor" -vvsr
