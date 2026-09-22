#!/bin/zsh
# Native SwiftUI fixture screenshots only; no running application is controlled.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --product FocusStudio
fi
BUILD_DIR="$(swift build --show-bin-path)"
TEST_DIR="$PROJECT_DIR/.artifacts/toolbar-snapshot-tests"
OUTPUT_DIR="${2:-$PROJECT_DIR/.artifacts/qa-1.6.0-b11}"
mkdir -p "$TEST_DIR"
APP_SOURCES=(Sources/FocusStudio/*.swift Sources/FocusStudio/AI/*.swift Sources/FocusStudio/AI/Assistant/*.swift Sources/FocusStudio/AI/Assistant/UI/*.swift(N))
APP_SOURCES=("${(@)APP_SOURCES:#Sources/FocusStudio/FocusStudioApp.swift}")
CORE_OBJECTS=("$BUILD_DIR"/FocusStudioCore.build/*.swift.o)
CAPTURE_OBJECTS=("$BUILD_DIR"/FocusStudioCapture.build/*.swift.o)
swiftc -parse-as-library -g \
  -I "$BUILD_DIR/Modules" \
  "${APP_SOURCES[@]}" \
  Tests/ToolbarSnapshotTests/main.swift \
  "${CORE_OBJECTS[@]}" "${CAPTURE_OBJECTS[@]}" \
  -o "$TEST_DIR/ToolbarSnapshotTests"
"$TEST_DIR/ToolbarSnapshotTests" "$OUTPUT_DIR"
