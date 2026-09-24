#!/bin/sh
# Session-only idle inhibitor. Manual Lock, Sign Out, and Shut Down remain available.
set -eu
uid=$(id -u)
[ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] || exit 1
if [ -f /etc/tether-guest/user ]; then
    IFS= read -r guest_user < /etc/tether-guest/user || true
    [ "$(id -un)" = "$guest_user" ] || exit 1
else
    [ "$(id -un)" = tether ] || exit 1
fi
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || exit 1
runtime=${XDG_RUNTIME_DIR:-}
[ "$runtime" = "/run/user/$uid" ] && [ -d "$runtime" ] && [ ! -L "$runtime" ] || exit 1
[ "$(stat -c %u "$runtime")" = "$uid" ] || exit 1
lock="$runtime/tether-keep-awake.lock"
[ ! -L "$lock" ] || exit 1
umask 077
exec 9>"$lock"
# Autostart can be retried by the desktop; only one inhibitor may own this lock.
flock -n 9 || exit 0
# BEGIN_KEEP_AWAKE_DESKTOP
case ${XDG_CURRENT_DESKTOP:-} in
    *GNOME*|*gnome*)
        command -v gnome-session-inhibit >/dev/null 2>&1 || exit 1
        exec gnome-session-inhibit --app-id app.tether.guest \
            --reason 'Tether guest computer use' --inhibit idle:suspend --inhibit-only
        ;;
    *XFCE*|*Xfce*|*xfce*)
        # Xfce's command holds its screensaver inhibit until this process exits.
        command -v xfce4-screensaver-command >/dev/null 2>&1 || exit 1
        exec xfce4-screensaver-command --inhibit
        ;;
esac
exit 1
# END_KEEP_AWAKE_DESKTOP
