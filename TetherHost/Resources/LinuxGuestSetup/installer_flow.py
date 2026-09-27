"""Small, GTK-independent contract for the Debian guest installer guide."""

from dataclasses import dataclass
from pathlib import Path
import re
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Stage:
    key: str
    title: str
    description: str
    guidance: str
    action: str
    interactive: bool = False

    def receipt(self, home: Path) -> Path:
        return home / ".local" / "share" / "tether-guest" / (self.key + ".ready")


STAGES = (
    Stage("internet", "Check guest Internet",
          "Check DNS and reach the Debian package servers from this VM.",
          "This check repairs the guest NAT DNS only if it is failing.", "Check Internet"),
    Stage("tailscale", "Connect Tailscale",
          "Install Tailscale if needed and connect this VM to your tailnet.",
          "Complete sign-in in the browser if asked, then return to this window and follow the console prompt.",
          "Connect Tailscale", True),
    Stage("hermes-install", "Install Hermes",
          "Install the pinned Hermes runtime and its required packages.",
          "Existing Hermes data is preserved. Downloads may take several minutes.",
          "Install Hermes"),
    Stage("hermes-configure", "Set up Hermes",
          "Choose your model provider and start the private Hermes gateway.",
          "Enter provider credentials in the console or the provider's own sign-in page.",
          "Configure Hermes", True),
    Stage("computer-use", "Enable computer use",
          "Check Chromium and set up control of this Debian desktop.",
          "Keep this graphical session open while Hermes checks screen capture and control.",
          "Enable computer use"),
    Stage("verify", "Verify connection",
          "Check the private HTTPS route, Hermes, and a real model response.",
          "A successful check creates a private connection receipt in this VM.",
          "Verify connection"),
)


def first_incomplete(home: Path):
    """Receipts are hints for resume; each rerun still uses backend verification."""
    return next((stage for stage in STAGES if not stage.receipt(home).is_file()), None)


def verified_exit(stage: Stage, home: Path, exit_code: int) -> bool:
    return exit_code == 0 and stage.receipt(home).is_file()


def stage_event(line: str):
    """Ignore arbitrary process output; accept only the backend's stage event shape."""
    parts = line.rstrip("\r\n").split("\t", 3)
    if len(parts) != 4 or parts[0] != "TETHER_STAGE":
        return None
    if parts[1] not in {stage.key for stage in STAGES} or parts[2] not in {"start", "done", "error"}:
        return None
    return parts[1], parts[2], parts[3][:500]


def safe_https_url(value: str):
    """Only allow a browser URL, never shell text or an alternate URI scheme."""
    if not isinstance(value, str) or len(value) > 2_048 or re.search(r"[\s\x00-\x1f]", value):
        return None
    try:
        parsed = urlsplit(value)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            return None
        if parsed.port not in (None, 443):
            return None
        if not re.fullmatch(r"[A-Za-z0-9.-]+", parsed.hostname) or ".." in parsed.hostname:
            return None
    except ValueError:
        return None
    return value


def tailscale_login_url(terminal_text: str):
    """Find a single-use Tailscale sign-in link in visible PTY text only."""
    prefix = "https://login.tailscale.com/a/"
    for match in reversed(list(re.finditer(re.escape(prefix), terminal_text[-20_000:]))):
        tail = terminal_text[-20_000:][match.end():]
        token = []
        for char in tail[:80]:
            if char in "0123456789abcdefABCDEF":
                token.append(char)
            elif char in "\r\n" and len(token) < 12:
                # A short token may continue on the next terminal row.
                continue
            else:
                break
        if 10 <= len(token) <= 64:
            url = prefix + "".join(token)
            if safe_https_url(url):
                return url
    return None
