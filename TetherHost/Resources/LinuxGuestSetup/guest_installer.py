#!/usr/bin/env python3
"""Graphical Debian guest setup. Runs as the desktop user, never as root."""

import codecs
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import threading
import time

from installer_flow import STAGES, first_incomplete, safe_https_url, tailscale_login_url, verified_exit
from installer_logging import InstallerLog


RESOURCE_DIR = Path(__file__).resolve().parent
HOME = Path.home()
COMPUTER_USE_SIGNOUT_MARKER = HOME / ".local/share/tether-guest/computer-use.signout-required"
COMPUTER_USE_SIGNOUT_GUIDANCE = (
    "Debian installed the desktop control helper. Sign out of Debian and sign back in to activate it. "
    "Then reopen Tether Guest Installer and retry Enable computer use."
)

def installer_version():
    try:
        data = json.loads((RESOURCE_DIR / "installer-version.json").read_text(encoding="utf-8"))
        version, build = data["version"], data["build"]
        if isinstance(version, str) and isinstance(build, (str, int)) and len(version) <= 32:
            return f"{version} ({build})"
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return "development"


def runtime_error(message):
    print("Tether Guest Installer: " + message, file=sys.stderr)
    try:
        subprocess.run(["zenity", "--error", "--title=Tether Guest Installer", "--text=" + message],
                       check=False, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        pass


def main():
    if os.geteuid() == 0 or os.getuid() < 1000:
        runtime_error("Sign in to Debian with your normal desktop account, then open Tether Guest Installer again.")
        return 1
    if not (RESOURCE_DIR / "update-guest-tools.sh").is_file():
        runtime_error("Installer resources are missing. Open the original Tether Guest Installer again.")
        return 1
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk, GLib, Gdk
    except (ImportError, ValueError) as error:
        runtime_error("Debian's GTK 3 Python runtime is missing. Install python3-gi and gir1.2-gtk-3.0, then reopen this installer. "
                      + str(error))
        return 1

    class Installer(Gtk.Window):
        def __init__(self):
            super().__init__(title="Tether Guest Installer")
            screen = Gdk.Screen.get_default()
            monitor = screen.get_primary_monitor()
            workarea = screen.get_monitor_workarea(monitor if monitor >= 0 else 0)
            self.set_default_size(min(900, max(620, workarea.width - 24)),
                                  min(620, max(400, workarea.height - 20)))
            self.set_size_request(600, 380)
            self.set_position(Gtk.WindowPosition.CENTER)
            self.set_border_width(0)
            self.connect("delete-event", self.on_close)
            self.current = first_incomplete(HOME) or STAGES[-1]
            self.phase = "idle"
            self.failed_at = None
            self.process = None
            self.child_pid = None
            self.stop_after_current = False
            self.terminal = None
            self.login_url = None
            self.login_scan_pending = False
            self.link_regex = None
            self.Vte = None
            self.bootstrapped = False
            try:
                self.log = InstallerLog(HOME)
                self.log.note(f"installer launched: {installer_version()}")
            except OSError:
                self.log = None
            if RESOURCE_DIR == Path("/opt/tether-guest") and Path("/opt/tether-guest/setup.sh").is_file():
                try:
                    gi.require_version("Vte", "2.91")
                    from gi.repository import Vte
                    self.Vte = Vte
                    self.bootstrapped = True
                except (ImportError, ValueError):
                    pass
            self.rows = {}
            self.statuses = {stage.key: ("Complete" if stage.receipt(HOME).is_file() else "Not started")
                             for stage in STAGES}
            if COMPUTER_USE_SIGNOUT_MARKER.is_file():
                self.statuses["computer-use"] = "Sign out needed"
            self.build_ui(Gtk, GLib)
            self.refresh()
            if self.bootstrapped:
                self.start_clipboard_broker()
                self.start_keep_awake()

        def start_keep_awake(self):
            helper = Path("/opt/tether-guest/keep-awake.sh")
            if not helper.is_file():
                return
            try:
                subprocess.Popen([str(helper)], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            except OSError:
                pass  # Session autostart retries the inhibitor at the next login.

        def start_clipboard_broker(self):
            path = Path("/opt/tether-guest/clipboard_broker.py")
            if not path.is_file():
                self.clipboard_status.set_text("Clipboard: needs guest tools. Prepare them first.")
                return
            state = HOME / ".local/share/tether-guest"
            if (state / "clipboard-disabled").exists():
                self.clipboard_status.set_text("Clipboard: off. Open Tether Text Clipboard to enable it.")
                return
            if not (state / "clipboard-enabled").is_file():
                self.clipboard_status.set_text("Clipboard: needs attention. Open Tether Text Clipboard to enable it.")
                return
            self.clipboard_status.set_text("Clipboard: checking desktop session…")
            try:
                subprocess.Popen(["/usr/bin/python3", str(path)], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            except OSError as error:
                self.clipboard_status.set_text(f"Clipboard: needs attention ({error}).")
                return

            def probe():
                endpoint = f"/run/user/{os.getuid()}/tether-clipboard.sock"
                for _ in range(10):
                    try:
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                            connection.settimeout(0.7)
                            connection.connect(endpoint)
                            connection.sendall(b"\x04\x00\x00\x00\x00")
                            header = connection.recv(5, socket.MSG_WAITALL)
                            if len(header) == 5 and header[0] == 0 and struct.unpack(">I", header[1:])[0] == 0:
                                self.GLib.idle_add(self.clipboard_status.set_text, "Clipboard: ready for explicit Mac transfers.")
                                return
                    except OSError:
                        pass
                    time.sleep(0.2)
                self.GLib.idle_add(self.clipboard_status.set_text,
                                   "Clipboard: needs attention. Check your desktop session, then choose Retry.")

            threading.Thread(target=probe, daemon=True).start()

        def build_ui(self, Gtk, GLib):
            self.Gtk, self.GLib = Gtk, GLib
            css = Gtk.CssProvider()
            css.load_from_data(b"""
                .hero { background: #142b31; color: #f7f6ef; padding: 9px 16px; }
                .hero-title { font-size: 20px; font-weight: 700; }
                .hero-subtitle { color: #c8d7d4; }
                .sidebar { background: #f2f4f1; padding: 8px; }
                .step-title { font-weight: 600; }
                .muted { color: #62736d; }
                .content { padding: 12px 18px; }
                .content-title { font-size: 20px; font-weight: 700; }
                .footer { padding: 8px 14px; border-top: 1px solid #d9e0dc; }
                .error { color: #a63832; font-weight: 600; }
                .success { color: #26704b; font-weight: 600; }
                .primary { background: #137c71; color: white; border-radius: 7px; padding: 7px 16px; }
                .details { background: #102028; color: #e7efed; }
            """)
            Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                                     Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
            outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            self.add(outer)
            hero = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            hero.get_style_context().add_class("hero")
            heading = Gtk.Label(label="Set up Tether in this Debian VM", xalign=0)
            heading.get_style_context().add_class("hero-title")
            hero.pack_start(heading, False, False, 0)
            sub = Gtk.Label(label=f"One guide for the guest connection  ·  Version {installer_version()}", xalign=0)
            sub.get_style_context().add_class("hero-subtitle")
            hero.pack_start(sub, False, False, 0)
            outer.pack_start(hero, False, False, 0)

            main_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            outer.pack_start(main_box, True, True, 0)
            side_scroll = Gtk.ScrolledWindow()
            side_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            side_scroll.set_size_request(215, -1)
            main_box.pack_start(side_scroll, False, True, 0)
            side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            side.get_style_context().add_class("sidebar")
            side_scroll.add(side)
            label = Gtk.Label(label="SETUP STEPS", xalign=0)
            label.get_style_context().add_class("muted")
            side.pack_start(label, False, False, 8)
            bootstrap = Gtk.Label(label="Prepare guest tools", xalign=0)
            bootstrap.get_style_context().add_class("step-title")
            side.pack_start(bootstrap, False, False, 4)
            self.bootstrap_status = Gtk.Label(label="Ready" if self.bootstrapped else "Not started", xalign=0)
            self.bootstrap_status.get_style_context().add_class("muted")
            side.pack_start(self.bootstrap_status, False, False, 8)
            for number, stage in enumerate(STAGES, 1):
                button = Gtk.Button()
                button.set_relief(Gtk.ReliefStyle.NONE)
                button.connect("clicked", self.select_stage, stage)
                row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
                name = Gtk.Label(label=f"{number}. {stage.title}", xalign=0)
                name.get_style_context().add_class("step-title")
                status = Gtk.Label(label="Not started", xalign=0)
                status.get_style_context().add_class("muted")
                row.pack_start(name, False, False, 0)
                row.pack_start(status, False, False, 0)
                button.add(row)
                side.pack_start(button, False, False, 0)
                self.rows[stage.key] = (button, status)

            content_scroll = Gtk.ScrolledWindow()
            content_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            main_box.pack_start(content_scroll, True, True, 0)
            content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            content.get_style_context().add_class("content")
            content_scroll.add(content)
            self.step_count = Gtk.Label(xalign=0)
            self.step_count.get_style_context().add_class("muted")
            content.pack_start(self.step_count, False, False, 0)
            self.title_label = Gtk.Label(xalign=0)
            self.title_label.get_style_context().add_class("content-title")
            content.pack_start(self.title_label, False, False, 0)
            self.description = Gtk.Label(xalign=0)
            self.description.set_line_wrap(True)
            self.description.set_max_width_chars(54)
            content.pack_start(self.description, False, False, 0)
            self.guidance = Gtk.Label(xalign=0)
            self.guidance.set_line_wrap(True)
            self.guidance.set_max_width_chars(54)
            self.guidance.get_style_context().add_class("muted")
            content.pack_start(self.guidance, False, False, 0)
            activity = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            self.spinner = Gtk.Spinner()
            activity.pack_start(self.spinner, False, False, 0)
            self.activity_label = Gtk.Label(xalign=0)
            self.activity_label.set_line_wrap(True)
            self.activity_label.set_max_width_chars(54)
            activity.pack_start(self.activity_label, True, True, 0)
            content.pack_start(activity, False, False, 8)
            clipboard_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            self.clipboard_status = Gtk.Label(label="Clipboard: checking desktop session…", xalign=0)
            clipboard_row.pack_start(self.clipboard_status, True, True, 0)
            self.clipboard_retry = Gtk.Button(label="Retry")
            self.clipboard_retry.connect("clicked", lambda _button: self.start_clipboard_broker())
            clipboard_row.pack_start(self.clipboard_retry, False, False, 0)
            content.pack_start(clipboard_row, False, False, 0)

            console_tools = Gtk.FlowBox()
            console_tools.set_selection_mode(Gtk.SelectionMode.NONE)
            console_tools.set_column_spacing(6)
            console_tools.set_row_spacing(4)
            console_tools.set_min_children_per_line(2)
            console_tools.set_max_children_per_line(2)
            content.pack_start(console_tools, False, False, 0)
            self.copy_button = Gtk.Button(label="Copy selected text")
            self.copy_button.set_tooltip_text("Copy a selection to this Debian VM's clipboard (Ctrl+Shift+C).")
            self.copy_button.connect("clicked", self.copy_terminal_selection)
            console_tools.add(self.copy_button)
            self.paste_button = Gtk.Button(label="Paste")
            self.paste_button.set_tooltip_text("Paste from this Debian VM's clipboard into the console (Ctrl+Shift+V).")
            self.paste_button.connect("clicked", self.paste_terminal_clipboard)
            console_tools.add(self.paste_button)
            self.open_login_button = Gtk.Button(label="Open Tailscale sign-in")
            self.open_login_button.set_tooltip_text("Open the sign-in link shown by Tailscale in this Debian VM.")
            self.open_login_button.connect("clicked", self.open_tailscale_login)
            console_tools.add(self.open_login_button)
            self.copy_login_button = Gtk.Button(label="Copy sign-in link")
            self.copy_login_button.set_tooltip_text("Copy the sign-in link to Debian's clipboard, then use Tether Host to copy VM text to Mac.")
            self.copy_login_button.connect("clicked", self.copy_tailscale_login)
            console_tools.add(self.copy_login_button)

            self.details = Gtk.Expander(label="Details and interactive console")
            self.details.set_expanded(False)
            content.pack_start(self.details, True, True, 0)
            self.detail_stack = Gtk.Stack()
            self.details.add(self.detail_stack)
            bootstrap_scroll = Gtk.ScrolledWindow()
            bootstrap_scroll.set_min_content_height(160)
            self.bootstrap_text = Gtk.TextView()
            self.bootstrap_text.set_editable(False)
            self.bootstrap_text.set_cursor_visible(False)
            self.bootstrap_text.set_monospace(True)
            self.bootstrap_text.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
            self.bootstrap_text.get_style_context().add_class("details")
            bootstrap_scroll.add(self.bootstrap_text)
            self.detail_stack.add_named(bootstrap_scroll, "bootstrap")
            self.detail_stack.set_visible_child_name("bootstrap")

            bottom = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            bottom.get_style_context().add_class("footer")
            outer.pack_end(bottom, False, False, 0)
            self.return_button = Gtk.Button(label="I returned from sign-in")
            self.return_button.connect("clicked", self.focus_console)
            bottom.pack_start(self.return_button, False, False, 0)
            self.cancel_button = Gtk.Button(label="Stop after this step")
            self.cancel_button.connect("clicked", self.cancel)
            bottom.pack_end(self.cancel_button, False, False, 0)
            self.action_button = Gtk.Button(label="Start setup")
            self.action_button.get_style_context().add_class("primary")
            self.action_button.connect("clicked", self.primary_action)
            bottom.pack_end(self.action_button, False, False, 0)
            self.show_all()

        def select_stage(self, _button, stage):
            if self.phase not in {"idle", "failed", "done"}:
                return
            self.current = stage
            self.phase = "idle"
            self.failed_at = None
            self.refresh()

        def refresh(self):
            stage = self.current
            signout_needed = stage.key == "computer-use" and COMPUTER_USE_SIGNOUT_MARKER.is_file()
            position = STAGES.index(stage) + 1
            self.step_count.set_text(f"STEP {position} OF {len(STAGES)}")
            self.title_label.set_text(stage.title)
            self.description.set_text(stage.description)
            self.guidance.set_text(stage.guidance)
            for key, (button, status) in self.rows.items():
                status.set_text(self.statuses[key])
                button.set_sensitive(self.phase in {"idle", "failed", "done"})
            self.return_button.set_visible(self.phase == "stage" and stage.interactive)
            busy = self.phase in {"bootstrap", "stage", "stopping"}
            pending = first_incomplete(HOME)
            blocked = self.bootstrapped and self.phase == "idle" and pending is not None and \
                STAGES.index(pending) < STAGES.index(stage)
            self.action_button.set_sensitive(not busy and not blocked)
            self.copy_button.set_sensitive(self.terminal is not None and self.terminal.get_has_selection())
            self.paste_button.set_sensitive(self.terminal is not None and self.phase in {"stage", "stopping"})
            self.open_login_button.set_visible(stage.key == "tailscale" and self.login_url is not None)
            self.copy_login_button.set_visible(stage.key == "tailscale" and self.login_url is not None)
            self.cancel_button.set_sensitive(busy and self.phase != "stopping")
            self.cancel_button.set_visible(busy)
            if busy:
                self.spinner.start()
            else:
                self.spinner.stop()
            if self.phase == "idle":
                self.action_button.set_label("Retry after sign-in" if signout_needed and self.bootstrapped else
                                             (stage.action if self.bootstrapped else "Prepare guest tools"))
                if blocked:
                    self.activity_label.set_text(f"Complete {pending.title} first. Select it on the left to continue.")
                elif self.bootstrapped:
                    self.activity_label.set_text(COMPUTER_USE_SIGNOUT_GUIDANCE if signout_needed else
                                                 "Ready to run this step. Completed steps are checked again when run.")
                else:
                    self.activity_label.set_text("Prepare guest tools first. Debian will ask for administrator approval.")
            elif self.phase == "bootstrap":
                self.activity_label.set_text("Preparing guest tools. Approve the Debian administrator prompt when it appears.")
            elif self.phase == "stage":
                self.activity_label.set_text("Waiting for you in the console…" if stage.interactive else
                                             "Working on this step…")
            elif self.phase == "stopping":
                self.activity_label.set_text("Stopping after the current operation completes…")
            elif self.phase == "failed":
                self.action_button.set_label("Retry after sign-in" if signout_needed else "Retry step")
            elif self.phase == "done":
                self.action_button.set_label("Recheck connection")
                self.activity_label.set_text("Guest setup is complete. The private connection was verified.")

        def primary_action(self, _button):
            if self.phase == "failed" and self.failed_at is not None:
                if self.failed_at == "bootstrap":
                    self.start_bootstrap()
                else:
                    self.run_stage(self.failed_at)
            elif self.phase == "done":
                self.run_stage(STAGES[-1])
            elif self.phase == "idle":
                if self.bootstrapped:
                    self.run_stage(self.current)
                else:
                    self.start_bootstrap()

        def fail(self, message, at):
            if self.log:
                self.log.stage(at if at == "bootstrap" else at.key, "failed")
                self.log.note(message)
            self.phase = "failed"
            self.failed_at = at
            self.activity_label.set_text(message)
            self.activity_label.get_style_context().add_class("error")
            self.details.set_expanded(True)
            if at != "bootstrap":
                self.statuses[at.key] = ("Sign out needed" if at.key == "computer-use" and
                                         COMPUTER_USE_SIGNOUT_MARKER.is_file() else "Failed")
            else:
                self.bootstrap_status.set_text("Failed")
            self.refresh()
            self.activity_label.set_text(message)

        def append_bootstrap(self, chunk):
            if self.log:
                self.log.bootstrap_chunk(chunk)
            chunk = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", chunk)
            chunk = "".join(char for char in chunk if char in "\n\r\t" or ord(char) >= 32)
            buffer = self.bootstrap_text.get_buffer()
            buffer.insert(buffer.get_end_iter(), chunk)
            if buffer.get_char_count() > 100_000:
                buffer.delete(buffer.get_start_iter(), buffer.get_iter_at_offset(buffer.get_char_count() - 100_000))
            self.bootstrap_text.scroll_to_iter(buffer.get_end_iter(), 0, False, 0, 0)
            if "Get:" in chunk or "Fetched " in chunk:
                self.activity_label.set_text("Downloading Debian packages…")
            elif "Setting up " in chunk or "Unpacking " in chunk:
                self.activity_label.set_text("Installing guest tools…")
            return False

        def start_bootstrap(self):
            if self.log:
                self.log.stage("bootstrap", "started")
            self.phase = "bootstrap"
            self.failed_at = None
            self.stop_after_current = False
            self.bootstrap_status.set_text("Running")
            self.activity_label.get_style_context().remove_class("error")
            self.detail_stack.set_visible_child_name("bootstrap")
            self.details.set_expanded(True)
            self.refresh()
            try:
                self.process = subprocess.Popen(
                    ["pkexec", "/bin/sh", str(RESOURCE_DIR / "update-guest-tools.sh")],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    close_fds=True)
            except OSError as error:
                self.process = None
                self.fail(f"Could not open Debian authentication: {error}", "bootstrap")
                return

            def read_output(process):
                decoder = codecs.getincrementaldecoder("utf-8")("replace")
                try:
                    while True:
                        raw = os.read(process.stdout.fileno(), 8192)
                        if not raw:
                            break
                        text = decoder.decode(raw)
                        if text:
                            GLib.idle_add(self.append_bootstrap, text)
                    tail = decoder.decode(b"", final=True)
                    if tail:
                        GLib.idle_add(self.append_bootstrap, tail)
                    code = process.wait()
                except OSError as error:
                    GLib.idle_add(self.append_bootstrap, f"\nOutput stream error: {error}\n")
                    code = process.wait()
                GLib.idle_add(self.bootstrap_finished, code)

            threading.Thread(target=read_output, args=(self.process,), daemon=True).start()

        def bootstrap_finished(self, code):
            if self.log:
                self.log.flush_bootstrap()
                if code == 0:
                    self.log.stage("bootstrap", "complete", exit_code=code)
                else:
                    self.log.stage("bootstrap", "failed", exit_code=code)
            self.process = None
            if code != 0:
                detail = "Authentication was cancelled." if code in {126, 127} else f"Guest tools stopped (exit code {code}). Read Details, then retry."
                self.fail(detail, "bootstrap")
                return False
            self.bootstrap_status.set_text("Complete")
            if self.stop_after_current:
                self.phase = "idle"
                self.stop_after_current = False
                self.refresh()
                return False
            if not Path("/opt/tether-guest/setup.sh").is_file():
                self.fail("Guest tools did not install the setup program. Read Details, then retry.", "bootstrap")
                return False
            try:
                gi.require_version("Vte", "2.91")
                from gi.repository import Vte
                self.Vte = Vte
                self.bootstrapped = True
            except (ImportError, ValueError) as error:
                self.fail("The interactive console is missing. Install gir1.2-vte-2.91 and retry. " + str(error),
                          "bootstrap")
                return False
            self.phase = "idle"
            self.current = first_incomplete(HOME) or STAGES[-1]
            self.login_url = None
            self.start_clipboard_broker()
            self.start_keep_awake()
            self.refresh()
            self.activity_label.set_text("Guest tools are ready. Choose the next step to continue.")
            return False

        def ensure_terminal(self):
            if self.terminal is not None:
                return
            self.terminal = self.Vte.Terminal()
            self.terminal.set_scrollback_lines(2500)
            self.terminal.connect("child-exited", self.stage_finished)
            self.terminal.connect("selection-changed", lambda *_: self.refresh())
            self.terminal.connect("contents-changed", self.terminal_contents_changed)
            self.terminal.connect("key-press-event", self.terminal_key_press)
            self.terminal.connect("button-press-event", self.terminal_button_press)
            try:
                pattern = r"https://[^\s<>\"']+"
                self.link_regex = self.Vte.Regex.new_for_match(pattern, -1, 0)
                self.terminal.match_add_regex(self.link_regex, 0)
            except (AttributeError, ValueError, self.GLib.Error):
                self.link_regex = None
            scroll = self.Gtk.ScrolledWindow()
            scroll.set_min_content_height(160)
            scroll.add(self.terminal)
            self.detail_stack.add_named(scroll, "terminal")
            scroll.show_all()

        def run_stage(self, stage):
            if self.log:
                self.log.stage(stage.key, "started")
            self.current = stage
            self.login_url = None
            self.phase = "stage"
            self.failed_at = None
            self.stop_after_current = False
            for later in STAGES[STAGES.index(stage) + 1:]:
                self.statuses[later.key] = "Not started"
            self.statuses[stage.key] = "Waiting for you" if stage.interactive else "Running"
            self.activity_label.get_style_context().remove_class("error")
            self.ensure_terminal()
            self.terminal.reset(True, True)
            self.detail_stack.set_visible_child_name("terminal")
            # Sudo and provider prompts can appear in any stage.
            self.details.set_expanded(True)
            self.refresh()
            argv = ["/opt/tether-guest/setup.sh", stage.key]

            def spawned(*result):
                pid = result[1] if len(result) > 1 else -1
                error = result[2] if len(result) > 2 else None
                if error is not None:
                    self.child_pid = None
                    self.fail(f"Could not start {stage.title}: {error}", stage)
                else:
                    self.child_pid = pid
                    if stage.interactive:
                        self.terminal.grab_focus()

            try:
                self.terminal.spawn_async(self.Vte.PtyFlags.DEFAULT, str(HOME), argv, [],
                                          self.GLib.SpawnFlags.DEFAULT, None, None, -1, None, spawned, None)
            except (OSError, TypeError, self.GLib.Error) as error:
                self.child_pid = None
                self.fail(f"Could not start {stage.title}: {error}", stage)

        def stage_finished(self, _terminal, wait_status):
            stage = self.current
            self.child_pid = None
            try:
                code = os.waitstatus_to_exitcode(wait_status)
            except ValueError:
                code = 1
            receipt = verified_exit(stage, HOME, code)
            if self.log:
                self.log.stage(stage.key, "complete" if receipt else "failed",
                               exit_code=code, receipt=receipt)
            if not receipt and code != 0 and stage.key == "computer-use" and COMPUTER_USE_SIGNOUT_MARKER.is_file():
                self.stop_after_current = False
                self.fail(COMPUTER_USE_SIGNOUT_GUIDANCE, stage)
                return
            if self.stop_after_current:
                self.statuses[stage.key] = "Complete" if receipt else "Cancelled"
                self.phase = "idle"
                self.stop_after_current = False
                self.refresh()
                self.activity_label.set_text("Stopped after this step. Press Start setup to resume.")
                return
            if not receipt:
                message = (f"{stage.title} stopped (exit code {code}). Read the console error and retry."
                           if code != 0 else
                           f"{stage.title} exited without a verified receipt. Read Details and retry.")
                self.fail(message, stage)
                return
            self.statuses[stage.key] = "Complete"
            index = STAGES.index(stage)
            if index + 1 < len(STAGES):
                self.current = STAGES[index + 1]
                self.login_url = None
                self.phase = "idle"
                self.details.set_expanded(False)
                self.refresh()
                self.activity_label.set_text(f"{stage.title} is complete. Choose the next step when ready.")
            else:
                self.phase = "done"
                self.refresh()

        def focus_console(self, _button):
            self.details.set_expanded(True)
            if self.terminal:
                self.terminal.grab_focus()

        def copy_terminal_selection(self, _button=None):
            if self.terminal is not None and self.terminal.get_has_selection():
                self.terminal.copy_clipboard_format(self.Vte.Format.TEXT)

        def paste_terminal_clipboard(self, _button=None):
            if self.terminal is not None and self.phase in {"stage", "stopping"}:
                self.terminal.paste_clipboard()
                self.terminal.grab_focus()

        def terminal_key_press(self, _terminal, event):
            modifiers = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK
            if event.state & modifiers != modifiers:
                return False
            key = (Gdk.keyval_name(event.keyval) or "").lower()
            if key == "c":
                self.copy_terminal_selection()
                return True
            if key == "v":
                self.paste_terminal_clipboard()
                return True
            return False

        def terminal_button_press(self, terminal, event):
            if event.button == 3:
                menu = self.Gtk.Menu()
                copy_item = self.Gtk.MenuItem.new_with_label("Copy selected text")
                copy_item.set_sensitive(terminal.get_has_selection())
                copy_item.connect("activate", self.copy_terminal_selection)
                menu.append(copy_item)
                paste_item = self.Gtk.MenuItem.new_with_label("Paste from Debian clipboard")
                paste_item.set_sensitive(self.phase in {"stage", "stopping"})
                paste_item.connect("activate", self.paste_terminal_clipboard)
                menu.append(paste_item)
                menu.show_all()
                menu.popup_at_pointer(event)
                return True
            if event.button == 1 and event.state & Gdk.ModifierType.CONTROL_MASK:
                try:
                    match = terminal.match_check_event(event)
                    text = match[0] if isinstance(match, tuple) else match
                    url = safe_https_url(text.rstrip(".,;)")) if text else None
                    if url:
                        self.open_url(url)
                        return True
                except (AttributeError, ValueError, self.GLib.Error):
                    pass
            return False

        def terminal_contents_changed(self, _terminal):
            if self.current.key != "tailscale" or self.login_url is not None or self.login_scan_pending:
                return
            self.login_scan_pending = True
            self.GLib.timeout_add(150, self.scan_tailscale_login)

        def scan_tailscale_login(self):
            self.login_scan_pending = False
            if self.current.key != "tailscale" or self.terminal is None:
                return False
            try:
                visible = self.terminal.get_text_format(self.Vte.Format.TEXT)
            except (AttributeError, ValueError, self.GLib.Error):
                return False
            url = tailscale_login_url(visible or "")
            if url:
                self.login_url = url
                self.open_login_button.set_visible(True)
            return False

        def open_url(self, url):
            try:
                self.Gtk.show_uri_on_window(self, url, Gdk.CURRENT_TIME)
            except (OSError, ValueError, self.GLib.Error) as error:
                self.activity_label.get_style_context().add_class("error")
                self.activity_label.set_text(f"Could not open the browser: {error}. Copy the link from the console and open it in Firefox.")

        def open_tailscale_login(self, _button):
            if self.current.key == "tailscale" and self.login_url:
                self.open_url(self.login_url)

        def copy_tailscale_login(self, _button):
            if self.current.key != "tailscale" or not self.login_url:
                return
            clipboard = self.Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
            clipboard.set_text(self.login_url, -1)
            self.activity_label.set_text("Sign-in link copied in Debian. In Tether Host, choose Clipboard → Copy VM text to Mac.")

        def cancel(self, _button):
            if self.phase == "bootstrap":
                self.stop_after_current = True
                self.phase = "stopping"
                self.refresh()
                self.activity_label.set_text("Package installation must finish safely. If the administrator prompt is open, you may cancel it there.")
            elif self.phase == "stage":
                self.stop_after_current = True
                self.phase = "stopping"
                self.refresh()
                self.activity_label.set_text("This step will finish or reach a safe stopping point before setup stops. If it is waiting for sign-in, return to the console to cancel that prompt.")

        def on_close(self, _window, _event):
            if self.phase in {"bootstrap", "stage", "stopping"}:
                dialog = self.Gtk.MessageDialog(self, 0, self.Gtk.MessageType.INFO,
                                                self.Gtk.ButtonsType.OK,
                                                "Finish or cancel the current step before closing")
                dialog.format_secondary_text("Package changes and interactive sign-in need a safe stopping point. Use Cancel in this window.")
                dialog.run()
                dialog.destroy()
                return True
            self.Gtk.main_quit()
            return False

    # `gi` stays in this scope so lazy VTE import in bootstrap_finished works.
    window = Installer()
    Gtk.main()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
