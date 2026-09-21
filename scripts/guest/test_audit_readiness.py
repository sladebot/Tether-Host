import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import MagicMock

import audit_readiness as audit


class ReadinessTests(unittest.TestCase):
    def capabilities(self):
        return {"features": {"run_submission": True, "run_status": True,
                             "run_events_sse": True, "run_stop": True,
                             "runs_idempotency": {"supported": True, "durable": True,
                                                  "retention_seconds": 3600}}}

    def test_required_capabilities(self):
        data = self.capabilities()
        self.assertTrue(audit.summarize_capabilities(data)["ready"])
        del data["features"]["run_stop"]
        self.assertFalse(audit.summarize_capabilities(data)["ready"])

    def test_malformed_fail_closed(self):
        for value in (None, [], {}, {"features": []}):
            self.assertFalse(audit.summarize_capabilities(value).get("ready", False))
        for retention in (True, 0, -1, "3600", None):
            data = self.capabilities()
            data["features"]["runs_idempotency"]["retention_seconds"] = retention
            self.assertFalse(audit.summarize_capabilities(data)["ready"])

    def test_response_secrets_not_copied(self):
        data = self.capabilities()
        data["token"] = "TOP_SECRET"
        data["features"]["runs_idempotency"]["secret"] = "TOP_SECRET"
        self.assertNotIn("TOP_SECRET", json.dumps(audit.summarize_capabilities(data)))

    def test_config_metadata_does_not_read_or_follow_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "config.yaml"
            target.symlink_to("/nonexistent/credential")
            with patch.object(Path, "read_text", side_effect=AssertionError("credential read")):
                result = audit.file_metadata(target)
            self.assertTrue(result["symlink"])
            self.assertTrue(result["present"])

    def test_no_redirect(self):
        self.assertIsNone(audit.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.com"))

    def test_api_key_only_in_loopback_request_and_output_is_filtered(self):
        response = MagicMock()
        response.status = 200
        payload = self.capabilities()
        payload["accidental_secret"] = "TOP_SECRET"
        response.read.return_value = json.dumps(payload).encode()
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value = response
        with patch.object(audit.urllib.request, "build_opener", return_value=opener) as build:
            result = audit.api_get(8642, "/v1/capabilities", "TOP_SECRET")
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "http://127.0.0.1:8642/v1/capabilities")
        self.assertEqual(request.get_header("Authorization"), "Bearer TOP_SECRET")
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 10)
        self.assertEqual(build.call_args.args[0].proxies, {})
        self.assertIsInstance(build.call_args.args[1], audit.NoRedirect)
        self.assertNotIn("TOP_SECRET", json.dumps(result))
        self.assertTrue(result["capabilities"]["ready"])

    def test_oversized_response_rejected(self):
        response = MagicMock()
        response.status = 200
        response.read.return_value = b"x" * 65537
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value = response
        with patch.object(audit.urllib.request, "build_opener", return_value=opener):
            result = audit.api_get(8642, "/v1/capabilities", "test-key")
        self.assertEqual(result["error"], "response_too_large")

    def test_guest_attestation_required_before_inspection(self):
        with patch("sys.argv", ["audit", "--expected-user", "runtime"]), \
                patch.object(audit, "run", side_effect=AssertionError("inspection ran")), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as exc:
                audit.main()
        self.assertEqual(exc.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
