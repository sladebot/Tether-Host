# Installer DNS recovery (build 69)

Apple Virtualization NAT can hand guests 192.168.64.1 as their resolver even when that forwarder refuses DNS queries. An affected guest can have working IPv4 connectivity while `deb.debian.org` still fails to resolve. The Debian cloud-image workflow uses the guest DNS fallback before its first APT transaction and verifies the signed Trixie repository endpoint afterward.

Manual Debian installations now receive a small NoCloud seed alongside the official, unchanged desktop ISO. The seed runs the shared DNS check automatically, preserves a working resolver, and falls back to 1.1.1.1 and 9.9.9.9 when needed. On NetworkManager desktops the active connection UUID receives the fallback DNS settings, so DHCP renewals do not immediately replace them. A live-session dispatcher and timer recheck DNS after network changes. Active Tailscale DNS is preserved. Existing manual VM bundles receive the versioned seed on their next start with the installer attached. The seed does not automate installation, create accounts, or choose passwords.

Automatic Debian setup and the Debian guest-tools installer use the same helper before package downloads. Guest tools install a boot-time DNS check.

macOS guest setup checks connectivity before its download stages and applies a temporary guest Ethernet DNS fallback only when system name resolution fails and direct DNS works. Previous settings are restored after the setup step. Active VPN/Tailscale configurations are preserved. This runs after macOS restore; it does not alter host networking or Apple's VZMacOSInstaller restore process.

A session already running an older build does not receive the new seed until it is started with the updated app. Failed offline Debian attempts need a fresh installer attempt after working online access is detected; changing DNS does not retroactively replace the failed target's APT sources.

Validation: core tests, mocked DNS recovery/preservation tests for both guest OSes, signed app and DMG verification, and a fresh stock Debian Desktop ARM64 ISO boot which reports TETHER_MANUAL_DNS_READY over its serial console. This is a DNS startup smoke test, not completion of a full interactive installation.
