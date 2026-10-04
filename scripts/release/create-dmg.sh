#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIRECTORY}/lib/common.sh"

if [[ "${1:-}" != "--execute" ]]; then
    release_log "dry run: would create ${TETHER_DMG_PATH} from ${TETHER_APP_PATH}"
    exit 0
fi
require_execute_flag "$@"
require_command hdiutil
require_command ditto
require_directory "${TETHER_APP_PATH}"
require_file "${TETHER_APP_PATH}/Contents/Resources/Tether Debian Guest Tools.img"
require_file "${TETHER_APP_PATH}/Contents/Resources/LinuxGuestSetup/installer-version.json"
project_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${TETHER_APP_PATH}/Contents/Info.plist")"
guest_build="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "${TETHER_APP_PATH}/Contents/Resources/LinuxGuestSetup/installer-version.json")"
[[ "$project_build" == "$guest_build" ]] || release_die \
    "host build ${project_build} does not match Debian guest tools build ${guest_build}"
ensure_new_output "${TETHER_DMG_PATH}"
make_release_parent

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/tether-dmg.XXXXXX")"
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

ditto "${TETHER_APP_PATH}" "${temporary_directory}/Tether Host for Mac.app"
ln -s /Applications "${temporary_directory}/Applications"

release_log "creating read-only compressed DMG"
hdiutil create \
    -srcfolder "$temporary_directory" \
    -volname "Tether Host for Mac" \
    -format UDZO \
    -fs HFS+ \
    "${TETHER_DMG_PATH}"

require_file "${TETHER_DMG_PATH}"
release_log "unsigned-container DMG created at ${TETHER_DMG_PATH}"
