"""Debian verifier diagnostics must identify failed commands without leaking output."""

import base64
import importlib.util
import json
import os
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

PNG = base64.b64encode(b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR' + b'\x00' * 8).decode()


class DebianCommandDiagnosticsTests(unittest.TestCase):
    def test_failed_doctor_names_command_and_status_without_private_output(self):
        result = Mock(returncode=1, stdout='API token: secret-from-stdout',
                      stderr='secret-from-stderr')
        with patch.object(guest, 'hermes_bin', return_value='/private/hermes'), \
             patch.object(guest, 'ensure_cua_daemon'), \
             patch.dict(guest.os.environ, {'DISPLAY': ':0', 'XDG_SESSION_TYPE': 'x11'}), \
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
            capture = Mock(returncode=0, stdout=json.dumps({
                'screenshot_mime_type': 'image/png', 'screenshot_png_b64': PNG}))
            with patch.object(guest, 'HOME', home), \
                 patch.object(guest.shutil, 'which', return_value=str(binary)), \
                 patch.dict(guest.os.environ, {'DISPLAY': ':0', 'XDG_SESSION_TYPE': 'x11'}), \
                 patch.object(guest, 'command') as command, \
                 patch.object(guest.subprocess, 'run', return_value=capture) as run:
                guest.ensure_cua_daemon()
                guest.ensure_cua_daemon()
            unit = home / '.config/systemd/user/tether-cua-driver.service'
            self.assertIn(f'ExecStart={binary.resolve()} serve --socket %h/.cache/cua-driver/cua-driver.sock', unit.read_text())
            self.assertEqual(unit.stat().st_mode & 0o777, 0o600)
            self.assertEqual((home / '.cache/cua-driver').stat().st_mode & 0o777, 0o700)
            self.assertEqual(sum(call.args[2] == 'daemon-reload' for call in command.call_args_list), 1)
            self.assertEqual(sum(call.args[2] == 'unset-environment' for call in command.call_args_list), 2)
            self.assertEqual(sum(call.args[2] == 'restart' for call in command.call_args_list), 2)
            self.assertEqual(run.call_count, 2)

    def test_empty_or_invalid_png_does_not_verify_capture(self):
        for encoded in ('AA==', 'not-base64', ''):
            with self.subTest(encoded=encoded):
                self.assertFalse(guest.has_png_capture({'screenshot_png_b64': encoded}))
        self.assertTrue(guest.has_png_capture({'screenshot_png_b64': PNG}))

    def test_cua_daemon_failure_does_not_accept_a_live_process_without_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'cua-driver'
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755)
            failed = Mock(returncode=1, stdout='', stderr='secret')
            with patch.object(guest, 'HOME', Path(directory)), \
                 patch.object(guest.shutil, 'which', return_value=str(binary)), \
                 patch.dict(guest.os.environ, {'DISPLAY': ':0', 'XDG_SESSION_TYPE': 'x11'}), \
                 patch.object(guest, 'command'), \
                 patch.object(guest.subprocess, 'run', return_value=failed), \
                 patch.object(guest.time, 'sleep'):
                with self.assertRaisesRegex(guest.SetupFailure, 'cannot capture') as failure:
                    guest.ensure_cua_daemon()
            self.assertNotIn('secret', str(failure.exception))

    def test_wayland_session_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / '.local/bin/cua-driver'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755)
            with patch.object(guest, 'HOME', home), \
                 patch.object(guest.shutil, 'which', return_value=str(binary)), \
                 patch.dict(guest.os.environ, {'DISPLAY': ':0', 'WAYLAND_DISPLAY': 'wayland-0',
                                              'XDG_SESSION_TYPE': 'wayland'}):
                with self.assertRaisesRegex(guest.SetupFailure, 'Xfce/X11'):
                    guest.ensure_cua_daemon()

    def test_chromium_probe_discovers_captures_and_reads_native_browser(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            chromium = root / 'chromium'
            chromium.write_text('#!/bin/sh\n')
            chromium.chmod(0o755)
            process = Mock()
            process.poll.return_value = None
            process.wait.return_value = 0
            def reply(*args, **kwargs):
                probe = next((root / 'state').glob('chromium-cua-*/probe.html')).read_text()
                marker = probe.split('<h1>')[1].split('</h1>')[0]
                title = 'Tether Computer Use Probe ' + marker
                if args[2] == 'list_windows':
                    return json.dumps({'windows': [
                        {'pid': 41, 'window_id': 6, 'app_name': 'Chromium', 'title': 'Other page'},
                        {'pid': 42, 'window_id': 7, 'app_name': 'Chromium', 'title': title}]})
                if args[2] == 'get_window_state':
                    return json.dumps({'screenshot_png_b64': PNG,
                                       'elements': [{'label': 'Agent input'}]})
                return json.dumps({'text': marker})
            with patch.object(guest, 'STATE', root / 'state'), \
                 patch.object(guest.shutil, 'which', return_value=str(chromium)), \
                 patch.object(guest.subprocess, 'Popen', return_value=process) as popen, \
                 patch.object(guest, 'command', side_effect=reply) as command:
                guest.verify_chromium_control('/usr/bin/cua-driver')
            self.assertIn('--new-window', popen.call_args.args[0])
            self.assertFalse(list((root / 'state').glob('chromium-cua-*')))
            self.assertEqual([call.args[2] for call in command.call_args_list],
                             ['list_windows', 'get_window_state', 'page'])
            self.assertEqual(json.loads(command.call_args.args[3])['pid'], 42)
            process.terminate.assert_called_once()

    def test_chromium_probe_rejects_unrelated_browser_window(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            chromium = root / 'chromium'
            chromium.write_text('#!/bin/sh\n')
            chromium.chmod(0o755)
            process = Mock()
            process.poll.return_value = None
            with patch.object(guest, 'STATE', root / 'state'), \
                 patch.object(guest.shutil, 'which', return_value=str(chromium)), \
                 patch.object(guest.subprocess, 'Popen', return_value=process), \
                 patch.object(guest, 'command', return_value=json.dumps({'windows': [
                     {'pid': 99, 'window_id': 5, 'app_name': 'Chromium', 'title': 'Another tab'}
                 ]})) as command, \
                 patch.object(guest.time, 'monotonic', side_effect=[0, 1, 45]), \
                 patch.object(guest.time, 'sleep'):
                with self.assertRaisesRegex(guest.SetupFailure, 'could not discover'):
                    guest.verify_chromium_control('/usr/bin/cua-driver')
            self.assertEqual(command.call_count, 1)
            process.terminate.assert_called_once()
            self.assertFalse(list((root / 'state').glob('chromium-cua-*')))

    def test_chromium_probe_reports_early_browser_exit_without_private_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            chromium = root / 'chromium'
            chromium.write_text('#!/bin/sh\n')
            chromium.chmod(0o755)
            process = Mock()
            process.poll.return_value = 1
            with patch.object(guest, 'STATE', root / 'state'), \
                 patch.object(guest.shutil, 'which', return_value=str(chromium)), \
                 patch.object(guest.subprocess, 'Popen', return_value=process), \
                 patch.object(guest, 'command') as command:
                with self.assertRaisesRegex(guest.SetupFailure, 'Chromium closed before') as failure:
                    guest.verify_chromium_control('/usr/bin/cua-driver')
            command.assert_not_called()
            self.assertNotIn(str(root), str(failure.exception))

    def test_session_login_refreshes_x11_environment_before_driver_restart(self):
        session = MODULE_PATH.with_name('session-start.sh').read_text()
        actions = session[session.index('systemctl --user unset-environment'):
                          session.index('gateway="$HOME/.hermes')]
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / 'systemctl.log'
            runner = 'systemctl() { printf "%s\\n" "$*" >> "$TRACE"; }\n' + actions
            env = os.environ.copy()
            env.update({'TRACE': str(trace), 'DISPLAY': ':0', 'XDG_SESSION_TYPE': 'x11',
                        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus',
                        'XDG_CURRENT_DESKTOP': 'XFCE'})
            env.pop('XAUTHORITY', None)
            result = subprocess.run(['sh', '-c', runner], env=env, capture_output=True,
                                    text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = trace.read_text().splitlines()
            self.assertEqual(calls[0], '--user unset-environment DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE XDG_CURRENT_DESKTOP')
            self.assertEqual(calls[1], '--user import-environment DISPLAY XDG_SESSION_TYPE DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP')
            self.assertEqual(calls[-1], '--user restart tether-cua-driver.service')

    def test_configure_forces_native_wayland_off(self):
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
                self.assertIs(dump.call_args.args[0]['computer_use']['native_wayland'], False)

    def test_serve_cleanup_changes_only_confirmed_old_hermes_route(self):
        current = 'debian-tether-vm.example-tailnet.ts.net:443'
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
            guest.remove_obsolete_tether_serve('https://debian-tether-vm.example-tailnet.ts.net')
            self.assertEqual(json.loads((Path(directory) / 'serve-config-before-cleanup.json').read_text()), original)
        sent = json.loads(run.call_args.kwargs['input'])
        self.assertEqual(sent, updated)
        self.assertEqual(run.call_args.args[0], ['tailscale', 'serve', 'set-raw'])

    def test_serve_cleanup_preserves_custom_or_public_routes(self):
        current = 'debian-tether-vm.example-tailnet.ts.net:443'
        old = 'localhost-0.example-tailnet.ts.net:443'
        hermes = {'Handlers': {'/': {'Proxy': guest.API}}}
        for route in ({'Handlers': {'/': {'Proxy': 'http://127.0.0.1:9000'}}},
                      {'Handlers': {'/': {'Proxy': guest.API}, '/other': {'Proxy': guest.API}}}):
            config = {'Web': {current: hermes, old: route}}
            with self.subTest(route=route), patch.object(guest, 'command', return_value=json.dumps(config)), \
                 patch.object(guest.subprocess, 'run') as run:
                guest.remove_obsolete_tether_serve('https://debian-tether-vm.example-tailnet.ts.net')
                run.assert_not_called()
        config = {'Web': {current: hermes, old: hermes}, 'AllowFunnel': {old: True}}
        with patch.object(guest, 'command', return_value=json.dumps(config)), \
             patch.object(guest.subprocess, 'run') as run:
            with self.assertRaisesRegex(guest.SetupFailure, 'may be public'):
                guest.remove_obsolete_tether_serve('https://debian-tether-vm.example-tailnet.ts.net')
            run.assert_not_called()



if __name__ == '__main__':
    unittest.main()
