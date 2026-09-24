#!/usr/bin/env python3
"""Ubuntu guest configuration; no host paths or macOS permissions are used."""
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

import yaml

HOME = Path.home()
STATE = HOME / '.local/share/tether-guest'
HERMES = HOME / '.hermes'
API = 'http://127.0.0.1:8642'
CUA_UNIT = 'tether-cua-driver.service'


class SetupFailure(Exception):
    pass


def private_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise SetupFailure('Refusing a symbolic link for private guest data.')
    temp = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def command(*args, timeout=90, label='Guest setup command', recovery='Retry this setup step.'):
    # Callers provide fixed, user-safe labels. Never print argv, stdout, or
    # stderr here: driver output and command arguments may contain secrets.
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise SetupFailure(f'{label} timed out after {timeout} seconds. {recovery}')
    except OSError:
        raise SetupFailure(f'{label} could not start. {recovery}')
    if result.returncode != 0:
        status = (f'exited with status {result.returncode}' if result.returncode > 0
                  else f'was stopped by signal {-result.returncode}')
        raise SetupFailure(f'{label} {status}. {recovery}')
    return result.stdout


def hermes_bin():
    binary = HERMES / 'hermes-agent/venv/bin/hermes'
    if not binary.is_file():
        raise SetupFailure('Hermes is missing. Run /opt/tether-guest/setup.sh first.')
    return str(binary)


def gnome_wayland_helper_ready():
    try:
        result = subprocess.run(['gnome-extensions', 'info', 'winrects@cua'],
                                capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and bool(re.search(r'^\s*State:\s*ACTIVE\s*$', result.stdout,
                                                    re.IGNORECASE | re.MULTILINE))


def ensure_gnome_wayland_helper():
    marker = STATE / 'computer-use.signout-required'
    if 'GNOME' not in os.environ.get('XDG_CURRENT_DESKTOP', '').upper():
        marker.unlink(missing_ok=True)
        return
    if gnome_wayland_helper_ready():
        marker.unlink(missing_ok=True)
        return
    marker.unlink(missing_ok=True)
    helper = HOME / '.cua-driver/packages/current/wayland-helper/install.sh'
    if not helper.is_file():
        raise SetupFailure('The CuaDriver GNOME helper is missing from this installation. Retry Enable computer use.')
    command('/bin/bash', str(helper), timeout=30, label='CuaDriver GNOME helper install',
            recovery='Retry Enable computer use from the Ubuntu desktop.')
    if not gnome_wayland_helper_ready():
        private_write(marker, 'Sign out of Ubuntu and sign back in, then retry Enable computer use.\n')
        raise SetupFailure('The GNOME computer-use helper is installed. Sign out of Ubuntu and sign back in once, then retry Enable computer use.')


def ensure_cua_daemon():
    """Run the installed driver in this desktop user's systemd session."""
    binary = shutil.which('cua-driver')
    if not binary:
        raise SetupFailure('CuaDriver is missing. Retry Enable computer use.')
    resolved = Path(binary).resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK) or not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(resolved)):
        raise SetupFailure('CuaDriver has an unsupported installation path. Retry Enable computer use.')
    if not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
        raise SetupFailure('Log in to the Ubuntu graphical desktop before starting computer use.')
    socket_dir = HOME / '.cache/cua-driver'
    socket_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    socket_dir.chmod(0o700)
    unit_dir = HOME / '.config/systemd/user'
    unit = unit_dir / CUA_UNIT
    native_wayland = False
    if os.environ.get('WAYLAND_DISPLAY') and os.environ.get('XDG_SESSION_TYPE') == 'wayland':
        config_path = HERMES / 'config.yaml'
        config = yaml.safe_load(config_path.read_text()) if config_path.exists() else {}
        native_wayland = (config or {}).get('computer_use', {}).get('native_wayland') is True
    if native_wayland:
        ensure_gnome_wayland_helper()
    else:
        (STATE / 'computer-use.signout-required').unlink(missing_ok=True)
    content = ('[Unit]\nDescription=Tether Guest Cua Driver\nAfter=graphical-session.target\n\n'
               '[Service]\nType=simple\n'
               + ('Environment=CUA_DRIVER_RS_ENABLE_WAYLAND=1\n' if native_wayland else '') +
               f'ExecStart={resolved} serve --socket %h/.cache/cua-driver/cua-driver.sock\n'
               'Restart=on-failure\nRestartSec=2\n\n[Install]\nWantedBy=default.target\n')
    changed = not unit.exists() or unit.read_text() != content
    if changed:
        private_write(unit, content)
        command('systemctl', '--user', 'daemon-reload', label='CuaDriver service reload',
                recovery='Retry Enable computer use from the Ubuntu desktop.')
    environment = [name for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'XAUTHORITY',
                                     'DBUS_SESSION_BUS_ADDRESS', 'XDG_SESSION_TYPE',
                                     'XDG_CURRENT_DESKTOP') if os.environ.get(name)]
    command('systemctl', '--user', 'import-environment', *environment,
            label='Desktop session import', recovery='Log out of Ubuntu, log back in, then retry Enable computer use.')
    command('systemctl', '--user', 'enable', '--now', CUA_UNIT,
            label='CuaDriver service start', recovery='Retry Enable computer use from the Ubuntu desktop.')
    if changed:
        command('systemctl', '--user', 'restart', CUA_UNIT,
                label='CuaDriver service restart', recovery='Retry Enable computer use from the Ubuntu desktop.')
    # On GNOME Wayland the first capture can open a portal consent dialog.
    # Give that single request time for a human answer; retrying it can stack
    # permission dialogs and make the installer appear stuck.
    attempts = 1 if native_wayland else 15
    for attempt in range(attempts):
        try:
            result = subprocess.run([str(resolved), 'call', 'get_desktop_state', '{}'],
                                    capture_output=True, text=True,
                                    timeout=90 if native_wayland else 10, check=False)
        except (OSError, subprocess.TimeoutExpired):
            result = None
        if result is not None and result.returncode == 0:
            try:
                desktop = json.loads(result.stdout)
            except ValueError:
                desktop = {}
            if desktop.get('screenshot_mime_type') == 'image/png' and desktop.get('screenshot_png_b64'):
                return
        if attempt + 1 < attempts:
            time.sleep(1)
    if native_wayland:
        raise SetupFailure('CuaDriver could not capture the GNOME desktop. Allow the Ubuntu screenshot permission prompt, then retry Enable computer use.')
    raise SetupFailure('CuaDriver service started but cannot capture this Ubuntu desktop. Retry Enable computer use after checking the desktop session.')


def env_values(path):
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                key, value = line.split('=', 1)
                values[key.strip()] = value.strip().strip('"\'')
    return values


def configure():
    env_path = HERMES / '.env'
    previous = env_path.read_text() if env_path.exists() else ''
    values = env_values(env_path)
    token = values.get('API_SERVER_KEY') or secrets.token_urlsafe(32)
    if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', token):
        raise SetupFailure('The existing Hermes API key is invalid; no configuration was changed.')
    managed = {'API_SERVER_ENABLED': 'true', 'API_SERVER_HOST': '127.0.0.1',
               'API_SERVER_PORT': '8642', 'API_SERVER_KEY': token}
    lines = [line for line in previous.splitlines() if line.split('=', 1)[0].strip() not in managed]
    private_write(env_path, '\n'.join(lines + [f'{key}={value}' for key, value in managed.items()]) + '\n')
    config_path = HERMES / 'config.yaml'
    config = yaml.safe_load(config_path.read_text()) if config_path.exists() else {}
    config = config or {}
    if os.environ.get('WAYLAND_DISPLAY') and os.environ.get('XDG_SESSION_TYPE') == 'wayland':
        computer_use = config.setdefault('computer_use', {})
        if not isinstance(computer_use, dict):
            raise SetupFailure('Existing Hermes computer-use settings must be a mapping.')
        computer_use.setdefault('native_wayland', True)
    toolsets = config.setdefault('platform_toolsets', {})
    enabled = toolsets.setdefault('api_server', ['hermes-cli'])
    if not isinstance(enabled, list):
        raise SetupFailure('Existing Hermes API toolsets must be a list.')
    if 'computer_use' not in enabled:
        enabled.append('computer_use')
    private_write(config_path, yaml.safe_dump(config, sort_keys=False))
    identity = STATE / 'installation-id'
    if not identity.exists():
        private_write(identity, str(uuid.uuid4()))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


def request(endpoint, path, token=None, body=None, key=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if key:
        headers['Idempotency-Key'] = key
    req = urllib.request.Request(endpoint + path,
        data=json.dumps(body).encode() if body is not None else None, headers=headers)
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(req, timeout=15) as response:
            data = response.read(1_048_577)
            if len(data) > 1_048_576:
                raise SetupFailure('The Hermes API response was too large.')
            return response.status, json.loads(data)
    except urllib.error.HTTPError as error:
        return error.code, {}


def verify_api(endpoint, token):
    for invalid in (None, secrets.token_urlsafe(32)):
        status, _ = request(endpoint, '/v1/capabilities', invalid)
        if status not in (401, 403):
            raise SetupFailure('Hermes did not reject an unauthenticated request.')
    status, data = request(endpoint, '/v1/capabilities', token)
    if status != 200 or data.get('platform') != 'hermes-agent':
        raise SetupFailure('Hermes authentication or API identity failed.')
    if data.get('auth', {}).get('type') != 'bearer' or data.get('auth', {}).get('required') is not True:
        raise SetupFailure('Hermes bearer authentication is required.')
    features = data.get('features', {})
    if any(features.get(item) is not True for item in ('run_submission', 'run_status', 'run_events_sse', 'run_stop')):
        raise SetupFailure('Hermes lacks the required durable run API.')
    durable = features.get('runs_idempotency', {})
    if durable.get('supported') is not True or durable.get('durable') is not True or durable.get('retention_seconds', 0) <= 0:
        raise SetupFailure('Hermes lacks durable duplicate protection.')


def verify_computer_use():
    if not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
        raise SetupFailure('Log in to the Ubuntu graphical desktop before verifying computer use.')
    ensure_cua_daemon()
    raw = command(hermes_bin(), 'computer-use', 'doctor', '--json', timeout=120,
                  label='Hermes computer-use doctor',
                  recovery='Retry Enable computer use, then Verify connection. The doctor output is available by running hermes computer-use doctor in Ubuntu.')
    try:
        doctor = json.loads(raw)
    except ValueError:
        raise SetupFailure('Hermes computer-use doctor returned unreadable JSON.')
    checks = {item.get('name'): item.get('status') for item in doctor.get('checks', []) if isinstance(item, dict)}
    if checks.get('ax_capability') != 'pass':
        raise SetupFailure('CuaDriver cannot access the Ubuntu desktop. Check DISPLAY and AT-SPI.')
    binary = shutil.which('cua-driver')
    if not binary:
        raise SetupFailure('CuaDriver is missing. Run hermes computer-use install.')
    try:
        desktop = json.loads(command(binary, 'call', 'get_desktop_state', '{}', timeout=90,
                                     label='CuaDriver desktop capture',
                                     recovery='Retry Enable computer use from the Ubuntu desktop.'))
    except ValueError:
        raise SetupFailure('CuaDriver did not return a desktop capture.')
    if desktop.get('screenshot_mime_type') != 'image/png' or not desktop.get('screenshot_png_b64'):
        raise SetupFailure('CuaDriver could not capture the Ubuntu desktop.')


def tailnet_endpoint():
    status = json.loads(command('tailscale', 'status', '--json', label='Tailscale status',
                                recovery='Reconnect Tailscale in Ubuntu, then retry Verify connection.'))
    if status.get('BackendState') != 'Running':
        raise SetupFailure('Connect Tailscale inside Ubuntu before verification.')
    hostname = status.get('Self', {}).get('DNSName', '').rstrip('.').lower()
    if not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net', hostname):
        raise SetupFailure('Ubuntu has no valid private Tailscale DNS name.')
    return 'https://' + hostname


def verify_serve(endpoint):
    config = json.loads(command('tailscale', 'serve', 'status', '--json', label='Tailscale Serve status',
                                recovery='Retry Verify connection after checking the private Serve route.'))
    if any(value is not False for value in config.get('AllowFunnel', {}).values()):
        raise SetupFailure('Tailscale Funnel is enabled. Disable public access.')
    host = endpoint.removeprefix('https://') + ':443'
    if config.get('TCP') != {'443': {'HTTPS': True}} or set(config.get('Web', {})) != {host}:
        raise SetupFailure('Tailscale Serve is not the expected private HTTPS route.')
    if config['Web'][host].get('Handlers') != {'/': {'Proxy': API}}:
        raise SetupFailure('Tailscale Serve must forward only to Hermes loopback.')


def remove_obsolete_tether_serve(endpoint):
    """Remove the old localhost-0 handler left by this VM's node rename."""
    raw = command('tailscale', 'serve', 'status', '--json', label='Tailscale Serve status',
                  recovery='Retry Verify connection after checking Serve status.')
    try:
        config = json.loads(raw)
    except ValueError:
        raise SetupFailure('Tailscale Serve status returned unreadable JSON.')
    web = config.get('Web', {})
    if not isinstance(web, dict):
        raise SetupFailure('Tailscale Serve routes have an unexpected format.')
    current = endpoint.removeprefix('https://') + ':443'
    expected = {'Handlers': {'/': {'Proxy': API}}}
    if web.get(current) != expected:
        return
    old = 'localhost-0.' + current.split('.', 1)[1]
    if old == current or web.get(old) != expected:
        return
    funnel = config.get('AllowFunnel', {})
    if not isinstance(funnel, dict) or funnel.get(old) is True:
        raise SetupFailure('The obsolete Tether route may be public. Disable its Funnel route before retrying.')
    private_write(STATE / 'serve-config-before-cleanup.json', raw)
    del web[old]
    if old in funnel:
        del funnel[old]
    # The supported set-config CLI applies only to Tailscale Services; the
    # raw node Serve configuration must be updated through set-raw.
    try:
        result = subprocess.run(['tailscale', 'serve', 'set-raw'], input=json.dumps(config),
                                text=True, capture_output=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SetupFailure('Could not update the obsolete Tether Serve route. Retry Verify connection.')
    if result.returncode != 0:
        raise SetupFailure('Tailscale rejected the obsolete Tether Serve route update. Retry Verify connection.')
    updated = json.loads(command('tailscale', 'serve', 'status', '--json',
                                 label='Tailscale Serve status after cleanup'))
    if old in updated.get('Web', {}) or updated.get('Web', {}).get(current) != expected:
        raise SetupFailure('Tailscale Serve did not retain the expected private route after cleanup.')


def test_model(endpoint, token):
    path = STATE / 'verification-run.json'
    run = json.loads(path.read_text()) if path.exists() else {
        'key': str(uuid.uuid4()), 'marker': 'TETHER_READY_' + secrets.token_hex(6)}
    private_write(path, json.dumps(run))
    if 'run_id' not in run:
        status, data = request(endpoint, '/v1/runs', token,
            {'input': 'Reply with exactly ' + run['marker'] + '. Do not call tools.',
             'session_id': 'tether-setup-' + run['key']}, run['key'])
        if status not in (200, 201, 202) or not re.fullmatch(r'[A-Za-z0-9_-]+', data.get('run_id', '')):
            raise SetupFailure('The model verification run was not accepted.')
        run['run_id'] = data['run_id']
        private_write(path, json.dumps(run))
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        status, data = request(endpoint, '/v1/runs/' + run['run_id'], token)
        if status != 200:
            raise SetupFailure('The model verification run could not be read.')
        if data.get('status') == 'completed':
            if data.get('output', '').strip() != run['marker']:
                raise SetupFailure('The model did not return its verification marker.')
            path.rename(STATE / ('verification-run-' + run['key'] + '-completed.json'))
            return
        if data.get('status') in ('failed', 'cancelled', 'interrupted', 'stopped'):
            path.rename(STATE / ('verification-run-' + run['key'] + '.json'))
            raise SetupFailure('Model verification failed. Repair model login, then retry.')
        time.sleep(2)
    raise SetupFailure('Model verification is still pending. Retry to resume the same run.')


def verify():
    token = env_values(HERMES / '.env').get('API_SERVER_KEY')
    if not token:
        raise SetupFailure('Hermes API key is missing. Re-run guest setup.')
    verify_api(API, token)
    verify_computer_use()
    endpoint = tailnet_endpoint()
    remove_obsolete_tether_serve(endpoint)
    verify_serve(endpoint)
    verify_api(endpoint, token)
    status, tools = request(endpoint, '/v1/toolsets', token)
    if status != 200 or not any(item.get('name') == 'computer_use' and item.get('enabled') is True
                                and item.get('configured') is True for item in tools.get('data', [])):
        raise SetupFailure('Computer use is not configured for Hermes API requests.')
    test_model(endpoint, token)
    private_write(STATE / 'connection.json', json.dumps({
        'id': (STATE / 'installation-id').read_text().strip(), 'endpoint': endpoint,
        'token': token, 'verified_at': time.time(), 'guest_permissions_verified': True,
        'model_verified': True}))


def main(action):
    os_release = Path('/etc/os-release').read_text()
    if not re.search(r'^ID=ubuntu$', os_release, re.MULTILINE) or subprocess.run(
            ['systemd-detect-virt', '--quiet'], check=False).returncode != 0:
        raise SetupFailure('Run this only inside the Ubuntu virtual machine.')
    if os.geteuid() == 0:
        raise SetupFailure('Run guest setup as your normal Ubuntu desktop user, not root.')
    if action == 'configure':
        configure()
    elif action == 'start-computer-use':
        ensure_cua_daemon()
    elif action == 'verify':
        verify()
    elif action == 'show-connection':
        receipt = STATE / 'connection.json'
        if not receipt.is_file():
            raise SetupFailure('No verified guest connection is available yet.')
        details = json.loads(receipt.read_text())
        print('URL: ' + details['endpoint'])
        print('API token: ' + details['token'])
    else:
        raise SetupFailure('Unknown setup action.')


if __name__ == '__main__':
    try:
        main(sys.argv[1])
    except (SetupFailure, IndexError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print('Ubuntu guest verification failed. Check Tailscale, Hermes, and computer use; no connection was marked ready.', file=sys.stderr)
        sys.exit(1)
