"""Debian X11 display follows the host's preferred virtio scanout mode."""

import importlib.util
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "TetherHost/Resources/LinuxGuestSetup/display-resize.py"
spec = importlib.util.spec_from_file_location("display_resize", SOURCE)
resize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resize)


class DisplayResizeTests(unittest.TestCase):
    def test_parses_connected_output_and_preferred_mode(self):
        query = """Screen 0: minimum 320 x 200, current 1024 x 768, maximum 16384 x 16384
Virtual-1 connected primary 1024x768+0+0 (normal left inverted right x axis y axis)
   1600x1000     60.00 +
   1024x768      60.00*  59.92
HDMI-1 disconnected (normal left inverted right x axis y axis)
"""
        self.assertEqual(resize.display_modes(query), {
            "Virtual-1": {"current": "1024x768", "preferred": "1600x1000"}
        })

    def test_tracks_host_changes_without_overriding_manual_guest_change(self):
        last = {}
        sizes = {"Virtual-1": {"current": "1024x768", "preferred": "1600x1000"}}
        self.assertEqual(list(resize.modes_to_apply(sizes, last)), [("Virtual-1", "1600x1000")])
        last["Virtual-1"] = "1600x1000"  # Successful xrandr --auto.
        self.assertEqual(list(resize.modes_to_apply(sizes, last)), [])
        sizes["Virtual-1"] = {"current": "1280x800", "preferred": "1600x1000"}
        self.assertEqual(list(resize.modes_to_apply(sizes, last)), [])
        sizes["Virtual-1"]["preferred"] = "1920x1080"
        self.assertEqual(list(resize.modes_to_apply(sizes, last)), [("Virtual-1", "1920x1080")])
        self.assertEqual(list(resize.modes_to_apply({}, last)), [])
        self.assertEqual(last, {})

    def test_missing_preferred_mode_does_not_guess(self):
        sizes = {"Virtual-1": {"current": "1024x768", "preferred": None}}
        self.assertEqual(list(resize.modes_to_apply(sizes, {})), [])


if __name__ == "__main__":
    unittest.main()
