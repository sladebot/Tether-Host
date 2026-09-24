#!/bin/sh
# Install or update guest tools from the read-only Tether tools ISO:
#   sudo sh /path/to/update-guest-tools.sh
set -eu

fail() { printf '%s\n' "$1" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail 'Run this installer with sudo inside the Ubuntu VM.'
. /etc/os-release
[ "${ID:-}" = ubuntu ] || fail 'This installer is for Ubuntu only.'
systemd-detect-virt --quiet || fail 'Refusing to configure a physical Ubuntu host.'

# sudo and pkexec record who explicitly requested installation. Never infer
# the owner from a writable home directory or display environment.
guest_user=${SUDO_USER:-}
guest_uid=${SUDO_UID:-}
if [ -n "${PKEXEC_UID:-}" ]; then
  case "$PKEXEC_UID" in *[!0-9]*|'') fail 'pkexec did not identify a normal local Ubuntu account.' ;; esac
  [ "$PKEXEC_UID" -ge 1000 ] && [ "$PKEXEC_UID" -lt 65534 ] ||
    fail 'Run pkexec from a normal local Ubuntu account.'
  [ -z "$guest_uid" ] || [ "$guest_uid" = "$PKEXEC_UID" ] ||
    fail 'sudo and pkexec identified different Ubuntu accounts.'
  guest_uid=$PKEXEC_UID
  pkexec_account=$(getent passwd "$guest_uid") || fail 'The invoking Ubuntu account was not found.'
  IFS=: read -r pkexec_user _ pkexec_uid _ _ _ _ <<EOF
$pkexec_account
EOF
  [ "$pkexec_uid" = "$guest_uid" ] || fail 'pkexec account lookup did not match its UID.'
  [ -z "$guest_user" ] || [ "$guest_user" = "$pkexec_user" ] ||
    fail 'sudo and pkexec identified different Ubuntu accounts.'
  guest_user=$pkexec_user
fi
case "$guest_user" in
  ''|*[!a-zA-Z0-9_.-]*) fail 'Run sudo or pkexec from a normal local Ubuntu account.' ;;
esac
case "$guest_uid" in
  ''|*[!0-9]*) fail 'Privilege escalation did not identify a normal local Ubuntu account.' ;;
esac
[ "$guest_uid" -ge 1000 ] && [ "$guest_uid" -lt 65534 ] || fail 'Run sudo from a normal local Ubuntu account.'
account=$(getent passwd "$guest_user") || fail 'The invoking Ubuntu account was not found.'
IFS=: read -r account_name _ account_uid account_gid _ account_home _ <<EOF
$account
EOF
[ "$account_name" = "$guest_user" ] && [ "$account_uid" = "$guest_uid" ] &&
  [ -d "$account_home" ] && [ "$(stat -c %u "$account_home")" = "$guest_uid" ] ||
  fail 'The invoking Ubuntu account does not match privilege escalation.'

service_user=$(systemctl show -p User --value tether-vsock.service 2>/dev/null || true)
[ -z "$service_user" ] || [ "$service_user" = "$guest_user" ] ||
  fail 'Guest tools already belong to a different Ubuntu account.'
if [ -e /etc/tether-guest ] || [ -L /etc/tether-guest ]; then
  [ ! -L /etc/tether-guest ] && [ -d /etc/tether-guest ] &&
    [ "$(stat -c '%u:%a' /etc/tether-guest)" = '0:755' ] ||
    fail 'The guest account directory is unsafe.'
fi
if [ -e /etc/tether-guest/user ] || [ -L /etc/tether-guest/user ]; then
  [ ! -L /etc/tether-guest/user ] || fail 'The guest account record is unsafe.'
  [ "$(stat -c '%u:%a' /etc/tether-guest/user)" = '0:644' ] ||
    fail 'The guest account record has unexpected ownership or permissions.'
  recorded_user=$(cat /etc/tether-guest/user)
  [ "$recorded_user" = "$guest_user" ] || fail 'Guest tools already belong to a different Ubuntu account.'
fi

source_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
for name in update-guest-tools.sh vsock_helper.py clipboard_broker.py clipboard-toggle.sh session-start.sh keep-awake.sh setup.sh dns-fallback.sh linux_guest_setup.py guest_installer.py installer_flow.py installer_logging.py components.json; do
  [ -f "$source_dir/$name" ] && [ ! -L "$source_dir/$name" ] ||
    fail "Missing guest installer file: $name"
done

# A fresh manually installed Ubuntu image may still be named localhost. Name
# only that placeholder before its first tailnet join; upgrades and custom
# machine names must retain their existing identity.
is_fresh_placeholder_hostname() {
  printf '%s\n' "$1" | grep -Eq '^localhost(-[0-9]+)?$' && [ ! -s "$2" ]
}
if is_fresh_placeholder_hostname "$(hostname -s)" /var/lib/tailscale/tailscaled.state; then
  hostnamectl set-hostname ubuntu-tether-vm ||
    fail 'Could not name this fresh Ubuntu VM. Check hostnamectl and retry.'
fi

# The VM's DHCP DNS forwarder may be unavailable when the host uses a VPN.
# Repair DNS before apt needs it, while preserving working DHCP or Tailscale DNS.
install -d -m 0755 /opt/tether-guest
if [ "$source_dir" != /opt/tether-guest ]; then
  install -m 0755 "$source_dir/dns-fallback.sh" /opt/tether-guest/dns-fallback.sh
fi
/opt/tether-guest/dns-fallback.sh

apt-get update -o APT::Update::Error-Mode=any -o Acquire::Retries=3
env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
  apt-get install -y --no-install-recommends ca-certificates curl jq python3 python3-venv python3-yaml python3-gi gir1.2-gtk-3.0 gir1.2-vte-2.91 dbus-x11 at-spi2-core xdg-utils xclip snapd

# Chromium is Canonical's stable, confined snap on Ubuntu. Keep this visible
# in the installer bootstrap log and leave the user's default browser alone.
# BEGIN_CHROMIUM_INSTALL
install_chromium() {
  printf '%s\n' 'Preparing Ubuntu snap service for Chromium…'
  systemctl enable --now snapd.socket ||
    fail 'Could not start snapd. Check the Ubuntu snapd.socket service, then retry Prepare guest tools.'
  printf '%s\n' 'Waiting for Ubuntu snap setup (up to 5 minutes)…'
  timeout --foreground 300s snap wait system seed.loaded ||
    fail 'Ubuntu snap setup did not finish within 5 minutes. Check snapd and Internet access, then retry Prepare guest tools.'
  if snap list chromium >/dev/null 2>&1; then
    printf '%s\n' 'Chromium is already installed in this Ubuntu VM.'
  else
    printf '%s\n' 'Installing Chromium from the official stable snap channel (up to 20 minutes)…'
    timeout --foreground 1200s snap install chromium --channel=stable ||
      fail 'Chromium installation failed or timed out. Check guest Internet and snapd, then retry Prepare guest tools.'
  fi
  snap list chromium >/dev/null 2>&1 ||
    fail 'Chromium is not available after installation. Check snapd, then retry Prepare guest tools.'
  printf '%s\n' 'Chromium is ready for guest computer use.'
}
# END_CHROMIUM_INSTALL
install_chromium

install -d -m 0755 /opt/tether-guest /etc/tether-guest
if [ "$source_dir" != /opt/tether-guest ]; then
  install -m 0755 "$source_dir/update-guest-tools.sh" /opt/tether-guest/update-guest-tools.sh
  install -m 0755 "$source_dir/vsock_helper.py" /opt/tether-guest/vsock_helper.py
  install -m 0755 "$source_dir/clipboard_broker.py" /opt/tether-guest/clipboard_broker.py
  install -m 0755 "$source_dir/clipboard-toggle.sh" /opt/tether-guest/clipboard-toggle.sh
  install -m 0755 "$source_dir/session-start.sh" /opt/tether-guest/session-start.sh
  install -m 0755 "$source_dir/keep-awake.sh" /opt/tether-guest/keep-awake.sh
  install -m 0755 "$source_dir/setup.sh" /opt/tether-guest/setup.sh
  install -m 0755 "$source_dir/linux_guest_setup.py" /opt/tether-guest/linux_guest_setup.py
  install -m 0755 "$source_dir/guest_installer.py" /opt/tether-guest/guest_installer.py
  install -m 0644 "$source_dir/installer_flow.py" /opt/tether-guest/installer_flow.py
  install -m 0644 "$source_dir/installer_logging.py" /opt/tether-guest/installer_logging.py
  install -m 0644 "$source_dir/components.json" /opt/tether-guest/components.json
  if [ -f "$source_dir/installer-version.json" ] && [ ! -L "$source_dir/installer-version.json" ]; then
    install -m 0644 "$source_dir/installer-version.json" /opt/tether-guest/installer-version.json
  fi
fi
cat > /etc/systemd/system/tether-dns-fallback.service <<'EOF'
[Unit]
Description=Tether guest DNS fallback when NAT DNS is unavailable
Wants=network-online.target
After=network-online.target systemd-resolved.service
ConditionPathExists=/opt/tether-guest/dns-fallback.sh

[Service]
Type=oneshot
ExecStart=/opt/tether-guest/dns-fallback.sh
TimeoutStartSec=150

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/tether-dns-fallback.service
account_temp=$(mktemp /etc/tether-guest/user.XXXXXX)
printf '%s\n' "$guest_user" > "$account_temp"
chmod 0644 "$account_temp"
mv -f "$account_temp" /etc/tether-guest/user

if [ -z "$service_user" ]; then
  cat > /etc/systemd/system/tether-vsock.service <<EOF
[Unit]
Description=Tether private Ubuntu guest helper
After=network.target

[Service]
Type=simple
User=$guest_user
ExecStart=/usr/bin/python3 /opt/tether-guest/vsock_helper.py
Restart=on-failure
RestartSec=2
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/tether-vsock.service
  systemctl daemon-reload
fi
rm -f /usr/share/applications/tether-guest-setup.desktop
cat > /usr/share/applications/tether-guest-installer.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Tether Guest Installer
Comment=Set up and verify this Ubuntu VM
Exec=/usr/bin/python3 /opt/tether-guest/guest_installer.py
Terminal=false
Categories=System;
EOF
chmod 0644 /usr/share/applications/tether-guest-installer.desktop
cat > /usr/share/applications/tether-text-clipboard.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Tether Text Clipboard
Comment=Switch explicit host and Ubuntu text clipboard transfers on or off
Exec=/opt/tether-guest/clipboard-toggle.sh
Terminal=false
Categories=System;
EOF
chmod 0644 /usr/share/applications/tether-text-clipboard.desktop
runuser -u "$guest_user" -- sh -s <<'EOF'
set -eu
mkdir -p "$HOME/.config/autostart"
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
cat > "$HOME/.config/autostart/tether-session.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Tether Guest Session
Exec=/opt/tether-guest/session-start.sh
Terminal=false
X-GNOME-Autostart-enabled=true
DESKTOP
chmod 0644 "$HOME/.config/autostart/tether-session.desktop"
EOF
systemctl daemon-reload
systemctl enable --now tether-dns-fallback.service
systemctl enable --now tether-vsock.service
systemctl restart tether-vsock.service
systemctl is-active --quiet tether-vsock.service
printf '%s\n' 'Tether guest tools installed. The text clipboard bridge starts in the logged-in Ubuntu desktop; transfers occur only when chosen in Tether Host.'
