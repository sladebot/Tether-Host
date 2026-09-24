"""Contract tests for the staged Ubuntu guest setup and privileged updater."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / 'TetherHost/Resources/LinuxGuestSetup/setup.sh'
UPDATER = SETUP.with_name('update-guest-tools.sh')


class LinuxSetupStageTests(unittest.TestCase):
    def run_stage_helpers(self, actions):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            source = SETUP.read_text()
            helpers = source[source.index('invalidate_from() {'):source.index('check_internet() {')]
            runner = f'''set -Eeuo pipefail
CURRENT_STAGE=setup
ERROR_REPORTED=0
STATE="{state}"
emit() {{ printf 'TETHER_STAGE\\t%s\\t%s\\t%s\\n' "$CURRENT_STAGE" "$1" "$2"; }}
die() {{ emit error "$1" >&2; exit 1; }}
{helpers}
{actions}
'''
            result = subprocess.run(['bash', '-c', runner], text=True, capture_output=True)
            remaining = sorted(path.name for path in state.glob('*.ready'))
            return result, remaining

    def test_completed_stage_has_structured_events_and_receipt(self):
        result, remaining = self.run_stage_helpers("start_stage internet 'Checking Internet'; finish_stage 'DNS works'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('TETHER_STAGE\tinternet\tstart\tChecking Internet', result.stdout)
        self.assertIn('TETHER_STAGE\tinternet\tdone\tDNS works', result.stdout)
        self.assertEqual(remaining, ['internet.ready'])

    def test_restarting_upstream_stage_invalidates_downstream_receipts(self):
        actions = '''touch "$STATE/internet.ready" "$STATE/tailscale.ready" "$STATE/hermes-install.ready" "$STATE/verify.ready"
start_stage tailscale 'Reconnect Tailscale'
'''
        result, remaining = self.run_stage_helpers(actions)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(remaining, ['internet.ready'])

    def test_missing_prerequisite_emits_error_and_fails(self):
        result, remaining = self.run_stage_helpers('start_stage verify "Verify"; require_stage tailscale')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('TETHER_STAGE\tverify\terror\tComplete the tailscale step first.', result.stderr)
        self.assertEqual(remaining, [])

    def test_all_stage_names_and_legacy_path_are_present(self):
        source = SETUP.read_text()
        for stage in ('internet', 'tailscale', 'hermes-install', 'hermes-configure', 'computer-use', 'verify'):
            self.assertIn(f'{stage}) run_', source)
            self.assertIn(f'start_stage {stage} ', source)
        self.assertIn('if [[ "$ACTION" == all ]]', source)
        self.assertIn('for mode in -lc -ic; do', source)

    def run_hermes_path_setup(self, profiles=(), *, conflicting_command=False, repeat=False):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / '.hermes/hermes-agent/venv/bin/hermes'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
            for profile in profiles:
                (home / profile).write_text('# Keep user settings\nexport EXISTING_SETTING=keep\n')
            if conflicting_command:
                local = home / '.local/bin'
                local.mkdir(parents=True)
                other = home / 'other-hermes'
                other.write_text('#!/bin/sh\nexit 0\n')
                other.chmod(0o755)
                (local / 'hermes').symlink_to(other)
            source = SETUP.read_text()
            function = source[source.index('ensure_hermes_command() {'):source.index('run_hermes_install() {')]
            runner = f'''set -Eeuo pipefail
hermes="$HOME/.hermes/hermes-agent/venv/bin/hermes"
die() {{ echo "$1" >&2; exit 1; }}
{function}
ensure_hermes_command
{'' if not repeat else 'ensure_hermes_command'}
'''
            env = os.environ.copy()
            env['HOME'] = str(home)
            result = subprocess.run(['bash', '-c', runner], env=env, text=True,
                                    capture_output=True, timeout=10)
            files = {name: (home / name).read_text() for name in
                     ('.profile', '.bash_profile', '.bash_login', '.bashrc') if (home / name).exists()}
            link = home / '.local/bin/hermes'
            return result, files, link.resolve() if link.exists() else None, binary

    def test_fresh_home_gets_login_and_interactive_hermes_path(self):
        result, files, link, binary = self.run_hermes_path_setup(repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(link, binary.resolve())
        self.assertEqual(files['.profile'].count('# Tether Hermes command'), 1)
        self.assertEqual(files['.bashrc'].count('# Tether Hermes command'), 1)

    def test_existing_bash_profile_takes_login_precedence_without_clobbering(self):
        result, files, _, _ = self.run_hermes_path_setup(
            profiles=('.profile', '.bash_login', '.bash_profile', '.bashrc'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('EXISTING_SETTING=keep', files['.bash_profile'])
        self.assertIn('# Tether Hermes command', files['.bash_profile'])
        self.assertNotIn('# Tether Hermes command', files['.bash_login'])
        self.assertNotIn('# Tether Hermes command', files['.profile'])
        self.assertIn('# Tether Hermes command', files['.bashrc'])

    def test_bash_login_is_used_when_bash_profile_is_absent(self):
        result, files, _, _ = self.run_hermes_path_setup(profiles=('.profile', '.bash_login'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('# Tether Hermes command', files['.bash_login'])
        self.assertNotIn('# Tether Hermes command', files['.profile'])

    def test_conflicting_existing_hermes_command_is_preserved_and_reported(self):
        result, files, link, binary = self.run_hermes_path_setup(conflicting_command=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not point to this Hermes installation', result.stderr)
        self.assertNotEqual(link, binary.resolve())
        self.assertEqual(files, {})


class PrivilegedUpdaterTests(unittest.TestCase):
    def run_identity(self, *, sudo_uid='', sudo_user='', pkexec_uid=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            home = root / 'guest-home'
            home.mkdir()
            (bin_dir / 'getent').write_text(f'#!/bin/sh\necho "guest:x:1000:1000::{home}:/bin/bash"\n')
            (bin_dir / 'stat').write_text('#!/bin/sh\necho 1000\n')
            for name in ('getent', 'stat'):
                (bin_dir / name).chmod(0o755)
            source = UPDATER.read_text()
            identity = source[source.index('guest_user=${SUDO_USER:-}'):source.index('service_user=$(systemctl')]
            runner = 'set -eu\nfail() { echo "$1" >&2; exit 1; }\n' + identity + '\necho "$guest_user:$guest_uid"\n'
            env = os.environ.copy()
            env.update({'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'SUDO_UID': sudo_uid,
                        'SUDO_USER': sudo_user, 'PKEXEC_UID': pkexec_uid})
            return subprocess.run(['sh', '-c', runner], env=env, text=True, capture_output=True)

    def test_pkexec_and_sudo_resolve_same_account(self):
        for values in ({'pkexec_uid': '1000'}, {'sudo_uid': '1000', 'sudo_user': 'guest'},
                       {'pkexec_uid': '1000', 'sudo_uid': '1000', 'sudo_user': 'guest'}):
            with self.subTest(values=values):
                result = self.run_identity(**values)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'guest:1000')

    def test_mismatched_or_nonlocal_account_is_rejected(self):
        for values in ({'pkexec_uid': '1000', 'sudo_uid': '1001', 'sudo_user': 'guest'},
                       {'pkexec_uid': '0'}, {'pkexec_uid': 'bad'}):
            with self.subTest(values=values):
                self.assertNotEqual(self.run_identity(**values).returncode, 0)

    def test_gui_dependencies_and_installed_launcher(self):
        source = UPDATER.read_text()
        for item in ('python3-gi', 'gir1.2-gtk-3.0', 'gir1.2-vte-2.91',
                     'guest_installer.py', 'installer_flow.py',
                     'install -m 0755 "$source_dir/update-guest-tools.sh"'):
            self.assertIn(item, source)
        self.assertIn('Exec=/usr/bin/python3 /opt/tether-guest/guest_installer.py', source)
        self.assertIn('Terminal=false', source)

    def test_fresh_placeholder_hostname_guard_preserves_existing_identity(self):
        source = UPDATER.read_text()
        helper = source[source.index('is_fresh_placeholder_hostname() {'):
                        source.index('if is_fresh_placeholder_hostname "$(hostname -s)"')]
        self.assertIn('hostnamectl set-hostname ubuntu-tether-vm', source)
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'tailscaled.state'
            for name, expected in [('localhost', True), ('localhost-0', True),
                                   ('localhost-12', True), ('jarvis', False),
                                   ('localhost-0-custom', False)]:
                with self.subTest(name=name):
                    runner = helper + f'\nis_fresh_placeholder_hostname "$1" "{state}"\n'
                    result = subprocess.run(['sh', '-c', runner, 'sh', name], capture_output=True)
                    self.assertEqual(result.returncode == 0, expected)
            state.write_text('existing tailnet identity')
            result = subprocess.run(['sh', '-c', helper + f'\nis_fresh_placeholder_hostname localhost "{state}"\n'],
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
