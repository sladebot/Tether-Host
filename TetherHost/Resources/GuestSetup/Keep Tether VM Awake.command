#!/bin/bash
set -euo pipefail
umask 077

fail() { printf 'Keep-awake setup stopped: %s\n' "$1" >&2; exit 1; }
case "$(/usr/sbin/sysctl -n hw.model)" in VirtualMac*) ;; *) fail 'Run this only inside the macOS VM.' ;; esac
[ "$(id -u)" -ne 0 ] || fail 'Run as the logged-in guest user, not root.'

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
SOURCE="$SCRIPT_DIRECTORY/app.tether.keep-awake.plist"
DESTINATION="$HOME/Library/LaunchAgents/app.tether.keep-awake.plist"
[ -f "$SOURCE" ] || fail 'The keep-awake service is missing from this setup disk.'
/usr/bin/plutil -lint "$SOURCE" >/dev/null || fail 'The keep-awake service is invalid.'
/bin/mkdir -p "$HOME/Library/LaunchAgents"
/usr/bin/install -m 600 "$SOURCE" "$DESTINATION"

SERVICE="gui/$(id -u)/app.tether.keep-awake"
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
    /bin/launchctl bootout "$SERVICE"
fi
/bin/launchctl bootstrap "gui/$(id -u)" "$DESTINATION"
/bin/launchctl print "$SERVICE" >/dev/null || fail 'The keep-awake service did not start.'

# The guest must stay visible for remote computer use. This does not bypass a
# manual lock, logout, FileVault unlock, or a host shutdown.
/usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 0
printf 'Guest idle sleep and display sleep are disabled while you are logged in.\n'
printf 'The automatic screen saver is disabled for this guest user.\n'
