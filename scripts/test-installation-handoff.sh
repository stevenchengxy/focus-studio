#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TEST_DIR="$PROJECT_DIR/.artifacts/installation-handoff-tests"
mkdir -p "$TEST_DIR"
swiftc -parse-as-library \
    "$PROJECT_DIR/Sources/FocusStudio/AppInstallation.swift" \
    "$PROJECT_DIR/Sources/FocusStudio/AppInstallationHandoff.swift" \
    "$PROJECT_DIR/Tests/FocusStudioInstallationHandoffTests/main.swift" \
    -o "$TEST_DIR/installation-handoff-tests"
"$TEST_DIR/installation-handoff-tests"
