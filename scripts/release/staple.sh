#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIRECTORY}/lib/common.sh"

if [[ "${1:-}" != "--execute" ]]; then
    release_log "dry run: would staple and validate ${TETHER_DMG_PATH}"
    exit 0
fi
require_execute_flag "$@"
require_command xcrun
require_command spctl
require_file "${TETHER_DMG_PATH}"

release_log "stapling the accepted notarization ticket"
xcrun stapler staple "${TETHER_DMG_PATH}"
xcrun stapler validate "${TETHER_DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=4 "${TETHER_DMG_PATH}"
release_log "stapled DMG assessment passed"
