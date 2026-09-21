#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
TEST_DIR="$PROJECT_DIR/.artifacts/localization-tests"
mkdir -p "$TEST_DIR"
swiftc -parse-as-library \
  Sources/FocusStudio/AppLocalization.swift \
  Tests/FocusStudioLocalization/main.swift \
  -o "$TEST_DIR/language-preferences"
"$TEST_DIR/language-preferences"
