#!/bin/bash
set -euo pipefail

REPO_DIRECTORY="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD_DIRECTORY="${TETHER_TEST_BUILD_DIR:-/private/tmp/tether-host-onboarding-build}"
PRODUCTS_DIRECTORY="$BUILD_DIRECTORY/Build/Products/Debug"
SOURCE_APP="$PRODUCTS_DIRECTORY/Tether Host for Mac.app"
TEST_ROOT="${TETHER_DEBIAN_E2E_ROOT:-/tmp/tether-debian-e2e}"
# /tmp and /private/tmp name the same macOS directory. Keep the /tmp spelling
# for the E2E-only host-copy guard in NativeVMManager.
case "$TEST_ROOT" in
    /private/tmp/*) TEST_ROOT="/tmp/${TEST_ROOT#/private/tmp/}" ;;
esac
APP="$TEST_ROOT/TetherDebianE2E.app"
if [[ "${2:-}" == "--existing-id" ]]; then
    APP="$TEST_ROOT/TetherDebianE2EInspect.app"
fi

if [[ "${1:-}" != "--run" ]]; then
    cat <<EOF
Debian E2E test (no VM launched)

Run: $0 --run
Test files: $TEST_ROOT

The test downloads the official Debian ARM64 cloud image, creates a separate
24 GiB sparse VM disk, boots it, checks Debian DNS/HTTPS, native Chromium,
Xfce/X11, the guest service, and packaged tools. It reboots and checks
persistence and sparse disk use. It never opens or stops an existing Tether VM.
Build the Debug app first; set TETHER_TEST_BUILD_DIR if it is elsewhere.
EOF
    exit 0
fi

if [[ -e "$TEST_ROOT" && ! -d "$TEST_ROOT" ]]; then
    echo "Test root exists and is not a directory: $TEST_ROOT" >&2
    exit 2
fi
if [[ ! -d "$SOURCE_APP" || ! -f "$PRODUCTS_DIRECTORY/TetherHostCore.o" ]]; then
    echo "Build TetherHost Debug first; missing app or TetherHostCore.o in $PRODUCTS_DIRECTORY" >&2
    exit 2
fi
if [[ ! -f "$SOURCE_APP/Contents/Resources/Tether Debian Guest Tools.img" ]]; then
    echo "Debug app is missing the packaged Debian guest tools disk." >&2
    exit 2
fi
if [[ ! -x /opt/homebrew/bin/qemu-img && ! -x /usr/local/bin/qemu-img && \
      ! -x "$SOURCE_APP/Contents/Resources/Tools/qemu-img" ]]; then
    echo "qemu-img is required to prepare the Debian cloud image." >&2
    exit 2
fi

mkdir -p "$TEST_ROOT"
chmod 700 "$TEST_ROOT"
if [[ -e "$APP" ]]; then
    echo "Test app already exists: $APP. Use a fresh TETHER_DEBIAN_E2E_ROOT." >&2
    exit 2
fi
cp -R "$SOURCE_APP" "$APP"
ditto "$REPO_DIRECTORY/TetherHost/Resources/LinuxGuestSetup" \
    "$APP/Contents/Resources/LinuxGuestSetup"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.tether.debian.e2e' "$APP/Contents/Info.plist"
xcrun swiftc -swift-version 6 -D TETHER_E2E \
    -module-cache-path "$TEST_ROOT/module-cache" \
    -I "$PRODUCTS_DIRECTORY" \
    "$REPO_DIRECTORY/TetherHost/App/AppViewModel.swift" \
    "$REPO_DIRECTORY/TetherHost/App/NativeVMManager.swift" \
    "$REPO_DIRECTORY/scripts/test-debian-e2e.swift" \
    "$PRODUCTS_DIRECTORY/TetherHostCore.o" \
    -o "$APP/Contents/MacOS/Tether Host for Mac"
codesign --force --deep --sign - \
    --entitlements "$REPO_DIRECTORY/Config/TetherHost.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
exec "$APP/Contents/MacOS/Tether Host for Mac" --root "$TEST_ROOT" "${@:2}"
