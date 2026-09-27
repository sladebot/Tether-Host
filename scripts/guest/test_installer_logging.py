"""Private Debian installer diagnostics never persist sign-in or terminal input."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


MODULE = Path(__file__).resolve().parents[2] / 'TetherHost/Resources/LinuxGuestSetup/installer_logging.py'
SPEC = importlib.util.spec_from_file_location('installer_logging', MODULE)
logging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(logging)


class InstallerLoggingTests(unittest.TestCase):
    def test_redacts_urls_credentials_codes_and_split_chunks(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(logging, 'debug_share_mounted', return_value=False):
                log = logging.InstallerLog(directory)
                log.bootstrap_chunk('Get:1 https://packages.example/path?code=abc')
                log.bootstrap_chunk('def token: privatevalue\nPassword=hidden 123456\n')
                log.flush_bootstrap()
            text = (log.directory / logging.LOG_NAME).read_text()
            self.assertIn('bootstrap output:', text)
            for secret in ('https://packages.example', 'abcdef', 'privatevalue', 'hidden', '123456'):
                self.assertNotIn(secret, text)
            self.assertIn('[URL redacted]', text)
            self.assertEqual((log.directory / logging.LOG_NAME).stat().st_mode & 0o777, 0o600)
            self.assertEqual(log.directory.stat().st_mode & 0o777, 0o700)

    def test_stage_records_safe_metadata_without_terminal_content(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(logging, 'debug_share_mounted', return_value=False):
                log = logging.InstallerLog(directory)
                log.stage('verify', 'started')
                log.stage('verify', 'failed', exit_code=1, receipt=False)
                log.stage('fake-stage', 'complete')
            text = (log.directory / logging.LOG_NAME).read_text()
            self.assertIn('verify: failed (exit 1), receipt=no', text)
            self.assertNotIn('fake-stage', text)

    def test_rotation_bounds_private_log(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(logging, 'debug_share_mounted', return_value=False), \
                 patch.object(logging, 'MAX_BYTES', 350):
                log = logging.InstallerLog(directory)
                for index in range(30):
                    log.note(f'package progress {index}: ' + 'x' * 80)
            files = list(log.directory.glob('installer.log*'))
            self.assertLessEqual(len(files), 3)
            self.assertTrue(all(path.stat().st_size <= 350 for path in files))

    def test_share_is_used_only_when_expected_virtiofs_mount_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mountinfo = root / 'mountinfo'
            with patch.object(logging, 'SHARE', root / 'share'):
                mountinfo.write_text('1 0 0:1 / /mnt/tether-debug rw - tmpfs tether-debug rw\n')
                self.assertFalse(logging.debug_share_mounted(mountinfo))
                mountinfo.write_text(f'1 0 0:1 / {root / "share"} rw - virtiofs tether-debug rw\n')
                self.assertTrue(logging.debug_share_mounted(mountinfo))
                with patch.object(logging, 'debug_share_mounted', return_value=False):
                    log = logging.InstallerLog(root / 'home')
                    log.note('local only')
                self.assertFalse((root / 'share').exists())
                (root / 'share').mkdir()
                with patch.object(logging, 'debug_share_mounted', return_value=True):
                    log.note('mirror after mount')
                shared = root / 'share/installer-logs/installer.log'
                self.assertTrue(shared.is_file())
                self.assertIn('local only', shared.read_text())
                self.assertIn('mirror after mount', shared.read_text())
                self.assertEqual(shared.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
