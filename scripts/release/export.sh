#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIRECTORY}/lib/common.sh"

if [[ "${1:-}" != "--execute" ]]; then
    release_log "dry run: would export ${TETHER_ARCHIVE_PATH} to ${TETHER_EXPORT_PATH}"
    release_log "the generated export options contain identifiers only, never credentials"
    exit 0
fi
require_execute_flag "$@"
require_command xcodebuild
require_command plutil
require_team_id
require_signing_identity
require_directory "${TETHER_ARCHIVE_PATH}"
require_file "${TETHER_EXPORT_OPTIONS_TEMPLATE}"
ensure_new_output "${TETHER_EXPORT_PATH}"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/tether-export.XXXXXX")"
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT
export_options="${temporary_directory}/ExportOptions.plist"
cp "${TETHER_EXPORT_OPTIONS_TEMPLATE}" "$export_options"
plutil -insert teamID -string "${TETHER_DEVELOPMENT_TEAM}" "$export_options"
plutil -insert signingCertificate -string "${TETHER_SIGNING_IDENTITY}" "$export_options"

release_log "exporting the Developer ID archive"
xcodebuild \
    -exportArchive \
    -archivePath "${TETHER_ARCHIVE_PATH}" \
    -exportPath "${TETHER_EXPORT_PATH}" \
    -exportOptionsPlist "$export_options"

require_directory "${TETHER_APP_PATH}"
release_log "exported app at ${TETHER_APP_PATH}"
