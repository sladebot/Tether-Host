#!/usr/bin/env python3
"""Follow Virtualization's changing virtio display size in an X11 session."""

import fcntl
import os
from pathlib import Path
import re
import subprocess
import time


XRANDR = "/usr/bin/xrandr"
OUTPUT = re.compile(r"^(\S+) connected(?: primary)?(?:\s|$)")
MODE = re.compile(r"^\s+(\d+x\d+)\s+(.+)$")


def display_modes(query):
    """Return current and preferred modes for each connected XRandR output."""
    modes = {}
    output = None
    for line in query.splitlines():
        match = OUTPUT.match(line)
        if match:
            output = match.group(1)
            modes[output] = {"current": None, "preferred": None}
            continue
        if line and not line[0].isspace():
            output = None
        match = MODE.match(line) if output else None
        if match:
            mode, refresh_rates = match.groups()
            if "*" in refresh_rates:
                modes[output]["current"] = mode
            if "+" in refresh_rates:
                modes[output]["preferred"] = mode
    return modes


def modes_to_apply(modes, last_preferred):
    """Change modes only when the host's preferred size changes."""
    for output in tuple(last_preferred):
        if output not in modes:
            del last_preferred[output]
    for output, sizes in modes.items():
        preferred = sizes["preferred"]
        if preferred is None:
            continue
        if sizes["current"] == preferred:
            last_preferred[output] = preferred
        elif last_preferred.get(output) != preferred:
            yield output, preferred


def main():
    if os.environ.get("XDG_SESSION_TYPE") != "x11" or not os.environ.get("DISPLAY"):
        return
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    if not runtime.is_dir() or runtime.stat().st_uid != os.getuid():
        return
    with (runtime / "tether-display-resize.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        last_preferred = {}
        failed_queries = 0
        while True:
            try:
                query = subprocess.check_output([XRANDR, "--query"], text=True,
                                                stderr=subprocess.DEVNULL, timeout=3)
                failed_queries = 0
            except (OSError, subprocess.SubprocessError):
                failed_queries += 1
                if failed_queries >= 10:
                    return  # The X11 session has ended.
                time.sleep(1)
                continue
            modes = display_modes(query)
            for output, preferred in modes_to_apply(modes, last_preferred):
                try:
                    subprocess.run([XRANDR, "--output", output, "--auto"], check=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                    last_preferred[output] = preferred
                except (OSError, subprocess.SubprocessError):
                    pass  # The mode may be changing; retry on the next poll.
            time.sleep(1)


if __name__ == "__main__":
    main()
