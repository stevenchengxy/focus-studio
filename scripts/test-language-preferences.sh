#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --target FocusStudioAutomation
fi
BUILD_DIR="$(swift build --show-bin-path)"
TEST_DIR="$PROJECT_DIR/.artifacts/localization-tests"
mkdir -p "$TEST_DIR"
# AppLanguage and L10n live in the FocusStudioAutomation library; the
# SwiftUI-facing AppLocalization stays in the app.
CORE_OBJECTS=("$BUILD_DIR"/FocusStudioCore.build/*.swift.o)
AUTOMATION_OBJECTS=("$BUILD_DIR"/FocusStudioAutomation.build/*.swift.o)
swiftc -parse-as-library \
  -I "$BUILD_DIR/Modules" \
  Sources/FocusStudio/AppLocalization.swift \
  Tests/FocusStudioLocalization/main.swift \
  "${CORE_OBJECTS[@]}" "${AUTOMATION_OBJECTS[@]}" \
  -o "$TEST_DIR/language-preferences"
"$TEST_DIR/language-preferences"
