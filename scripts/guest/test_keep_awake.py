"""Check the session inhibitor command selected by the shipped helper."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "TetherHost/Resources/LinuxGuestSetup/keep-awake.sh"
DESKTOP_CASE = SOURCE.read_text().split("# BEGIN_KEEP_AWAKE_DESKTOP\n", 1)[1].split(
    "# END_KEEP_AWAKE_DESKTOP", 1)[0]


class KeepAwakeTests(unittest.TestCase):
    def run_desktop(self, desktop, available=("gnome-session-inhibit", "xfce4-screensaver-command")):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            trace = root / "trace"
            for name in available:
                command = root / name
                command.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" > "$TRACE"\n')
                command.chmod(0o755)
            env = os.environ.copy()
            env.update(XDG_CURRENT_DESKTOP=desktop, PATH=str(root) + os.pathsep + env.get("PATH", ""),
                       TRACE=str(trace))
            result = subprocess.run(["/bin/sh", "-eu", "-c", DESKTOP_CASE], env=env,
                                    capture_output=True, text=True, timeout=5)
            return result, trace.read_text() if trace.exists() else ""

    def test_gnome_inhibits_idle_and_suspend_without_logout(self):
        result, command = self.run_desktop("ubuntu:GNOME")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--inhibit idle:suspend --inhibit-only", command)
        self.assertIn("--app-id app.tether.guest", command)
        self.assertNotIn("logout", command)

    def test_xfce_uses_its_session_screensaver_inhibitor(self):
        result, command = self.run_desktop("XFCE")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("xfce4-screensaver-command --inhibit", command)

    def test_missing_or_unknown_desktop_inhibitor_fails_closed(self):
        for desktop, available in (("ubuntu:GNOME", ()), ("UNKNOWN", ("gnome-session-inhibit",))):
            with self.subTest(desktop=desktop):
                result, command = self.run_desktop(desktop, available)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(command, "")


if __name__ == "__main__":
    unittest.main()
