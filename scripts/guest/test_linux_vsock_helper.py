import importlib.util
import json
from pathlib import Path
import pwd
import socket
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch


PATH = Path(__file__).resolve().parents[2] / 'TetherHost/Resources/LinuxGuestSetup/vsock_helper.py'
spec = importlib.util.spec_from_file_location('vsock_helper', PATH)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class LinuxVsockHelperTests(unittest.TestCase):
    def test_helper_requires_installer_selected_unprivileged_account(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'home'
            home.mkdir()
            record = Path(directory) / 'user'
            record.write_text('alice\n')
            record.chmod(0o644)
            account = pwd.struct_passwd(('alice', 'x', 1000, 1000, '', str(home), '/bin/bash'))
            with patch.object(helper, 'ACCOUNT_RECORD', record), \
                 patch.object(helper.os, 'geteuid', return_value=1000), \
                 patch.object(helper.pwd, 'getpwuid', return_value=account), \
                 patch('pathlib.Path.home', return_value=home):
                # A test-owned temporary record cannot be root-owned; mock
                # only that filesystem ownership check.
                original_lstat = record.lstat
                original_parent_lstat = record.parent.lstat
                with patch.object(Path, 'lstat', autospec=True, side_effect=lambda path: \
                        type('Meta', (), {'st_mode': original_lstat().st_mode, 'st_uid': 0})()
                        if path == record else
                        type('Meta', (), {'st_mode': original_parent_lstat().st_mode, 'st_uid': 0})()):
                    self.assertEqual(helper.configured_guest_uid(), 1000)
                    record.write_text('bob\n')
                    with self.assertRaises(RuntimeError):
                        helper.configured_guest_uid()

    def test_legacy_cloud_account_without_record(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            account = pwd.struct_passwd(('tether', 'x', 1000, 1000, '', str(home), '/bin/bash'))
            with patch.object(helper, 'ACCOUNT_RECORD', home / 'missing'), \
                 patch.object(helper.os, 'geteuid', return_value=1000), \
                 patch.object(helper.pwd, 'getpwuid', return_value=account), \
                 patch('pathlib.Path.home', return_value=home):
                self.assertEqual(helper.configured_guest_uid(), 1000)
                account = pwd.struct_passwd(('alice', 'x', 1000, 1000, '', str(home), '/bin/bash'))
                with patch.object(helper.pwd, 'getpwuid', return_value=account):
                    with self.assertRaises(RuntimeError):
                        helper.configured_guest_uid()

    def exchange(self, opcode, payload=b'', declared_size=None):
        left, right = socket.socketpair()
        try:
            right.sendall(bytes([opcode]) + struct.pack('>I', len(payload) if declared_size is None else declared_size) + payload)
            helper.serve_once(left)
            header = helper.read_exact(right, 5)
            result = helper.read_exact(right, struct.unpack('>I', header[1:])[0])
            return header[0], result
        finally:
            left.close()
            right.close()

    def test_only_verified_private_receipt_is_released(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            state.chmod(0o700)
            receipt = state / 'connection.json'
            fields = {'endpoint': 'https://debian.example.ts.net', 'token': 'A' * 32,
                      'guest_permissions_verified': True, 'model_verified': True}
            receipt.write_text(json.dumps(fields))
            receipt.chmod(0o600)
            with patch.object(helper, 'STATE', state), \
                 patch.object(helper, 'live_endpoint', return_value=fields['endpoint']):
                self.assertEqual(json.loads(helper.verified_connection())['token'], 'A' * 32)
                fields['model_verified'] = False
                receipt.write_text(json.dumps(fields))
                self.assertIsNone(helper.verified_connection())

    def test_clipboard_opt_in_requires_private_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            state.chmod(0o700)
            marker = state / 'clipboard-enabled'
            with patch.object(helper, 'STATE', state):
                self.assertFalse(helper.clipboard_enabled())
                marker.write_text('enabled\n')
                marker.chmod(0o644)
                self.assertFalse(helper.clipboard_enabled())
                marker.chmod(0o600)
                self.assertTrue(helper.clipboard_enabled())
            marker.unlink()
            with patch.object(helper, 'STATE', state):
                status, message = self.exchange(2, b'text')
                self.assertEqual(status, 1)
                self.assertIn(b'Tether Text Clipboard', message)

    def test_explicit_clipboard_read_write_and_verified_receipt(self):
        text = 'Hello \u03c0 from Debian'
        with patch.object(helper, 'clipboard_enabled', return_value=True), \
             patch.object(helper, 'broker_request', side_effect=lambda opcode, payload=b'': text if opcode == 1 else ''), \
             patch.object(helper, 'clipboard_environment', return_value={'DISPLAY': ':0'}), \
             patch.object(helper, 'read_clipboard', return_value=text), \
             patch.object(helper, 'write_clipboard') as write:
            self.assertEqual(self.exchange(1), (0, text.encode('utf-8')))
            self.assertEqual(self.exchange(2, text.encode('utf-8')), (0, b''))
            self.assertEqual(self.exchange(4), (0, b''))
            write.assert_not_called()
        receipt = '{"endpoint":"https://debian.example.ts.net","token":"' + 'A' * 32 + '"}'
        with patch.object(helper, 'verified_connection', return_value=receipt):
            status, payload = self.exchange(3)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(payload)['endpoint'], 'https://debian.example.ts.net')

    def test_clipboard_size_and_utf8_are_enforced_before_access(self):
        with patch.object(helper, 'clipboard_enabled') as enabled:
            self.assertEqual(self.exchange(2, declared_size=helper.MAX_TEXT_BYTES + 1)[0], 1)
            self.assertEqual(self.exchange(1, declared_size=1)[0], 1)
            self.assertEqual(self.exchange(2, b'\xff')[0], 1)
            enabled.assert_not_called()
        with patch.object(helper, 'clipboard_enabled', return_value=True), \
             patch.object(helper, 'broker_request', side_effect=helper.ClipboardUnavailable('not ready')), \
             patch.object(helper, 'clipboard_environment', return_value={}), \
             patch.object(helper, 'read_clipboard', return_value='\u03c0' * 32769):
            self.assertEqual(self.exchange(1)[0], 1)

    def test_readiness_needs_live_broker_and_does_not_read_clipboard(self):
        with patch.object(helper, 'clipboard_enabled', return_value=True), \
             patch.object(helper, 'broker_request', side_effect=helper.ClipboardUnavailable('no session')):
            self.assertEqual(self.exchange(4)[0], 1)
        with patch.object(helper, 'clipboard_enabled', return_value=True), \
             patch.object(helper, 'broker_request', return_value='') as broker:
            self.assertEqual(self.exchange(4), (0, b''))
            broker.assert_called_once_with(4)

    def test_xclip_output_is_bounded_before_decoding(self):
        with self.assertRaises(helper.ClipboardTooLarge):
            helper.read_bounded_command(
                [sys.executable, '-c', 'import sys; sys.stdout.buffer.write(b"x" * 65537)'],
                {})
        self.assertEqual(helper.read_bounded_command(
            [sys.executable, '-c', 'import sys; sys.stdout.buffer.write("\u03c0".encode())'],
            {}), '\u03c0')


if __name__ == '__main__':
    unittest.main()
