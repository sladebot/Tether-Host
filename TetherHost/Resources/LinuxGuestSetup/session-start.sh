#!/bin/sh
# Desktop autostart runs in the actual logged-in session. Refresh the
# systemd user environment before restarting an already installed gateway.
[ "$(id -u)" -ge 1000 ] || exit 0
[ -f /etc/tether-guest/user ] || [ "$(id -un)" = tether ] || exit 0
if [ -f /etc/tether-guest/user ]; then
    IFS= read -r guest_user < /etc/tether-guest/user || true
    [ "$(id -un)" = "$guest_user" ] || exit 0
fi
[ "${XDG_SESSION_TYPE:-}" = x11 ] && [ -n "${DISPLAY:-}" ] || exit 0
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
if [ -x /opt/tether-guest/keep-awake.sh ]; then
    nohup /opt/tether-guest/keep-awake.sh >/dev/null 2>&1 &
fi
state="$HOME/.local/share/tether-guest"
if [ ! -L "$state" ] && [ ! -L "$state/clipboard-enabled" ] && [ ! -L "$state/clipboard-disabled" ]; then
    umask 077
    mkdir -p "$state"
    chmod 700 "$state"
    if [ ! -f "$state/clipboard-disabled" ]; then
        printf 'enabled\n' > "$state/clipboard-enabled"
        chmod 600 "$state/clipboard-enabled"
    fi
fi
if [ -f "$state/clipboard-enabled" ] && [ -f /opt/tether-guest/clipboard_broker.py ]; then
    /usr/bin/python3 /opt/tether-guest/clipboard_broker.py >/dev/null 2>&1 &
fi
# The user manager can retain variables from an earlier login. Clear them
# before importing the current X11 session, then restart the driver.
systemctl --user unset-environment DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE XDG_CURRENT_DESKTOP || exit 0
set -- DISPLAY XDG_SESSION_TYPE
for name in XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP; do
    eval "value=\${$name:-}"
    if [ -n "$value" ]; then set -- "$@" "$name"; fi
done
systemctl --user import-environment "$@" || exit 0
if systemctl --user cat tether-cua-driver.service >/dev/null 2>&1; then
    systemctl --user restart tether-cua-driver.service >/dev/null 2>&1 || true
fi
gateway="$HOME/.hermes/hermes-agent/venv/bin/hermes"
[ -x "$gateway" ] || exit 0
"$gateway" gateway restart >/dev/null 2>&1 || true
