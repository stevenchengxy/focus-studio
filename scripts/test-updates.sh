#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
update_test_build="$(mktemp -d -t focus-studio-update-tests)"
trap 'rm -f "$update_test_build/UpdateTests"; rmdir "$update_test_build"' EXIT
swiftc -parse-as-library \
  Sources/FocusStudio/AppUpdateRelease.swift \
  Sources/FocusStudio/AppUpdateService.swift \
  Tests/FocusStudioUpdateTests/main.swift \
  -o "$update_test_build/UpdateTests"
"$update_test_build/UpdateTests"
