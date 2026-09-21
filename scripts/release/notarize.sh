#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIRECTORY}/lib/common.sh"

if [[ "${1:-}" != "--execute" ]]; then
    release_log "dry run: would submit ${TETHER_DMG_PATH} using the named Keychain profile"
    release_log "no Apple ID password or API private key is accepted by this script"
    exit 0
fi
require_execute_flag "$@"
require_command xcrun
require_command codesign
require_notary_profile
require_file "${TETHER_DMG_PATH}"
codesign --verify --strict --verbose=2 "${TETHER_DMG_PATH}"

release_log "submitting the signed DMG to Apple's notary service and waiting for a result"
xcrun notarytool submit "${TETHER_DMG_PATH}" \
    --keychain-profile "${TETHER_NOTARY_KEYCHAIN_PROFILE}" \
    --wait
release_log "notary service accepted the DMG"
