#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${1:-$PROJECT_DIR/dist/Focus Studio.app}"
REQUIRE_UNIVERSAL="${2:-}"
EXECUTABLE="$APP_DIR/Contents/MacOS/FocusStudio"
# The stdio MCP server that Claude Code, Codex and other clients start.
HELPER="$APP_DIR/Contents/MacOS/focus-studio-mcp"
HELPER_IDENTIFIER="com.local.focusstudio.mcp"
PLIST="$APP_DIR/Contents/Info.plist"

[[ -x "$EXECUTABLE" ]] || { echo "Missing app executable: $EXECUTABLE" >&2; exit 1; }
[[ -f "$HELPER" && -x "$HELPER" && ! -L "$HELPER" ]] || { echo "Missing MCP helper executable: $HELPER" >&2; exit 1; }
plutil -lint "$PLIST"
codesign --verify --deep --strict "$APP_DIR"
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")"
[[ "$icon_name" == "FocusStudio.icns" && -s "$APP_DIR/Contents/Resources/$icon_name" ]] || { echo "Missing bundle icon" >&2; exit 1; }
[[ -s "$APP_DIR/Contents/Resources/FocusStudioIcon.png" ]] || { echo "Missing in-app brand icon" >&2; exit 1; }
# The licence and notice texts of the packages focus-studio-mcp links
# statically (the same list as build-app.sh).
THIRD_PARTY_NOTICES="$APP_DIR/Contents/Resources/ThirdPartyNotices.txt"
[[ -s "$THIRD_PARTY_NOTICES" ]] || { echo "Missing third-party notices: $THIRD_PARTY_NOTICES" >&2; exit 1; }
for notice_package in swift-sdk swift-log swift-system eventsource; do
    grep -q "^==== $notice_package " "$THIRD_PARTY_NOTICES" || { echo "Third-party notices omit $notice_package." >&2; exit 1; }
done
grep -q 'The SwiftLog Project' "$THIRD_PARTY_NOTICES" || { echo "Third-party notices omit swift-log's NOTICE." >&2; exit 1; }
for app_language in en zh-Hans; do
    plutil -lint "$APP_DIR/Contents/Resources/$app_language.lproj/Localizable.strings"
    plutil -lint "$APP_DIR/Contents/Resources/$app_language.lproj/InfoPlist.strings"
done
swift "$SCRIPT_DIR/test-localization.swift" "$APP_DIR/Contents/Resources"

architecture_list="$(lipo -archs "$EXECUTABLE")"
if [[ "$REQUIRE_UNIVERSAL" == "--require-universal" ]]; then
    [[ " $architecture_list " == *" arm64 "* && " $architecture_list " == *" x86_64 "* ]] || {
        echo "Release must include both arm64 and x86_64; got $architecture_list." >&2
        exit 1
    }
fi

helper_architecture_list="$(lipo -archs "$HELPER")"
[[ "${(j: :)${(o)${(z)helper_architecture_list}}}" == "${(j: :)${(o)${(z)architecture_list}}}" ]] || {
    echo "MCP helper architectures [$helper_architecture_list] differ from the app's [$architecture_list]." >&2
    exit 1
}

minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[[ "$minimum_macos" == "15.0" && "$bundle_id" == "com.local.focusstudio" ]] || {
    echo "Unexpected app platform or bundle identity." >&2
    exit 1
}
for binary in "$EXECUTABLE" "$HELPER"; do
    for architecture in ${(z)architecture_list}; do
        linked_minimum="$(xcrun vtool -arch "$architecture" -show-build "$binary" | awk '/minos / { print $2; exit }')"
        [[ "$linked_minimum" == "$minimum_macos" ]] || { echo "${binary:t} $architecture minimum OS mismatch: $linked_minimum" >&2; exit 1; }
    done
done

# Every linked framework/runtime must ship with macOS, not the developer's Mac.
for binary in "$EXECUTABLE" "$HELPER"; do
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*) ;;
            *) echo "Non-portable linked dependency of ${binary:t}: $dependency" >&2; exit 1 ;;
        esac
    done < <(otool -L "$binary" | awk '/^[[:space:]]+[^[:space:]]/ { print $1 }' | sort -u)
done

# The helper is nested code with its own identity: its own identifier and
# designated requirement, no entitlements, and the app's hardened runtime and
# Team ID whenever the app has them.
codesign --verify --strict "$HELPER"
app_signature="$(codesign -dv --verbose=2 "$APP_DIR" 2>&1)"
helper_signature="$(codesign -dv --verbose=2 "$HELPER" 2>&1)"
signature_field() { print -r -- "$1" | sed -n "s/^$2=//p" | head -1 }
code_directory_flags() { print -r -- "$1" | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p' | head -1 }
[[ "$(signature_field "$helper_signature" Identifier)" == "$HELPER_IDENTIFIER" ]] || {
    echo "MCP helper identifier is $(signature_field "$helper_signature" Identifier), expected $HELPER_IDENTIFIER." >&2
    exit 1
}
[[ "$(codesign -d -r- "$HELPER" 2>&1)" == *"designated => identifier \"$HELPER_IDENTIFIER\""* ]] || {
    echo "MCP helper's designated requirement does not name $HELPER_IDENTIFIER." >&2
    exit 1
}
[[ -z "$(codesign -d --entitlements - "$HELPER" 2>/dev/null)" ]] || { echo "MCP helper must not carry entitlements." >&2; exit 1; }
app_team="$(signature_field "$app_signature" TeamIdentifier)"
helper_team="$(signature_field "$helper_signature" TeamIdentifier)"
[[ "$helper_team" == "$app_team" ]] || { echo "MCP helper Team ID $helper_team differs from the app's $app_team." >&2; exit 1; }
if [[ "$(code_directory_flags "$app_signature")" == *runtime* ]]; then
    [[ "$(code_directory_flags "$helper_signature")" == *runtime* ]] || { echo "The app has the hardened runtime; the MCP helper must too." >&2; exit 1; }
fi
# Run the stdio smoke test on every slice this Mac can execute (x86_64
# through Rosetta on Apple Silicon); a slice it cannot run is only checked
# statically, and says so.
helper_slices_run=()
for helper_architecture in ${(z)helper_architecture_list}; do
    if arch -"$helper_architecture" /usr/bin/true 2>/dev/null; then
        python3 "$SCRIPT_DIR/verify-mcp-helper.py" "$HELPER" "$PROJECT_DIR/Tests/MCPTests/v1-tools.txt" "$app_version" "$helper_architecture"
        helper_slices_run+=("$helper_architecture")
    else
        echo "MCP helper $helper_architecture slice: not run, this Mac cannot execute $helper_architecture code; checked statically only."
    fi
done

audio_directory="$APP_DIR/Contents/Resources/Audio"
for asset in catalog.json README.md product-demo-bed.wav calm-gradient-bed.wav bright-launch-bed.wav midnight-focus-bed.wav ui-click.wav soft-tap.wav typing-key.wav zoom-whoosh.wav city-loop.mp3 overworld.mp3 calm-loop.mp3 loading-screen-loop.wav; do
    [[ -s "$audio_directory/$asset" ]] || { echo "Missing bundled resource: $asset" >&2; exit 1; }
done
plutil -convert xml1 -o /dev/null "$audio_directory/catalog.json"
catalog_version="$(plutil -extract schemaVersion raw -o - "$audio_directory/catalog.json")"
asset_count="$(plutil -extract assets raw -o - "$audio_directory/catalog.json")"
[[ "$catalog_version" == 1 && "$asset_count" == <-> && "$asset_count" -gt 0 ]] || {
    echo "Invalid bundled audio catalog metadata." >&2
    exit 1
}
for (( asset_index = 0; asset_index < asset_count; asset_index++ )); do
    asset_path="$(plutil -extract "assets.$asset_index.relativePath" raw -o - "$audio_directory/catalog.json")"
    [[ "$asset_path" != */* && -s "$audio_directory/$asset_path" ]] || {
        echo "Audio catalog references a missing or external resource: $asset_path" >&2
        exit 1
    }
    if expected_hash="$(plutil -extract "assets.$asset_index.sha256" raw -o - "$audio_directory/catalog.json" 2>/dev/null)"; then
        actual_hash="$(shasum -a 256 "$audio_directory/$asset_path" | awk '{ print $1 }')"
        [[ "$actual_hash" == "$expected_hash" ]] || {
            echo "Bundled audio integrity mismatch: $asset_path" >&2
            exit 1
        }
    fi
done

# A release contains only the app binary, static resources and signature. Never
# copy projects, user preferences, or Codex credentials into a distribution.
while IFS= read -r entry; do
    case "$entry" in
        Contents/Info.plist|Contents/MacOS/FocusStudio|Contents/MacOS/focus-studio-mcp|Contents/_CodeSignature/CodeResources) ;;
        Contents/Resources/FocusStudio.icns|Contents/Resources/FocusStudioIcon.png|Contents/Resources/ThirdPartyNotices.txt) ;;
        Contents/Resources/en.lproj/Localizable.strings|Contents/Resources/zh-Hans.lproj/Localizable.strings) ;;
        Contents/Resources/en.lproj/InfoPlist.strings|Contents/Resources/zh-Hans.lproj/InfoPlist.strings) ;;
        Contents/Resources/Audio/catalog.json|Contents/Resources/Audio/README.md) ;;
        Contents/Resources/Audio/product-demo-bed.wav|Contents/Resources/Audio/calm-gradient-bed.wav|Contents/Resources/Audio/bright-launch-bed.wav|Contents/Resources/Audio/midnight-focus-bed.wav) ;;
        Contents/Resources/Audio/ui-click.wav|Contents/Resources/Audio/soft-tap.wav|Contents/Resources/Audio/typing-key.wav|Contents/Resources/Audio/zoom-whoosh.wav) ;;
        Contents/Resources/Audio/city-loop.mp3|Contents/Resources/Audio/overworld.mp3|Contents/Resources/Audio/calm-loop.mp3|Contents/Resources/Audio/loading-screen-loop.wav) ;;
        *) echo "Unexpected release file: $entry" >&2; exit 1 ;;
    esac
done < <(cd "$APP_DIR" && find Contents -type f -print)
[[ -z "$(find "$APP_DIR/Contents" -type l -print)" ]] || { echo "App bundle contains external symlinks." >&2; exit 1; }

helper_tool_count="$(grep -cv -e '^#' -e '^[[:space:]]*$' "$PROJECT_DIR/Tests/MCPTests/v1-tools.txt")"
echo "Verified app: macOS $minimum_macos+, architectures [$architecture_list], system frameworks only, MCP helper focus-studio-mcp ($HELPER_IDENTIFIER, same architectures, $helper_tool_count tools over stdio on [${helper_slices_run[*]:-none}]), third-party notices, icon and both language catalogs verified, $asset_count bundled audio assets verified."
