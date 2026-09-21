#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly TETHER_REPOSITORY_ROOT="$(cd "${RELEASE_SCRIPT_DIR}/../.." && pwd -P)"
readonly TETHER_PROJECT_PATH="${TETHER_REPOSITORY_ROOT}/TetherHost.xcodeproj"
readonly TETHER_ARCHIVE_PATH="${TETHER_REPOSITORY_ROOT}/build/release/TetherHostForMac.xcarchive"
readonly TETHER_EXPORT_PATH="${TETHER_REPOSITORY_ROOT}/build/release/export"
readonly TETHER_APP_PATH="${TETHER_EXPORT_PATH}/Tether Host for Mac.app"
readonly TETHER_DMG_PATH="${TETHER_REPOSITORY_ROOT}/build/release/Tether Host for Mac.dmg"
readonly TETHER_EXPORT_OPTIONS_TEMPLATE="${TETHER_REPOSITORY_ROOT}/Config/ExportOptions.DeveloperID.plist"

release_log() {
    printf '%s\n' "release: $*" >&2
}

release_die() {
    printf '%s\n' "release: error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || release_die "required command is unavailable: $1"
}

require_file() {
    [[ -f "$1" ]] || release_die "required file does not exist: $1"
}

require_directory() {
    [[ -d "$1" ]] || release_die "required directory does not exist: $1"
}

require_team_id() {
    local team_id="${TETHER_DEVELOPMENT_TEAM:-}"
    [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || release_die \
        "TETHER_DEVELOPMENT_TEAM must be the 10-character Apple Developer Team ID"
}

require_signing_identity() {
    local identity="${TETHER_SIGNING_IDENTITY:-}"
    [[ -n "$identity" ]] || release_die "TETHER_SIGNING_IDENTITY must name an exact Developer ID Application identity"
    [[ "$identity" != *$'\n'* && "$identity" != *$'\r'* ]] || release_die "TETHER_SIGNING_IDENTITY contains a newline"

    security find-identity -v -p codesigning | grep -F -- "$identity" >/dev/null || release_die \
        "the requested signing identity is not available in the current keychain search list"
}

require_notary_profile() {
    local profile="${TETHER_NOTARY_KEYCHAIN_PROFILE:-}"
    [[ -n "$profile" ]] || release_die \
        "TETHER_NOTARY_KEYCHAIN_PROFILE must name a notarytool Keychain profile"
    [[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || release_die \
        "TETHER_NOTARY_KEYCHAIN_PROFILE contains unsupported characters"
}

require_execute_flag() {
    [[ "${1:-}" == "--execute" ]] || release_die \
        "dry-run only; pass --execute after reviewing paths and environment"
    [[ $# -eq 1 ]] || release_die "unexpected arguments"
}

ensure_new_output() {
    [[ ! -e "$1" ]] || release_die "refusing to overwrite existing output: $1"
}

make_release_parent() {
    mkdir -p "${TETHER_REPOSITORY_ROOT}/build/release"
}
