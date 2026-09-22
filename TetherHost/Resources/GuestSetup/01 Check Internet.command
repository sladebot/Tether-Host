#!/bin/bash
set -euo pipefail
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
exec /bin/bash "$SCRIPT_DIRECTORY/Set up Tether Guest.command" internet
