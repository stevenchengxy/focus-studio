#!/bin/zsh
# Offline coverage for the AI assistant: protocol parsing, the agent loop with
# a scripted model, the confirmation gate, tool validation, dropped and
# interleaved edits, the app-control tools against a fake app
# (record/stop/library/zooms/music/export paths and the export guard),
# the automation API (structured results, result language, working-directory
# paths, per-export options with progress and cancellation, get_project,
# get_status), the MCP layer (tool catalog, result shape and inline images,
# long-call jobs, library tools), recording sessions (start returns once
# live, duration auto-stop, wait_for_recording, a paused recording,
# cancellation, the sound prompt for sound an external start adds), the shared
# conversation (saved history, provider resets, recording-plan drafts that
# run only from Run, the recording confirmation, Retry without replaying a
# tool), AVFoundation
# clip assembly and the Ark client against a local Python fixture server.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --product FocusStudio
fi
BUILD_DIR="$(swift build --show-bin-path)"
TEST_DIR="$PROJECT_DIR/.artifacts/ai-assistant"
mkdir -p "$TEST_DIR"
CORE_OBJECTS=("$BUILD_DIR"/FocusStudioCore.build/*.swift.o)
swiftc -parse-as-library -g \
  -target "$(uname -m)-apple-macosx15.0" \
  -I "$BUILD_DIR/Modules" \
  Sources/FocusStudioAutomation/Localization.swift \
  Sources/FocusStudioAutomation/AIJSONValue.swift \
  Sources/FocusStudioAutomation/AIAssistantModels.swift \
  Sources/FocusStudioAutomation/CodexRecordingPlan.swift \
  Sources/FocusStudioAutomation/ArkMediaClient.swift \
  Sources/FocusStudioAutomation/AIAssistantTools.swift \
  Sources/FocusStudioAutomation/AIAssistantAppControl.swift \
  Sources/FocusStudioAutomation/AIProjectReport.swift \
  Sources/FocusStudioAutomation/AIAutomationTools.swift \
  Sources/FocusStudioAutomation/AIProjectLibraryTools.swift \
  Sources/FocusStudioAutomation/MCPToolResult.swift \
  Sources/FocusStudioAutomation/AutomationJobs.swift \
  Sources/FocusStudioAutomation/MCPToolCatalog.swift \
  Sources/FocusStudioAutomation/AIAssistantSession.swift \
  Tests/AIAssistantTests/main.swift \
  Tests/AIAssistantTests/AutomationAPITests.swift \
  Tests/AIAssistantTests/MCPAutomationTests.swift \
  Tests/AIAssistantTests/RecordingSessionTests.swift \
  "${CORE_OBJECTS[@]}" \
  -o "$TEST_DIR/AIAssistantTests"
chmod +x Tests/AIAssistantTests/fake-ark.py
"$TEST_DIR/AIAssistantTests" "$PROJECT_DIR/Tests/AIAssistantTests/fake-ark.py"
