#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIRECTORY}/lib/common.sh"

if [[ "${1:-}" != "--execute" ]]; then
    release_log "dry run: would archive scheme 'Tether Host for Mac' to ${TETHER_ARCHIVE_PATH}"
    release_log "run validate-environment.sh, then pass --execute"
    exit 0
fi
require_execute_flag "$@"
"${SCRIPT_DIRECTORY}/validate-environment.sh"
ensure_new_output "${TETHER_ARCHIVE_PATH}"
make_release_parent

release_log "archiving Tether Host for Mac with hardened runtime enabled"
xcodebuild \
    -project "${TETHER_PROJECT_PATH}" \
    -scheme "Tether Host for Mac" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${TETHER_ARCHIVE_PATH}" \
    DEVELOPMENT_TEAM="${TETHER_DEVELOPMENT_TEAM}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${TETHER_SIGNING_IDENTITY}" \
    ENABLE_HARDENED_RUNTIME=YES \
    archive

require_directory "${TETHER_ARCHIVE_PATH}"
release_log "archive created at ${TETHER_ARCHIVE_PATH}"
