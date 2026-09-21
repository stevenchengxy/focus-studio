#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build
fi
BUILD_DIR="$(swift build --show-bin-path)"
TEST_DIR="$PROJECT_DIR/.artifacts/app-regression"
mkdir -p "$TEST_DIR"
APP_SOURCES=(Sources/FocusStudio/*.swift)
APP_SOURCES=("${(@)APP_SOURCES:#Sources/FocusStudio/FocusStudioApp.swift}")
CORE_OBJECTS=("$BUILD_DIR"/FocusStudioCore.build/*.swift.o)
CAPTURE_OBJECTS=("$BUILD_DIR"/FocusStudioCapture.build/*.swift.o)
swiftc -parse-as-library -g \
  -I "$BUILD_DIR/Modules" \
  "${APP_SOURCES[@]}" \
  Tests/FocusStudioAppRegression/*.swift \
  "${CORE_OBJECTS[@]}" "${CAPTURE_OBJECTS[@]}" \
  -o "$TEST_DIR/navigation-regression"
"$TEST_DIR/navigation-regression"
