#!/bin/bash
# Local and CI verification. Does not provision a VM or alter host networking.
set -euo pipefail
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
REPO_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
cd "$REPO_DIRECTORY"
PYTHON="${TETHER_TEST_PYTHON:-python3}"
VERIFY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/tether-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIRECTORY"' EXIT

"$PYTHON" -c 'import yaml' || {
    printf '%s\n' 'Install test dependencies: python3 -m pip install -r requirements-test.txt' >&2
    exit 1
}
"$PYTHON" -B -m unittest discover -s scripts/guest -p 'test_*.py' -v
"$PYTHON" -B -m unittest discover -s scripts/isolation -p 'test_*.py' -v
swift test --package-path TetherHost

while IFS= read -r -d '' script; do bash -n "$script"; done < <(
    find scripts TetherHost/Resources/GuestSetup TetherHost/Resources/LinuxGuestSetup -type f \( -name '*.sh' -o -name '*.command' \) -print0
)
xcrun swiftc -parse-as-library -D TAILSCALE_STATUS_TESTS \
    -module-cache-path "$VERIFY_DIRECTORY/ModuleCache" \
    scripts/guest/TetherGuestInstaller.swift scripts/guest/test_tailscale_status.swift \
    -o "$VERIFY_DIRECTORY/tailscale-tests"
"$VERIFY_DIRECTORY/tailscale-tests"
xcrun swiftc -parse-as-library -module-cache-path "$VERIFY_DIRECTORY/ModuleCache" \
    scripts/guest/TetherGuestClipboardHelper.swift -o "$VERIFY_DIRECTORY/clipboard-tests"
"$VERIFY_DIRECTORY/clipboard-tests" --self-test

for configuration in Debug Release; do
    xcodebuild -quiet -project TetherHost.xcodeproj -scheme 'Tether Host for Mac' \
        -configuration "$configuration" -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$VERIFY_DIRECTORY/DerivedData" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
        OTHER_CODE_SIGN_FLAGS='--options runtime' build
    app="$VERIFY_DIRECTORY/DerivedData/Build/Products/$configuration/Tether Host for Mac.app"
    codesign --verify --deep --strict "$app"
    while IFS= read -r -d '' candidate; do
        if file -b "$candidate" | grep -F 'Mach-O' >/dev/null; then
            codesign --verify --strict "$candidate"
            # Ad-hoc standalone converter/dylibs cannot satisfy Team-ID library
            # validation. Their signatures are checked above; host and guest
            # helpers still require hardened runtime. Developer ID releases use
            # release/verify-signatures.sh to require it for every Mach-O.
            case "$candidate" in "$app/Contents/Resources/Tools/"*) continue ;; esac
            codesign -dvvv "$candidate" 2>&1 | grep -E '^CodeDirectory .*flags=.*runtime' >/dev/null || {
                printf 'Missing hardened runtime: %s\n' "$candidate" >&2
                exit 1
            }
        fi
    done < <(find "$app/Contents" -type f -print0)
done
git diff --check
