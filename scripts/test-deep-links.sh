#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TEST_STAGE="$(mktemp -d -t focus-studio-deep-links)"
trap 'rm -f "$TEST_STAGE/DeepLinkTests"; rmdir "$TEST_STAGE"' EXIT
# This Foundation-only regression never builds, launches or registers the app.
swiftc -parse-as-library \
    "$PROJECT_DIR/Sources/FocusStudio/AppSettingsDeepLink.swift" \
    "$PROJECT_DIR/Tests/FocusStudioDeepLinkTests/main.swift" \
    -o "$TEST_STAGE/DeepLinkTests"
"$TEST_STAGE/DeepLinkTests" "$PROJECT_DIR/Resources/Info.plist"
