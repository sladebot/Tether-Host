#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CURRENT_STAGE=setup
ERROR_REPORTED=0
emit() { printf 'TETHER_STAGE\t%s\t%s\t%s\n' "$CURRENT_STAGE" "$1" "$2"; }
die() {
    printf 'Debian guest setup stopped: %s\n' "$1" >&2
    emit error "$1" >&2
    ERROR_REPORTED=1
    exit 1
}
on_error() {
    local status="$1" line="$2"
    if [[ "$ERROR_REPORTED" != 1 ]]; then
        printf 'Debian guest setup command failed at line %s (exit %s).\n' "$line" "$status" >&2
        emit error "A setup command failed (exit $status). See Details and retry this step." >&2
    fi
    exit "$status"
}
trap 'on_error "$?" "$LINENO"' ERR

ACTION="${1:-all}"
case "$ACTION" in
    all|internet|tailscale|hermes-install|hermes-configure|computer-use|verify) ;;
    *) die 'Choose a supported guest setup step.' ;;
esac
[[ $# -le 1 ]] || die 'Choose one guest setup step at a time.'
[[ "$(id -u)" != 0 && "$(id -u)" -ge 1000 ]] || die 'Log in as your normal Debian desktop user and run this without sudo.'
if [[ -f /etc/tether-guest/user ]]; then
    read -r guest_user < /etc/tether-guest/user || true
    [[ "$(id -un)" == "$guest_user" ]] || die 'Run setup as the Debian account that installed guest tools.'
elif [[ "$(id -un)" != tether ]]; then
    die 'Install Tether guest tools for your account before running setup.'
fi
[[ "$(. /etc/os-release; printf '%s' "$ID")" == debian ]] || die 'This setup is for the Debian guest only.'
systemd-detect-virt --quiet || die 'Refusing to configure a physical Debian host.'
[[ -t 0 ]] || die 'Run this from the Debian installer console so sign-in can be completed.'

ROOT=/opt/tether-guest
STATE="$HOME/.local/share/tether-guest"
mkdir -p "$STATE"
chmod 700 "$STATE"
exec 9>"$STATE/setup.lock"
flock -n 9 || die 'Guest setup is already running.'
hermes="$HOME/.hermes/hermes-agent/venv/bin/hermes"
python="$HOME/.hermes/hermes-agent/venv/bin/python"

invalidate_from() {
    local seen=0 item
    for item in internet tailscale hermes-install hermes-configure computer-use verify; do
        [[ "$item" == "$1" ]] && seen=1
        if [[ "$seen" == 1 ]]; then rm -f "$STATE/$item.ready"; fi
    done
    rm -f "$STATE/connection.json"
}
start_stage() {
    CURRENT_STAGE="$1"
    ERROR_REPORTED=0
    invalidate_from "$1"
    emit start "$2"
    printf '\n%s\n' "$2"
}
finish_stage() {
    touch "$STATE/$CURRENT_STAGE.ready"
    emit done "$1"
}
require_stage() {
    [[ -f "$STATE/$1.ready" ]] || die "Complete the $1 step first."
}
check_internet() {
    ip -4 route get 1.1.1.1 >/dev/null 2>&1 || die 'The VM has no IPv4 route. Check its virtual network connection.'
    if ! getent ahostsv4 pkgs.tailscale.com >/dev/null 2>&1; then
        printf 'Guest DNS is unavailable; checking the Tether DNS recovery helper.\n'
        sudo "$ROOT/dns-fallback.sh" || die 'Guest DNS recovery failed. Check the VM network and retry.'
        getent ahostsv4 pkgs.tailscale.com >/dev/null 2>&1 || die 'The VM still cannot resolve package servers.'
    fi
    curl --proto '=https' --tlsv1.2 -fIsS --connect-timeout 10 --max-time 20 \
        https://pkgs.tailscale.com/stable/ >/dev/null || die 'The VM resolves package servers but cannot reach them over HTTPS.'
}
run_internet() {
    start_stage internet 'Checking Internet inside this Debian VM'
    check_internet
    finish_stage 'Guest DNS and HTTPS are working.'
}
run_tailscale() {
    start_stage tailscale 'Installing and connecting Tailscale'
    require_stage internet
    check_internet
    if ! command -v tailscale >/dev/null; then
        local codename key list
        codename="$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")"
        [[ "$codename" =~ ^[a-z]+$ ]] || die 'Debian release codename is invalid.'
        key="$STATE/tailscale.noarmor.gpg"
        list="$STATE/tailscale.list"
        curl --proto '=https' --tlsv1.2 -fLsS --retry 2 \
            "https://pkgs.tailscale.com/stable/debian/${codename}.noarmor.gpg" -o "$key"
        curl --proto '=https' --tlsv1.2 -fLsS --retry 2 \
            "https://pkgs.tailscale.com/stable/debian/${codename}.tailscale-keyring.list" -o "$list"
        grep -Fq 'signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg' "$list" || die 'Tailscale package source was unexpected.'
        sudo install -m 0644 "$key" /usr/share/keyrings/tailscale-archive-keyring.gpg
        sudo install -m 0644 "$list" /etc/apt/sources.list.d/tailscale.list
        sudo apt-get update
        sudo apt-get install -y tailscale
    fi
    sudo systemctl enable --now tailscaled
    if [[ "$(tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))')" != Running ]]; then
        printf 'Complete the Tailscale sign-in URL shown below, then return here.\n'
        sudo tailscale up
    fi
    [[ "$(tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))')" == Running ]] || die 'Tailscale is not connected.'
    sudo tailscale set --operator="$(id -un)"
    finish_stage 'Tailscale is connected.'
}
is_hermes_command() {
    local command_path="$1"
    [[ -x "$command_path" ]] || return 1
    [[ "$command_path" -ef "$hermes" ]] && return 0
    # The upstream installer publishes a shell wrapper rather than a symlink.
    # Compare the whole file: a path mention alone must not approve extra code.
    [[ -f "$command_path" && ! -L "$command_path" ]] || return 1
    cmp -s "$command_path" <(printf '#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\nexec "%s" "$@"\n' "$hermes") && return 0
    cmp -s "$command_path" <(printf '#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\nexec "%s" "%s" "$@"\n' \
        "$python" "$HOME/.hermes/hermes-agent/hermes")
}
ensure_hermes_command() {
    local command_path="$HOME/.local/bin/hermes" profile mode
    mkdir -p "$HOME/.local/bin"
    if [[ -e "$command_path" || -L "$command_path" ]]; then
        is_hermes_command "$command_path" ||
            die 'The existing ~/.local/bin/hermes command does not point to this Hermes installation. Repair it, then retry.'
    else
        ln -s "$hermes" "$command_path"
    fi
    profile="$HOME/.profile"
    if [[ -f "$HOME/.bash_profile" ]]; then
        profile="$HOME/.bash_profile"
    elif [[ -f "$HOME/.bash_login" ]]; then
        profile="$HOME/.bash_login"
    fi
    if ! grep -Fq '# Tether Hermes command' "$profile" 2>/dev/null; then
        printf '\n# Tether Hermes command\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$profile"
    fi
    if ! grep -Fq '# Tether Hermes command' "$HOME/.bashrc" 2>/dev/null; then
        printf '\n# Tether Hermes command\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
    fi
    for mode in -lc -ic; do
        PATH=/usr/local/bin:/usr/bin:/bin /bin/bash "$mode" \
            '[[ $(command -v hermes) == "$HOME/.local/bin/hermes" ]]' ||
            die 'Hermes installed, but a fresh Bash shell cannot find the correct hermes command.'
    done
}
run_hermes_install() {
    start_stage hermes-install 'Installing Hermes'
    require_stage internet
    check_internet
    if [[ ! -x "$hermes" || ! -x "$python" ]]; then
        [[ ! -e "$HOME/.hermes" || -f "$STATE/managed-hermes" ]] ||
            die 'Existing Hermes data is incomplete; repair it before rerunning setup.'
        touch "$STATE/managed-hermes"
        local revision url digest
        revision="$(python3 -c 'import json;print(json.load(open("/opt/tether-guest/components.json"))["hermes_revision"])')"
        url="$(python3 -c 'import json;print(json.load(open("/opt/tether-guest/components.json"))["hermes_installer_url"])')"
        digest="$(python3 -c 'import json;print(json.load(open("/opt/tether-guest/components.json"))["hermes_installer_sha256"])')"
        [[ "$revision" =~ ^[a-f0-9]{40}$ && "$digest" =~ ^[a-f0-9]{64}$ ]] || die 'Pinned Hermes component data is invalid.'
        curl --proto '=https' --tlsv1.2 -fLsS --retry 2 "$url" -o "$STATE/hermes-install.sh"
        printf '%s  %s\n' "$digest" "$STATE/hermes-install.sh" | sha256sum -c - || die 'Hermes installer checksum did not match.'
        bash "$STATE/hermes-install.sh" --skip-setup --skip-browser --commit "$revision"
    fi
    [[ -x "$hermes" && -x "$python" ]] || die 'Hermes did not install correctly.'
    [[ -x "$HOME/.hermes/bin/uv" ]] || die 'Hermes managed uv is missing.'
    "$HOME/.hermes/bin/uv" pip install --python "$python" -e "$HOME/.hermes/hermes-agent[messaging]"
    "$HOME/.hermes/bin/uv" cache clean >/dev/null 2>&1 || true
    sudo -n fstrim -av >/dev/null 2>&1 || true
    ensure_hermes_command
    finish_stage 'Hermes and its command are installed.'
}
run_hermes_configure() {
    start_stage hermes-configure 'Signing in to the model and starting Hermes'
    require_stage hermes-install
    [[ -x "$hermes" && -x "$python" ]] || die 'Hermes is missing. Retry its installation step.'
    "$hermes" model
    "$python" "$ROOT/linux_guest_setup.py" configure
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        [[ -z "${DISPLAY:-}" ]] || systemctl --user import-environment DISPLAY
        [[ -z "${WAYLAND_DISPLAY:-}" ]] || systemctl --user import-environment WAYLAND_DISPLAY
        [[ -z "${XAUTHORITY:-}" ]] || systemctl --user import-environment XAUTHORITY
        [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || systemctl --user import-environment DBUS_SESSION_BUS_ADDRESS
        [[ -z "${XDG_SESSION_TYPE:-}" ]] || systemctl --user import-environment XDG_SESSION_TYPE
    fi
    "$hermes" gateway install
    "$hermes" gateway restart
    finish_stage 'Model sign-in and Hermes gateway are configured.'
}
run_computer_use() {
    start_stage computer-use 'Checking Debian desktop computer use'
    require_stage hermes-configure
    printf 'Checking Chromium for desktop computer use…\n'
    command -v chromium >/dev/null 2>&1 ||
        die 'Chromium is missing. Run Prepare guest tools again to install the Debian browser.'
    timeout 30 chromium --version ||
        die 'Chromium could not start. Run Prepare guest tools again, then retry Enable computer use.'
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] ||
        die 'A graphical Debian session is needed for computer use. Log into the desktop, then retry.'
    if [[ -n "${DISPLAY:-}" ]] && ! systemctl --user show-environment | grep -Fq "DISPLAY=$DISPLAY"; then
        die 'The Hermes user service cannot see the desktop display. Log out, log back in, and retry.'
    fi
    "$hermes" computer-use install
    if [[ "${XDG_SESSION_TYPE:-}" == wayland && -n "${WAYLAND_DISPLAY:-}" ]]; then
        printf 'Debian may ask to allow screenshots for computer use. Choose Allow in the desktop prompt, then return here.\n'
    fi
    "$python" "$ROOT/linux_guest_setup.py" start-computer-use
    "$hermes" computer-use doctor
    finish_stage 'Computer use passed its checks.'
}
run_verify() {
    start_stage verify 'Verifying the private guest connection'
    require_stage tailscale
    require_stage computer-use
    [[ "$(tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin).get("BackendState",""))')" == Running ]] ||
        die 'Tailscale disconnected. Reconnect it, then retry.'
    [[ -x "$python" ]] || die 'Hermes runtime is missing. Retry installation.'
    tailscale serve --bg --https=443 http://127.0.0.1:8642
    "$python" "$ROOT/linux_guest_setup.py" verify
    "$python" "$ROOT/linux_guest_setup.py" show-connection
    finish_stage 'The private guest connection is verified.'
    printf '\nDebian guest connection verified. Tether Host still checks HTTPS and Hermes independently.\n'
}

if [[ "$ACTION" == all ]]; then
    run_internet
    run_tailscale
    run_hermes_install
    run_hermes_configure
    run_computer_use
    run_verify
else
    case "$ACTION" in
        internet) run_internet ;;
        tailscale) run_tailscale ;;
        hermes-install) run_hermes_install ;;
        hermes-configure) run_hermes_configure ;;
        computer-use) run_computer_use ;;
        verify) run_verify ;;
    esac
fi
