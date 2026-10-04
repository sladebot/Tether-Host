import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import subprocess
import os
import tempfile
import unittest
import urllib.error
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True

module_path = Path(__file__).resolve().parents[2] / 'TetherHost/Resources/GuestSetup/guest_setup.py'
spec = importlib.util.spec_from_file_location('guest_setup', module_path)
guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest)

class GuestSetupTests(unittest.TestCase):
    def test_retry_invalidates_stage_receipts_and_dependents(self):
        script = (module_path.parent / 'Set up Tether Guest.command').read_text()
        invalidation = script.split('# Any changed guest dependency')[1].split('stage()')[0]
        markers = {'internet.ready', 'tailscale.ready', 'hermes-installed.ready',
                   'hermes-configured.ready', 'computer-use.ready', 'verified.ready', 'connection.json'}
        expected = {
            'internet': {'internet.ready'},
            'tailscale': {'tailscale.ready'},
            'hermes-install': {'hermes-installed.ready', 'hermes-configured.ready', 'computer-use.ready'},
            'hermes-configure': {'hermes-configured.ready', 'computer-use.ready'},
            'computer-use': {'computer-use.ready'},
            'verify': set(),
        }
        # Execute only the receipt invalidation block, never the provisioning code.
        invalidation = '# Any changed guest dependency' + invalidation
        for action, removed in expected.items():
            with self.subTest(action=action), tempfile.TemporaryDirectory() as folder:
                for marker in markers:
                    (Path(folder) / marker).touch()
                subprocess.run(['/bin/bash', '-euc', invalidation], check=True,
                               env={**os.environ, 'ACTION': action, 'TETHER_GUEST_STATE': folder})
                if action != 'internet':
                    removed = removed | {'verified.ready', 'connection.json'}
                self.assertEqual({p.name for p in Path(folder).iterdir()}, markers - removed)

    def test_changed_endpoint_keeps_pending_run_and_does_not_contact_new_guest(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(guest, 'STATE', Path(folder)):
            active = Path(folder) / 'verification-run.json'
            run = {'key': 'key', 'marker': 'marker', 'run_id': 'run', 'endpoint': 'https://old.example.ts.net'}
            active.write_text(json.dumps(run))
            with patch.object(guest, 'request') as request:
                with self.assertRaisesRegex(guest.SetupFailure, 'previous guest endpoint'):
                    guest.test_model('https://new.example.ts.net', 'token')
            request.assert_not_called()
            self.assertEqual(json.loads(active.read_text()), run)

    def test_non_string_terminal_output_allows_new_attempt(self):
        for output in (None, [], {}, 42):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as folder, \
                 patch.object(guest, 'STATE', Path(folder)):
                active = Path(folder) / 'verification-run.json'
                active.write_text(json.dumps({'key': 'key', 'marker': 'marker', 'run_id': 'run'}))
                with patch.object(guest, 'request', return_value=(200, {'status': 'completed', 'output': output})):
                    with self.assertRaisesRegex(guest.SetupFailure, 'verification marker'):
                        guest.test_model('https://guest.example.ts.net', 'token')
                self.assertFalse(active.exists())

    def test_wrong_marker_archives_terminal_run_and_next_attempt_is_new(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(guest, 'STATE', Path(folder)):
            active = Path(folder) / 'verification-run.json'
            previous = {'key': 'old-key', 'marker': 'TETHER_READY_old', 'run_id': 'old-run'}
            active.write_text(json.dumps(previous))
            with patch.object(guest, 'request', return_value=(200, {'status': 'completed', 'output': 'wrong'})):
                with self.assertRaisesRegex(guest.SetupFailure, 'verification marker'):
                    guest.test_model('https://guest.example.ts.net', 'token')
            self.assertFalse(active.exists())
            self.assertEqual(json.loads((Path(folder) / 'verification-run-old-key-rejected.json').read_text()), {**previous, 'endpoint': 'https://guest.example.ts.net'})

            def respond(endpoint, path, token, body=None, key=None):
                persisted = json.loads(active.read_text())
                self.assertNotEqual(persisted['key'], previous['key'])
                if path == '/v1/runs':
                    self.assertEqual(key, persisted['key'])
                    return 202, {'run_id': 'new-run'}
                return 200, {'status': 'completed', 'output': persisted['marker']}

            with patch.object(guest, 'request', side_effect=respond) as request:
                guest.test_model('https://guest.example.ts.net', 'token')
            self.assertEqual(request.call_count, 2)
            self.assertFalse(active.exists())

    def test_pending_run_retries_poll_same_run_without_resubmission(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(guest, 'STATE', Path(folder)):
            active = Path(folder) / 'verification-run.json'
            with patch.object(guest, 'request', side_effect=[(202, {'run_id': 'pending-run'}),
                    (200, {'status': 'running'})]), \
                 patch.object(guest.time, 'monotonic', side_effect=[0, 0, 181]), \
                 patch.object(guest.time, 'sleep'):
                with self.assertRaisesRegex(guest.SetupFailure, 'still pending'):
                    guest.test_model('https://guest.example.ts.net', 'token')
            persisted = json.loads(active.read_text())
            with patch.object(guest, 'request', return_value=(200, {'status': 'completed', 'output': persisted['marker']})) as request:
                guest.test_model('https://guest.example.ts.net', 'token')
            request.assert_called_once_with('https://guest.example.ts.net', '/v1/runs/pending-run', 'token')

    def test_unsuccessful_terminal_runs_release_active_attempt(self):
        for status in ('failed', 'cancelled', 'interrupted', 'stopped'):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as folder, \
                 patch.object(guest, 'STATE', Path(folder)):
                active = Path(folder) / 'verification-run.json'
                run = {'key': 'key', 'marker': 'marker', 'run_id': 'run'}
                active.write_text(json.dumps(run))
                with patch.object(guest, 'request', return_value=(200, {'status': status})):
                    with self.assertRaisesRegex(guest.SetupFailure, 'Model verification failed'):
                        guest.test_model('https://guest.example.ts.net', 'token')
                self.assertFalse(active.exists())
                self.assertEqual(json.loads((Path(folder) / 'verification-run-key.json').read_text()), {**run, 'endpoint': 'https://guest.example.ts.net'})

    def test_ambiguous_admission_reuses_persisted_idempotency_key(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(guest, 'STATE', Path(folder)):
            active = Path(folder) / 'verification-run.json'
            with patch.object(guest, 'request', side_effect=TimeoutError):
                with self.assertRaises(TimeoutError):
                    guest.test_model('https://guest.example.ts.net', 'token')
            persisted = json.loads(active.read_text())
            with patch.object(guest, 'request', side_effect=[(202, {'run_id': 'same-run'}),
                    (200, {'status': 'completed', 'output': persisted['marker']})]) as request:
                guest.test_model('https://guest.example.ts.net', 'token')
            self.assertEqual(request.call_args_list[0].args[4], persisted['key'])
            self.assertEqual(request.call_args_list[0].args[3]['session_id'], 'tether-setup-' + persisted['key'])

    def test_computer_use_verification_requires_live_grant_permissions_and_health(self):
        permissions = {'accessibility': True, 'screen_recording': True,
                       'source': {'attribution': 'driver-daemon'},
                       'direct_capture_verification': {
                           'source': 'permissions_grant', 'bundle_id': 'com.trycua.driver',
                           'verified_at': '2026-09-22T20:00:00Z'}}
        checks = {'checks': [{'name': name, 'status': 'pass'} for name in
                             ('bundle_identity', 'tcc_accessibility', 'tcc_screen_recording', 'ax_capability')]}
        desktop = {'screenshot_mime_type': 'image/png', 'screenshot_width': 1280,
                   'screenshot_height': 720, 'screenshot_png_b64': 'valid'}
        grant = Mock(returncode=0)
        with patch.object(guest.subprocess, 'run', side_effect=[grant, Mock(returncode=0, stdout=json.dumps(permissions)),
                                                               Mock(returncode=1, stdout=json.dumps(checks)),
                                                               Mock(returncode=0, stdout='[]', stderr=''),
                                                               Mock(returncode=0, stdout=json.dumps(desktop), stderr='')]) as run:
            guest.verify_computer_use()
        self.assertEqual(run.call_args_list[0].args[0][-3:], ['computer-use', 'permissions', 'grant'])
        self.assertEqual(run.call_args_list[-1].args[0][-3:], ['call', 'get_desktop_state', '{}'])

    def test_computer_use_verification_rejects_unverified_capture_and_missing_grants(self):
        with patch.object(guest.subprocess, 'run', return_value=Mock(returncode=1)):
            with self.assertRaisesRegex(guest.SetupFailure, 'direct capture'):
                guest.verify_computer_use()
        with patch.object(guest.subprocess, 'run', side_effect=[Mock(returncode=0),
                Mock(returncode=0, stdout=json.dumps({'accessibility': True, 'screen_recording': False}))]):
            with self.assertRaisesRegex(guest.SetupFailure, 'Screen & System Audio Recording'):
                guest.verify_computer_use()

    def test_computer_use_verification_rejects_missing_required_health_check(self):
        permissions = {'accessibility': True, 'screen_recording': True,
                       'source': {'attribution': 'driver-daemon'},
                       'direct_capture_verification': {
                           'source': 'permissions_grant', 'bundle_id': 'com.trycua.driver',
                           'verified_at': '2026-09-22T20:00:00Z'}}
        report = {'checks': [{'name': 'bundle_identity', 'status': 'pass'}]}
        with patch.object(guest.subprocess, 'run', side_effect=[Mock(returncode=0),
                Mock(returncode=0, stdout=json.dumps(permissions)), Mock(returncode=1, stdout=json.dumps(report))]):
            with self.assertRaisesRegex(guest.SetupFailure, 'ax_capability'):
                guest.verify_computer_use()

    def test_computer_use_verification_rejects_missing_direct_capture_consent(self):
        permissions = {'accessibility': True, 'screen_recording': True,
                       'source': {'attribution': 'driver-daemon'}}
        with patch.object(guest.subprocess, 'run', side_effect=[Mock(returncode=0),
                Mock(returncode=0, stdout=json.dumps(permissions))]):
            with self.assertRaisesRegex(guest.SetupFailure, 'private window picker'):
                guest.verify_computer_use()

    def test_computer_use_verification_rejects_invalid_desktop_capture(self):
        permissions = {'accessibility': True, 'screen_recording': True,
                       'source': {'attribution': 'driver-daemon'},
                       'direct_capture_verification': {
                           'source': 'permissions_grant', 'bundle_id': 'com.trycua.driver',
                           'verified_at': '2026-09-22T20:00:00Z'}}
        checks = {'checks': [{'name': name, 'status': 'pass'} for name in
                             ('bundle_identity', 'tcc_accessibility', 'tcc_screen_recording', 'ax_capability')]}
        with patch.object(guest.subprocess, 'run', side_effect=[Mock(returncode=0),
                Mock(returncode=0, stdout=json.dumps(permissions)),
                Mock(returncode=0, stdout=json.dumps(checks)),
                Mock(returncode=0, stdout='[]', stderr=''),
                Mock(returncode=0, stdout=json.dumps({'screenshot_width': 0}), stderr='')]):
            with self.assertRaisesRegex(guest.SetupFailure, 'valid full-screen PNG'):
                guest.verify_computer_use()

    def test_guest_shell_installs_hermes_command_and_uses_prompting_permission_probe(self):
        script = (module_path.parent / 'Set up Tether Guest.command').read_text()
        self.assertIn('command_path="$command_directory/hermes"', script)
        self.assertIn('is_hermes_command "$command_path"', script)
        self.assertIn('guest_setup.py" verify-computer-use', script)
        self.assertIn('bypass the private window picker and directly access your screen and audio, click Allow', script)
        self.assertNotIn('"$HERMES_BIN" computer-use doctor', script)

    def test_macos_hermes_path_accepts_only_managed_commands(self):
        source = (module_path.parent / 'Set up Tether Guest.command').read_text()
        helpers = source[source.index('is_hermes_command() {'):source.index('complete() {')]
        for variant in ('missing', 'direct', 'official', 'official-python',
                        'unrelated', 'wrong-target', 'wrong-entry', 'extra-command',
                        'wrapper-symlink', 'non-executable'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as folder:
                home = Path(folder)
                binary = home / '.hermes/hermes-agent/venv/bin/hermes'
                binary.parent.mkdir(parents=True)
                binary.write_text('#!/bin/sh\nexit 0\n')
                binary.chmod(0o755)
                python = binary.with_name('python')
                python.write_text('#!/bin/sh\nexit 0\n')
                python.chmod(0o755)
                entry = home / '.hermes/hermes-agent/hermes'
                entry.write_text('# Hermes entry point\n')
                command_dir = home / '.local/bin'
                command_dir.mkdir(parents=True)
                command = command_dir / 'hermes'
                if variant == 'direct':
                    command.symlink_to(binary)
                elif variant != 'missing':
                    target = binary if variant != 'wrong-target' else home / 'other-hermes'
                    script = ('#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\n'
                              f'exec "{target}" "$@"\n')
                    if variant in ('official-python', 'wrong-entry'):
                        target_entry = entry if variant == 'official-python' else home / 'other-hermes'
                        script = ('#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\n'
                                  f'exec "{python}" "{target_entry}" "$@"\n')
                    if variant == 'unrelated':
                        script = '#!/bin/sh\nexit 0\n'
                    elif variant == 'extra-command':
                        script += 'echo unexpected\n'
                    wrapper = command if variant != 'wrapper-symlink' else home / 'wrapper'
                    wrapper.write_text(script)
                    wrapper.chmod(0o644 if variant == 'non-executable' else 0o755)
                    if variant == 'wrapper-symlink':
                        command.symlink_to(wrapper)
                runner = ('set -euo pipefail\n'
                          'HERMES_BIN="$HOME/.hermes/hermes-agent/venv/bin/hermes"\n'
                          'PYTHON_BIN="$HOME/.hermes/hermes-agent/venv/bin/python"\n'
                          'fail() { echo "$1" >&2; exit 1; }\n'
                          + helpers + '\ninstall_hermes_command\ninstall_hermes_command\n')
                result = subprocess.run(['/bin/bash', '-c', runner], env={**os.environ, 'HOME': str(home)},
                                        text=True, capture_output=True, timeout=10)
                accepted = variant in ('missing', 'direct', 'official', 'official-python')
                if accepted:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((home / '.zprofile').read_text().count('# Tether Hermes command'), 1)
                    if variant == 'missing':
                        self.assertEqual(command.resolve(), binary.resolve())
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('does not point to this Hermes installation', result.stderr)
                    self.assertFalse((home / '.zprofile').exists())

    def test_private_write_atomic_permissions_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'token.json'
            guest.private_write(target, 'first')
            guest.private_write(target, 'second')
            self.assertEqual(target.read_text(), 'second')
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            link = Path(folder) / 'link'
            link.symlink_to(target)
            with self.assertRaises(guest.SetupFailure): guest.private_write(link, 'bad')
            self.assertEqual(target.read_text(), 'second')

    def test_configuration_preserves_provider_and_token_on_retry(self):
        import yaml
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as folder:
            hermes = Path(folder) / 'hermes'
            state = Path(folder) / 'state'
            hermes.mkdir()
            (hermes / 'config.yaml').write_text('model:\n  provider: openai-codex\n')
            (hermes / '.env').write_text('EXISTING_SETTING=keep\n')
            with patch.object(guest, 'HERMES', hermes), patch.object(guest, 'STATE', state), patch.object(guest.Path, 'home', return_value=Path(folder)):
                guest.configure()
                first = guest.environment_values((hermes / '.env').read_text())
                guest.configure()
                second = guest.environment_values((hermes / '.env').read_text())
                self.assertEqual(first['API_SERVER_KEY'], second['API_SERVER_KEY'])
                self.assertEqual(second['EXISTING_SETTING'], 'keep')
                self.assertEqual(second['API_SERVER_HOST'], '127.0.0.1')
                config = yaml.safe_load((hermes / 'config.yaml').read_text())
                self.assertEqual(config['model']['provider'], 'openai-codex')
                self.assertEqual(config['platform_toolsets']['api_server'].count('computer_use'), 1)

    def test_tailnet_requires_running_and_exact_dns_hostname(self):
        good = {'BackendState':'Running','Self':{'DNSName':'guest.example.ts.net.'}}
        self.assertEqual(guest.tailnet_endpoint(good), 'https://guest.example.ts.net')
        for bad in ['guest.example.com', 'guest.ts.net.evil.test', 'guest.example.ts.net/path']:
            good['Self']['DNSName'] = bad
            with self.assertRaises(guest.SetupFailure): guest.tailnet_endpoint(good)
        with self.assertRaises(guest.SetupFailure): guest.tailnet_endpoint({'BackendState':'NeedsLogin'})

    def test_serve_rejects_funnel_unrelated_routes_and_nonloopback(self):
        good = {'TCP': {'443': {'HTTPS':True}}, 'Web': {'guest.example.ts.net:443': {'Handlers': {'/': {'Proxy':'http://127.0.0.1:8642'}}}}}
        guest.validate_serve(good, 'https://guest.example.ts.net')
        guest.validate_serve({}, 'https://guest.example.ts.net', allow_empty=True)
        for change in [{'AllowFunnel':{'guest.example.ts.net:443':True}}, {'TCP':{'80':{'HTTP':True}}}, {'Services':{'service':{}}}]:
            bad = {**good, **change}
            with self.assertRaises(guest.SetupFailure): guest.validate_serve(bad, 'https://guest.example.ts.net')
        good['Web']['guest.example.ts.net:443']['Handlers']['/']['Proxy'] = 'http://0.0.0.0:8642'
        with self.assertRaises(guest.SetupFailure): guest.validate_serve(good, 'https://guest.example.ts.net')

    def test_capabilities_require_auth_and_all_phone_features(self):
        data = {'platform':'hermes-agent','auth':{'type':'bearer','required':True},'features':{key:True for key in ['run_submission','run_status','run_events_sse','run_stop']}}
        data['features']['runs_idempotency'] = {'supported':True,'durable':True,'retention_seconds':3600}
        guest.validate_capabilities(data)
        data['features']['runs_idempotency']['durable'] = False
        with self.assertRaises(guest.SetupFailure): guest.validate_capabilities(data)

    def test_loopback_verification_waits_for_gateway_and_api(self):
        with patch.object(guest, 'loopback_health_status', side_effect=[urllib.error.URLError('starting'), 200, 200]) as health, \
             patch.object(guest, 'verify_api', side_effect=[guest.SetupFailure('The generated token was rejected by Hermes.'), None]) as api, \
             patch.object(guest.time, 'monotonic', side_effect=itertools.count()), \
             patch.object(guest.time, 'sleep'):
            guest.verify_loopback('test-token')
        self.assertEqual(health.call_count, 3)
        self.assertEqual(api.call_count, 2)

    def test_loopback_verification_reports_specific_final_failure(self):
        with patch.object(guest, 'loopback_health_status', return_value=503), \
             patch.object(guest, 'verify_api') as api, \
             patch.object(guest.time, 'monotonic', side_effect=itertools.count()), \
             patch.object(guest.time, 'sleep'):
            with self.assertRaisesRegex(guest.SetupFailure, 'health check returned HTTP 503'):
                guest.verify_loopback('test-token', timeout_seconds=3)
        api.assert_not_called()

    def test_hermes_loopback_setup_does_not_require_tailscale_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            hermes = Path(folder) / 'hermes'
            hermes.mkdir()
            (hermes / '.env').write_text('API_SERVER_KEY=test-token\n')
            with patch.object(guest, 'HERMES', hermes), \
                 patch.object(guest, 'STATE', Path(folder) / 'no-tailscale-status'), \
                 patch.object(guest.subprocess, 'check_output', return_value='VirtualMac1,1'), \
                 patch.object(guest, 'verify_loopback') as verify:
                guest.main('verify-loopback')
            verify.assert_called_once_with('test-token')

if __name__ == '__main__': unittest.main()
