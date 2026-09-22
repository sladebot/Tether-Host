#!/bin/bash
# Reproducible local preview. This is ad-hoc signed, not a Developer ID release.
set -euo pipefail
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
REPO_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
TETHER_PREVIEW_BUILD_DIR="${TETHER_PREVIEW_BUILD_DIR:-$REPO_DIRECTORY/build/PreviewDerivedData}"
mkdir -p "$REPO_DIRECTORY/build"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/tether-preview.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
xcodebuild -quiet -project "$REPO_DIRECTORY/TetherHost.xcodeproj" -scheme 'Tether Host for Mac' \
    -configuration Debug -derivedDataPath "$TETHER_PREVIEW_BUILD_DIR" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
APP_PATH="$TETHER_PREVIEW_BUILD_DIR/Build/Products/Debug/Tether Host for Mac.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
case "$APP_VERSION" in ''|*[!0-9A-Za-z._-]*) printf 'Invalid app version: %s\n' "$APP_VERSION" >&2; exit 1 ;; esac
case "$APP_BUILD" in ''|*[!0-9A-Za-z._-]*) printf 'Invalid app build: %s\n' "$APP_BUILD" >&2; exit 1 ;; esac
DEFAULT_PREVIEW_DMG="$REPO_DIRECTORY/build/Tether-Host-for-Mac-v${APP_VERSION}-build-${APP_BUILD}-preview.dmg"
TETHER_PREVIEW_DMG="${TETHER_PREVIEW_DMG:-$DEFAULT_PREVIEW_DMG}"
mkdir -p "$(dirname "$TETHER_PREVIEW_DMG")"
find "$APP_PATH/Contents/Resources/GuestSetup" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$APP_PATH/Contents/Resources/GuestSetup" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
codesign --force --deep --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
mkdir "$STAGING_DIRECTORY/content"
ditto "$APP_PATH" "$STAGING_DIRECTORY/content/Tether Host for Mac.app"
# Finder shows the bundle directory timestamp; set it to this packaged build.
touch -m "$STAGING_DIRECTORY/content/Tether Host for Mac.app"
codesign --verify --deep --strict "$STAGING_DIRECTORY/content/Tether Host for Mac.app"
mkdir "$STAGING_DIRECTORY/guest-disk"
ditto --norsrc --noextattr --noqtn --noacl \
    "$APP_PATH/Contents/Resources/GuestSetup/Tether Guest Installer.app" \
    "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app"
xattr -cr "$STAGING_DIRECTORY/guest-disk"
codesign --verify --strict "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app"
test -x "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app/Contents/Resources/Set up Tether Guest.command"
test -x "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app/Contents/Resources/Keep Tether VM Awake.command"
for guest_step in '01 Check Internet.command' '02 Set up Tailscale.command' \
    '03 Install Hermes.command' '04 Configure Hermes.command' \
    '05 Enable Computer Use.command' '06 Verify Connection.command'; do
    test -x "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app/Contents/Resources/$guest_step"
done
test -f "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app/Contents/Resources/guest_setup.py"
test -x "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app/Contents/Resources/Tether Guest Clipboard Helper"
test -x "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app/Contents/Resources/install-clipboard-helper.sh"
test -f "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app/Contents/Resources/app.tether.guest-clipboard.plist"
for guest_asset in terminal.html xterm.js xterm.css LICENSE; do
    test -f "$STAGING_DIRECTORY/guest-disk/Tether Guest Installer.app/Contents/Resources/$guest_asset"
done
printf 'Tether Guest Setup — version %s (%s)\nRun only inside the VM.\n\n' \
    "$APP_VERSION" "$APP_BUILD" > "$STAGING_DIRECTORY/guest-disk/Read Me.txt"
cat >> "$STAGING_DIRECTORY/guest-disk/Read Me.txt" <<'GUEST_NOTE'

After reaching the macOS desktop, double-click Tether Guest Installer.app on
this disk and follow its six separate steps. Interactive setup runs in the
installer's own console. Do not install a second copy of Tether Host. Existing
Tailscale and Hermes installations are reused when healthy. The guide checks
guest Internet, connects Tailscale, installs Hermes if needed, configures
model login, installs computer use in the VM, then verifies the private connection.

Run this only inside the macOS virtual machine.
GUEST_NOTE
hdiutil makehybrid -iso -joliet -iso-volume-name TETHERGUEST \
    -joliet-volume-name 'Tether Guest Setup' -o "$STAGING_DIRECTORY/content/Tether Guest Setup.iso" \
    "$STAGING_DIRECTORY/guest-disk"
ln -s /Applications "$STAGING_DIRECTORY/content/Applications"
printf 'Tether Host local development preview\nVersion %s (%s)\n\n' \
    "$APP_VERSION" "$APP_BUILD" > "$STAGING_DIRECTORY/content/Read Me.txt"
cat >> "$STAGING_DIRECTORY/content/Read Me.txt" <<'NOTE'

Drag Tether Host for Mac into Applications and launch it.
Built-in Apple Virtualization is the default VM provider. Tether Host stores
and displays its VM directly. A new VM needs a compatible macOS IPSW; an
existing one does not. UTM remains an optional backup for existing UTM VMs
or a new VM that appears in UTM. The four checks are:
1. Create or select the exact VM.
2. Install and boot macOS.
3. Check/install/configure Tailscale inside the VM.
4. Check/install/configure Hermes inside the VM, then verify it.

The included Tether Guest Setup.iso carries a small guest helper without
enabling host folder sharing. Built-in Apple VMs can optionally enable explicit,
text-only clipboard transfer from the guest installer. Each transfer requires
a button click in Tether Host; clipboard contents are never synced continuously.
Tether-created built-in and UTM VMs
include a read-only copy. In the guest, open Tether Guest Installer.app and
follow its six checks. Updating this installer does not reinstall the VM.
For a pre-existing UTM VM, attach the included ISO manually once.

Dependency detection for Tailscale and Hermes runs inside the VM. Software on
the physical Mac never satisfies those checks. The installer guides Tailscale
sign-in, model login, guest permissions, service configuration, and verification.
The helper verifies the URL/token in the VM. Enter those connection details in
Tether iOS with the phone on the same tailnet.

Existing Hermes installations are preserved: the guest installer refuses
to overwrite unmanaged data. You can verify an existing connection manually.

This local preview is ad-hoc signed, not Developer ID signed or notarized.
The built-in VM path has not yet completed a clean-VM, real-phone end-to-end
test. UTM remains a manual backup path.
NOTE
hdiutil create -srcfolder "$STAGING_DIRECTORY/content" -volname 'Tether Host Guest Setup' \
    -format UDZO -fs HFS+ "$STAGING_DIRECTORY/preview.dmg"
hdiutil verify "$STAGING_DIRECTORY/preview.dmg"
mv "$STAGING_DIRECTORY/preview.dmg" "$TETHER_PREVIEW_DMG"
CHECKSUM_PATH="${TETHER_PREVIEW_DMG}.sha256"
(
    cd "$(dirname "$TETHER_PREVIEW_DMG")"
    shasum -a 256 "$(basename "$TETHER_PREVIEW_DMG")" > "$(basename "$CHECKSUM_PATH")"
)
printf 'Preview ready: %s\nChecksum: %s\n' "$TETHER_PREVIEW_DMG" "$CHECKSUM_PATH"
