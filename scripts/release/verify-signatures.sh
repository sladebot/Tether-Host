#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIRECTORY}/lib/common.sh"

require_command codesign
require_command security
require_command file
require_team_id
require_directory "${TETHER_APP_PATH}"

release_log "verifying the app and every embedded Mach-O object"
codesign --verify --deep --strict --verbose=2 "${TETHER_APP_PATH}"

signature_details="$(codesign -dvvv "${TETHER_APP_PATH}" 2>&1)"
grep -F "Authority=Developer ID Application:" <<<"$signature_details" >/dev/null || release_die \
    "the app is not signed by a Developer ID Application certificate"
grep -F "TeamIdentifier=${TETHER_DEVELOPMENT_TEAM}" <<<"$signature_details" >/dev/null || release_die \
    "the app TeamIdentifier does not match TETHER_DEVELOPMENT_TEAM"
grep -E '^CodeDirectory .*flags=.*runtime' <<<"$signature_details" >/dev/null || release_die \
    "the app signature does not enable hardened runtime"
grep -E '^Timestamp=.' <<<"$signature_details" >/dev/null || release_die \
    "the app signature has no secure timestamp"

while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -F 'Mach-O' >/dev/null; then
        codesign --verify --strict --verbose=2 "$candidate"
        candidate_details="$(codesign -dvvv "$candidate" 2>&1)"
        grep -F "Authority=Developer ID Application:" <<<"$candidate_details" >/dev/null || release_die \
            "embedded Mach-O is not signed with Developer ID Application: $candidate"
        grep -F "TeamIdentifier=${TETHER_DEVELOPMENT_TEAM}" <<<"$candidate_details" >/dev/null || release_die \
            "embedded Mach-O has an unexpected TeamIdentifier: $candidate"
        grep -E '^CodeDirectory .*flags=.*runtime' <<<"$candidate_details" >/dev/null || release_die \
            "embedded Mach-O lacks hardened runtime: $candidate"
        grep -E '^Timestamp=.' <<<"$candidate_details" >/dev/null || release_die \
            "embedded Mach-O lacks a secure timestamp: $candidate"
    fi
done < <(find "${TETHER_APP_PATH}/Contents" -type f -print0)

release_log "signature verification passed"
