#!/bin/bash
set -euo pipefail
umask 077

# Run from Tether Guest Installer.app in the VM's logged-in desktop account.
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
SOURCE="$SCRIPT_DIRECTORY/Tether Guest Clipboard Helper"
SOURCE_PLIST="$SCRIPT_DIRECTORY/app.tether.guest-clipboard.plist"
INSTALL_DIRECTORY="$HOME/Library/Application Support/Tether Host for Mac/Guest Clipboard"
AGENT_DIRECTORY="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIRECTORY/app.tether.guest-clipboard.plist"
LABEL="app.tether.guest-clipboard"
HANDOFF_STATE="$HOME/Library/Application Support/Tether Host for Mac/Guest Setup"
HANDOFF_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SCRIPT_DIRECTORY/../Info.plist")"

if [[ "$(/usr/sbin/sysctl -n hw.model)" != VirtualMac* ]]; then
    echo "Clipboard sharing can only be installed inside the macOS VM." >&2
    exit 1
fi
if [[ "$(/usr/bin/id -u)" == 0 ]]; then
    echo "Open Tether Guest Installer from the VM desktop user account, not as root." >&2
    exit 1
fi
/bin/mkdir -p -m 700 "$HANDOFF_STATE"
/bin/chmod 700 "$HANDOFF_STATE"
/bin/rm -f "$HANDOFF_STATE/handoff.ready" "$HANDOFF_STATE/handoff.failed"
record_handoff_result() {
    result=$?
    if [[ "$result" -eq 0 ]]; then
        printf '%s\n' "$HANDOFF_VERSION" > "$HANDOFF_STATE/handoff.ready"
    else
        printf '%s\n' 'Automatic host handoff needs attention. Use Retry host handoff in the guest installer.' > "$HANDOFF_STATE/handoff.failed"
    fi
}
trap record_handoff_result EXIT
if [[ ! -x "$SOURCE" || ! -f "$SOURCE_PLIST" ]]; then
    echo "The clipboard helper is missing from this guest installer. Use the latest guest setup disk." >&2
    exit 1
fi

DOMAIN="gui/$(/usr/bin/id -u)"
/bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/mkdir -p -m 700 "$INSTALL_DIRECTORY" "$AGENT_DIRECTORY"
/usr/bin/install -m 700 "$SOURCE" "$INSTALL_DIRECTORY/Tether Guest Clipboard Helper"
/usr/bin/install -m 600 "$SOURCE_PLIST" "$AGENT"
# launchd does not guarantee HOME in a LaunchAgent's environment. Store the
# guest user's exact executable path and start it directly, without a shell.
/usr/libexec/PlistBuddy -c 'Delete :ProgramArguments' "$AGENT"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$AGENT"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $INSTALL_DIRECTORY/Tether Guest Clipboard Helper" "$AGENT"
/usr/bin/plutil -lint "$AGENT" >/dev/null
/bin/launchctl bootstrap "$DOMAIN" "$AGENT"
/bin/launchctl kickstart -k "$DOMAIN/$LABEL"
/bin/sleep 1
HELPER_RUNNING=0
for _ in 1 2 3 4 5; do
    if /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null | /usr/bin/grep -qE '^[[:space:]]*state = running$'; then
        HELPER_RUNNING=1
        break
    fi
    /bin/sleep 1
done
if [[ "$HELPER_RUNNING" -ne 1 ]]; then
    echo "The guest helper did not stay running. Check the VM's system log, then retry host handoff." >&2
    exit 1
fi
echo "Guest connection handoff is ready. Tether Host can read verified connection details while this VM is running. Clipboard text transfers only when you click a copy button."
