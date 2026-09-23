"""Guest-local configuration and real API verification."""
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

class SetupFailure(Exception):
    pass


STATE = Path.home() / 'Library/Application Support/Tether Host for Mac/Guest Setup'
HERMES = Path.home() / '.hermes'
HERMES_BIN = HERMES / 'hermes-agent/venv/bin/hermes'


def private_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise SetupFailure('Refusing a symbolic link for private configuration.')
    temp = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def environment_values(text):
    values = {}
    for line in text.splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip().strip('"\'')
    return values


def configure():
    import yaml
    env_path = HERMES / '.env'
    previous = env_path.read_text() if env_path.exists() else ''
    values = environment_values(previous)
    token = values.get('API_SERVER_KEY') or secrets.token_urlsafe(32)
    if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', token):
        raise SetupFailure('Existing API token is invalid; no credentials were changed.')
    managed = {'API_SERVER_ENABLED': 'true', 'API_SERVER_HOST': '127.0.0.1',
               'API_SERVER_PORT': '8642', 'API_SERVER_KEY': token}
    lines = [line for line in previous.splitlines() if line.split('=', 1)[0].strip() not in managed]
    lines += [f'{key}={value}' for key, value in managed.items()]
    private_write(env_path, '\n'.join(lines) + '\n')
    config_path = HERMES / 'config.yaml'
    config = yaml.safe_load(config_path.read_text()) if config_path.exists() else {}
    config = config or {}
    # Preserve the provider selected by the user and enable guest computer use.
    toolsets = config.setdefault('platform_toolsets', {})
    enabled = toolsets.setdefault('api_server', ['hermes-cli'])
    if not isinstance(enabled, list):
        raise SetupFailure('Existing API toolsets must be a list.')
    if 'computer_use' not in enabled:
        enabled.append('computer_use')
    private_write(config_path, yaml.safe_dump(config, sort_keys=False))
    identity = STATE / 'installation-id' 
    if not identity.exists():
        private_write(identity, str(uuid.uuid4()))


def tailnet_endpoint(status):
    if status.get('BackendState') != 'Running':
        raise SetupFailure('Sign in to Tailscale and connect before continuing.')
    host = status.get('Self', {}).get('DNSName', '').rstrip('.').lower()
    if not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net', host):
        raise SetupFailure('A valid guest MagicDNS hostname is required.')
    return 'https://' + host


def validate_serve(config, endpoint, allow_empty=False):
    if any(value is not False for value in config.get('AllowFunnel', {}).values()):
        raise SetupFailure('Public Funnel is enabled. Disable it for this guest before continuing.')
    web = config.get('Web', {})
    tcp = config.get('TCP', {})
    if any(config.get(key) for key in ('Services', 'Foreground')):
        raise SetupFailure('Additional Serve configurations need review.')
    if allow_empty and not web and not tcp:
        return
    host = urllib.parse.urlsplit(endpoint).hostname + ':443'
    if set(web) != {host} or set(tcp) != {'443'} or tcp['443'] != {'HTTPS': True}:
        raise SetupFailure('Existing Serve routes differ from Tether’s private HTTPS route. Review them before retrying; they were not overwritten.')
    if web[host].get('Handlers') != {'/': {'Proxy': 'http://127.0.0.1:8642'}}:
        raise SetupFailure('Serve must forward only HTTPS / to guest loopback port 8642.')
    if any(config.get(key) for key in ('Services', 'Foreground')):
        raise SetupFailure('Additional Serve configurations need review.')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
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
                raise SetupFailure('The API response exceeded the expected size.')
            try:
                return response.status, json.loads(data)
            except (ValueError, UnicodeError):
                raise SetupFailure('Hermes returned an invalid JSON response for ' + path + '.')
    except urllib.error.HTTPError as error:
        return error.code, {}


def loopback_health_status():
    req = urllib.request.Request('http://127.0.0.1:8642/health')
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(req, timeout=5) as response:
            response.read(1024)
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def verify_loopback(token, timeout_seconds=60):
    deadline = time.monotonic() + timeout_seconds
    last_issue = 'The local gateway did not answer.'
    while time.monotonic() < deadline:
        try:
            status = loopback_health_status()
            if status == 200:
                verify_api('http://127.0.0.1:8642', token)
                return
            last_issue = 'The gateway health check returned HTTP ' + str(status) + '.'
        except SetupFailure as error:
            last_issue = str(error)
        except (urllib.error.URLError, TimeoutError, OSError):
            last_issue = 'The gateway is not accepting local API requests yet.'
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(2, remaining))
    raise SetupFailure('Hermes started, but local API verification did not pass: ' + last_issue)


def validate_capabilities(data):
    if data.get('platform') != 'hermes-agent' or data.get('auth', {}).get('type') != 'bearer' or data.get('auth', {}).get('required') is not True:
        raise SetupFailure('Hermes bearer authentication is required.')
    features = data.get('features', {})
    if any(features.get(key) is not True for key in ('run_submission', 'run_status', 'run_events_sse', 'run_stop')):
        raise SetupFailure('Hermes does not support Tether’s required durable run API.')
    durable = features.get('runs_idempotency', {})
    if durable.get('supported') is not True or durable.get('durable') is not True or not isinstance(durable.get('retention_seconds'), (int, float)) or durable['retention_seconds'] <= 0:
        raise SetupFailure('Durable duplicate protection is unavailable.')


def verify_api(endpoint, token):
    for invalid in (None, secrets.token_urlsafe(32)):
        status, _ = request(endpoint, '/v1/capabilities', invalid)
        if status not in (401, 403):
            raise SetupFailure('The API did not reject missing or incorrect authentication.')
    status, data = request(endpoint, '/v1/capabilities', token)
    if status != 200:
        raise SetupFailure('The generated token was rejected by Hermes.')
    validate_capabilities(data)


def json_command(arguments, label, timeout=90):
    try:
        result = subprocess.run([str(HERMES_BIN), *arguments], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SetupFailure(label + ' could not be completed.')
    try:
        payload = json.loads(result.stdout)
    except (TypeError, ValueError):
        raise SetupFailure(label + ' returned an unreadable result.')
    if not isinstance(payload, dict):
        raise SetupFailure(label + ' returned an unreadable result.')
    return result.returncode, payload


def verify_computer_use():
    try:
        grant = subprocess.run([str(HERMES_BIN), 'computer-use', 'permissions', 'grant'],
                               timeout=180, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SetupFailure('CuaDriver permission and direct-capture verification could not run.')
    if grant.returncode != 0:
        raise SetupFailure('CuaDriver could not verify Accessibility, Screen Recording, and direct capture. Complete both guest permissions, then retry.')

    _, permissions = json_command(
        ['computer-use', 'permissions', 'status', '--json'],
        'CuaDriver permission status')
    if permissions.get('accessibility') is not True:
        raise SetupFailure('Enable CuaDriver in guest Accessibility, then retry.')
    if permissions.get('screen_recording') is not True:
        raise SetupFailure('Enable CuaDriver in guest Screen & System Audio Recording, then retry.')

    required = {'bundle_identity', 'tcc_accessibility', 'tcc_screen_recording', 'ax_capability'}
    # The prompt-capable direct-capture probe above is authoritative. The
    # read-only health report intentionally skips that probe, so inspect its
    # individual identity/TCC/AX checks instead of its aggregate exit code.
    _, report = json_command(['computer-use', 'doctor', '--json'], 'CuaDriver health check')
    checks = {item.get('name'): item.get('status') for item in report.get('checks', [])
              if isinstance(item, dict)}
    failed = sorted(check for check in required if checks.get(check) != 'pass')
    if failed:
        raise SetupFailure('CuaDriver did not pass: ' + ', '.join(failed) + '.')


def test_model(endpoint, token):
    # Persist admission identity BEFORE sending; retries cannot duplicate an ambiguous run.
    path = STATE / 'verification-run.json'
    run = json.loads(path.read_text()) if path.exists() else {'key': str(uuid.uuid4()), 'marker': 'TETHER_READY_' + secrets.token_hex(6)}
    private_write(path, json.dumps(run))
    if 'run_id' not in run:
        status, data = request(endpoint, '/v1/runs', token,
            {'input': 'Reply with exactly ' + run['marker'] + '. Do not call tools.', 'session_id': 'tether-setup-' + run['key']}, run['key'])
        if status not in (200, 201, 202) or not re.fullmatch(r'[A-Za-z0-9_-]+', data.get('run_id', '')):
            raise SetupFailure('The model verification run could not be admitted.')
        run['run_id'] = data['run_id']
        private_write(path, json.dumps(run))
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        status, data = request(endpoint, '/v1/runs/' + run['run_id'], token)
        if status != 200:
            raise SetupFailure('The model verification run could not be read.')
        if data.get('status') == 'completed':
            if data.get('output', '').strip() != run['marker']:
                raise SetupFailure('The model did not return the verification marker.')
            path.rename(STATE / ('verification-run-' + run['key'] + '-completed.json'))
            return
        if data.get('status') in ('failed', 'cancelled', 'interrupted', 'stopped'):
            # Retain the terminal result, and allow a deliberate next setup attempt.
            path.rename(STATE / ('verification-run-' + run['key'] + '.json'))
            raise SetupFailure('Model verification failed. Repair model login, then rerun setup.')
        time.sleep(2)
    raise SetupFailure('Model verification is still pending. Rerun setup to resume checking the same run.')


def main(action):
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip()
    if not model.startswith('VirtualMac'):
        raise SetupFailure('Guest configuration is allowed only inside a macOS VM.')
    if action == 'show-connection':
        receipt = STATE / 'connection.json'
        if not receipt.is_file():
            raise SetupFailure('No verified guest connection is available yet.')
        details = json.loads(receipt.read_text())
        print('\nEnter these details in Tether on your iPhone:')
        print('URL: ' + details['endpoint'])
        print('API token: ' + details['token'])
        print('Keep this token private. It is also saved in the guest connection.json file.\n')
        return
    if action == 'configure':
        configure()
        return
    if action == 'verify-loopback':
        # launchd starts asynchronously; wait for health and the authenticated API contract.
        token = environment_values((HERMES / '.env').read_text()).get('API_SERVER_KEY')
        if not token:
            raise SetupFailure('Hermes API key is missing. Re-run the Configure Hermes step.')
        verify_loopback(token)
        return
    if action == 'verify-computer-use':
        verify_computer_use()
        return
    status = json.loads((STATE / 'tailscale-status.json').read_text())
    endpoint = tailnet_endpoint(status)
    if action == 'tailscale':
        return
    if action == 'check-serve-before':
        validate_serve(json.loads((STATE / 'serve-before.json').read_text()), endpoint, allow_empty=True)
        return
    if action != 'verify':
        raise SetupFailure('Unknown setup action.')
    token = environment_values((HERMES / '.env').read_text()).get('API_SERVER_KEY')
    if not token:
        raise SetupFailure('Hermes API key is missing. Re-run the Configure Hermes step.')
    verify_computer_use()
    validate_serve(json.loads((STATE / 'serve-after.json').read_text()), endpoint)
    verify_api(endpoint, token)
    status, tools = request(endpoint, '/v1/toolsets', token)
    if status != 200 or not any(item.get('name') == 'computer_use' and item.get('enabled') is True
                               and item.get('configured') is True for item in tools.get('data', [])):
        raise SetupFailure('Enable and configure computer use for the Hermes API before connecting.')
    test_model(endpoint, token)
    private_write(STATE / 'connection.json', json.dumps({
        'id': (STATE / 'installation-id').read_text().strip(), 'endpoint': endpoint,
        'token': token, 'verified_at': time.time(), 'guest_permissions_verified': True,
        'model_verified': True}))


if __name__ == '__main__':
    try:
        main(sys.argv[1])
    except SetupFailure as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Never render exception strings: transport and provider errors may contain credentials.
        print('Verification/configuration failed. Check model login, Tailscale, permissions, and the current setup stage. No connection was marked ready.', file=sys.stderr)
        sys.exit(1)
