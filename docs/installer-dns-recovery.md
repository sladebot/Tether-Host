# Installer DNS recovery (build 69)

Apple Virtualization NAT can hand guests 192.168.64.1 as their resolver even when that forwarder refuses DNS queries. An affected Ubuntu live session had working IPv4 connectivity but could not resolve ports.ubuntu.com. Its failed installation target had only the CD-ROM APT source, so linux-generic-hwe-24.04 was unavailable.

Manual Ubuntu installations now receive a small NoCloud seed alongside the official, unchanged desktop ISO. The seed runs the shared DNS check automatically, preserves a working resolver, and falls back to 1.1.1.1 and 9.9.9.9 when needed. On NetworkManager desktops the active connection UUID receives the fallback DNS settings, so DHCP renewals do not immediately replace them. A live-session dispatcher and timer recheck DNS after network changes. Active Tailscale DNS is preserved. Existing manual VM bundles receive the versioned seed on their next start with the installer attached. The seed does not automate installation, create accounts, or choose passwords.

Automatic Ubuntu setup and the Ubuntu guest-tools installer use the same helper before package downloads. Guest tools install a boot-time DNS check.

macOS guest setup checks connectivity before its download stages and applies a temporary guest Ethernet DNS fallback only when system name resolution fails and direct DNS works. Previous settings are restored after the setup step. Active VPN/Tailscale configurations are preserved. This runs after macOS restore; it does not alter host networking or Apple's VZMacOSInstaller restore process.

A session already running an older build does not receive the new seed until it is started with the updated app. Failed offline Ubuntu attempts need a fresh installer attempt after working online access is detected; changing DNS does not retroactively replace the failed target's APT sources.

Validation: core tests, mocked DNS recovery/preservation tests for both guest OSes, signed app and DMG verification, and a fresh stock Ubuntu Desktop ARM64 ISO boot which reports TETHER_MANUAL_DNS_READY over its serial console. This is a DNS startup smoke test, not completion of a full interactive installation.
