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
# (N): the assistant UI subfolder may not exist yet on every checkout.
APP_SOURCES=(Sources/FocusStudio/*.swift Sources/FocusStudio/AI/*.swift Sources/FocusStudio/AI/Assistant/*.swift Sources/FocusStudio/AI/Assistant/UI/*.swift(N))
APP_SOURCES=("${(@)APP_SOURCES:#Sources/FocusStudio/FocusStudioApp.swift}")
CORE_OBJECTS=("$BUILD_DIR"/FocusStudioCore.build/*.swift.o)
CAPTURE_OBJECTS=("$BUILD_DIR"/FocusStudioCapture.build/*.swift.o)
AUTOMATION_OBJECTS=("$BUILD_DIR"/FocusStudioAutomation.build/*.swift.o)
swiftc -parse-as-library -g \
  -I "$BUILD_DIR/Modules" \
  "${APP_SOURCES[@]}" \
  Tests/FocusStudioAppRegression/*.swift \
  "${CORE_OBJECTS[@]}" "${CAPTURE_OBJECTS[@]}" "${AUTOMATION_OBJECTS[@]}" \
  -o "$TEST_DIR/navigation-regression"
"$TEST_DIR/navigation-regression"
