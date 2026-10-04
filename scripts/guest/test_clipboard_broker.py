"""Protocol boundaries for the session-owned GTK clipboard broker."""
import importlib.util
from pathlib import Path
import queue
import socket
import struct
import sys
import tempfile
import time
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'TetherHost/Resources/LinuxGuestSetup/clipboard_broker.py'
spec = importlib.util.spec_from_file_location('clipboard_broker', SOURCE)
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)


class ClipboardBrokerTests(unittest.TestCase):
    def exchange(self, opcode, payload=b'', count=None, owner=True):
        left, right = socket.socketpair()
        calls = []
        try:
            right.sendall(bytes([opcode]) + struct.pack('>I', len(payload) if count is None else count) + payload)
            with patch.object(broker, 'peer_is_owner', return_value=owner):
                broker.serve_request(left, lambda op, text: calls.append((op, text)) or b'hello')
            if not owner:
                return None, calls
            header = broker.read_exact(right, 5)
            body = broker.read_exact(right, struct.unpack('>I', header[1:])[0])
            return (header[0], body), calls
        finally:
            left.close()
            right.close()

    def test_peer_must_be_same_user(self):
        result, calls = self.exchange(1, owner=False)
        self.assertIsNone(result)
        self.assertEqual(calls, [])

    def test_size_utf8_and_readiness_payload_are_checked_before_clipboard(self):
        for opcode, payload, count in ((2, b'', broker.MAX_TEXT_BYTES + 1),
                                       (2, b'\xff', None), (4, b'text', None),
                                       (1, b'text', None)):
            with self.subTest(opcode=opcode, payload=payload):
                (status, _), calls = self.exchange(opcode, payload, count)
                self.assertEqual(status, 1)
                self.assertEqual(calls, [])

    def test_session_path_requires_private_correct_user_runtime(self):
        with patch.object(broker.os, 'getuid', return_value=1000), \
             patch.dict(broker.os.environ, {'XDG_RUNTIME_DIR': '/tmp', 'DISPLAY': ':0'}):
            with self.assertRaises(RuntimeError):
                broker.socket_path()

    def test_read_waits_for_async_gtk_clipboard_callback(self):
        """Regression: scheduling request_text must not complete the wire reply."""
        scheduled = queue.Queue()
        pending = []

        class Clipboard:
            def request_text(self, callback, user_data):
                pending.append((callback, user_data))

        clipboard = Clipboard()
        gi = ModuleType('gi')
        required_versions = []
        gi.require_version = lambda *args: required_versions.append(args)

        class Repository(ModuleType):
            def __getattribute__(self, name):
                if name == 'Gdk' and ('Gdk', '3.0') not in required_versions:
                    raise AssertionError('Gdk 3 must be pinned before import')
                return super().__getattribute__(name)

        repository = Repository('gi.repository')
        repository.Gdk = SimpleNamespace(
            Display=SimpleNamespace(get_default=lambda: object()),
            SELECTION_CLIPBOARD=object())
        repository.GLib = SimpleNamespace(idle_add=lambda function: scheduled.put(function))

        server, client = socket.socketpair()

        class Listener:
            def __init__(self):
                self.first = True
                self.closed = False

            def bind(self, _path):
                pass

            def listen(self, _backlog):
                pass

            def settimeout(self, _seconds):
                pass

            def accept(self):
                if self.first:
                    self.first = False
                    return server, None
                time.sleep(0.01)
                if self.closed:
                    raise SystemExit
                raise socket.timeout()

            def close(self):
                self.closed = True

        listener = Listener()

        def gtk_main():
            with client:
                client.settimeout(2)
                client.sendall(b'\x01\x00\x00\x00\x00')
                scheduled.get(timeout=2)()
                self.assertEqual(len(pending), 1)
                client.settimeout(0.1)
                with self.assertRaises(socket.timeout):
                    client.recv(1)
                callback, user_data = pending.pop()
                callback(None, 'async text', user_data)
                client.settimeout(2)
                header = broker.read_exact(client, 5)
                self.assertEqual(header[0], 0)
                self.assertEqual(broker.read_exact(client, struct.unpack('>I', header[1:])[0]),
                                 b'async text')

        repository.Gtk = SimpleNamespace(
            Clipboard=SimpleNamespace(get=lambda _selection: clipboard), main=gtk_main)
        with tempfile.TemporaryDirectory() as directory:
            endpoint = Path(directory) / 'broker.sock'
            with patch.dict(sys.modules, {'gi': gi, 'gi.repository': repository}), \
                 patch.object(broker, 'socket_path', return_value=endpoint), \
                 patch.object(broker, 'peer_is_owner', return_value=True), \
                 patch.object(broker.socket, 'socket', return_value=listener):
                self.assertEqual(broker.run(), 0)
        self.assertLess(required_versions.index(('Gdk', '3.0')),
                        required_versions.index(('Gtk', '3.0')))


if __name__ == '__main__':
    unittest.main()
