"""Command-stub checks for the updater's actual Chromium install function."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


UPDATER = Path(__file__).resolve().parents[2] / "TetherHost/Resources/LinuxGuestSetup/update-guest-tools.sh"
SOURCE = UPDATER.read_text()
FUNCTION = SOURCE.split("# BEGIN_CHROMIUM_INSTALL\n", 1)[1].split("# END_CHROMIUM_INSTALL", 1)[0]


class ChromiumInstallTests(unittest.TestCase):
    def run_installer(self, *, installed=False, failure=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for name, script in {
                "systemctl": '''#!/bin/sh
printf 'systemctl %s\\n' "$*" >> "$STUB_LOG"
[ "$STUB_FAIL" != socket ]
''',
                "timeout": '''#!/bin/sh
printf 'timeout %s\\n' "$*" >> "$STUB_LOG"
[ "$1" = --foreground ] && shift
shift
"$@"
''',
                "snap": '''#!/bin/sh
printf 'snap %s\\n' "$*" >> "$STUB_LOG"
case "$1" in
  wait) [ "$STUB_FAIL" != seed ] ;;
  list) [ -f "$STUB_INSTALLED" ] ;;
  install)
    [ "$STUB_FAIL" != install ] || exit 1
    : > "$STUB_INSTALLED" ;;
  *) exit 2 ;;
esac
''',
            }.items():
                executable = bin_dir / name
                executable.write_text(script)
                executable.chmod(0o755)
            state = root / "installed"
            if installed:
                state.touch()
            trace = root / "trace"
            env = os.environ.copy()
            env.update(PATH=str(bin_dir) + os.pathsep + env.get("PATH", ""),
                       STUB_LOG=str(trace), STUB_INSTALLED=str(state), STUB_FAIL=failure)
            script = "fail() { printf '%s\\n' \"$1\" >&2; exit 1; }\n" + FUNCTION + "\ninstall_chromium\n"
            result = subprocess.run(["/bin/sh", "-eu", "-c", script], env=env,
                                    text=True, capture_output=True, timeout=5)
            return result, trace.read_text().splitlines(), state.exists()

    def test_installs_official_stable_snap_after_bounded_seed_wait(self):
        result, trace, installed = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(installed)
        self.assertIn("systemctl enable --now snapd.socket", trace)
        self.assertIn("timeout --foreground 300s snap wait system seed.loaded", trace)
        self.assertIn("timeout --foreground 1200s snap install chromium --channel=stable", trace)
        self.assertEqual(trace.count("snap list chromium"), 2)

    def test_existing_chromium_is_not_reinstalled(self):
        result, trace, installed = self.run_installer(installed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(installed)
        self.assertNotIn("snap install chromium --channel=stable", "\n".join(trace))
        self.assertIn("already installed", result.stdout)

    def test_install_and_seed_failures_are_actionable(self):
        for failure, expected in (("install", "Chromium installation failed"),
                                  ("seed", "Ubuntu snap setup did not finish"),
                                  ("socket", "Could not start snapd")):
            with self.subTest(failure=failure):
                result, _trace, installed = self.run_installer(failure=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(installed)
                self.assertIn(expected, result.stderr)
                self.assertIn("retry Prepare guest tools", result.stderr)


if __name__ == "__main__":
    unittest.main()
