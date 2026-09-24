#!/bin/sh
# Optional manual switch; setup enables explicit transfers by default.
set -eu
message() {
  if command -v zenity >/dev/null 2>&1; then
    zenity --info --title='Tether Text Clipboard' --text="$1" 2>/dev/null || true
  else
    printf '%s\n' "$1"
  fi
}
if [ "$(id -u)" -lt 1000 ] || [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  message 'Log in to the Ubuntu desktop as your guest user first.'
  exit 1
fi
if [ -f /etc/tether-guest/user ]; then
  IFS= read -r guest_user < /etc/tether-guest/user || true
  [ "$(id -un)" = "$guest_user" ] || { message 'This switch is for the configured guest user.'; exit 1; }
elif [ "$(id -un)" != tether ]; then
  message 'Guest tools are not installed for this user.'
  exit 1
fi
state="$HOME/.local/share/tether-guest"
enabled="$state/clipboard-enabled"
disabled="$state/clipboard-disabled"
if [ -L "$state" ] || [ -L "$enabled" ] || [ -L "$disabled" ]; then
  message 'The Tether guest settings path is unsafe.'
  exit 1
fi
umask 077
mkdir -p "$state"
chmod 700 "$state"
if [ -f "$enabled" ]; then
  rm -- "$enabled"
  printf 'disabled\n' > "$disabled"
  chmod 600 "$disabled"
  message 'Tether text clipboard transfers are off. Open this switch again to turn them on.'
else
  rm -f -- "$disabled"
  printf 'enabled\n' > "$enabled"
  chmod 600 "$enabled"
  if [ -f /opt/tether-guest/clipboard_broker.py ]; then
    /usr/bin/python3 /opt/tether-guest/clipboard_broker.py >/dev/null 2>&1 &
  fi
  message 'Tether text clipboard transfers are on. Text moves only when you choose a clipboard button in Tether Host.'
fi
