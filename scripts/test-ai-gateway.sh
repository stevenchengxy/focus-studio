#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ai_test_build="$(mktemp -d -t focus-studio-ai-gateway-tests)"
trap 'rm -f "$ai_test_build/AIGatewayTests"; rmdir "$ai_test_build"' EXIT
swiftc -parse-as-library \
  Sources/FocusStudio/AI/AIProvider.swift \
  Sources/FocusStudio/AI/AIGatewayClient.swift \
  Sources/FocusStudio/AI/AIGatewayStore.swift \
  Tests/AIGatewayTests/main.swift \
  -o "$ai_test_build/AIGatewayTests"
"$ai_test_build/AIGatewayTests"
