#!/usr/bin/env python3
"""Explicit clipboard requests from the private vsock service in this GTK session."""
import os
from pathlib import Path
import socket
import stat
import struct
import threading

MAX_TEXT_BYTES = 65_536
SOCKET_NAME = "tether-clipboard.sock"


def socket_path():
    uid = os.getuid()
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", ""))
    if uid < 1000 or uid >= 65534 or runtime != Path(f"/run/user/{uid}"):
        raise RuntimeError("Log in to the configured Debian desktop first.")
    info = runtime.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077:
        raise RuntimeError("The Debian session directory is not private.")
    if not (os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")):
        raise RuntimeError("No Debian graphical session is available.")
    return runtime / SOCKET_NAME


def peer_is_owner(connection, uid=None):
    uid = os.getuid() if uid is None else uid
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    _pid, peer_uid, _gid = struct.unpack("3i", credentials)
    return peer_uid == uid


def read_exact(connection, count):
    data = bytearray()
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            raise ConnectionError("Clipboard request ended early.")
        data.extend(chunk)
    return bytes(data)


def reply(connection, status, data=b""):
    connection.sendall(bytes([status]) + struct.pack(">I", len(data)) + data)


def serve_request(connection, clipboard_action, uid=None):
    """Run one bounded same-user request; clipboard_action runs on GTK's main thread."""
    connection.settimeout(5)
    if not peer_is_owner(connection, uid):
        return
    opcode, count = struct.unpack(">BI", read_exact(connection, 5))
    if opcode not in (1, 2, 4) or count > MAX_TEXT_BYTES or (opcode != 2 and count):
        reply(connection, 1, b"Invalid clipboard request.")
        return
    payload = read_exact(connection, count)
    if opcode == 2:
        try:
            payload.decode("utf-8", "strict")
        except UnicodeError:
            reply(connection, 1, b"Clipboard text must be UTF-8.")
            return
    try:
        value = clipboard_action(opcode, payload)
        if not isinstance(value, bytes) or len(value) > MAX_TEXT_BYTES:
            raise ValueError("Clipboard text exceeds 64 KiB.")
        reply(connection, 0, value)
    except (RuntimeError, ValueError, TimeoutError) as error:
        reply(connection, 1, str(error).encode("utf-8")[:512])


def run():
    # GNOME's XWayland selection bridge serves unfocused background clients;
    # native Wayland clipboard reads can be denied without an input serial.
    if os.environ.get("DISPLAY"):
        os.environ["GDK_BACKEND"] = "x11"
    import gi
    gi.require_version("Gdk", "3.0")
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gdk, GLib, Gtk

    path = socket_path()
    if Gdk.Display.get_default() is None:
        raise RuntimeError("The Debian graphical session is not ready.")
    clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)

    def clipboard_action(opcode, payload):
        completed = threading.Event()
        expired = threading.Event()
        result = {}

        def perform():
            if expired.is_set():
                return False
            if opcode == 1:
                def received(_clipboard, text, _data):
                    if expired.is_set():
                        return
                    try:
                        if text is None:
                            raise RuntimeError("No text is available on the Debian clipboard.")
                        result["value"] = text.encode("utf-8")
                    except Exception as error:
                        result["error"] = error
                    completed.set()
                try:
                    clipboard.request_text(received, None)
                except Exception as error:
                    result["error"] = error
                    completed.set()
                return False
            try:
                if opcode == 2:
                    clipboard.set_text(payload.decode("utf-8"), -1)
                    result["value"] = b""
                else:
                    result["value"] = b""
            except Exception as error:
                result["error"] = error
            finally:
                completed.set()
            return False

        GLib.idle_add(perform)
        if not completed.wait(4):
            expired.set()
            raise TimeoutError("The Debian clipboard did not respond in time.")
        if "error" in result:
            raise RuntimeError(str(result["error"]))
        return result["value"]

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    bound = False
    try:
        if path.exists() or path.is_symlink():
            old = path.lstat()
            if not stat.S_ISSOCK(old.st_mode) or old.st_uid != os.getuid():
                raise RuntimeError("The clipboard socket path is unsafe.")
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(0.3)
                    probe.connect(str(path))
                return 0  # Already running in this desktop session.
            except ConnectionRefusedError:
                path.unlink()
        previous_umask = os.umask(0o077)
        try:
            listener.bind(str(path))
            bound = True
        finally:
            os.umask(previous_umask)
        listener.listen(8)
        listener.settimeout(1)

        def accept_loop():
            while True:
                try:
                    connection, _address = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    try:
                        serve_request(connection, clipboard_action)
                    except (ConnectionError, OSError, socket.timeout):
                        pass

        threading.Thread(target=accept_loop, daemon=True).start()
        Gtk.main()
        return 0
    finally:
        listener.close()
        try:
            if bound and path.is_socket() and path.stat().st_uid == os.getuid():
                path.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(run())
