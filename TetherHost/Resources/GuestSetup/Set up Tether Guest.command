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
DNS_OVERRIDE_SERVICE=''
DNS_ORIGINAL_SERVERS=''
restore_guest_dns() {
    [ -n "$DNS_OVERRIDE_SERVICE" ] || return 0
    local service="$DNS_OVERRIDE_SERVICE"
    local original="$DNS_ORIGINAL_SERVERS"
    local servers=()
    if [[ "$original" == "There aren't any DNS Servers set on "* ]]; then
        servers=(Empty)
    else
        while IFS= read -r server; do
            [ -n "$server" ] && servers+=("$server")
        done <<< "$original"
    fi
    if [ "${#servers[@]}" -eq 0 ]; then servers=(Empty); fi
    /usr/bin/sudo /usr/sbin/networksetup -setdnsservers "$service" "${servers[@]}" || {
        printf 'Could not restore DNS for %s. Restore it in System Settings > Network > DNS.\n' "$service" >&2
        return 1
    }
    DNS_OVERRIDE_SERVICE=''
}
cleanup() {
    result=$?
    restore_guest_dns || result=1
    rmdir "$TETHER_GUEST_STATE/running.lock" 2>/dev/null || true
    if [ "$result" -ne 0 ]; then
        printf '%s\n' "Stopped during: $CURRENT_STAGE. Fix the error above, then run setup again." > "$TETHER_GUEST_STATE/status.txt"
    fi
    exit "$result"
}
trap cleanup EXIT
# Any changed guest dependency requires a fresh final verification.
if [ "$ACTION" != internet ]; then rm -f "$TETHER_GUEST_STATE/connection.json" "$TETHER_GUEST_STATE/verified.ready"; fi
# A retry must not leave a previous completion receipt behind after failure.
# Invalidate dependent steps before changing their prerequisites.
case "$ACTION" in
    internet) rm -f "$TETHER_GUEST_STATE/internet.ready" ;;
    tailscale) rm -f "$TETHER_GUEST_STATE/tailscale.ready" ;;
    hermes-install) rm -f "$TETHER_GUEST_STATE/hermes-installed.ready" "$TETHER_GUEST_STATE/hermes-configured.ready" "$TETHER_GUEST_STATE/computer-use.ready" ;;
    hermes-configure) rm -f "$TETHER_GUEST_STATE/hermes-configured.ready" "$TETHER_GUEST_STATE/computer-use.ready" ;;
    computer-use) rm -f "$TETHER_GUEST_STATE/computer-use.ready" ;;
esac
stage() { CURRENT_STAGE="$1"; printf '\n%s\n' "$1"; printf '%s\n' "$1" > "$TETHER_GUEST_STATE/status.txt"; }
wait_for_user() { printf '\n%s\nPress Return when finished, or Control-C to stop. ' "$1"; read -r _; }
check_guest_https() {
    /usr/bin/curl --proto '=https' --tlsv1.2 -sSI --connect-timeout 10 --max-time 20 "$1" > /dev/null 2>&1
}
guest_name_resolves() {
    /usr/bin/dscacheutil -q host -a name "$1" 2>/dev/null | /usr/bin/grep -q '^ip_address:'
}
guest_vpn_active() {
    local tailscale_bin='/Applications/Tailscale.app/Contents/MacOS/Tailscale'
    if [ -x "$tailscale_bin" ] &&
       /usr/bin/env TAILSCALE_BE_CLI=1 "$tailscale_bin" status --json 2>/dev/null |
           /usr/bin/plutil -extract BackendState raw -o - - 2>/dev/null | /usr/bin/grep -qx Running; then
        return 0
    fi
    /usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/grep -q '(Connected)' && return 0
    /usr/sbin/scutil --dns 2>/dev/null | /usr/bin/grep -q SupplementalMatchDomains && return 0
    return 1
}
ensure_guest_download_dns() {
    local hostname="$1"
    local url="$2"
    local interface ip service
    if check_guest_https "$url"; then return 0; fi
    if guest_name_resolves "$hostname"; then
        fail "The VM resolves $hostname but cannot reach it over HTTPS. Check the guest network, then retry."
    fi
    interface="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '$1 == "interface:" { print $2; exit }')"
    case "$interface" in en[0-9]*) ;; *) fail 'The VM has no Ethernet default route for DNS recovery. Check its network settings, then retry.' ;; esac
    ip="$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)"
    [ -n "$ip" ] || fail 'The VM has no Ethernet address. Check its network settings, then retry.'
    /usr/bin/nslookup "$hostname" 1.1.1.1 > /dev/null 2>&1 ||
        fail "The VM cannot reach a direct DNS server for $hostname. Check its network settings, then retry."
    guest_vpn_active && fail 'The VM has an active VPN or split DNS policy. Check its DNS settings without replacing the VPN resolver, then retry.'
    service="$(/usr/sbin/networksetup -listnetworkserviceorder | /usr/bin/awk -v device="$interface" '
        /^\([0-9]+\) / { service = $0; sub(/^\([0-9]+\) /, "", service) }
        index($0, "Device: " device ")") { print service; exit }
    ')"
    [ -n "$service" ] || fail 'Could not identify the VM Ethernet service for DNS recovery.'
    DNS_ORIGINAL_SERVERS="$(/usr/sbin/networksetup -getdnsservers "$service")" || fail 'Could not read the VM Ethernet DNS settings.'
    printf 'The VM DNS server cannot resolve %s. Using Cloudflare DNS temporarily for this step; the previous setting will be restored.\n' "$hostname"
    /usr/bin/sudo /usr/sbin/networksetup -setdnsservers "$service" 1.1.1.1 || fail 'Could not set temporary guest DNS.'
    DNS_OVERRIDE_SERVICE="$service"
    for attempt in 1 2 3; do
        if check_guest_https "$url"; then return 0; fi
        /bin/sleep 2
    done
    fail "The VM still cannot reach $hostname over HTTPS. Check its network settings, then retry."
}
check_tailnet() {
    [ "$(/usr/bin/plutil -extract BackendState raw -o - "$TETHER_GUEST_STATE/tailscale-status.json" 2>/dev/null || true)" = Running ] || return 1
    TAILNET_NAME="$(/usr/bin/plutil -extract Self.DNSName raw -o - "$TETHER_GUEST_STATE/tailscale-status.json" 2>/dev/null || true)"
    [[ "$TAILNET_NAME" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+\.ts\.net\.$ ]]
}
tailscale_cli() {
    /usr/bin/env TAILSCALE_BE_CLI=1 "$TAILSCALE_BIN" "$@"
}
is_hermes_command() {
    local command_path="$1"
    [ -x "$command_path" ] || return 1
    [ "$command_path" -ef "$HERMES_BIN" ] && return 0
    # The upstream installer may publish a shell wrapper instead of a symlink.
    [ -f "$command_path" ] && [ ! -L "$command_path" ] || return 1
    /usr/bin/cmp -s "$command_path" <(printf '#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\nexec "%s" "$@"\n' "$HERMES_BIN") && return 0
    /usr/bin/cmp -s "$command_path" <(printf '#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\nexec "%s" "%s" "$@"\n' \
        "$PYTHON_BIN" "$HOME/.hermes/hermes-agent/hermes")
}
install_hermes_command() {
    local command_directory="$HOME/.local/bin"
    local command_path="$command_directory/hermes"
    local shell_profile="$HOME/.zprofile"
    /bin/mkdir -p "$command_directory"
    if [ -e "$command_path" ] || [ -L "$command_path" ]; then
        is_hermes_command "$command_path" ||
            fail 'The existing ~/.local/bin/hermes command does not point to this Hermes installation. Repair it, then retry.'
    else
        /bin/ln -s "$HERMES_BIN" "$command_path"
    fi
    if ! /usr/bin/grep -Fq '# Tether Hermes command' "$shell_profile" 2>/dev/null; then
        printf '\n# Tether Hermes command\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$shell_profile"
    fi
}
complete() {
    restore_guest_dns || fail 'Could not restore the guest DNS setting after this step.'
    printf '%s\n' "Completed: $2" > "$TETHER_GUEST_STATE/status.txt"
    /usr/bin/touch "$TETHER_GUEST_STATE/$1.ready"
    printf '\n%s\n' "$2 is complete. Return to Tether Guest Installer for the next step."
}

if [ "$ACTION" = internet ]; then
stage '1 of 6 — Keeping this macOS VM awake'
/bin/bash "$SCRIPT_DIRECTORY/Keep Tether VM Awake.command"

stage '1 of 6 — Checking Internet inside this VM'
ensure_guest_download_dns pkgs.tailscale.com https://pkgs.tailscale.com/stable/
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
    ensure_guest_download_dns pkgs.tailscale.com https://pkgs.tailscale.com/stable/
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
    ensure_guest_download_dns raw.githubusercontent.com "$INSTALLER_URL"
    curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 15 --max-time 180 "$INSTALLER_URL" -o "$TETHER_GUEST_STATE/hermes-install.sh"
    ACTUAL_DIGEST="$(shasum -a 256 "$TETHER_GUEST_STATE/hermes-install.sh" | awk '{print $1}')"
    [ "$ACTUAL_DIGEST" = "$INSTALLER_DIGEST" ] || fail 'The Hermes installer checksum did not match.'
    # The runtime checks above are authoritative. A historical installation
    # marker must not prevent repair of an incomplete managed installation.
    printf 'Hermes may spend up to 10 minutes downloading its optional Chromium browser; the upstream installer is quiet during that step.\n'
    /bin/bash "$TETHER_GUEST_STATE/hermes-install.sh" --skip-setup --commit "$HERMES_REVISION"
    touch "$TETHER_GUEST_STATE/hermes-installed"
fi
[ -x "$HERMES_BIN" ] && [ -x "$PYTHON_BIN" ] || fail 'Hermes is incomplete. Repair it inside this VM, then run setup again.'
install_hermes_command

stage '3 of 6 — Installing Hermes API support'
HERMES_UV="$HOME/.hermes/bin/uv"
[ -x "$HERMES_UV" ] || fail 'Hermes managed uv is missing. Repair the Hermes installation in this VM, then retry.'
ensure_guest_download_dns pypi.org https://pypi.org/simple/
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
