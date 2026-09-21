#!/usr/bin/env python3
"""Read-only guest inventory. Never interprets config or reads saved credentials."""
import argparse
import datetime
import getpass
import grp
import json
import os
import pwd
from pathlib import Path
import shutil
import stat
import subprocess
import urllib.error
import urllib.request


def run(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=10)
        return {"exit_code": p.returncode, "output": p.stdout.strip()[:8000]}
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"error": type(e).__name__}


def file_metadata(path):
    """lstat only: even a symlink to a credential file is never followed/read."""
    try:
        s = path.lstat()
    except FileNotFoundError:
        return {"present": False}
    except OSError as e:
        return {"error": type(e).__name__}
    return {"present": True, "owner_uid": s.st_uid,
            "mode": oct(stat.S_IMODE(s.st_mode)), "symlink": stat.S_ISLNK(s.st_mode),
            "private": not bool(s.st_mode & 0o077), "owned_by_runtime": s.st_uid == os.getuid()}


def summarize_capabilities(data):
    if not isinstance(data, dict):
        return {"valid": False}
    features = data.get("features", {})
    # The installed guest schema must match the client's required discovery fields.
    if not isinstance(features, dict):
        features = {}
    required = ("run_submission", "run_status", "run_events_sse", "run_stop")
    flags = {key: features.get(key) is True for key in required}
    idem = features.get("runs_idempotency", {})
    if not isinstance(idem, dict):
        idem = {}
    retention = idem.get("retention_seconds")
    retention_ok = type(retention) in (int, float) and retention > 0
    return {"required_features": flags,
            "durable_idempotency": idem.get("supported") is True and idem.get("durable") is True,
            "positive_retention": retention_ok,
            "ready": all(flags.values()) and idem.get("supported") is True
            and idem.get("durable") is True and retention_ok}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api_get(port, path, token=None):
    # A fixed loopback origin and disabled proxies/redirects prevent token forwarding.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    headers = {"Authorization": "Bearer " + token} if token else {}
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers)
    try:
        with opener.open(request, timeout=10) as response:
            body = response.read(65537)
            result = {"status": response.status}
            if len(body) > 65536:
                return {**result, "error": "response_too_large"}
            if path == "/v1/capabilities" and token:
                try:
                    result["capabilities"] = summarize_capabilities(json.loads(body))
                except (ValueError, TypeError):
                    result["error"] = "invalid_json"
            return result
    except urllib.error.HTTPError as e:
        return {"status": e.code}
    except (OSError, urllib.error.URLError) as e:
        return {"error": type(e).__name__}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-guest", action="store_true", help="Attest this is the VM console/session")
    parser.add_argument("--expected-user", required=True, help="Chosen non-admin guest runtime username")
    parser.add_argument("--port", type=int, default=8642)
    parser.add_argument("--api", action="store_true", help="Probe already-running loopback API after isolation passes")
    parser.add_argument("--authenticated", action="store_true", help="Prompt privately for guest API key; never read saved keys")
    args = parser.parse_args()
    if not args.confirm_guest:
        parser.error("run inside the VM with --confirm-guest; host evidence cannot establish guest readiness")
    if not 1 <= args.port <= 65535:
        parser.error("port must be 1..65535")
    if args.authenticated and not args.api:
        parser.error("--authenticated requires --api")
    if args.authenticated and not os.isatty(0):
        parser.error("authenticated checks require an interactive terminal for a hidden key prompt")
    username = pwd.getpwuid(os.getuid()).pw_name
    groups = [grp.getgrgid(g).gr_name for g in os.getgroups()]
    home = Path.home()
    hermes_home = Path(os.environ.get("HERMES_HOME", str(home / ".hermes")))
    report = {"timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "operator-attested guest; inventory does not prove isolation",
              "identity": {"username": username, "uid": os.getuid(), "groups": groups,
                           "expected_user": username == args.expected_user,
                           "non_admin": os.getuid() != 0 and "admin" not in groups},
              "executables": {name: shutil.which(name) for name in ("hermes", "tailscale", "cua-driver")},
              "config_metadata": {name: file_metadata(hermes_home / name)
                                  for name in ("config.yaml", ".env")},
              "config_values": "not read; binding and authentication must be verified on running API",
              "hermes_version": run([shutil.which("hermes"), "--version"]) if shutil.which("hermes") else {"installed": False},
              "listen_sockets": run(["/usr/sbin/lsof", "-nP", f"-iTCP:{args.port}", "-sTCP:LISTEN", "-FpcuLn"]),
              "mounts": run(["/sbin/mount"]),
              "cua_app": file_metadata(Path("/Applications/CuaDriver.app")),
              "cua_permissions": "unverified: doctor and capture need the chosen interactive guest session",
              "isolation": "unverified: requires host/tailnet enforcement and independent negative tests"}
    if args.api:
        report["api"] = {"health": api_get(args.port, "/health"),
                         "anonymous_capabilities": api_get(args.port, "/v1/capabilities"),
                         "wrong_key_capabilities": api_get(args.port, "/v1/capabilities", "readiness-invalid-key")}
        if args.authenticated:
            token = getpass.getpass("Guest API key (hidden, not saved): ")
            if not token or "\r" in token or "\n" in token:
                parser.error("key must be nonempty and single-line")
            report["api"]["authenticated_capabilities"] = api_get(args.port, "/v1/capabilities", token)
            del token
    print(json.dumps(report, indent=2))
    # This is an inventory, deliberately never an isolation acceptance result.
    return 0 if report["identity"]["expected_user"] and report["identity"]["non_admin"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
