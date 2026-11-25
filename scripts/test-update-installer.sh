#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_dir=$(mktemp -d -t focus-update-installer)
trap 'rm -f "$test_dir/installer-tests"; rmdir "$test_dir"' EXIT
swiftc -parse-as-library Sources/FocusStudio/AppInstallation.swift Sources/FocusStudio/AppUpdateInstaller.swift \
    Tests/FocusStudioUpdateInstallerTests/main.swift -o "$test_dir/installer-tests"
"$test_dir/installer-tests"
