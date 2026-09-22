#!/bin/bash
set -euo pipefail
umask 077
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
TETHER_GUEST_STATE="$HOME/Library/Application Support/Tether Host for Mac/Guest Setup"
CURRENT_STAGE="Checking this guest"
fail() { printf '\nSetup stopped: %s\n' "$1"; exit 1; }
# This bundle must never provision the physical Mac by mistake.
case "$(/usr/sbin/sysctl -n hw.model)" in VirtualMac*) ;; *) fail 'Run this installer inside your macOS VM, not on the host Mac.' ;; esac
[ "$(uname -m)" = arm64 ] || fail 'An Apple silicon macOS guest is required.'
[ "$(id -u)" -ne 0 ] || fail 'Run as the logged-in guest user, not root.'
[ -t 0 ] || fail 'Open this setup command in Terminal inside the VM.'
mkdir -p "$TETHER_GUEST_STATE"
chmod 700 "$TETHER_GUEST_STATE"
# flock is not present on a fresh Mac. mkdir provides an atomic per-user lock.
if ! mkdir "$TETHER_GUEST_STATE/running.lock" 2>/dev/null; then
    fail 'Guest setup is already running. If it was interrupted, close its Terminal and remove the running.lock folder before retrying.'
fi
cleanup() {
    result=$?
    rmdir "$TETHER_GUEST_STATE/running.lock" 2>/dev/null || true
    if [ "$result" -ne 0 ]; then
        printf '%s\n' "Stopped during: $CURRENT_STAGE. Fix the error above, then run setup again." > "$TETHER_GUEST_STATE/status.txt"
    fi
}
trap cleanup EXIT
# A failed new attempt must not leave a stale success receipt.
rm -f "$TETHER_GUEST_STATE/connection.json"
stage() { CURRENT_STAGE="$1"; printf '\n%s\n' "$1"; printf '%s\n' "$1" > "$TETHER_GUEST_STATE/status.txt"; }
wait_for_user() { printf '\n%s\nPress Return when finished, or Control-C to stop. ' "$1"; read -r _; }

stage 'Keeping this macOS VM awake during setup'
/bin/bash "$SCRIPT_DIRECTORY/Keep Tether VM Awake.command"

stage 'Step 3 of 4 — Checking Internet from inside this VM'
check_guest_https() {
    /usr/bin/curl --proto '=https' --tlsv1.2 -sSI --connect-timeout 10 --max-time 20 \
        https://pkgs.tailscale.com/stable/ > /dev/null 2>&1
}
if ! check_guest_https; then
    GUEST_INTERFACE="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '$1 == "interface:" { print $2; exit }')"
    GUEST_IP="$(/usr/sbin/ipconfig getifaddr "$GUEST_INTERFACE" 2>/dev/null || true)"
    if [ -n "$GUEST_IP" ] && /usr/bin/nslookup pkgs.tailscale.com 1.1.1.1 > /dev/null 2>&1; then
        printf '\nThe VM has an IP address (%s), but its assigned DNS server is not resolving names.\n' "$GUEST_IP"
        printf 'Cloudflare DNS (1.1.1.1) works from inside this VM.\n'
        printf 'Switch this VM to 1.1.1.1? DNS queries will be sent to Cloudflare. [y/N] '
        read -r USE_CLOUDFLARE_DNS
        if [ "$USE_CLOUDFLARE_DNS" = y ] || [ "$USE_CLOUDFLARE_DNS" = Y ]; then
            NETWORK_SERVICE="$(/usr/sbin/networksetup -listnetworkserviceorder | /usr/bin/awk -v device="$GUEST_INTERFACE" '
                /^\([0-9]+\) / { service = $0; sub(/^\([0-9]+\) /, "", service) }
                index($0, "Device: " device ")") { print service; exit }
            ')"
            [ -n "$NETWORK_SERVICE" ] || fail 'Could not identify the VM Ethernet service. Set its DNS server to 1.1.1.1 in System Settings > Network, then retry.'
            /usr/bin/sudo /usr/sbin/networksetup -setdnsservers "$NETWORK_SERVICE" 1.1.1.1
            for attempt in 1 2 3; do
                if check_guest_https; then break; fi
                /bin/sleep 2
            done
        fi
    fi
    check_guest_https || fail 'The VM still cannot reach the Tailscale package server. In this VM, check System Settings > Network > Ethernet > DNS, then rerun setup.'
fi
printf 'Guest HTTPS access is working.\n'

stage 'Step 3 of 4 — Checking Tailscale inside this VM'
TAILSCALE_BIN='/Applications/Tailscale.app/Contents/MacOS/Tailscale'
if [ ! -x "$TAILSCALE_BIN" ]; then
    stage 'Step 3 of 4 — Installing Tailscale inside this VM'
    curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 15 --max-time 600 \
        https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg -o "$TETHER_GUEST_STATE/Tailscale.pkg"
    pkgutil --check-signature "$TETHER_GUEST_STATE/Tailscale.pkg" > "$TETHER_GUEST_STATE/package-signature.txt"
    /usr/bin/grep -q 'Developer ID Installer: Tailscale.*(W5364U7YZB)' "$TETHER_GUEST_STATE/package-signature.txt" || fail 'The Tailscale package signer is not recognized.'
    open -W "$TETHER_GUEST_STATE/Tailscale.pkg"
    [ -x "$TAILSCALE_BIN" ] || fail 'Complete Tailscale installation, then retry.'
fi
/usr/bin/codesign --verify --strict -R 'anchor apple generic and certificate leaf[subject.OU] = "W5364U7YZB"' /Applications/Tailscale.app || fail 'Tailscale signature verification failed.'

stage 'Step 3 of 4 — Configuring Tailscale inside this VM'
if ! "$TAILSCALE_BIN" status --json > "$TETHER_GUEST_STATE/tailscale-status.json" 2>/dev/null || \
   [ "$(/usr/bin/plutil -extract BackendState raw -o - "$TETHER_GUEST_STATE/tailscale-status.json" 2>/dev/null || true)" != 'Running' ]; then
    open /Applications/Tailscale.app
    wait_for_user 'Approve Tailscale’s VPN/system extension and sign in to the same tailnet you will use on your iPhone.'
    "$TAILSCALE_BIN" status --json > "$TETHER_GUEST_STATE/tailscale-status.json"
fi

stage 'Step 4 of 4 — Checking Hermes inside this VM'
HERMES_BIN="$HOME/.hermes/hermes-agent/venv/bin/hermes"
PYTHON_BIN="$HOME/.hermes/hermes-agent/venv/bin/python"
if [ ! -x "$HERMES_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    if [ -e "$HOME/.hermes" ] && [ ! -f "$TETHER_GUEST_STATE/managed-hermes" ]; then
        fail 'Hermes data exists in this VM, but its runtime is incomplete. Repair that installation, then run Tether setup again.'
    fi
    stage 'Step 4 of 4 — Installing Hermes inside this VM'
    touch "$TETHER_GUEST_STATE/managed-hermes"
    HERMES_REVISION="$(/usr/bin/plutil -extract hermes_revision raw -o - "$SCRIPT_DIRECTORY/components.json")"
    INSTALLER_URL="$(/usr/bin/plutil -extract hermes_installer_url raw -o - "$SCRIPT_DIRECTORY/components.json")"
    INSTALLER_DIGEST="$(/usr/bin/plutil -extract hermes_installer_sha256 raw -o - "$SCRIPT_DIRECTORY/components.json")"
    curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 15 --max-time 180 "$INSTALLER_URL" -o "$TETHER_GUEST_STATE/hermes-install.sh"
    ACTUAL_DIGEST="$(shasum -a 256 "$TETHER_GUEST_STATE/hermes-install.sh" | awk '{print $1}')"
    [ "$ACTUAL_DIGEST" = "$INSTALLER_DIGEST" ] || fail 'The Hermes installer checksum did not match.'
    if [ ! -f "$TETHER_GUEST_STATE/hermes-installed" ]; then
        /bin/bash "$TETHER_GUEST_STATE/hermes-install.sh" --skip-setup --commit "$HERMES_REVISION"
        touch "$TETHER_GUEST_STATE/hermes-installed"
    fi
fi
[ -x "$HERMES_BIN" ] && [ -x "$PYTHON_BIN" ] || fail 'Hermes is incomplete. Repair it inside this VM, then run setup again.'

stage 'Step 4 of 4 — Configuring Hermes API support'
uv pip install --python "$PYTHON_BIN" -e "$HOME/.hermes/hermes-agent[messaging]"
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" tailscale

stage 'Step 4 of 4 — Configuring Hermes authentication'
"$HERMES_BIN" model
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" configure

stage 'Step 4 of 4 — Configuring Hermes computer use'
"$HERMES_BIN" computer-use install
while ! "$HERMES_BIN" computer-use doctor; do
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
    wait_for_user 'Inside this VM, grant Accessibility and Screen Recording to the identity named by the doctor report. Restart that app if macOS asks. Permissions will be checked again.'
done

stage 'Step 4 of 4 — Verifying the Hermes gateway'
"$HERMES_BIN" gateway install
"$HERMES_BIN" gateway restart
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" verify-loopback

stage 'Step 4 of 4 — Verifying private HTTPS and model access'
"$TAILSCALE_BIN" serve status --json > "$TETHER_GUEST_STATE/serve-before.json"
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" check-serve-before
"$TAILSCALE_BIN" serve --bg --https=443 http://127.0.0.1:8642
"$TAILSCALE_BIN" serve status --json > "$TETHER_GUEST_STATE/serve-after.json"
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" verify
stage 'Installation complete — backend verified'
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" show-connection
printf 'Keep Tailscale connected on your phone and this guest.\n'
wait_for_user 'The setup has finished. The guest must remain running and logged in for the gateway and computer use to stay available.'
