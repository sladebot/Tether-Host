#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
REPO_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/../.." && pwd -P)"
GUEST_RESOURCES="${1:?Pass the built host app GuestSetup resources directory}"
APP="$GUEST_RESOURCES/Tether Guest Installer.app"
APP_RESOURCES="$APP/Contents/Resources"
APP_EXECUTABLE="$APP/Contents/MacOS/Tether Guest Installer"
SDK_PATH="${SDKROOT:-$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
MODULE_CACHE="${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}/TetherGuestInstallerModuleCache"

rm -rf "$APP"
mkdir -p "$APP_RESOURCES" "$APP/Contents/MacOS"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
    -sdk "$SDK_PATH" -module-cache-path "$MODULE_CACHE" \
    "$SCRIPT_DIRECTORY/TetherGuestInstaller.swift" -o "$APP_EXECUTABLE"
for filename in 'Set up Tether Guest.command' 'Keep Tether VM Awake.command' \
    'app.tether.keep-awake.plist' 'guest_setup.py' 'components.json'; do
    cp "$REPO_DIRECTORY/TetherHost/Resources/GuestSetup/$filename" "$APP_RESOURCES/$filename"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Tether Guest Installer</string>
<key>CFBundleIdentifier</key><string>app.tether.guest-installer</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Tether Guest Installer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION:-1.0.0}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${CURRENT_PROJECT_VERSION:-1}" "$APP/Contents/Info.plist"
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "$SIGNING_IDENTITY" ]; then SIGNING_IDENTITY='-'; fi
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict "$APP"
