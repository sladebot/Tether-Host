"""Ubuntu verifier diagnostics must identify failed commands without leaking output."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


sys.dont_write_bytecode = True
MODULE_PATH = Path(__file__).resolve().parents[2] / 'TetherHost/Resources/LinuxGuestSetup/linux_guest_setup.py'
SPEC = importlib.util.spec_from_file_location('linux_guest_setup', MODULE_PATH)
guest = importlib.util.module_from_spec(SPEC)
with patch.dict(sys.modules, {'yaml': Mock()}):
    SPEC.loader.exec_module(guest)


class UbuntuCommandDiagnosticsTests(unittest.TestCase):
    def test_failed_doctor_names_command_and_status_without_private_output(self):
        result = Mock(returncode=1, stdout='API token: secret-from-stdout',
                      stderr='secret-from-stderr')
        with patch.object(guest, 'hermes_bin', return_value='/private/hermes'), \
             patch.object(guest, 'ensure_cua_daemon'), \
             patch.dict(guest.os.environ, {'DISPLAY': ':0'}), \
             patch.object(guest.subprocess, 'run', return_value=result):
            with self.assertRaises(guest.SetupFailure) as failure:
                guest.verify_computer_use()
        message = str(failure.exception)
        self.assertIn('Hermes computer-use doctor exited with status 1', message)
        self.assertIn('Retry Enable computer use', message)
        self.assertNotIn('secret-from-', message)
        self.assertNotIn('/private/hermes', message)

    def test_timeout_and_launch_error_remain_labeled_and_redacted(self):
        cases = [
            (subprocess.TimeoutExpired(['secret-argument'], 5, output='secret-output'), 'timed out after 5 seconds'),
            (OSError('secret-file-path'), 'could not start'),
        ]
        for error, expected in cases:
            with self.subTest(expected=expected), patch.object(guest.subprocess, 'run', side_effect=error):
                with self.assertRaises(guest.SetupFailure) as failure:
                    guest.command('secret-argument', timeout=5, label='CuaDriver desktop capture',
                                  recovery='Retry Enable computer use.')
            message = str(failure.exception)
            self.assertIn('CuaDriver desktop capture', message)
            self.assertIn(expected, message)
            self.assertNotIn('secret-', message)

    def test_signal_and_success_are_distinguished(self):
        with patch.object(guest.subprocess, 'run', return_value=Mock(returncode=-15,
                                                                     stdout='secret', stderr='secret')):
            with self.assertRaisesRegex(guest.SetupFailure, 'was stopped by signal 15'):
                guest.command('tailscale', label='Tailscale status')
        with patch.object(guest.subprocess, 'run', return_value=Mock(returncode=0, stdout='{}')):
            self.assertEqual(guest.command('tailscale', label='Tailscale status'), '{}')

    def test_tailscale_failure_names_the_specific_probe(self):
        with patch.object(guest.subprocess, 'run', return_value=Mock(returncode=2, stdout='secret', stderr='secret')):
            with self.assertRaisesRegex(guest.SetupFailure, 'Tailscale status exited with status 2'):
                guest.tailnet_endpoint()

    def test_cua_daemon_installs_user_service_and_checks_real_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / '.local/bin/cua-driver'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755)
            capture = Mock(returncode=0, stdout='{"screenshot_mime_type":"image/png","screenshot_png_b64":"AA=="}')
            with patch.object(guest, 'HOME', home), \
                 patch.object(guest.shutil, 'which', return_value=str(binary)), \
                 patch.dict(guest.os.environ, {'DISPLAY': ':0'}), \
                 patch.object(guest, 'command') as command, \
                 patch.object(guest.subprocess, 'run', return_value=capture) as run:
                guest.ensure_cua_daemon()
                guest.ensure_cua_daemon()
            unit = home / '.config/systemd/user/tether-cua-driver.service'
            self.assertIn(f'ExecStart={binary.resolve()} serve --socket %h/.cache/cua-driver/cua-driver.sock', unit.read_text())
            self.assertEqual(unit.stat().st_mode & 0o777, 0o600)
            self.assertEqual((home / '.cache/cua-driver').stat().st_mode & 0o777, 0o700)
            self.assertEqual(sum(call.args[2] == 'daemon-reload' for call in command.call_args_list), 1)
            self.assertEqual(run.call_count, 2)

    def test_cua_daemon_failure_does_not_accept_a_live_process_without_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'cua-driver'
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755)
            failed = Mock(returncode=1, stdout='', stderr='secret')
            with patch.object(guest, 'HOME', Path(directory)), \
                 patch.object(guest.shutil, 'which', return_value=str(binary)), \
                 patch.dict(guest.os.environ, {'DISPLAY': ':0'}), \
                 patch.object(guest, 'command'), \
                 patch.object(guest.subprocess, 'run', return_value=failed), \
                 patch.object(guest.time, 'sleep'):
                with self.assertRaisesRegex(guest.SetupFailure, 'cannot capture') as failure:
                    guest.ensure_cua_daemon()
            self.assertNotIn('secret', str(failure.exception))

    def test_wayland_daemon_opt_in_requires_real_wayland_and_hermes_setting(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / '.local/bin/cua-driver'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755)
            (home / '.hermes').mkdir()
            (home / '.hermes/config.yaml').write_text('computer_use:\n  native_wayland: true\n')
            capture = Mock(returncode=0, stdout='{"screenshot_mime_type":"image/png","screenshot_png_b64":"AA=="}')
            with patch.object(guest, 'HOME', home), patch.object(guest, 'HERMES', home / '.hermes'), \
                 patch.object(guest.shutil, 'which', return_value=str(binary)), \
                 patch.object(guest.yaml, 'safe_load', return_value={'computer_use': {'native_wayland': True}}), \
                 patch.object(guest, 'command'), patch.object(guest.subprocess, 'run', return_value=capture) as run, \
                 patch.dict(guest.os.environ, {'DISPLAY': ':0', 'WAYLAND_DISPLAY': 'wayland-0',
                                              'XDG_SESSION_TYPE': 'wayland'}):
                guest.ensure_cua_daemon()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.kwargs['timeout'], 90)
            unit = home / '.config/systemd/user/tether-cua-driver.service'
            self.assertIn('Environment=CUA_DRIVER_RS_ENABLE_WAYLAND=1', unit.read_text())
            with patch.object(guest, 'HOME', home), patch.object(guest, 'HERMES', home / '.hermes'), \
                 patch.object(guest.shutil, 'which', return_value=str(binary)), \
                 patch.object(guest.yaml, 'safe_load', return_value={'computer_use': {'native_wayland': False}}), \
                 patch.object(guest, 'command'), patch.object(guest.subprocess, 'run', return_value=capture), \
                 patch.dict(guest.os.environ, {'DISPLAY': ':0', 'WAYLAND_DISPLAY': 'wayland-0',
                                              'XDG_SESSION_TYPE': 'wayland'}):
                guest.ensure_cua_daemon()
            self.assertNotIn('Environment=CUA_DRIVER_RS_ENABLE_WAYLAND=1', unit.read_text())

    def test_configure_defaults_native_wayland_without_overwriting_explicit_false(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hermes = root / '.hermes'
            hermes.mkdir()
            (hermes / '.env').write_text('API_SERVER_KEY=' + 'a' * 32 + '\n')
            config = hermes / 'config.yaml'
            config.write_text('computer_use:\n  native_wayland: false\n')
            with patch.object(guest, 'HERMES', hermes), patch.object(guest, 'STATE', root / 'state'), \
                 patch.object(guest.yaml, 'safe_load', return_value={'computer_use': {'native_wayland': False}}), \
                 patch.object(guest.yaml, 'safe_dump', side_effect=lambda value, **_: repr(value)) as dump, \
                 patch.dict(guest.os.environ, {'WAYLAND_DISPLAY': 'wayland-0', 'XDG_SESSION_TYPE': 'wayland'}):
                guest.configure()
                self.assertIs(dump.call_args.args[0]['computer_use']['native_wayland'], False)
            config.unlink()
            with patch.object(guest, 'HERMES', hermes), patch.object(guest, 'STATE', root / 'state'), \
                 patch.object(guest.yaml, 'safe_dump', side_effect=lambda value, **_: repr(value)) as dump, \
                 patch.dict(guest.os.environ, {'WAYLAND_DISPLAY': 'wayland-0', 'XDG_SESSION_TYPE': 'wayland'}):
                guest.configure()
                self.assertIs(dump.call_args.args[0]['computer_use']['native_wayland'], True)

    def test_gnome_helper_install_requires_signout_then_clears_marker_when_active(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            helper = home / '.cua-driver/packages/current/wayland-helper/install.sh'
            helper.parent.mkdir(parents=True)
            helper.write_text('#!/bin/bash\n')
            state = home / 'state'
            inactive = Mock(returncode=0, stdout='State: INACTIVE\n')
            active = Mock(returncode=0, stdout='State: ACTIVE\n')
            with patch.object(guest, 'HOME', home), patch.object(guest, 'STATE', state), \
                 patch.dict(guest.os.environ, {'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME'}), \
                 patch.object(guest.subprocess, 'run', side_effect=[inactive, inactive, active]), \
                 patch.object(guest, 'command') as command:
                with self.assertRaisesRegex(guest.SetupFailure, 'Sign out of Ubuntu'):
                    guest.ensure_gnome_wayland_helper()
                marker = state / 'computer-use.signout-required'
                self.assertTrue(marker.is_file())
                self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
                self.assertEqual(command.call_args.args[:2], ('/bin/bash', str(helper)))
                guest.ensure_gnome_wayland_helper()
                self.assertFalse(marker.exists())

    def test_gnome_helper_does_not_install_on_other_desktop(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state'
            state.mkdir()
            marker = state / 'computer-use.signout-required'
            marker.write_text('stale')
            with patch.object(guest, 'STATE', state), \
                 patch.dict(guest.os.environ, {'XDG_CURRENT_DESKTOP': 'KDE'}, clear=True), \
                 patch.object(guest, 'command') as command, \
                 patch.object(guest.subprocess, 'run') as run:
                guest.ensure_gnome_wayland_helper()
                self.assertFalse(marker.exists())
                command.assert_not_called()
                run.assert_not_called()

    def test_serve_cleanup_changes_only_confirmed_old_hermes_route(self):
        current = 'ubuntu-tether-vm.example-tailnet.ts.net:443'
        old = 'localhost-0.example-tailnet.ts.net:443'
        hermes = {'Handlers': {'/': {'Proxy': guest.API}}}
        unrelated = {'Handlers': {'/wiki': {'Proxy': 'http://127.0.0.1:9000'}}}
        original = {'TCP': {'443': {'HTTPS': True}}, 'Web': {old: hermes, current: hermes,
                    'other.example-tailnet.ts.net:443': unrelated}, 'Services': {'svc:other': {'x': 1}}}
        updated = {**original, 'Web': {current: hermes, 'other.example-tailnet.ts.net:443': unrelated}}
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(guest, 'STATE', Path(directory)), \
             patch.object(guest, 'command', side_effect=[json.dumps(original), json.dumps(updated)]), \
             patch.object(guest.subprocess, 'run', return_value=Mock(returncode=0)) as run:
            guest.remove_obsolete_tether_serve('https://ubuntu-tether-vm.example-tailnet.ts.net')
            self.assertEqual(json.loads((Path(directory) / 'serve-config-before-cleanup.json').read_text()), original)
        sent = json.loads(run.call_args.kwargs['input'])
        self.assertEqual(sent, updated)
        self.assertEqual(run.call_args.args[0], ['tailscale', 'serve', 'set-raw'])

    def test_serve_cleanup_preserves_custom_or_public_routes(self):
        current = 'ubuntu-tether-vm.example-tailnet.ts.net:443'
        old = 'localhost-0.example-tailnet.ts.net:443'
        hermes = {'Handlers': {'/': {'Proxy': guest.API}}}
        for route in ({'Handlers': {'/': {'Proxy': 'http://127.0.0.1:9000'}}},
                      {'Handlers': {'/': {'Proxy': guest.API}, '/other': {'Proxy': guest.API}}}):
            config = {'Web': {current: hermes, old: route}}
            with self.subTest(route=route), patch.object(guest, 'command', return_value=json.dumps(config)), \
                 patch.object(guest.subprocess, 'run') as run:
                guest.remove_obsolete_tether_serve('https://ubuntu-tether-vm.example-tailnet.ts.net')
                run.assert_not_called()
        config = {'Web': {current: hermes, old: hermes}, 'AllowFunnel': {old: True}}
        with patch.object(guest, 'command', return_value=json.dumps(config)), \
             patch.object(guest.subprocess, 'run') as run:
            with self.assertRaisesRegex(guest.SetupFailure, 'may be public'):
                guest.remove_obsolete_tether_serve('https://ubuntu-tether-vm.example-tailnet.ts.net')
            run.assert_not_called()



if __name__ == '__main__':
    unittest.main()
