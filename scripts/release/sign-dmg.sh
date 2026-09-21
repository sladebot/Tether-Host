#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIRECTORY}/lib/common.sh"

if [[ "${1:-}" != "--execute" ]]; then
    release_log "dry run: would sign ${TETHER_DMG_PATH} with TETHER_SIGNING_IDENTITY"
    exit 0
fi
require_execute_flag "$@"
require_command codesign
require_signing_identity
require_file "${TETHER_DMG_PATH}"

release_log "signing the DMG container"
codesign --force --sign "${TETHER_SIGNING_IDENTITY}" --timestamp "${TETHER_DMG_PATH}"
codesign --verify --strict --verbose=2 "${TETHER_DMG_PATH}"
release_log "DMG signature verification passed"
