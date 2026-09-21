#!/bin/zsh
# Offline coverage for the AI assistant: protocol parsing, the agent loop with
# a scripted model, the confirmation gate, tool validation, AVFoundation clip
# assembly and the Ark client against a local Python fixture server.
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
  Sources/FocusStudio/AppLocalization.swift \
  Sources/FocusStudio/AI/Assistant/AIAssistantModels.swift \
  Sources/FocusStudio/AI/Assistant/ArkMediaClient.swift \
  Sources/FocusStudio/AI/Assistant/AIAssistantTools.swift \
  Sources/FocusStudio/AI/Assistant/AIAssistantSession.swift \
  Tests/AIAssistantTests/main.swift \
  "${CORE_OBJECTS[@]}" \
  -o "$TEST_DIR/AIAssistantTests"
chmod +x Tests/AIAssistantTests/fake-ark.py
"$TEST_DIR/AIAssistantTests" "$PROJECT_DIR/Tests/AIAssistantTests/fake-ark.py"
