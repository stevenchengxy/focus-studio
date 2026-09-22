#!/bin/zsh
# Pure pause/cancellation checks. No real application is opened or controlled.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --target FocusStudioCore
fi
BUILD_DIR="$(swift build --show-bin-path)"
TEST_DIR="$PROJECT_DIR/.artifacts/codex-plan-runner"
mkdir -p "$TEST_DIR"
CORE_OBJECTS=("$BUILD_DIR"/FocusStudioCore.build/*.swift.o)
swiftc -parse-as-library \
  -target "$(uname -m)-apple-macosx15.0" \
  -I "$BUILD_DIR/Modules" \
  Sources/FocusStudio/CodexDirectorModels.swift \
  Sources/FocusStudio/CodexPlanRunner.swift \
  Tests/CodexPlanRunnerTests/main.swift \
  "${CORE_OBJECTS[@]}" \
  -o "$TEST_DIR/CodexPlanRunnerTests"
"$TEST_DIR/CodexPlanRunnerTests"
