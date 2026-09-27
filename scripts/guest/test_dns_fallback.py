"""Behavioral tests for the shared Debian guest DNS preflight."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "TetherHost/Resources/LinuxGuestSetup/dns-fallback.sh"
UPDATER = SCRIPT.with_name("update-guest-tools.sh")


class DNSFallbackTests(unittest.TestCase):
    def run_helper(self, *, dns="working", route=True, interface="enp0s1", tailscale=None,
                   network_manager=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            commands = {
                "ip": """#!/bin/sh
if [ "$1 $2 $3" = '-4 route get' ]; then
  [ "$TEST_ROUTE" = yes ]
elif [ "$1 $2 $3 $4" = '-o -4 route show' ]; then
  echo "default via 192.168.64.1 dev $TEST_INTERFACE proto dhcp"
else
  exit 1
fi
""",
                "getent": """#!/bin/sh
echo getent >> "$TEST_LOG"
[ "$TEST_DNS" = working ] || { [ "$TEST_DNS" = fallback ] && [ -f "$TEST_REPAIRED" ]; }
""",
                "resolvectl": """#!/bin/sh
echo "resolvectl $*" >> "$TEST_LOG"
if [ "$1" = dns ]; then touch "$TEST_REPAIRED"; fi
""",
                "systemctl": "#!/bin/sh\n[ \"$1 $2\" = 'is-active --quiet' ]\n",
                "timeout": "#!/bin/sh\nshift\nexec \"$@\"\n",
                "sleep": "#!/bin/sh\nexit 0\n",
            }
            # Never probe the real host Tailscale daemon in a guest unit test.
            commands["tailscale"] = "#!/bin/sh\necho \"$TEST_TAILSCALE\"\n"
            if network_manager:
                commands["nmcli"] = """#!/bin/sh
echo "nmcli $*" >> "$TEST_LOG"
if [ "$1 $2 $3" = '-g GENERAL.CON-UUID device' ]; then
  echo 22de611b-9696-4c6a-b781-9a00e0383d89
fi
"""
            for name, body in commands.items():
                executable = bin_dir / name
                executable.write_text(body)
                executable.chmod(0o755)
            log = root / "commands.log"
            env = os.environ.copy()
            env.update({
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "TEST_DNS": dns,
                "TEST_ROUTE": "yes" if route else "no",
                "TEST_INTERFACE": interface,
                "TEST_TAILSCALE": tailscale or '{"BackendState":"Stopped"}',
                "TEST_LOG": str(log),
                "TEST_REPAIRED": str(root / "repaired"),
            })
            result = subprocess.run(["sh", str(SCRIPT)], env=env, text=True,
                                    capture_output=True, timeout=10)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_working_dhcp_dns_is_preserved(self):
        result, commands = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, ["getent"])

    def test_failed_dhcp_dns_uses_per_link_fallback(self):
        result, commands = self.run_helper(dns="fallback")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("resolvectl dns enp0s1 1.1.1.1 9.9.9.9", commands)
        self.assertIn("resolvectl flush-caches", commands)
        self.assertIn("fallback is active", result.stdout)

    def test_failed_dhcp_dns_persists_active_network_manager_profile(self):
        result, commands = self.run_helper(dns="fallback", network_manager=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nmcli connection modify uuid 22de611b-9696-4c6a-b781-9a00e0383d89 "
                      "ipv4.ignore-auto-dns yes ipv4.dns 1.1.1.1 9.9.9.9", commands)
        self.assertIn("nmcli device reapply enp0s1", commands)
        self.assertIn("resolvectl dns enp0s1 1.1.1.1 9.9.9.9", commands)

    def test_working_dns_does_not_modify_network_manager_profile(self):
        result, commands = self.run_helper(network_manager=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, ["getent"])

    def test_running_tailscale_dns_is_preserved(self):
        result, commands = self.run_helper(dns="failed", tailscale='{"BackendState":"Running"}',
                                           network_manager=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command.startswith(("resolvectl", "nmcli")) for command in commands))
        self.assertIn("preserving its DNS", result.stderr)

    def test_disconnected_tailscale_allows_fallback(self):
        result, commands = self.run_helper(dns="fallback", tailscale='{"BackendState":"NeedsLogin"}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("resolvectl dns enp0s1 1.1.1.1 9.9.9.9", commands)

    def test_unresolved_dns_reports_failure_after_fallback(self):
        result, commands = self.run_helper(dns="failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not resolve Debian package servers", result.stderr)
        self.assertIn("resolvectl dns enp0s1 1.1.1.1 9.9.9.9", commands)

    def test_no_route_or_non_nat_interface_does_not_change_dns(self):
        for options, message in [({"route": False}, "no IPv4 route"),
                                 ({"interface": "tailscale0"}, "NAT interface is unavailable")]:
            with self.subTest(options=options):
                result, commands = self.run_helper(dns="failed", **options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(any(command.startswith("resolvectl") for command in commands))

    def test_manual_updater_runs_shared_preflight_before_apt_and_installs_boot_service(self):
        updater = UPDATER.read_text()
        self.assertLess(updater.index('\n/opt/tether-guest/dns-fallback.sh\n'),
                        updater.index('apt-get update'))
        self.assertIn('install -m 0755 "$source_dir/dns-fallback.sh"', updater)
        self.assertIn('ExecStart=/opt/tether-guest/dns-fallback.sh', updater)
        self.assertIn('systemctl enable --now tether-dns-fallback.service', updater)


if __name__ == "__main__":
    unittest.main()
