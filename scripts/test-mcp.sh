#!/bin/zsh
# Coverage for focus-studio-mcp, the stdio MCP server:
# 1. Tests/MCPTests/*.swift: the v1 catalog (exact names, conservative
#    schemas), the SDK adapter's tools/list entries and result mapping by
#    protocol version, JSON values, identity, the progress relay, and the
#    server over a scripted transport (handshake, forwarding with working
#    directory/client/version/roots, progress, cancellation, unknown and
#    withheld tools, shutdown). Compiled from the helper's sources (not its
#    main.swift) and linked with the objects of the helper's debug build.
# 2. Tests/MCPTests/mcp_client.py: the built helper over real stdio, as a
#    stdlib-only Python MCP client (version negotiation, ping, tools/list
#    against the catalog, tools/call, -32602, unknown arguments, batches
#    -32600, progress token, cancellation, an idle helper that does not poll
#    and leaves stdin blocking, stdout carrying only JSON-RPC, exit at end of
#    input), then the same handshake from inside a minimal Focus Studio.app
#    and through a symlink to it, which must report the app's version.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --product focus-studio-mcp
fi
BUILD_DIR="$(swift build --show-bin-path)"
HELPER="$BUILD_DIR/focus-studio-mcp"
LINK_LIST="$BUILD_DIR/focus-studio-mcp.product/Objects.LinkFileList"
[[ -x "$HELPER" && -f "$LINK_LIST" ]] || { echo "Build focus-studio-mcp first: swift build --product focus-studio-mcp" >&2; exit 1; }
TEST_DIR="$PROJECT_DIR/.artifacts/mcp-tests"
mkdir -p "$TEST_DIR"

HELPER_SOURCES=(Sources/FocusStudioMCP/*.swift)
HELPER_SOURCES=("${(@)HELPER_SOURCES:#Sources/FocusStudioMCP/main.swift}")
# Everything the helper links except its own objects: Core, Automation, the
# MCP SDK and the SDK's dependencies, whatever they are in this SDK version.
DEPENDENCY_OBJECTS=("${(@f)$(grep -v '/FocusStudioMCP\.build/' "$LINK_LIST")}")
swiftc -parse-as-library -g \
  -target "$(uname -m)-apple-macosx15.0" \
  -I "$BUILD_DIR/Modules" \
  "${HELPER_SOURCES[@]}" \
  Tests/MCPTests/*.swift \
  "${DEPENDENCY_OBJECTS[@]}" \
  -o "$TEST_DIR/MCPTests"
"$TEST_DIR/MCPTests" --fixture "$PROJECT_DIR/Tests/MCPTests/v1-tools.txt" --dump "$TEST_DIR/catalog.json"

python3 "$PROJECT_DIR/Tests/MCPTests/mcp_client.py" "$HELPER" \
  --catalog "$TEST_DIR/catalog.json" \
  --fixture "$PROJECT_DIR/Tests/MCPTests/v1-tools.txt" \
  --expect-version 0.0.0-dev

# From Focus Studio.app/Contents/MacOS the helper reports the app's version,
# whatever the executable's name, and also when started through a symlink
# (a PATH shortcut, a Homebrew cask binary), which Bundle.main does not follow.
BUNDLE_PROBE="$TEST_DIR/bundle-probe/Focus Studio.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
rm -rf -- "$TEST_DIR/bundle-probe"
mkdir -p "$BUNDLE_PROBE/Contents/MacOS" "$TEST_DIR/bundle-probe/bin"
cp "$PROJECT_DIR/Resources/Info.plist" "$BUNDLE_PROBE/Contents/Info.plist"
cp "$HELPER" "$BUNDLE_PROBE/Contents/MacOS/focus-studio-mcp"
ln -s "$BUNDLE_PROBE/Contents/MacOS/focus-studio-mcp" "$TEST_DIR/bundle-probe/bin/focus-studio-mcp"
for probe in "$BUNDLE_PROBE/Contents/MacOS/focus-studio-mcp" "$TEST_DIR/bundle-probe/bin/focus-studio-mcp"; do
    python3 "$PROJECT_DIR/Tests/MCPTests/mcp_client.py" "$probe" \
      --catalog "$TEST_DIR/catalog.json" \
      --fixture "$PROJECT_DIR/Tests/MCPTests/v1-tools.txt" \
      --expect-version "$APP_VERSION" \
      --handshake-only
done
