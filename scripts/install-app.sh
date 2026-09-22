#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
INSTALLER_DIR="$PROJECT_DIR/.artifacts/installer"
mkdir -p "$INSTALLER_DIR"
swiftc -parse-as-library \
    "$PROJECT_DIR/Sources/FocusStudio/AppInstallation.swift" \
    "$SCRIPT_DIR/InstallAppMain.swift" \
    -o "$INSTALLER_DIR/focus-studio-installer"
"$INSTALLER_DIR/focus-studio-installer" "$@"
