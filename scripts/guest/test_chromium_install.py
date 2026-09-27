"""Checks for Debian's native Chromium package verification."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


UPDATER = Path(__file__).resolve().parents[2] / "TetherHost/Resources/LinuxGuestSetup/update-guest-tools.sh"
SOURCE = UPDATER.read_text()
FUNCTION = SOURCE.split("# BEGIN_CHROMIUM_INSTALL\n", 1)[1].split("# END_CHROMIUM_INSTALL", 1)[0]


class ChromiumInstallTests(unittest.TestCase):
    def run_check(self, *, chromium=True, package=True):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory) / "bin"
            bin_dir.mkdir()
            if chromium:
                executable = bin_dir / "chromium"
                executable.write_text("#!/bin/sh\nexit 0\n")
                executable.chmod(0o755)
            dpkg = bin_dir / "dpkg-query"
            dpkg.write_text("#!/bin/sh\n" +
                            ("printf 'install ok installed\\n'\n" if package else "exit 1\n"))
            dpkg.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
            script = "fail() { printf '%s\\n' \"$1\" >&2; exit 1; }\n" + FUNCTION + "\ninstall_chromium\n"
            return subprocess.run(["/bin/sh", "-eu", "-c", script], env=env,
                                  text=True, capture_output=True, timeout=5)

    def test_accepts_native_debian_chromium_package(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Chromium is ready", result.stdout)
        self.assertNotIn("snap", FUNCTION.lower())

    def test_missing_executable_is_actionable(self):
        result = self.run_check(chromium=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Chromium is not available", result.stderr)
        self.assertIn("retry Prepare guest tools", result.stderr)

    def test_incomplete_package_is_actionable(self):
        result = self.run_check(package=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not fully installed", result.stderr)


if __name__ == "__main__":
    unittest.main()
