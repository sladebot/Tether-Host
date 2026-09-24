#!/bin/bash
set -euo pipefail
SOURCE_DIRECTORY="$1"
DESTINATION="$2"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/tether-linux-tools.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
"$SCRIPT_DIRECTORY/build-linux-installer.sh" "$SOURCE_DIRECTORY" "$STAGING_DIRECTORY/Tether Guest Installer"
cat > "$STAGING_DIRECTORY/Read Me.txt" <<'README'
Tether Guest Installer for Ubuntu Desktop (ARM64)

Open Tether Guest Installer to prepare guest tools and follow the setup guide.
The guide shows progress and details, and requests administrator approval using
Ubuntu's password dialog. Clipboard support is prepared before sign-in. Copy text
in Ubuntu, then use Clipboard > Copy VM text to Mac in Tether Host to paste
a sign-in link into your Mac browser. Transfers happen only when you choose them.
Do not send passwords or tokens to anyone.

After preparation, reopen Tether Guest Installer from the application launcher.
README
mkdir -p "$(dirname "$DESTINATION")"
TEMP_IMAGE="$STAGING_DIRECTORY.iso"
trap 'rm -rf "$STAGING_DIRECTORY"; rm -f "$TEMP_IMAGE"' EXIT
hdiutil makehybrid -quiet -iso -joliet -iso-volume-name TETHERUBUNTU \
    -joliet-volume-name TETHERUBUNTU -o "$TEMP_IMAGE" "$STAGING_DIRECTORY"
mv "$TEMP_IMAGE" "$DESTINATION"
