#!/bin/bash
# Reproducible local preview. This is ad-hoc signed, not a Developer ID release.
set -euo pipefail
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
REPO_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
TETHER_PREVIEW_BUILD_DIR="${TETHER_PREVIEW_BUILD_DIR:-$REPO_DIRECTORY/build/PreviewDerivedData}"
TETHER_PREVIEW_DMG="${TETHER_PREVIEW_DMG:-$REPO_DIRECTORY/build/Tether-Host-Guest-Setup-Preview.dmg}"
mkdir -p "$(dirname "$TETHER_PREVIEW_DMG")"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/tether-preview.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
xcodebuild -project "$REPO_DIRECTORY/TetherHost.xcodeproj" -scheme 'Tether Host for Mac' \
    -configuration Debug -derivedDataPath "$TETHER_PREVIEW_BUILD_DIR" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
APP_PATH="$TETHER_PREVIEW_BUILD_DIR/Build/Products/Debug/Tether Host for Mac.app"
find "$APP_PATH/Contents/Resources/GuestSetup" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$APP_PATH/Contents/Resources/GuestSetup" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
codesign --force --deep --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
mkdir "$STAGING_DIRECTORY/content"
ditto "$APP_PATH" "$STAGING_DIRECTORY/content/Tether Host for Mac.app"
mkdir "$STAGING_DIRECTORY/guest-disk"
ditto --norsrc --noextattr --noqtn --noacl "$APP_PATH" "$STAGING_DIRECTORY/guest-disk/Tether Host for Mac.app"
xattr -cr "$STAGING_DIRECTORY/guest-disk"
codesign --verify --deep --strict "$STAGING_DIRECTORY/guest-disk/Tether Host for Mac.app"
cat > "$STAGING_DIRECTORY/guest-disk/Read Me.txt" <<'GUEST_NOTE'
Tether Guest Setup — run only inside the VM

Copy Tether Host for Mac into this VM's Applications folder and launch it.
Open Setup Assistant and choose Run Guest Setup. The installer checks Tailscale
inside this VM first and installs or configures it as needed. It then checks
Hermes inside this VM, installing it when absent or configuring a working
existing installation for API access, model login, computer use, and final
verification.

Run this only inside the macOS virtual machine.
GUEST_NOTE
hdiutil makehybrid -iso -joliet -iso-volume-name TETHERGUEST \
    -joliet-volume-name 'Tether Guest Setup' -o "$STAGING_DIRECTORY/content/Tether Guest Setup.iso" \
    "$STAGING_DIRECTORY/guest-disk"
ln -s /Applications "$STAGING_DIRECTORY/content/Applications"
cat > "$STAGING_DIRECTORY/content/Read Me.txt" <<'NOTE'
Tether Host local development preview

Drag Tether Host for Mac into Applications and launch it.
Choose UTM in this preview and follow the four numbered setup checks:
1. Confirm the exact VM exists.
2. Confirm the VM reaches the running state.
3. Check/install/configure Tailscale inside the VM.
4. Check/install/configure Hermes inside the VM, then verify it.

The included Tether Guest Setup.iso transfers the app into the VM without
enabling host folder or clipboard sharing. Attach it to the VM, copy the app
to the guest's Applications folder, and choose Run Guest Setup.

Dependency detection for Tailscale and Hermes runs inside the VM. Software on
the physical Mac never satisfies those checks. The installer guides Tailscale
sign-in, model login, guest permissions, service configuration, and verification.
Load Guest Connection to verify the URL/token.
Enter the URL/token in Tether iOS with the phone on the same tailnet.

Existing Hermes installations are preserved: the guest installer refuses
to overwrite unmanaged data. You can verify an existing connection manually.

This local preview is ad-hoc signed, not Developer ID signed or notarized.
Automatic native VM creation is not implemented. ISO attachment remains a
manual UTM step.
NOTE
hdiutil create -srcfolder "$STAGING_DIRECTORY/content" -volname 'Tether Host Guest Setup' \
    -format UDZO -fs HFS+ "$STAGING_DIRECTORY/preview.dmg"
hdiutil verify "$STAGING_DIRECTORY/preview.dmg"
mv "$STAGING_DIRECTORY/preview.dmg" "$TETHER_PREVIEW_DMG"
printf 'Preview ready: %s\n' "$TETHER_PREVIEW_DMG"
