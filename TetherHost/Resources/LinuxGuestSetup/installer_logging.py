"""Small, redacted Debian installer log. Never feed it interactive PTY contents."""

import os
from pathlib import Path
import re
import stat
from datetime import datetime, timezone


LOG_NAME = 'installer.log'
MAX_BYTES = 128 * 1024
BACKUPS = 2
SHARE = Path('/mnt/tether-debug')
STAGES = {'bootstrap', 'internet', 'tailscale', 'hermes-install', 'hermes-configure', 'computer-use', 'verify'}
URL = re.compile(r'(?i)\b(?:https?|tailscale)://[^\s<>"\']+')
SECRET = re.compile(r'(?i)\b(?:token|api[_-]?token|api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|secret|authorization|auth[_-]?code|device[_-]?code|verification[_-]?code)\b\s*[:=]\s*\S+')
BEARER = re.compile(r'(?i)\bbearer\s+\S+')
LONG_VALUE = re.compile(r'\b[A-Za-z0-9_=-]{32,}\b')
NUMBER_CODE = re.compile(r'\b\d{4,8}\b')
EMAIL = re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b')
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')
APT_PROGRESS = re.compile(r'^(?:Get:\d+|Hit:\d+|Ign:\d+|Fetched |Reading package lists|Building dependency tree|Reading state information|Unpacking |Setting up |Processing triggers for |Preparing to unpack |\d+ upgraded,)', re.IGNORECASE)


def redact(value):
    text = ANSI.sub('', str(value))
    text = ''.join(char if char == '\t' or ord(char) >= 32 else ' ' for char in text)
    text = URL.sub('[URL redacted]', text)
    text = SECRET.sub('[credential redacted]', text)
    text = BEARER.sub('[credential redacted]', text)
    text = EMAIL.sub('[email redacted]', text)
    text = LONG_VALUE.sub('[long value redacted]', text)
    text = NUMBER_CODE.sub('[code redacted]', text)
    return text[:4096]


def debug_share_mounted(mountinfo=Path('/proc/self/mountinfo')):
    try:
        for line in mountinfo.read_text().splitlines():
            if ' - ' not in line:
                continue
            left, right = line.split(' - ', 1)
            fields, filesystem = left.split(), right.split()
            if len(fields) > 4 and len(filesystem) > 1 and fields[4] == str(SHARE) and \
                    filesystem[0] == 'virtiofs' and filesystem[1] == 'tether-debug':
                return True
    except OSError:
        pass
    return False


class InstallerLog:
    def __init__(self, home):
        self.directory = Path(home) / '.local/share/tether-guest/diagnostics'
        self._prepare_dir(self.directory)
        self.shared = None
        self.pending = ''

    @staticmethod
    def _prepare_dir(directory):
        if directory.is_symlink():
            raise OSError('Diagnostic directory is a symlink')
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = directory.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise OSError('Diagnostic directory has an unexpected owner')
        directory.chmod(0o700)

    @staticmethod
    def _append(directory, line):
        path = directory / LOG_NAME
        encoded = (line + '\n').encode('utf-8', 'replace')
        if len(encoded) > 8192:
            encoded = encoded[:8191] + b'\n'
        if path.exists() and path.stat().st_size + len(encoded) > MAX_BYTES:
            for index in range(BACKUPS, 0, -1):
                previous = directory / (LOG_NAME if index == 1 else f'{LOG_NAME}.{index - 1}')
                newer = directory / f'{LOG_NAME}.{index}'
                if previous.exists() and not previous.is_symlink():
                    previous.replace(newer)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise OSError('Diagnostic log has an unexpected owner')
            os.fchmod(descriptor, 0o600)
            os.write(descriptor, encoded)
        finally:
            os.close(descriptor)

    def _shared_dir(self):
        if not debug_share_mounted() or SHARE.is_symlink():
            self.shared = None
            return None
        directory = SHARE / 'installer-logs'
        try:
            self._prepare_dir(directory)
        except OSError:
            self.shared = None
            return None
        if self.shared != directory:
            try:
                for name in (f'{LOG_NAME}.2', f'{LOG_NAME}.1', LOG_NAME):
                    original = self.directory / name
                    if original.is_file() and not original.is_symlink():
                        target = directory / name
                        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                        try:
                            info = os.fstat(descriptor)
                            if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
                                raise OSError('Shared diagnostic log has an unexpected owner')
                            os.fchmod(descriptor, 0o600)
                            os.ftruncate(descriptor, 0)
                            os.write(descriptor, original.read_bytes()[:MAX_BYTES])
                        finally:
                            os.close(descriptor)
                self.shared = directory
            except OSError:
                self.shared = None
        return self.shared

    def note(self, message):
        line = f'{datetime.now(timezone.utc).isoformat(timespec="seconds")} {redact(message)}'
        try:
            self._append(self.directory, line)
            shared = self._shared_dir()
            if shared is not None:
                # The first connection copied this line with the local history.
                if getattr(self, '_shared_was_ready', False):
                    self._append(shared, line)
                self._shared_was_ready = True
            else:
                self._shared_was_ready = False
        except OSError:
            self.shared = None

    def stage(self, key, event, exit_code=None, receipt=None):
        if key not in STAGES or event not in {'started', 'complete', 'failed', 'cancelled'}:
            return
        detail = f'{key}: {event}'
        if isinstance(exit_code, int):
            detail += f' (exit {exit_code})'
        if isinstance(receipt, bool):
            detail += f', receipt={"yes" if receipt else "no"}'
        self.note(detail)

    def bootstrap_chunk(self, chunk):
        # pkexec receives DEVNULL stdin. Interactive VTE contents must never be
        # passed here: terminal echo can contain passwords and provider input.
        self.pending += chunk
        while True:
            positions = [position for character in ('\n', '\r') if (position := self.pending.find(character)) >= 0]
            if not positions:
                break
            end = min(positions)
            line, self.pending = self.pending[:end], self.pending[end + 1:]
            if APT_PROGRESS.match(line.strip()):
                self.note('bootstrap output: ' + line)
        if len(self.pending) > 8192:
            self.pending = ''

    def flush_bootstrap(self):
        if APT_PROGRESS.match(self.pending.strip()):
            self.note('bootstrap output: ' + self.pending)
        self.pending = ''
