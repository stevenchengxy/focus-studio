#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --product FocusStudio
fi
BUILD_DIR="$(swift build --show-bin-path)"
TEST_DIR="$PROJECT_DIR/.artifacts/system-capture-stop"
mkdir -p "$TEST_DIR"
swiftc -parse-as-library -g -I "$BUILD_DIR/Modules" \
  Tests/SystemCaptureStopTests/main.swift \
  "$BUILD_DIR"/FocusStudioCore.build/*.swift.o \
  "$BUILD_DIR"/FocusStudioCapture.build/*.swift.o \
  -o "$TEST_DIR/system-capture-stop-tests"
"$TEST_DIR/system-capture-stop-tests"
