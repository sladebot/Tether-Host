#!/bin/bash
set -euo pipefail
SOURCE_DIRECTORY="$1"
DESTINATION="$2"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/tether-linux-tools.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
"$SCRIPT_DIRECTORY/build-linux-installer.sh" "$SOURCE_DIRECTORY" "$STAGING_DIRECTORY/Tether Guest Installer"
cat > "$STAGING_DIRECTORY/Read Me.txt" <<'README'
Tether Guest Installer for Debian Desktop (ARM64)

Open Tether Guest Installer to prepare guest tools and follow the setup guide.
The guide shows progress and details, and requests administrator approval using
Debian's password dialog. Clipboard support is prepared before sign-in. Copy text
in Debian, then use Clipboard > Copy VM text to Mac in Tether Host to paste
a sign-in link into your Mac browser. Transfers happen only when you choose them.
Do not send passwords or tokens to anyone.

After preparation, reopen Tether Guest Installer from the application launcher.
README
mkdir -p "$(dirname "$DESTINATION")"
TEMP_IMAGE="$(mktemp "${TMPDIR:-/tmp}/tether-linux-tools-image.XXXXXX")"
ATTACHED_DEVICE=''
MOUNT_PATH=''
cleanup() {
    if [[ -n "$MOUNT_PATH" ]]; then hdiutil detach "$MOUNT_PATH" >/dev/null 2>&1 || true; fi
    if [[ -n "$ATTACHED_DEVICE" ]]; then hdiutil detach "$ATTACHED_DEVICE" >/dev/null 2>&1 || true; fi
    rm -rf "$STAGING_DIRECTORY"
    rm -f "$TEMP_IMAGE"
}
trap cleanup EXIT
truncate -s 16m "$TEMP_IMAGE"
ATTACHED_DEVICE="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$TEMP_IMAGE" | awk 'NR == 1 {print $1}')"
if [[ "$ATTACHED_DEVICE" != /dev/disk* ]]; then
    echo "Unexpected raw disk device: $ATTACHED_DEVICE" >&2
    exit 1
fi
RAW_DEVICE="/dev/r${ATTACHED_DEVICE#/dev/}"
newfs_msdos -F 16 -v TETHERTOOLS "$RAW_DEVICE" >/dev/null
hdiutil detach "$ATTACHED_DEVICE" >/dev/null
ATTACHED_DEVICE=''
MOUNT_PATH="$(hdiutil attach -nobrowse -readwrite -imagekey diskimage-class=CRawDiskImage "$TEMP_IMAGE" | awk 'NR == 1 {print $NF}')"
ditto --norsrc --noextattr --noqtn --noacl "$STAGING_DIRECTORY" "$MOUNT_PATH"
hdiutil detach "$MOUNT_PATH" >/dev/null
MOUNT_PATH=''
mv "$TEMP_IMAGE" "$DESTINATION"
