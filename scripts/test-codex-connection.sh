#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
codex_test_build="$(mktemp -d -t focus-studio-codex-tests)"
trap 'rm -f "$codex_test_build/CodexConnectionTests"; rmdir "$codex_test_build"' EXIT
swiftc -parse-as-library \
  Sources/FocusStudio/CodexDirectorModels.swift \
  Sources/FocusStudio/CodexConnectionConfiguration.swift \
  Sources/FocusStudio/CodexDirectorService.swift \
  Tests/CodexDirectorTests/main.swift \
  -o "$codex_test_build/CodexConnectionTests"
if [[ "${1:-}" == "--live-read-only" ]]; then
  "$codex_test_build/CodexConnectionTests" --live-read-only
else
  chmod +x Tests/CodexDirectorTests/fake-codex.py
  "$codex_test_build/CodexConnectionTests" "$PWD/Tests/CodexDirectorTests/fake-codex.py"
fi
