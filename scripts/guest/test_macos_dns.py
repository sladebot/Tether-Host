"""Exercise the macOS guest DNS preflight with simulated guest network commands."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "TetherHost/Resources/GuestSetup/Set up Tether Guest.command"


class MacGuestDNSTests(unittest.TestCase):
    def run_preflight(self, *, https="failed", dns="failed", vpn=False, tailscale=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            shims = {
                "curl": '#!/bin/sh\n[ "$MOCK_HTTPS" = working ] || [ -f "$MOCK_OVERRIDE" ]\n',
                "dscacheutil": '#!/bin/sh\n[ "$MOCK_DNS" = working ] && echo "ip_address: 1.2.3.4"\n',
                "route": '#!/bin/sh\necho "    interface: en0"\n',
                "ipconfig": '#!/bin/sh\necho 192.168.64.2\n',
                "nslookup": '#!/bin/sh\nexit 0\n',
                "scutil": '#!/bin/sh\n[ "$MOCK_VPN" = yes ] && echo "(Connected)"\nexit 0\n',
                "networksetup": '''#!/bin/sh
case "$1" in
  -listnetworkserviceorder) printf '(1) Ethernet\\n(Hardware Port: Ethernet, Device: en0)\\n' ;;
  -getdnsservers) echo "There aren't any DNS Servers set on Ethernet." ;;
  -setdnsservers)
    echo "$*" >> "$MOCK_LOG"
    if [ "$3" = Empty ]; then rm -f "$MOCK_OVERRIDE"; else touch "$MOCK_OVERRIDE"; fi ;;
  *) exit 1 ;;
esac
''',
                "sudo": '#!/bin/sh\nexec "$@"\n',
                "sleep": '#!/bin/sh\nexit 0\n',
                "tailscale": '#!/bin/sh\necho \'{"BackendState":"Running"}\'\n',
            }
            for name, body in shims.items():
                path = bin_dir / name
                path.write_text(body)
                path.chmod(0o755)
            source = SCRIPT.read_text()
            preflight = source[source.index("DNS_OVERRIDE_SERVICE=''"):source.index('check_tailnet() {')]
            for path in ("/usr/bin/curl", "/usr/bin/dscacheutil", "/usr/bin/grep",
                         "/usr/bin/awk", "/usr/bin/nslookup", "/usr/bin/sudo",
                         "/usr/sbin/scutil", "/usr/sbin/networksetup", "/usr/sbin/ipconfig",
                         "/sbin/route", "/bin/sleep"):
                preflight = preflight.replace(path, Path(path).name)
            preflight = preflight.replace(
                "/Applications/Tailscale.app/Contents/MacOS/Tailscale", str(bin_dir / "tailscale"))
            state = root / "state"
            state.mkdir()
            log = root / "networksetup.log"
            runner = f'''set -euo pipefail
TETHER_GUEST_STATE="{state}"
CURRENT_STAGE=DNS
ACTION=internet
fail() {{ echo "$1" >&2; exit 1; }}
{preflight}
ensure_guest_download_dns pkgs.tailscale.com https://pkgs.tailscale.com/stable/
restore_guest_dns
'''
            env = os.environ.copy()
            env.update({"PATH": f"{bin_dir}:{os.environ['PATH']}",
                        "MOCK_HTTPS": https, "MOCK_DNS": dns,
                        "MOCK_VPN": "yes" if vpn else "no",
                        "MOCK_LOG": str(log), "MOCK_OVERRIDE": str(root / "override")})
            if not tailscale:
                (bin_dir / "tailscale").unlink()
            result = subprocess.run(["bash", "-c", runner], env=env, text=True,
                                    capture_output=True, timeout=10)
            return result, log.read_text().splitlines() if log.exists() else [], (root / "override").exists()

    def test_working_https_does_not_change_dns(self):
        result, commands, override = self.run_preflight(https="working")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, [])
        self.assertFalse(override)

    def test_failed_dns_uses_temporary_resolver_and_restores_dhcp(self):
        result, commands, override = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, ["-setdnsservers Ethernet 1.1.1.1", "-setdnsservers Ethernet Empty"])
        self.assertFalse(override)

    def test_active_vpn_or_tailscale_preserves_dns(self):
        for options in ({"vpn": True}, {"tailscale": True}):
            with self.subTest(options=options):
                result, commands, override = self.run_preflight(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("active VPN or split DNS", result.stderr)
                self.assertEqual(commands, [])
                self.assertFalse(override)

    def test_https_failure_with_working_dns_is_not_misdiagnosed(self):
        result, commands, _ = self.run_preflight(dns="working")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resolves pkgs.tailscale.com", result.stderr)
        self.assertEqual(commands, [])

    def test_preflight_runs_before_each_guest_download_stage(self):
        source = SCRIPT.read_text()
        self.assertLess(source.index('ensure_guest_download_dns pkgs.tailscale.com'),
                        source.index('https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg -o'))
        self.assertLess(source.index('ensure_guest_download_dns raw.githubusercontent.com'),
                        source.index('"$INSTALLER_URL" -o'))
        self.assertLess(source.index('ensure_guest_download_dns pypi.org'),
                        source.index('"$HERMES_UV" pip install'))


if __name__ == '__main__':
    unittest.main()
