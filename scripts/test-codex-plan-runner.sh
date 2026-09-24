#!/bin/zsh
# Pure pause/cancellation checks. No real application is opened or controlled.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --target FocusStudioAutomation
fi
BUILD_DIR="$(swift build --show-bin-path)"
TEST_DIR="$PROJECT_DIR/.artifacts/codex-plan-runner"
mkdir -p "$TEST_DIR"
# The recording-plan types live in the FocusStudioAutomation library (next to
# the assistant session that drafts them); the runner stays in the app.
CORE_OBJECTS=("$BUILD_DIR"/FocusStudioCore.build/*.swift.o)
AUTOMATION_OBJECTS=("$BUILD_DIR"/FocusStudioAutomation.build/*.swift.o)
swiftc -parse-as-library \
  -target "$(uname -m)-apple-macosx15.0" \
  -I "$BUILD_DIR/Modules" \
  Sources/FocusStudio/CodexPlanRunner.swift \
  Tests/CodexPlanRunnerTests/main.swift \
  "${CORE_OBJECTS[@]}" "${AUTOMATION_OBJECTS[@]}" \
  -o "$TEST_DIR/CodexPlanRunnerTests"
"$TEST_DIR/CodexPlanRunnerTests"
