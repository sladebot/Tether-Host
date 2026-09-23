#!/bin/bash
set -euo pipefail
umask 077
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
TETHER_GUEST_STATE="$HOME/Library/Application Support/Tether Host for Mac/Guest Setup"
CURRENT_STAGE="Checking this guest"
fail() { printf '\nSetup stopped: %s\n' "$1"; exit 1; }
ACTION="${1:-}"
case "$ACTION" in
    internet|tailscale|hermes-install|hermes-configure|computer-use|verify) ;;
    *) fail 'Open Tether Guest Installer.app and choose a setup step.' ;;
esac
# This bundle must never provision the physical Mac by mistake.
case "$(/usr/sbin/sysctl -n hw.model)" in VirtualMac*) ;; *) fail 'Run this installer inside your macOS VM, not on the host Mac.' ;; esac
[ "$(uname -m)" = arm64 ] || fail 'An Apple silicon macOS guest is required.'
[ "$(id -u)" -ne 0 ] || fail 'Run as the logged-in guest user, not root.'
[ -t 0 ] || fail 'Open this setup step from Tether Guest Installer inside the VM.'
mkdir -p "$TETHER_GUEST_STATE"
chmod 700 "$TETHER_GUEST_STATE"
# flock is not present on a fresh Mac. mkdir provides an atomic per-user lock.
if ! mkdir "$TETHER_GUEST_STATE/running.lock" 2>/dev/null; then
    fail 'Guest setup is already running. If it was interrupted, close the installer and remove the running.lock folder before retrying.'
fi
cleanup() {
    result=$?
    rmdir "$TETHER_GUEST_STATE/running.lock" 2>/dev/null || true
    if [ "$result" -ne 0 ]; then
        printf '%s\n' "Stopped during: $CURRENT_STAGE. Fix the error above, then run setup again." > "$TETHER_GUEST_STATE/status.txt"
    fi
}
trap cleanup EXIT
# Any changed guest dependency requires a fresh final verification.
if [ "$ACTION" != internet ]; then rm -f "$TETHER_GUEST_STATE/connection.json" "$TETHER_GUEST_STATE/verified.ready"; fi
stage() { CURRENT_STAGE="$1"; printf '\n%s\n' "$1"; printf '%s\n' "$1" > "$TETHER_GUEST_STATE/status.txt"; }
wait_for_user() { printf '\n%s\nPress Return when finished, or Control-C to stop. ' "$1"; read -r _; }
check_tailnet() {
    [ "$(/usr/bin/plutil -extract BackendState raw -o - "$TETHER_GUEST_STATE/tailscale-status.json" 2>/dev/null || true)" = Running ] || return 1
    TAILNET_NAME="$(/usr/bin/plutil -extract Self.DNSName raw -o - "$TETHER_GUEST_STATE/tailscale-status.json" 2>/dev/null || true)"
    [[ "$TAILNET_NAME" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+\.ts\.net\.$ ]]
}
tailscale_cli() {
    /usr/bin/env TAILSCALE_BE_CLI=1 "$TAILSCALE_BIN" "$@"
}
install_hermes_command() {
    local command_directory="$HOME/.local/bin"
    local command_path="$command_directory/hermes"
    local shell_profile="$HOME/.zprofile"
    /bin/mkdir -p "$command_directory"
    if [ -e "$command_path" ] || [ -L "$command_path" ]; then
        [ -x "$command_path" ] || fail 'The existing ~/.local/bin/hermes command is not executable. Repair it, then retry.'
    else
        /bin/ln -s "$HERMES_BIN" "$command_path"
    fi
    if ! /usr/bin/grep -Fq '# Tether Hermes command' "$shell_profile" 2>/dev/null; then
        printf '\n# Tether Hermes command\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$shell_profile"
    fi
}
complete() {
    printf '%s\n' "Completed: $2" > "$TETHER_GUEST_STATE/status.txt"
    /usr/bin/touch "$TETHER_GUEST_STATE/$1.ready"
    printf '\n%s\n' "$2 is complete. Return to Tether Guest Installer for the next step."
}

if [ "$ACTION" = internet ]; then
stage '1 of 6 — Keeping this macOS VM awake'
/bin/bash "$SCRIPT_DIRECTORY/Keep Tether VM Awake.command"

stage '1 of 6 — Checking Internet inside this VM'
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
complete internet 'Guest Internet'
exit 0
fi

[ -f "$TETHER_GUEST_STATE/internet.ready" ] || fail 'Complete the Internet step in Tether Guest Installer first.'

if [ "$ACTION" = tailscale ]; then
stage '2 of 6 — Checking Tailscale inside this VM'
TAILSCALE_BIN='/Applications/Tailscale.app/Contents/MacOS/Tailscale'
if [ ! -x "$TAILSCALE_BIN" ]; then
    stage '2 of 6 — Installing Tailscale inside this VM'
    curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 15 --max-time 600 \
        https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg -o "$TETHER_GUEST_STATE/Tailscale.pkg"
    pkgutil --check-signature "$TETHER_GUEST_STATE/Tailscale.pkg" > "$TETHER_GUEST_STATE/package-signature.txt"
    /usr/bin/grep -q 'Developer ID Installer: Tailscale.*(W5364U7YZB)' "$TETHER_GUEST_STATE/package-signature.txt" || fail 'The Tailscale package signer is not recognized.'
    open -W "$TETHER_GUEST_STATE/Tailscale.pkg"
    [ -x "$TAILSCALE_BIN" ] || fail 'Complete Tailscale installation, then retry.'
fi
SIGNATURE_INFO="$(/usr/bin/codesign -dv --verbose=4 /Applications/Tailscale.app 2>&1)" || fail 'Could not read the Tailscale app signature.'
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -qx 'TeamIdentifier=W5364U7YZB' || fail 'The Tailscale app signer is not recognized.'
TAILSCALE_BUNDLE_ID="$(printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/sed -n 's/^Identifier=//p')"
case "$TAILSCALE_BUNDLE_ID" in
    io.tailscale.ipn.macos|io.tailscale.ipn.macsys) ;;
    *) fail 'The Tailscale app identity is not recognized.' ;;
esac
/usr/bin/codesign --verify --strict /Applications/Tailscale.app || fail 'Tailscale signature verification failed.'

stage '2 of 6 — Connecting Tailscale inside this VM'
if ! tailscale_cli status --json > "$TETHER_GUEST_STATE/tailscale-status.json" 2>/dev/null || \
   [ "$(/usr/bin/plutil -extract BackendState raw -o - "$TETHER_GUEST_STATE/tailscale-status.json" 2>/dev/null || true)" != 'Running' ]; then
    open /Applications/Tailscale.app
    wait_for_user 'Approve Tailscale’s VPN/system extension and sign in to the same tailnet you will use on your iPhone.'
    tailscale_cli status --json > "$TETHER_GUEST_STATE/tailscale-status.json"
fi
check_tailnet || fail 'Finish Tailscale sign-in in this VM, then re-run this step.'
complete tailscale 'Tailscale'
exit 0
fi

if [ "$ACTION" = hermes-install ]; then
stage '3 of 6 — Checking Hermes inside this VM'
HERMES_BIN="$HOME/.hermes/hermes-agent/venv/bin/hermes"
PYTHON_BIN="$HOME/.hermes/hermes-agent/venv/bin/python"
if [ ! -x "$HERMES_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    if [ -e "$HOME/.hermes" ] && [ ! -f "$TETHER_GUEST_STATE/managed-hermes" ]; then
        fail 'Hermes data exists in this VM, but its runtime is incomplete. Repair that installation, then run Tether setup again.'
    fi
    stage '3 of 6 — Installing Hermes inside this VM'
    touch "$TETHER_GUEST_STATE/managed-hermes"
    HERMES_REVISION="$(/usr/bin/plutil -extract hermes_revision raw -o - "$SCRIPT_DIRECTORY/components.json")"
    INSTALLER_URL="$(/usr/bin/plutil -extract hermes_installer_url raw -o - "$SCRIPT_DIRECTORY/components.json")"
    INSTALLER_DIGEST="$(/usr/bin/plutil -extract hermes_installer_sha256 raw -o - "$SCRIPT_DIRECTORY/components.json")"
    curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 15 --max-time 180 "$INSTALLER_URL" -o "$TETHER_GUEST_STATE/hermes-install.sh"
    ACTUAL_DIGEST="$(shasum -a 256 "$TETHER_GUEST_STATE/hermes-install.sh" | awk '{print $1}')"
    [ "$ACTUAL_DIGEST" = "$INSTALLER_DIGEST" ] || fail 'The Hermes installer checksum did not match.'
    if [ ! -f "$TETHER_GUEST_STATE/hermes-installed" ]; then
        printf 'Hermes may spend up to 10 minutes downloading its optional Chromium browser; the upstream installer is quiet during that step.\n'
        /bin/bash "$TETHER_GUEST_STATE/hermes-install.sh" --skip-setup --commit "$HERMES_REVISION"
        touch "$TETHER_GUEST_STATE/hermes-installed"
    fi
fi
[ -x "$HERMES_BIN" ] && [ -x "$PYTHON_BIN" ] || fail 'Hermes is incomplete. Repair it inside this VM, then run setup again.'
install_hermes_command

stage '3 of 6 — Installing Hermes API support'
HERMES_UV="$HOME/.hermes/bin/uv"
[ -x "$HERMES_UV" ] || fail 'Hermes managed uv is missing. Repair the Hermes installation in this VM, then retry.'
"$HERMES_UV" pip install --python "$PYTHON_BIN" -e "$HOME/.hermes/hermes-agent[messaging]"
complete hermes-installed 'Hermes installation'
exit 0
fi

[ -f "$TETHER_GUEST_STATE/hermes-installed.ready" ] || fail 'Complete the Hermes installation step in Tether Guest Installer first.'
HERMES_BIN="$HOME/.hermes/hermes-agent/venv/bin/hermes"
PYTHON_BIN="$HOME/.hermes/hermes-agent/venv/bin/python"
[ -x "$HERMES_BIN" ] && [ -x "$PYTHON_BIN" ] || fail 'Hermes is missing or incomplete. Re-run its installation step.'
install_hermes_command

if [ "$ACTION" = hermes-configure ]; then
stage '4 of 6 — Signing in to Hermes'
"$HERMES_BIN" model
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" configure

stage '4 of 6 — Starting the Hermes gateway'
"$HERMES_BIN" gateway install
"$HERMES_BIN" gateway restart
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" verify-loopback
complete hermes-configured 'Hermes model sign-in and gateway'
exit 0
fi

[ -f "$TETHER_GUEST_STATE/hermes-configured.ready" ] || fail 'Complete Hermes model sign-in and gateway setup first.'

if [ "$ACTION" = computer-use ]; then
stage '5 of 6 — Installing Hermes computer use inside this VM'
printf 'macOS needs CuaDriver Accessibility and Screen & System Audio Recording access.\n'
printf 'When macOS says CuaDriver wants to bypass the private window picker and directly access your screen and audio, click Allow. This lets computer use capture the full guest display without stopping at a window picker.\n'
"$HERMES_BIN" computer-use install
stage '5 of 6 — Requesting direct guest screen access'
if ! "$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" verify-computer-use; then
    stage '5 of 6 — Allow CuaDriver in guest Accessibility'
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' || open -a 'System Settings'
    wait_for_user 'In this VM, open Privacy & Security > Accessibility and enable CuaDriver. If it is absent, use + to add /Applications/CuaDriver.app. Return here after granting access.'
    stage '5 of 6 — Allow CuaDriver in guest Screen Recording'
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' || open -a 'System Settings'
    wait_for_user 'In this VM, open Privacy & Security > Screen & System Audio Recording and enable CuaDriver. If macOS asks to bypass the private window picker and directly access your screen and audio, click Allow. If CuaDriver is absent, use + to add /Applications/CuaDriver.app. Restart the driver if macOS asks, then return here.'
    stage '5 of 6 — Rechecking Accessibility, Screen Recording, and direct capture'
    "$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" verify-computer-use || fail 'CuaDriver still cannot capture and control this VM. Recheck both guest permissions, then retry.'
fi
complete computer-use 'Hermes computer use and permissions'
exit 0
fi

[ -f "$TETHER_GUEST_STATE/computer-use.ready" ] || fail 'Complete the Hermes computer-use step in this VM first.'
TAILSCALE_BIN='/Applications/Tailscale.app/Contents/MacOS/Tailscale'
[ -x "$TAILSCALE_BIN" ] || fail 'Tailscale is missing from this VM. Re-run its step.'
tailscale_cli status --json > "$TETHER_GUEST_STATE/tailscale-status.json" || fail 'Reconnect Tailscale inside this VM.'
check_tailnet || fail 'Reconnect Tailscale inside this VM.'
# A live connected tailnet is authoritative even when Tailscale was configured
# before this installer created its local setup receipts.
/usr/bin/touch "$TETHER_GUEST_STATE/tailscale.ready"

stage '6 of 6 — Verifying private HTTPS, computer use, and model access'
tailscale_cli serve status --json > "$TETHER_GUEST_STATE/serve-before.json"
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" check-serve-before
tailscale_cli serve --bg --https=443 http://127.0.0.1:8642
tailscale_cli serve status --json > "$TETHER_GUEST_STATE/serve-after.json"
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" verify
"$PYTHON_BIN" "$SCRIPT_DIRECTORY/guest_setup.py" show-connection
printf 'Keep Tailscale connected on your phone and this guest.\n'
complete verified 'Tether guest connection'
if ! /bin/bash "$SCRIPT_DIRECTORY/install-clipboard-helper.sh"; then
    printf '\nAutomatic handoff to Tether Host is unavailable. The guest connection is verified; use its displayed URL and token in Tether Host, or retry this step to enable handoff.\n'
fi
