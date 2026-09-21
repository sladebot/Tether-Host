import copy
import subprocess
import unittest

from audit_pf import COMMANDS, collect
from pf_policy import generate


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.config = {"interface": "bridge100", "guest_addresses": ["192.168.64.2", "fd00::2"],
                       "proxy": {"address": "192.168.64.1", "port": 3128},
                       "resolver": None, "transport_addresses": []}

    def test_default_deny_both_families_without_direct_https(self):
        result = generate(self.config)
        self.assertIn("inet from 192.168.64.2 to any", result)
        self.assertIn("inet6 from fd00::2 to any", result)
        self.assertNotIn("port 443", result)
        self.assertNotIn("proto udp", result)
        self.assertEqual(result.count("pass quick"), 1)

    def test_only_exact_transport_and_deterministic_order(self):
        self.config["transport_addresses"] = ["2606:4700:4700::1111", "1.1.1.1", "1.1.1.1"]
        result = generate(self.config)
        reverse = copy.deepcopy(self.config)
        reverse["transport_addresses"].reverse()
        reverse["guest_addresses"].reverse()
        self.assertEqual(result, generate(reverse))
        self.assertEqual(result.count('label "tether_transport"'), 2)
        self.assertNotIn("to any port", result)

    def test_unsafe_transport_inventory_rejected(self):
        for value in ["0.0.0.0/0", "*.example.com", "127.0.0.1", "192.168.1.1", "100.64.0.1",
                      "169.254.1.1", "224.0.0.1", "::", "fe80::1", "fd00::1", "ff02::1", "::ffff:1.1.1.1"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.config["transport_addresses"] = [value]
                generate(self.config)

    def test_injection_unknown_fields_missing_family_rejected(self):
        changes = [{"interface": "bridge100\npass all"}, {"guest_addresses": ["192.168.64.2"]},
                   {"guest_addresses": ["192.168.64.2", "fe80::1%bridge100"]}, {"allow_all": True},
                   {"proxy": {"address": "192.168.64.1", "port": "3128\npass all"}}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                generate(dict(self.config, **change))

    def test_resolver_and_absent_proxy(self):
        self.config["proxy"] = None
        self.config["resolver"] = {"address": "192.168.64.1", "port": 53}
        result = generate(self.config)
        self.assertIn("proto { tcp, udp }", result)
        self.assertNotIn("3128", result)


class AuditTests(unittest.TestCase):
    def test_permission_failure_never_claims_disabled_or_ready(self):
        def denied(command, **kwargs):
            return subprocess.CompletedProcess(command, 1, "", "Permission denied")
        report = collect(denied)
        self.assertFalse(report["deployment_ready"])
        self.assertTrue(report["unverified_gates"])
        self.assertTrue(all(v["returncode"] == 1 for v in report["checks"].values()))

    def test_commands_are_read_only_and_no_shell(self):
        for command in COMMANDS.values():
            self.assertNotIn("sudo", command)
            self.assertFalse(set(command) & {"-f", "-F", "-e", "-d", "-E", "-X", "-k", "-K"})
        def unavailable(command, **kwargs):
            self.assertNotIn("shell", kwargs)
            raise FileNotFoundError("not macOS")
        self.assertTrue(all(v["returncode"] is None for v in collect(unavailable)["checks"].values()))


if __name__ == "__main__":
    unittest.main()
