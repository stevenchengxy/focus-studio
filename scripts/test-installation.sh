#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TEST_DIR="$PROJECT_DIR/.artifacts/installation-tests"
mkdir -p "$TEST_DIR"
swiftc -parse-as-library \
    "$PROJECT_DIR/Sources/FocusStudio/AppInstallation.swift" \
    "$PROJECT_DIR/Tests/FocusStudioInstallationTests/main.swift" \
    -o "$TEST_DIR/installation-tests"
"$TEST_DIR/installation-tests"
