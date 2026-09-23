#!/bin/bash
set -euo pipefail
REPO_DIRECTORY="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD_DIRECTORY="${TETHER_TEST_BUILD_DIR:-/private/tmp/tether-host-onboarding-build}"
PRODUCTS_DIRECTORY="$BUILD_DIRECTORY/Build/Products/Debug"
TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/tether-onboarding-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT

# Build the app first; its local package product supplies the core module/object.
test -f "$PRODUCTS_DIRECTORY/TetherHostCore.o"
xcrun swiftc -parse-as-library -swift-version 6 \
    -I "$PRODUCTS_DIRECTORY" \
    "$REPO_DIRECTORY/TetherHost/App/AppViewModel.swift" \
    "$REPO_DIRECTORY/TetherHost/App/NativeVMManager.swift" \
    "$REPO_DIRECTORY/scripts/tests/OnboardingStateSmoke.swift" \
    "$PRODUCTS_DIRECTORY/TetherHostCore.o" \
    -o "$TEST_DIRECTORY/onboarding-state-tests"
"$TEST_DIRECTORY/onboarding-state-tests"
