#!/bin/bash
set -euo pipefail

# Run from Tether Guest Installer.app in the VM's logged-in desktop account.
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
SOURCE="$SCRIPT_DIRECTORY/Tether Guest Clipboard Helper"
SOURCE_PLIST="$SCRIPT_DIRECTORY/app.tether.guest-clipboard.plist"
INSTALL_DIRECTORY="$HOME/Library/Application Support/Tether Host for Mac/Guest Clipboard"
AGENT_DIRECTORY="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIRECTORY/app.tether.guest-clipboard.plist"
LABEL="app.tether.guest-clipboard"

if [[ "$(/usr/sbin/sysctl -n hw.model)" != VirtualMac* ]]; then
    echo "Clipboard sharing can only be installed inside the macOS VM." >&2
    exit 1
fi
if [[ "$(/usr/bin/id -u)" == 0 ]]; then
    echo "Open Tether Guest Installer from the VM desktop user account, not as root." >&2
    exit 1
fi
if [[ ! -x "$SOURCE" || ! -f "$SOURCE_PLIST" ]]; then
    echo "The clipboard helper is missing from this guest installer. Use the latest guest setup disk." >&2
    exit 1
fi

DOMAIN="gui/$(/usr/bin/id -u)"
/bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/mkdir -p -m 700 "$INSTALL_DIRECTORY" "$AGENT_DIRECTORY"
/usr/bin/install -m 700 "$SOURCE" "$INSTALL_DIRECTORY/Tether Guest Clipboard Helper"
/usr/bin/install -m 600 "$SOURCE_PLIST" "$AGENT"
/usr/bin/plutil -lint "$AGENT" >/dev/null
/bin/launchctl bootstrap "$DOMAIN" "$AGENT"
/bin/launchctl kickstart -k "$DOMAIN/$LABEL"
echo "Guest connection handoff is ready. Tether Host can read verified connection details while this VM is running. Clipboard text transfers only when you click a copy button."
