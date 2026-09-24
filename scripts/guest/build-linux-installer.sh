#!/bin/bash
set -euo pipefail
SOURCE_DIRECTORY="${1:?Pass guest resources}"
DESTINATION="${2:?Pass executable output path}"
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
GO_BINARY="${TETHER_GO_BINARY:-$(command -v go || true)}"
[[ -x "$GO_BINARY" ]] || { echo 'Set TETHER_GO_BINARY to a Go compiler to build the Ubuntu installer.' >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tether-linux-installer.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$SCRIPT_DIRECTORY/linux-launcher/main.go" "$STAGE/main.go"
python3 - "$SOURCE_DIRECTORY" "$STAGE/payload.zip" <<'PY'
from pathlib import Path
import sys, zipfile
source=Path(sys.argv[1])
required=['guest_installer.py','setup.sh','update-guest-tools.sh','dns-fallback.sh','linux_guest_setup.py','vsock_helper.py','clipboard_broker.py','installer_flow.py','installer_logging.py','session-start.sh','keep-awake.sh','clipboard-toggle.sh','components.json']
for name in required:
    if not (source/name).is_file(): raise SystemExit('Missing guest installer resource: '+name)
with zipfile.ZipFile(sys.argv[2], 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(source.iterdir()):
        if path.is_file() and path.suffix in ('.py','.sh','.json','.txt'):
            entry=zipfile.ZipInfo(path.name, (2026,1,1,0,0,0))
            entry.compress_type=zipfile.ZIP_DEFLATED
            archive.writestr(entry,path.read_bytes())
PY
mkdir -p "$(dirname "$DESTINATION")"
(cd "$STAGE" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local GOCACHE="${TETHER_GO_CACHE:-/private/tmp/tether-go-build-cache}" "$GO_BINARY" build -trimpath -ldflags='-s -w -buildid=' -o "$DESTINATION" main.go)
chmod 0755 "$DESTINATION"
