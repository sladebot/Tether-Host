#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIRECTORY}/lib/common.sh"

require_command xcodebuild
require_command codesign
require_command security
require_command plutil
require_command xcrun
require_command hdiutil
require_file "${TETHER_EXPORT_OPTIONS_TEMPLATE}"
require_directory "${TETHER_PROJECT_PATH}"
require_team_id
require_signing_identity

release_log "checking the Tether Host for Mac scheme without changing the project"
if ! xcodebuild -project "${TETHER_PROJECT_PATH}" -scheme "Tether Host for Mac" -showBuildSettings >/dev/null; then
    release_die "the shared Tether Host for Mac scheme is missing or cannot be evaluated"
fi

if [[ "${1:-}" == "--notary" ]]; then
    [[ $# -eq 1 ]] || release_die "unexpected arguments"
    require_notary_profile
    release_log "checking the named notarytool Keychain profile"
    xcrun notarytool history --keychain-profile "${TETHER_NOTARY_KEYCHAIN_PROFILE}" >/dev/null
elif [[ $# -ne 0 ]]; then
    release_die "usage: $0 [--notary]"
fi

release_log "environment validation passed"
