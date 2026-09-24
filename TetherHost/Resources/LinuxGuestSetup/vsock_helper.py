#!/usr/bin/env python3
"""Private AF_VSOCK text clipboard requests and verified connection handoff."""
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import socket
import stat
import struct
import subprocess
import time
import urllib.parse

PORT = 45251
HOST_CID = 2
STATE = Path.home() / '.local/share/tether-guest'
MAX_TEXT_BYTES = 65_536
ACCOUNT_RECORD = Path('/etc/tether-guest/user')
BROKER_NAME = 'tether-clipboard.sock'


class ClipboardUnavailable(Exception):
    pass


class ClipboardTooLarge(Exception):
    pass


def configured_guest_uid():
    """Bind the socket helper to its installer-selected, unprivileged account."""
    uid = os.geteuid()
    if uid < 1000 or uid >= 65534:
        raise RuntimeError('Guest helper requires a normal Ubuntu account.')
    account = pwd.getpwuid(uid)
    if Path.home().resolve() != Path(account.pw_dir).resolve():
        raise RuntimeError('Guest helper home does not match its account.')
    if ACCOUNT_RECORD.is_symlink():
        raise RuntimeError('Guest account record is unsafe.')
    if ACCOUNT_RECORD.exists():
        parent = ACCOUNT_RECORD.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0 or parent.st_mode & 0o022:
            raise RuntimeError('Guest account directory is unsafe.')
        metadata = ACCOUNT_RECORD.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise RuntimeError('Guest account record is unsafe.')
        if ACCOUNT_RECORD.stat().st_size > 256 or ACCOUNT_RECORD.read_text() != account.pw_name + '\n':
            raise RuntimeError('Guest helper account does not match its installer record.')
    elif account.pw_name != 'tether':
        # Existing cloud images predate the account record. Only their fixed
        # tether account may use that legacy path.
        raise RuntimeError('Guest account record is missing.')
    return uid


def owned_private(path, directory=False):
    metadata = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    return metadata.st_uid == os.geteuid() and metadata.st_mode & 0o077 == 0 and expected(metadata.st_mode)


def live_endpoint():
    result = subprocess.run(['tailscale', 'status', '--json'], capture_output=True,
                            timeout=5, check=False)
    if result.returncode != 0 or len(result.stdout) > 1_048_576:
        return None
    status = json.loads(result.stdout)
    if status.get('BackendState') != 'Running':
        return None
    name = status.get('Self', {}).get('DNSName', '').rstrip('.').lower()
    if not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net', name):
        return None
    return 'https://' + name


def verified_connection():
    receipt = STATE / 'connection.json'
    if not owned_private(STATE, directory=True) or not owned_private(receipt):
        return None
    if receipt.stat().st_size > 4096:
        return None
    fields = json.loads(receipt.read_text())
    endpoint = fields.get('endpoint')
    token = fields.get('token')
    if fields.get('guest_permissions_verified') is not True or fields.get('model_verified') is not True:
        return None
    if not isinstance(endpoint, str) or not isinstance(token, str):
        return None
    url = urllib.parse.urlsplit(endpoint)
    if url.scheme != 'https' or url.path or url.query or url.fragment or url.port or url.username or url.password:
        return None
    if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', token) or live_endpoint() != endpoint:
        return None
    return json.dumps({'endpoint': endpoint, 'token': token}, separators=(',', ':'))


def clipboard_enabled():
    marker = STATE / 'clipboard-enabled'
    disabled = STATE / 'clipboard-disabled'
    try:
        if disabled.exists() or disabled.is_symlink():
            return False
        return (owned_private(STATE, directory=True) and owned_private(marker) and
                marker.stat().st_size <= 16 and marker.read_text() == 'enabled\n')
    except (OSError, UnicodeError):
        return False


def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise ConnectionError('request ended early')
        result.extend(chunk)
    return bytes(result)


def respond(connection, status, message, limit=4096):
    payload = message.encode('utf-8')
    if len(payload) > limit:
        raise ValueError('response exceeds protocol limit')
    connection.sendall(bytes([status]) + struct.pack('>I', len(payload)) + payload)


def clipboard_environment():
    """Use only the configured user's X11 desktop, never the greeter or root."""
    try:
        uid = configured_guest_uid()
    except (OSError, KeyError, RuntimeError):
        raise ClipboardUnavailable('Log in as the configured Ubuntu guest user before transferring text.')
    runtime = Path(f'/run/user/{uid}')
    bus = runtime / 'bus'
    if not runtime.is_dir() or runtime.stat().st_uid != uid or not stat.S_ISSOCK(bus.stat().st_mode):
        raise ClipboardUnavailable('Log in to the Ubuntu desktop before transferring text.')
    probe_environment = {
        'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin',
        'XDG_RUNTIME_DIR': str(runtime),
        'DBUS_SESSION_BUS_ADDRESS': f'unix:path={bus}',
    }
    if not any(subprocess.run(['pgrep', '-u', str(uid), '-x', process],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=3, check=False).returncode == 0
               for process in ('xfce4-session', 'gnome-session-b')):
        raise ClipboardUnavailable('Log in to the Ubuntu X11 desktop before transferring text.')
    result = subprocess.run(['systemctl', '--user', 'show-environment'],
                            env=probe_environment, capture_output=True, timeout=3, check=False)
    if result.returncode != 0 or len(result.stdout) > 65_536:
        raise ClipboardUnavailable('The Ubuntu desktop session is not ready for clipboard text.')
    variables = {}
    for line in result.stdout.decode('utf-8', errors='strict').splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            if key in ('DISPLAY', 'XAUTHORITY', 'XDG_SESSION_TYPE'):
                variables[key] = value
    display = variables.get('DISPLAY', '')
    if not re.fullmatch(r':[0-9]{1,2}(?:\.[0-9]{1,2})?', display) or \
       variables.get('XDG_SESSION_TYPE', 'x11') != 'x11':
        raise ClipboardUnavailable('Log in to the Ubuntu X11 desktop before transferring text.')
    number = display[1:].split('.', 1)[0]
    if not stat.S_ISSOCK(Path('/tmp/.X11-unix', f'X{number}').stat().st_mode):
        raise ClipboardUnavailable('The Ubuntu desktop display is unavailable.')
    home = Path.home().resolve()
    authority = Path(variables.get('XAUTHORITY') or (home / '.Xauthority')).resolve(strict=True)
    if not (authority.is_relative_to(home) or authority.is_relative_to(runtime)) or \
       not owned_private(authority):
        raise ClipboardUnavailable('The Ubuntu desktop authorization is unavailable.')
    return {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8',
            'DISPLAY': display, 'XAUTHORITY': str(authority),
            'XDG_RUNTIME_DIR': str(runtime)}


def read_bounded_command(command, environment):
    process = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    output = bytearray()
    deadline = time.monotonic() + 5
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise ClipboardUnavailable('The Ubuntu clipboard did not respond in time.')
                chunk = os.read(process.stdout.fileno(), min(4096, MAX_TEXT_BYTES + 1 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > MAX_TEXT_BYTES:
                    raise ClipboardTooLarge('Clipboard text must be 64 KB or smaller.')
        if process.wait(timeout=max(0.1, deadline - time.monotonic())) != 0:
            raise ClipboardUnavailable('No UTF-8 text is available on the Ubuntu clipboard.')
        return output.decode('utf-8', errors='strict')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=1)
        process.stdout.close()


def read_clipboard(environment):
    return read_bounded_command(['xclip', '-selection', 'clipboard', '-out',
                                 '-target', 'UTF8_STRING'], environment)


def write_clipboard(environment, payload):
    result = subprocess.run(['xclip', '-selection', 'clipboard', '-in',
                             '-target', 'UTF8_STRING'], input=payload,
                            env=environment, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=5, check=False)
    if result.returncode != 0:
        raise ClipboardUnavailable('Could not set the Ubuntu desktop clipboard.')


def broker_request(opcode, payload=b''):
    """Ask the logged-in GTK session, avoiding X11 and Wayland display guessing."""
    uid = configured_guest_uid()
    runtime = Path(f'/run/user/{uid}')
    info = runtime.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077:
        raise ClipboardUnavailable('Log in to the Ubuntu desktop before transferring text.')
    path = runtime / BROKER_NAME
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077:
        raise ClipboardUnavailable('The Ubuntu clipboard session is unavailable.')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        connection.sendall(bytes([opcode]) + struct.pack('>I', len(payload)) + payload)
        header = read_exact(connection, 5)
        count = struct.unpack('>I', header[1:])[0]
        if count > MAX_TEXT_BYTES:
            raise ClipboardUnavailable('The Ubuntu clipboard response was too large.')
        answer = read_exact(connection, count)
    if header[0] != 0:
        raise ClipboardUnavailable(answer.decode('utf-8', errors='replace')[:512])
    if opcode in (2, 4) and answer:
        raise ClipboardUnavailable('The Ubuntu clipboard response was invalid.')
    return answer.decode('utf-8', errors='strict') if opcode == 1 else ''


def serve_once(connection):
    connection.settimeout(10)
    header = read_exact(connection, 5)
    opcode, count = header[0], struct.unpack('>I', header[1:])[0]
    if opcode not in (1, 2, 3, 4):
        respond(connection, 1, 'Unsupported guest request.')
        return
    if opcode == 3:
        if count != 0:
            respond(connection, 1, 'Verified connection requests cannot contain text.')
            return
        try:
            receipt = verified_connection()
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
            receipt = None
        if receipt is None:
            respond(connection, 1, 'No verified private connection is available in this Ubuntu VM.')
        else:
            respond(connection, 0, receipt)
        return
    if opcode == 4:
        if count != 0:
            respond(connection, 1, 'Clipboard readiness requests cannot contain text.')
            return
        try:
            if not clipboard_enabled():
                raise ClipboardUnavailable('Tether text clipboard is disabled in Ubuntu.')
            broker_request(4)
            respond(connection, 0, '')
        except (ClipboardUnavailable, OSError, ConnectionError, UnicodeError, ValueError, socket.timeout) as error:
            respond(connection, 1, str(error) or 'The Ubuntu clipboard session is unavailable.')
        return
    if count > MAX_TEXT_BYTES or (opcode == 1 and count != 0):
        respond(connection, 1, 'Clipboard text must be 64 KB or smaller.')
        return
    try:
        payload = read_exact(connection, count) if opcode == 2 else b''
        if opcode == 2:
            payload.decode('utf-8', errors='strict')
        if not clipboard_enabled():
            raise ClipboardUnavailable('Open Tether Text Clipboard in Ubuntu to enable transfers.')
        try:
            result = broker_request(opcode, payload)
            respond(connection, 0, result, limit=MAX_TEXT_BYTES)
        except (ClipboardUnavailable, OSError, ConnectionError, socket.timeout):
            # Older X11 installations can still use their existing explicit bridge.
            environment = clipboard_environment()
            if opcode == 1:
                respond(connection, 0, read_clipboard(environment), limit=MAX_TEXT_BYTES)
            else:
                write_clipboard(environment, payload)
                respond(connection, 0, '')
    except ClipboardTooLarge as error:
        respond(connection, 1, str(error))
    except ClipboardUnavailable as error:
        respond(connection, 1, str(error))
    except (UnicodeError, OSError, subprocess.TimeoutExpired, ValueError):
        respond(connection, 1, 'Log in to the Ubuntu X11 desktop and try the text clipboard again.')


def main():
    configured_guest_uid()
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.bind((socket.VMADDR_CID_ANY, PORT))
    listener.listen(4)
    while True:
        connection, peer = listener.accept()
        with connection:
            if peer[0] != HOST_CID:
                continue
            try:
                serve_once(connection)
            except (OSError, ConnectionError, ValueError):
                pass


if __name__ == '__main__':
    main()
