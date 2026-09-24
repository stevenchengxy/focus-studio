#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
REQUESTED_APP_DIR="${FOCUS_STUDIO_APP_DIR:-$PROJECT_DIR/dist/Focus Studio.app}"
[[ "$REQUESTED_APP_DIR" == /* ]] || { echo "FOCUS_STUDIO_APP_DIR must be an absolute path." >&2; exit 1; }
REQUESTED_APP_DIR="${REQUESTED_APP_DIR:a}"
APP_DIR="${REQUESTED_APP_DIR:A}"
[[ "$APP_DIR" == "$REQUESTED_APP_DIR" && "$APP_DIR" == "$PROJECT_DIR/dist/"* && "${APP_DIR:t}" == 'Focus Studio.app' ]] || {
    echo "App output must be a non-symlink Focus Studio.app path inside this project's dist directory." >&2
    exit 1
}
APP_PARENT="${APP_DIR:h}"
AUDIO_DIR="$PROJECT_DIR/Resources/Audio"
BACKGROUND_DIR="$PROJECT_DIR/Resources/Backgrounds"
AUDIO_GENERATOR="$PROJECT_DIR/scripts/generate-audio-assets.swift"
BUILD_ARCHITECTURES="${FOCUS_STUDIO_ARCHS:-universal}"
INSTALL_AFTER_BUILD=false
case "${1:-}" in
    "") ;;
    --install) INSTALL_AFTER_BUILD=true ;;
    *) echo "Usage: build-app.sh [--install]" >&2; exit 1 ;;
esac

app_is_running() {
    ps -axo args= | awk -v executable="$APP_DIR/Contents/MacOS/FocusStudio" \
        '$0 == executable || index($0, executable " ") == 1 { found = 1 } END { exit !found }'
}
if app_is_running; then
    echo "The output app is running and will not be replaced. Quit it yourself or select a separate FOCUS_STUDIO_APP_DIR candidate." >&2
    exit 1
fi

case "$BUILD_ARCHITECTURES" in
    universal) ARCHITECTURES=(arm64 x86_64) ;;
    native) ARCHITECTURES=("$(uname -m)") ;;
    arm64|x86_64) ARCHITECTURES=("$BUILD_ARCHITECTURES") ;;
    *) echo "FOCUS_STUDIO_ARCHS must be universal, native, arm64, or x86_64." >&2; exit 1 ;;
esac

cd "$PROJECT_DIR"

GENERATED_AUDIO_ASSETS=(
    product-demo-bed.wav
    calm-gradient-bed.wav
    bright-launch-bed.wav
    midnight-focus-bed.wav
    ui-click.wav
    soft-tap.wav
    typing-key.wav
    zoom-whoosh.wav
)

NETWORK_AUDIO_ASSETS=(
    city-loop.mp3
    overworld.mp3
    calm-loop.mp3
    loading-screen-loop.wav
)

BUNDLED_AUDIO_ASSETS=(
    "${GENERATED_AUDIO_ASSETS[@]}"
    "${NETWORK_AUDIO_ASSETS[@]}"
)

needs_audio_regen=false
for asset in "${GENERATED_AUDIO_ASSETS[@]}"; do
    if [[ ! -f "$AUDIO_DIR/$asset" || "$AUDIO_GENERATOR" -nt "$AUDIO_DIR/$asset" ]]; then
        needs_audio_regen=true
        break
    fi
done

for asset in "${NETWORK_AUDIO_ASSETS[@]}"; do
    if [[ ! -s "$AUDIO_DIR/$asset" ]]; then
        echo "Missing verified network audio asset: $asset" >&2
        exit 1
    fi
done

verify_network_audio() {
    local filename="$1"
    local expected_hash="$2"
    local actual_hash
    actual_hash="$(shasum -a 256 "$AUDIO_DIR/$filename" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "Network audio checksum mismatch: $filename" >&2
        exit 1
    fi
}

verify_network_audio city-loop.mp3 9349982fb8e365167bc5c89f2ac50d3b5376b9f627d506ba30a9b26c8230597e
verify_network_audio overworld.mp3 d32949f8467ac463a52ca88ed250e505545bc98a46e4e472c1f994bf447a1beb
verify_network_audio calm-loop.mp3 1d7e386c079d4add6b3b1592054846e4977035f26844466e409467c6dc7bdbde
verify_network_audio loading-screen-loop.wav 1d169377c84b4c62362cd21144daad68f41e56e8a7e2ab837723e9b01200f44c

if [[ "$needs_audio_regen" == true ]]; then
    swift "$AUDIO_GENERATOR" "$AUDIO_DIR"
fi

mkdir -p "$APP_PARENT"
mkdir -p "$PROJECT_DIR/.artifacts"
zsh "$SCRIPT_DIR/build-icon.sh"
BUILD_STAGE="$(mktemp -d "$APP_PARENT/.focusstudio-build.XXXXXX")"
STAGED_APP="$BUILD_STAGE/Focus Studio.app"
CONTENTS_DIR="$STAGED_APP/Contents"
# Never modify the existing app until the replacement has passed verification.
cleanup() {
    if [[ -e "$BUILD_STAGE/previous.app" && ! -e "$APP_DIR" ]]; then
        mv "$BUILD_STAGE/previous.app" "$APP_DIR"
    fi
    if [[ "$BUILD_STAGE" == "$APP_PARENT/.focusstudio-build."* && -d "$BUILD_STAGE" ]]; then
        rm -rf -- "$BUILD_STAGE"
    fi
}
trap cleanup EXIT
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PROJECT_DIR/Resources/Info.plist")"
source_digest() {
    {
        shasum -a 256 "$PROJECT_DIR/Package.swift" "$PROJECT_DIR/Package.resolved" "$PROJECT_DIR/Resources/Info.plist" "$PROJECT_DIR/Resources/FocusStudio.entitlements"
        find "$PROJECT_DIR/Sources/FocusStudio" "$PROJECT_DIR/Sources/FocusStudioCore" "$PROJECT_DIR/Sources/FocusStudioAutomation" "$PROJECT_DIR/Sources/FocusStudioMCP" -type f -name '*.swift' -print | LC_ALL=C sort | while IFS= read -r source_file; do
            shasum -a 256 "$source_file"
        done
        find "$PROJECT_DIR/Resources" -type f -print | LC_ALL=C sort | while IFS= read -r resource_file; do
            shasum -a 256 "$resource_file"
        done
    } | shasum -a 256 | awk '{ print $1 }'
}
SOURCE_DIGEST_BEFORE="$(source_digest)"
SLICE_PATHS=()
HELPER_SLICE_PATHS=()
HELPER_LINK_LISTS=()
# The MCP helper (focus-studio-mcp) is built exactly like the app, per
# architecture, from the versions pinned in Package.resolved.
for architecture in "${ARCHITECTURES[@]}"; do
    triple="$architecture-apple-macosx$MINIMUM_MACOS"
    scratch_path="$PROJECT_DIR/.build/distribution/$architecture"
    swift build -c release --product FocusStudio --triple "$triple" --scratch-path "$scratch_path" --force-resolved-versions
    swift build -c release --product focus-studio-mcp --triple "$triple" --scratch-path "$scratch_path" --force-resolved-versions
    binary_directory="$(swift build -c release --triple "$triple" --scratch-path "$scratch_path" --show-bin-path)"
    SLICE_PATHS+=("$binary_directory/FocusStudio")
    HELPER_SLICE_PATHS+=("$binary_directory/focus-studio-mcp")
    HELPER_LINK_LISTS+=("$binary_directory/focus-studio-mcp.product/Objects.LinkFileList")
done
[[ "$(source_digest)" == "$SOURCE_DIGEST_BEFORE" ]] || {
    echo "Sources changed during release build. Retry after edits are complete so both architectures use the same code." >&2
    exit 1
}
HELPER="$CONTENTS_DIR/MacOS/focus-studio-mcp"
HELPER_IDENTIFIER="com.local.focusstudio.mcp"
if (( ${#SLICE_PATHS[@]} > 1 )); then
    lipo -create "${SLICE_PATHS[@]}" -output "$CONTENTS_DIR/MacOS/FocusStudio"
    lipo -create "${HELPER_SLICE_PATHS[@]}" -output "$HELPER"
else
    cp "${SLICE_PATHS[1]}" "$CONTENTS_DIR/MacOS/FocusStudio"
    cp "${HELPER_SLICE_PATHS[1]}" "$HELPER"
fi
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/FocusStudio.icns" "$CONTENTS_DIR/Resources/FocusStudio.icns"
cp "$PROJECT_DIR/Resources/Brand/FocusStudioIcon.png" "$CONTENTS_DIR/Resources/FocusStudioIcon.png"
for app_language in en zh-Hans; do
    ditto "$PROJECT_DIR/Resources/$app_language.lproj" "$CONTENTS_DIR/Resources/$app_language.lproj"
done
ditto "$AUDIO_DIR" "$CONTENTS_DIR/Resources/Audio"
ditto "$BACKGROUND_DIR" "$CONTENTS_DIR/Resources/Backgrounds"

# Every bundled background is output of scripts/generate-background-assets.swift.
# The digests recorded in its catalog are re-checked here so a swapped-in
# third-party image cannot reach a build unnoticed.
python3 - "$CONTENTS_DIR/Resources/Backgrounds" <<'PYCHECK'
import hashlib, json, os, sys
directory = sys.argv[1]
catalog = json.load(open(os.path.join(directory, "catalog.json")))
for asset in catalog["assets"]:
    path = os.path.join(directory, asset["relativePath"])
    if not os.path.isfile(path):
        sys.exit("Missing bundled background: %s" % asset["relativePath"])
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if digest != asset["sha256"]:
        sys.exit("Background digest mismatch for %s" % asset["relativePath"])
print("Verified %d bundled backgrounds." % len(catalog["assets"]))
PYCHECK

# focus-studio-mcp statically links the MCP Swift SDK and some of its
# dependencies; their licence and notice texts ship in the app. Every module
# the helper links must belong to Focus Studio or to a package listed here,
# so a new dependency (after an SDK upgrade) stops the build until its texts
# are added (here and in verify-release.sh).
typeset -A NOTICE_PACKAGE_OF_MODULE=(
    MCP swift-sdk
    Logging swift-log
    SystemPackage swift-system
    CSystem swift-system
    EventSource eventsource
)
NOTICE_PACKAGES=(swift-sdk swift-log swift-system eventsource)
typeset -A NOTICE_FILES=(
    swift-sdk LICENSE
    swift-log "LICENSE.txt NOTICE.txt"
    swift-system LICENSE.txt
    eventsource LICENSE.md
)
for link_list in "${HELPER_LINK_LISTS[@]}"; do
    [[ -s "$link_list" ]] || { echo "Missing link file list of focus-studio-mcp: $link_list" >&2; exit 1; }
    for linked_module in $(sed -E 's#.*/([^/]+)\.build/.*#\1#' "$link_list" | sort -u); do
        case "$linked_module" in
            FocusStudioMCP|FocusStudioAutomation|FocusStudioCore) ;;
            *) [[ -n "${NOTICE_PACKAGE_OF_MODULE[$linked_module]:-}" ]] || {
                echo "focus-studio-mcp links $linked_module, which has no third-party notice; add its package to build-app.sh and verify-release.sh." >&2
                exit 1
            } ;;
        esac
    done
done
pinned_package() {
    python3 -c 'import json, sys
pins = {pin["identity"]: pin for pin in json.load(open(sys.argv[1]))["pins"]}
pin = pins[sys.argv[2]]
print(pin["state"].get("version") or pin["state"]["revision"], pin["location"])' "$PROJECT_DIR/Package.resolved" "$1"
}
notice_checkouts="$PROJECT_DIR/.build/distribution/${ARCHITECTURES[1]}/checkouts"
{
    print -r -- "Third-party software in Focus Studio"
    print -r -- ""
    print -r -- "Focus Studio's MCP helper (Contents/MacOS/focus-studio-mcp) includes the following open-source packages, at the versions pinned in Package.resolved. Their licence and notice texts follow."
    for notice_package in "${NOTICE_PACKAGES[@]}"; do
        notice_pin="$(pinned_package "$notice_package")"
        print -r -- ""
        print -r -- "==== $notice_package ${notice_pin%% *} (${notice_pin#* }) ===="
        for notice_file in ${(z)NOTICE_FILES[$notice_package]}; do
            [[ -s "$notice_checkouts/$notice_package/$notice_file" ]] || { echo "Missing licence text: $notice_package/$notice_file" >&2; exit 1; }
            print -r -- ""
            print -r -- "---- $notice_file ----"
            print -r -- ""
            cat "$notice_checkouts/$notice_package/$notice_file"
        done
    done
} > "$CONTENTS_DIR/Resources/ThirdPartyNotices.txt"

for required_resource in catalog.json README.md "${BUNDLED_AUDIO_ASSETS[@]}"; do
    if [[ ! -f "$CONTENTS_DIR/Resources/Audio/$required_resource" ]]; then
        echo "Missing bundled audio resource: $required_resource" >&2
        exit 1
    fi
done

FOCUS_SIGNING_IDENTITY="${FOCUS_STUDIO_SIGNING_IDENTITY:-}"
if [[ -z "$FOCUS_SIGNING_IDENTITY" ]]; then
    FOCUS_SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Developer ID Application/ { print $2; exit }'
    )"
fi
if [[ -z "$FOCUS_SIGNING_IDENTITY" ]]; then
    FOCUS_SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi

# The helper is nested code: it is signed first, under its own identifier and
# without entitlements, and the app's signature then seals it.
if [[ -n "$FOCUS_SIGNING_IDENTITY" && "$FOCUS_SIGNING_IDENTITY" != "-" ]]; then
    HELPER_SIGN_OPTIONS=(--force --options runtime --identifier "$HELPER_IDENTIFIER" --sign "$FOCUS_SIGNING_IDENTITY")
    SIGN_OPTIONS=(--force --options runtime --entitlements "$PROJECT_DIR/Resources/FocusStudio.entitlements" --sign "$FOCUS_SIGNING_IDENTITY")
    if [[ "$FOCUS_SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
        HELPER_SIGN_OPTIONS+=(--timestamp)
        SIGN_OPTIONS+=(--timestamp)
    fi
    codesign "${HELPER_SIGN_OPTIONS[@]}" "$HELPER"
    codesign "${SIGN_OPTIONS[@]}" "$STAGED_APP"
    echo "Signed with stable identity: $FOCUS_SIGNING_IDENTITY"
else
    # Keep the fallback identifiers deterministic, but ad-hoc signatures are not
    # a durable TCC identity across rebuilt binaries. For persistent Screen
    # Recording grants, set FOCUS_STUDIO_SIGNING_IDENTITY to an Apple
    # Development or Developer ID certificate.
    codesign \
        --force \
        --sign - \
        --identifier "$HELPER_IDENTIFIER" \
        --requirements "=designated => identifier \"$HELPER_IDENTIFIER\"" \
        "$HELPER"
    codesign \
        --force \
        --sign - \
        --requirements '=designated => identifier "com.local.focusstudio"' \
        "$STAGED_APP"
    echo "Signed ad hoc for local development; macOS may require permission again after rebuilding."
fi

"$SCRIPT_DIR/verify-release.sh" "$STAGED_APP"
if app_is_running; then
    echo "The output app was opened during the build. It was not replaced." >&2
    exit 1
fi
if [[ -e "$APP_DIR" ]]; then
    mv "$APP_DIR" "$BUILD_STAGE/previous.app"
fi
mv "$STAGED_APP" "$APP_DIR"
echo "$APP_DIR"
if [[ "$INSTALL_AFTER_BUILD" == true ]]; then
    zsh "$SCRIPT_DIR/install-app.sh" "$APP_DIR" --yes
else
    echo "To explicitly install or update the canonical app, run: zsh scripts/install-app.sh '$APP_DIR' --yes"
fi
