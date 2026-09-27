"""Headless checks for the Debian graphical guide's stage contract."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "TetherHost/Resources/LinuxGuestSetup/installer_flow.py"
spec = importlib.util.spec_from_file_location("installer_flow", SOURCE)
flow = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = flow
spec.loader.exec_module(flow)


class InstallerFlowTests(unittest.TestCase):
    def test_stages_match_backend_names_and_preserve_order(self):
        self.assertEqual([stage.key for stage in flow.STAGES], [
            "internet", "tailscale", "hermes-install", "hermes-configure", "computer-use", "verify"
        ])

    def test_receipt_only_counts_after_successful_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            stage = flow.STAGES[1]
            stage.receipt(home).parent.mkdir(parents=True)
            stage.receipt(home).touch()
            self.assertFalse(flow.verified_exit(stage, home, 1))
            self.assertTrue(flow.verified_exit(stage, home, 0))
            self.assertEqual(flow.first_incomplete(home), flow.STAGES[0])

    def test_stage_events_ignore_unstructured_and_unknown_output(self):
        self.assertEqual(flow.stage_event("TETHER_STAGE\ttailscale\tdone\tConnected\r\n"),
                         ("tailscale", "done", "Connected"))
        self.assertIsNone(flow.stage_event("TETHER_STAGE\tunknown\tdone\tNo"))
        self.assertIsNone(flow.stage_event("Password: "))

    def test_browser_links_accept_https_without_credentials_or_commands(self):
        self.assertEqual(flow.safe_https_url("https://login.tailscale.com/a/ff83ba3909f6"),
                         "https://login.tailscale.com/a/ff83ba3909f6")
        for value in ("http://login.tailscale.com/a/ff83ba3909f6",
                      "javascript:alert(1)", "https://user@tailscale.com/a/token",
                      "https://tailscale.com:444/a/token", "https://tailscale.com/a/token\nrm -rf x"):
            with self.subTest(value=value):
                self.assertIsNone(flow.safe_https_url(value))

    def test_tailscale_sign_in_link_is_extracted_only_from_expected_host(self):
        link = "https://login.tailscale.com/a/ff83ba3909f6"
        self.assertEqual(flow.tailscale_login_url("Open " + link + " to log in."), link)
        self.assertEqual(flow.tailscale_login_url("Open https://login.tailscale.com/a/ff83ba\n3909f6"), link)
        self.assertIsNone(flow.tailscale_login_url("https://login.tailscale.com.evil.test/a/ff83ba3909f6"))
        self.assertIsNone(flow.tailscale_login_url("https://example.org/a/ff83ba3909f6"))


if __name__ == "__main__":
    unittest.main()
