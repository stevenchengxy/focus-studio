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
AUDIO_GENERATOR="$PROJECT_DIR/scripts/generate-audio-assets.swift"
BUILD_ARCHITECTURES="${FOCUS_STUDIO_ARCHS:-universal}"

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
        shasum -a 256 "$PROJECT_DIR/Package.swift" "$PROJECT_DIR/Resources/Info.plist" "$PROJECT_DIR/Resources/FocusStudio.entitlements"
        find "$PROJECT_DIR/Sources/FocusStudio" "$PROJECT_DIR/Sources/FocusStudioCore" -type f -name '*.swift' -print | LC_ALL=C sort | while IFS= read -r source_file; do
            shasum -a 256 "$source_file"
        done
        find "$PROJECT_DIR/Resources" -type f -print | LC_ALL=C sort | while IFS= read -r resource_file; do
            shasum -a 256 "$resource_file"
        done
    } | shasum -a 256 | awk '{ print $1 }'
}
SOURCE_DIGEST_BEFORE="$(source_digest)"
SLICE_PATHS=()
for architecture in "${ARCHITECTURES[@]}"; do
    triple="$architecture-apple-macosx$MINIMUM_MACOS"
    scratch_path="$PROJECT_DIR/.build/distribution/$architecture"
    swift build -c release --product FocusStudio --triple "$triple" --scratch-path "$scratch_path"
    binary_directory="$(swift build -c release --triple "$triple" --scratch-path "$scratch_path" --show-bin-path)"
    SLICE_PATHS+=("$binary_directory/FocusStudio")
done
[[ "$(source_digest)" == "$SOURCE_DIGEST_BEFORE" ]] || {
    echo "Sources changed during release build. Retry after edits are complete so both architectures use the same code." >&2
    exit 1
}
if (( ${#SLICE_PATHS[@]} > 1 )); then
    lipo -create "${SLICE_PATHS[@]}" -output "$CONTENTS_DIR/MacOS/FocusStudio"
else
    cp "${SLICE_PATHS[1]}" "$CONTENTS_DIR/MacOS/FocusStudio"
fi
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/FocusStudio.icns" "$CONTENTS_DIR/Resources/FocusStudio.icns"
cp "$PROJECT_DIR/Resources/Brand/FocusStudioIcon.png" "$CONTENTS_DIR/Resources/FocusStudioIcon.png"
for app_language in en zh-Hans; do
    ditto "$PROJECT_DIR/Resources/$app_language.lproj" "$CONTENTS_DIR/Resources/$app_language.lproj"
done
ditto "$AUDIO_DIR" "$CONTENTS_DIR/Resources/Audio"

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

if [[ -n "$FOCUS_SIGNING_IDENTITY" && "$FOCUS_SIGNING_IDENTITY" != "-" ]]; then
    SIGN_OPTIONS=(--force --options runtime --entitlements "$PROJECT_DIR/Resources/FocusStudio.entitlements" --sign "$FOCUS_SIGNING_IDENTITY")
    if [[ "$FOCUS_SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
        SIGN_OPTIONS+=(--timestamp)
    fi
    codesign "${SIGN_OPTIONS[@]}" "$STAGED_APP"
    echo "Signed with stable identity: $FOCUS_SIGNING_IDENTITY"
else
    # Keep the fallback identifier deterministic, but ad-hoc signatures are not
    # a durable TCC identity across rebuilt binaries. For persistent Screen
    # Recording grants, set FOCUS_STUDIO_SIGNING_IDENTITY to an Apple
    # Development or Developer ID certificate.
    codesign \
        --force \
        --sign - \
        --requirements '=designated => identifier "com.local.focusstudio"' \
        "$STAGED_APP"
    echo "Signed ad hoc for local development; macOS may require permission again after rebuilding."
fi

"$SCRIPT_DIR/verify-release.sh" "$STAGED_APP"
if [[ -e "$APP_DIR" ]]; then
    mv "$APP_DIR" "$BUILD_STAGE/previous.app"
fi
mv "$STAGED_APP" "$APP_DIR"
echo "$APP_DIR"
