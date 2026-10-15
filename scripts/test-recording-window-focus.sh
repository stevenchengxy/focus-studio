#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
swift build --target FocusStudioCore
BUILD_DIR="$(swift build --show-bin-path)"
TEST_DIR="$PROJECT_DIR/.artifacts/recording-window-focus-regression"
mkdir -p "$TEST_DIR"
CORE_OBJECTS=("$BUILD_DIR"/FocusStudioCore.build/*.swift.o)
swiftc -parse-as-library -D FOCUS_WINDOW_FOCUS_STANDALONE \
    -I "$BUILD_DIR/Modules" \
    Sources/FocusStudio/RecordingWindowFocus.swift \
    Tests/FocusStudioAppRegression/RecordingWindowFocusRegression.swift \
    "${CORE_OBJECTS[@]}" -o "$TEST_DIR/window-focus-regression"
"$TEST_DIR/window-focus-regression"
