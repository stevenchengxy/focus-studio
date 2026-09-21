#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

cd "$PROJECT_DIR"
swift build
swift run FocusStudioPermissionTests
swift run FocusStudioE2E --output-dir "$PROJECT_DIR/.artifacts/e2e"
swift "$SCRIPT_DIR/test-localization.swift"
zsh "$SCRIPT_DIR/test-language-preferences.sh"
zsh "$SCRIPT_DIR/test-app-regression.sh" --skip-build
bash "$SCRIPT_DIR/test-codex-connection.sh"
