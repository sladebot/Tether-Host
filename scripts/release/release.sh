#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ "${1:-}" != "--execute" || $# -ne 1 ]]; then
    printf '%s\n' "release: dry run; the complete pipeline would archive, export, verify, create and sign the DMG, notarize, then staple it" >&2
    printf '%s\n' "release: each stage refuses to overwrite an existing output" >&2
    exit 0
fi

"${SCRIPT_DIRECTORY}/validate-environment.sh" --notary
"${SCRIPT_DIRECTORY}/archive.sh" --execute
"${SCRIPT_DIRECTORY}/export.sh" --execute
"${SCRIPT_DIRECTORY}/verify-signatures.sh"
"${SCRIPT_DIRECTORY}/create-dmg.sh" --execute
"${SCRIPT_DIRECTORY}/sign-dmg.sh" --execute
"${SCRIPT_DIRECTORY}/notarize.sh" --execute
"${SCRIPT_DIRECTORY}/staple.sh" --execute
