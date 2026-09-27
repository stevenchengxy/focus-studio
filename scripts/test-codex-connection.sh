#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# --skip-build: the caller (scripts/test.sh) has just run `swift build`.
# --live-read-only: talk to the real Codex app server, read-only.
skip_build=0
live=0
for argument in "$@"; do
  case "$argument" in
    --skip-build) skip_build=1 ;;
    --live-read-only) live=1 ;;
    *) echo "usage: $0 [--skip-build] [--live-read-only]" >&2; exit 2 ;;
  esac
done
# The recording-plan types come from the FocusStudioAutomation library. Build
# it (incremental, quick when up to date) so a run on its own never compiles
# against, or links, objects older than the sources.
if (( ! skip_build )); then
  swift build --target FocusStudioAutomation
fi
build_dir="$(swift build --show-bin-path)"
codex_test_build="$(mktemp -d -t focus-studio-codex-tests)"
trap 'rm -f "$codex_test_build/CodexConnectionTests"; rmdir "$codex_test_build"' EXIT
swiftc -parse-as-library \
  -target "$(uname -m)-apple-macosx15.0" \
  -I "$build_dir/Modules" \
  Sources/FocusStudio/CodexDirectorModels.swift \
  Sources/FocusStudio/CodexConnectionConfiguration.swift \
  Sources/FocusStudio/CodexDirectorService.swift \
  Tests/CodexDirectorTests/main.swift \
  "$build_dir"/FocusStudioCore.build/*.swift.o "$build_dir"/FocusStudioAutomation.build/*.swift.o \
  -o "$codex_test_build/CodexConnectionTests"
if (( live )); then
  "$codex_test_build/CodexConnectionTests" --live-read-only
else
  chmod +x Tests/CodexDirectorTests/fake-codex.py
  "$codex_test_build/CodexConnectionTests" "$PWD/Tests/CodexDirectorTests/fake-codex.py"
fi
