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
APP_SOURCES=(Sources/FocusStudio/*.swift Sources/FocusStudio/AI/*.swift Sources/FocusStudio/AI/Assistant/*.swift Sources/FocusStudio/AI/Assistant/UI/*.swift(N) Sources/FocusStudio/Automation/*.swift(N))
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
# MCPEndToEndRegression drives the real focus-studio-mcp from this build
# (swift build builds it) with Tests/MCPTests/mcp_e2e.py.
[[ -x "$BUILD_DIR/focus-studio-mcp" ]] || { echo "Build focus-studio-mcp first: swift build" >&2; exit 1; }
FOCUS_STUDIO_TEST_MCP_HELPER="$BUILD_DIR/focus-studio-mcp" \
FOCUS_STUDIO_TEST_MCP_E2E="$PROJECT_DIR/Tests/MCPTests/mcp_e2e.py" \
FOCUS_STUDIO_TEST_MCP_TOOLS="$PROJECT_DIR/Tests/MCPTests/v1-tools.txt" \
  "$TEST_DIR/navigation-regression"
