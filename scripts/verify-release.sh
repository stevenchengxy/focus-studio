#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${1:-$PROJECT_DIR/dist/Focus Studio.app}"
REQUIRE_UNIVERSAL="${2:-}"
EXECUTABLE="$APP_DIR/Contents/MacOS/FocusStudio"
PLIST="$APP_DIR/Contents/Info.plist"

[[ -x "$EXECUTABLE" ]] || { echo "Missing app executable: $EXECUTABLE" >&2; exit 1; }
plutil -lint "$PLIST"
codesign --verify --deep --strict "$APP_DIR"
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")"
[[ "$icon_name" == "FocusStudio.icns" && -s "$APP_DIR/Contents/Resources/$icon_name" ]] || { echo "Missing bundle icon" >&2; exit 1; }
[[ -s "$APP_DIR/Contents/Resources/FocusStudioIcon.png" ]] || { echo "Missing in-app brand icon" >&2; exit 1; }
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

minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
[[ "$minimum_macos" == "15.0" && "$bundle_id" == "com.local.focusstudio" ]] || {
    echo "Unexpected app platform or bundle identity." >&2
    exit 1
}
for architecture in ${(z)architecture_list}; do
    linked_minimum="$(xcrun vtool -arch "$architecture" -show-build "$EXECUTABLE" | awk '/minos / { print $2; exit }')"
    [[ "$linked_minimum" == "$minimum_macos" ]] || { echo "$architecture minimum OS mismatch: $linked_minimum" >&2; exit 1; }
done

# Every linked framework/runtime must ship with macOS, not the developer's Mac.
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/*|/usr/lib/*) ;;
        *) echo "Non-portable linked dependency: $dependency" >&2; exit 1 ;;
    esac
done < <(otool -L "$EXECUTABLE" | awk '/^[[:space:]]+[^[:space:]]/ { print $1 }' | sort -u)

audio_directory="$APP_DIR/Contents/Resources/Audio"
for asset in catalog.json README.md product-demo-bed.wav calm-gradient-bed.wav bright-launch-bed.wav midnight-focus-bed.wav ui-click.wav soft-tap.wav typing-key.wav zoom-whoosh.wav city-loop.mp3 overworld.mp3; do
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
        Contents/Info.plist|Contents/MacOS/FocusStudio|Contents/_CodeSignature/CodeResources) ;;
        Contents/Resources/FocusStudio.icns|Contents/Resources/FocusStudioIcon.png) ;;
        Contents/Resources/en.lproj/Localizable.strings|Contents/Resources/zh-Hans.lproj/Localizable.strings) ;;
        Contents/Resources/en.lproj/InfoPlist.strings|Contents/Resources/zh-Hans.lproj/InfoPlist.strings) ;;
        Contents/Resources/Audio/catalog.json|Contents/Resources/Audio/README.md) ;;
        Contents/Resources/Audio/product-demo-bed.wav|Contents/Resources/Audio/calm-gradient-bed.wav|Contents/Resources/Audio/bright-launch-bed.wav|Contents/Resources/Audio/midnight-focus-bed.wav) ;;
        Contents/Resources/Audio/ui-click.wav|Contents/Resources/Audio/soft-tap.wav|Contents/Resources/Audio/typing-key.wav|Contents/Resources/Audio/zoom-whoosh.wav|Contents/Resources/Audio/city-loop.mp3|Contents/Resources/Audio/overworld.mp3) ;;
        *) echo "Unexpected release file: $entry" >&2; exit 1 ;;
    esac
done < <(cd "$APP_DIR" && find Contents -type f -print)
[[ -z "$(find "$APP_DIR/Contents" -type l -print)" ]] || { echo "App bundle contains external symlinks." >&2; exit 1; }

echo "Verified app: macOS $minimum_macos+, architectures [$architecture_list], system frameworks only, icon and both language catalogs verified, $asset_count bundled audio assets verified."
