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
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    OTHER_CODE_SIGN_FLAGS='--options runtime' build
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
find "$APP_PATH/Contents/Resources/LinuxGuestSetup" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$APP_PATH/Contents/Resources/LinuxGuestSetup" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
test -x "$APP_PATH/Contents/Resources/Tools/qemu-img"
for debian_resource in setup.sh guest_installer.py vsock_helper.py linux_guest_setup.py display-resize.py; do
    test -f "$APP_PATH/Contents/Resources/LinuxGuestSetup/$debian_resource"
done
test -f "$APP_PATH/Contents/Resources/Tether Debian Guest Tools.img"
HOST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
GUEST_BUILD="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$APP_PATH/Contents/Resources/LinuxGuestSetup/installer-version.json")"
[[ "$HOST_BUILD" == "$GUEST_BUILD" ]] || { printf 'Host build %s does not match Debian guest tools build %s\n' "$HOST_BUILD" "$GUEST_BUILD" >&2; exit 1; }
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

Quit Tether Host before replacing it in Applications, then open the updated app.
Updating the app preserves existing VM disks and configuration. Keep only one
host copy running. Apple Virtualization creates and displays both macOS and
Debian 13 ARM64 VMs in the current sidebar workspace.

REUSE AN EXISTING VM
Choose Virtual machine, open the VM name menu, select your existing macOS or
Debian VM, and choose Start VM. Keep external storage connected. Reusing a VM
does not require another download or a new account.

CREATE A NEW VM
Choose VM library > Create New VM, select macOS or Debian, then continue to
configuration. Choose CPU, memory, disk capacity, and storage location.
For macOS, choose an IPSW or download a compatible Apple restore image.
Complete Apple's welcome screens and open Tether Guest Installer.app from the
read-only Tether Guest Setup disk. The DMG also includes its setup ISO.
For Debian, download and verify the official ARM64 image, choose your Debian
username and password, then create the VM. First boot prepares the desktop and
guest tools. Open Tether Guest Installer from the Debian applications menu.
The Debian converter, first-boot resources, and guest tools disk are bundled
inside the host app. Disk capacity grows sparsely only on supported filesystems.

CONNECT YOUR IPHONE
Follow the guest installer for Internet, clipboard, Tailscale, Hermes, model
sign-in, computer use, and private connection verification. The host verifies
the returned URL and token before you copy them into Tether Flow on the iPhone.
Join the same Tailscale network and run Test Connection on the phone.

This is an ad-hoc signed development preview, not Developer ID signed or
notarized. Internet mode uses Apple NAT; it does not block guest access to
reachable host or local-network services. No host folders are shared and
clipboard transfers occur only when you choose an action.

Build 93 was checked with an existing Debian VM, which booted to Xfce and
reconnected Tailscale and Hermes. Fresh guest and physical-iPhone end-to-end
acceptance remain outstanding. UTM runtime integration is retired.

NOTE
hdiutil create -srcfolder "$STAGING_DIRECTORY/content" -volname 'Tether Host Guest Setup' \
    -format UDRW -fs HFS+ "$STAGING_DIRECTORY/preview-rw.dmg"
hdiutil convert "$STAGING_DIRECTORY/preview-rw.dmg" -format UDZO \
    -o "$STAGING_DIRECTORY/preview.dmg"
hdiutil verify "$STAGING_DIRECTORY/preview.dmg"
mv "$STAGING_DIRECTORY/preview.dmg" "$TETHER_PREVIEW_DMG"
CHECKSUM_PATH="${TETHER_PREVIEW_DMG}.sha256"
(
    cd "$(dirname "$TETHER_PREVIEW_DMG")"
    shasum -a 256 "$(basename "$TETHER_PREVIEW_DMG")" > "$(basename "$CHECKSUM_PATH")"
)
printf 'Preview ready: %s\nChecksum: %s\n' "$TETHER_PREVIEW_DMG" "$CHECKSUM_PATH"
