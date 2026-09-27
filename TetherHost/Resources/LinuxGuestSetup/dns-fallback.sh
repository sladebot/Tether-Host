#!/bin/sh
# Apple Virtualization's NAT can supply a DNS forwarder that refuses queries
# when the host uses a VPN resolver. Keep the DHCP DNS when it works; otherwise
# use a public resolver on the guest NAT link until Tailscale is running.
set -eu

for attempt in $(seq 1 30); do
  if ip -4 route get 1.1.1.1 >/dev/null 2>&1; then break; fi
  sleep 2
done
ip -4 route get 1.1.1.1 >/dev/null 2>&1 || {
  echo 'Tether guest has no IPv4 route' >&2
  exit 1
}
interface="$(ip -o -4 route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
case "$interface" in
  en*) ;;
  *) echo 'Tether guest NAT interface is unavailable' >&2; exit 1 ;;
esac

for attempt in 1 2; do
  if timeout 5 getent ahostsv4 deb.debian.org >/dev/null 2>&1; then exit 0; fi
  sleep 2
done

# After the user sets up Tailscale, leave its split DNS policy alone.
if command -v tailscale >/dev/null 2>&1; then
  if timeout 5 tailscale status --json 2>/dev/null | python3 -c \
      'import json,sys; sys.exit(0 if json.load(sys.stdin).get("BackendState") == "Running" else 1)' 2>/dev/null; then
    echo 'Tailscale is running; preserving its DNS configuration' >&2
    exit 0
  fi
fi

# Desktop's NetworkManager can replace a one-off resolvectl setting when its
# DHCP lease renews or the installer reconnects. Set the active profile by UUID
# so it continues to ignore the broken DHCP DNS through those transitions.
# Server images without NetworkManager still get the per-link fallback below.
if command -v nmcli >/dev/null 2>&1; then
  connection_uuid="$(nmcli -g GENERAL.CON-UUID device show "$interface" 2>/dev/null || true)"
  case "$connection_uuid" in
    ????????-????-????-????-????????????)
      if nmcli connection modify uuid "$connection_uuid" \
          ipv4.ignore-auto-dns yes ipv4.dns '1.1.1.1 9.9.9.9'; then
        nmcli device reapply "$interface" || true
      fi
      ;;
  esac
fi
if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved.service; then
  resolvectl dns "$interface" 1.1.1.1 9.9.9.9
  resolvectl flush-caches
else
  resolv_conf=/etc/resolv.conf
  [ ! -L "$resolv_conf" ] || {
    echo 'Tether guest DNS fallback could not safely update the resolver symlink' >&2
    exit 1
  }
  temp=$(mktemp /etc/resolv.conf.tether.XXXXXX)
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions timeout:2 attempts:2\n' > "$temp"
  chmod 0644 "$temp"
  mv -f "$temp" "$resolv_conf"
fi
for attempt in $(seq 1 5); do
  if timeout 5 getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
    echo 'Tether guest DNS fallback is active for this boot'
    exit 0
  fi
  sleep 2
done
echo 'Tether guest DNS could not resolve Debian package servers' >&2
exit 1
