#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
REQUESTED_APP_DIR="${FOCUS_STUDIO_APP_DIR:-$PROJECT_DIR/dist/Focus Studio.app}"
[[ "$REQUESTED_APP_DIR" == /* ]] || { echo "FOCUS_STUDIO_APP_DIR must be an absolute path." >&2; exit 1; }
REQUESTED_APP_DIR="${REQUESTED_APP_DIR:a}"
APP_DIR="${REQUESTED_APP_DIR:A}"
[[ "$APP_DIR" == "$REQUESTED_APP_DIR" && "$APP_DIR" == "$PROJECT_DIR/dist/"* && "${APP_DIR:t}" == 'Focus Studio.app' ]] || {
    echo "App input must be a non-symlink Focus Studio.app path inside this project's dist directory." >&2
    exit 1
}
NOTARY_PROFILE="${FOCUS_STUDIO_NOTARY_PROFILE:-}"

case "${1:-}" in
    --skip-build) ;;
    "") FOCUS_STUDIO_ARCHS=universal "$SCRIPT_DIR/build-app.sh" ;;
    *) echo "Usage: package-release.sh [--skip-build]" >&2; exit 1 ;;
esac
"$SCRIPT_DIR/verify-release.sh" "$APP_DIR" --require-universal

for version_key in CFBundleShortVersionString CFBundleVersion; do
    bundle_value="$(/usr/libexec/PlistBuddy -c "Print :$version_key" "$APP_DIR/Contents/Info.plist")"
    source_value="$(/usr/libexec/PlistBuddy -c "Print :$version_key" "$PROJECT_DIR/Resources/Info.plist")"
    [[ "$bundle_value" == "$source_value" ]] || {
        echo "Refusing to package a stale app ($version_key: $bundle_value; source: $source_value). Build the current release first." >&2
        exit 1
    }
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
RELEASE_KIND="local"
if [[ "$SIGNATURE_DETAILS" == *"Authority=Developer ID Application:"* ]]; then
    RELEASE_KIND="developer-id"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    [[ "$RELEASE_KIND" == "developer-id" ]] || { echo "Notarization requires a Developer ID Application signature." >&2; exit 1; }
    [[ "$SIGNATURE_DETAILS" == *"runtime"* ]] || { echo "Notarization requires the hardened runtime." >&2; exit 1; }
    # Notarization checks nested code too: the MCP helper needs the same
    # Developer ID signature and the hardened runtime.
    HELPER_SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_DIR/Contents/MacOS/focus-studio-mcp" 2>&1)"
    [[ "$HELPER_SIGNATURE_DETAILS" == *"Authority=Developer ID Application:"* ]] || { echo "Notarization requires the MCP helper to be signed with Developer ID Application." >&2; exit 1; }
    [[ "$HELPER_SIGNATURE_DETAILS" == *"runtime"* ]] || { echo "Notarization requires the hardened runtime on the MCP helper." >&2; exit 1; }
    RELEASE_KIND="notarized"
fi

mkdir -p "$PROJECT_DIR/dist/releases"
PACKAGE_STAGE="$(mktemp -d "$PROJECT_DIR/dist/.focusstudio-package.XXXXXX")"
cleanup() {
    if [[ "$PACKAGE_STAGE" == "$PROJECT_DIR/dist/.focusstudio-package."* && -d "$PACKAGE_STAGE" ]]; then
        rm -rf -- "$PACKAGE_STAGE"
    fi
}
trap cleanup EXIT
PACKAGE_NAME="Focus-Studio-$VERSION-universal-$RELEASE_KIND"
PAYLOAD="$PACKAGE_STAGE/Focus Studio"
mkdir -p "$PAYLOAD"
ditto "$APP_DIR" "$PAYLOAD/Focus Studio.app"
cp "$PROJECT_DIR/docs/INSTALL.md" "$PAYLOAD/INSTALL.md"
cp "$APP_DIR/Contents/Resources/ThirdPartyNotices.txt" "$PAYLOAD/ThirdPartyNotices.txt"
ln -s /Applications "$PAYLOAD/Applications"

if [[ -n "$NOTARY_PROFILE" ]]; then
    # Credentials stay in Keychain; they are never copied into an archive.
    ditto -c -k --keepParent "$PAYLOAD/Focus Studio.app" "$PACKAGE_STAGE/notary-app.zip"
    xcrun notarytool submit "$PACKAGE_STAGE/notary-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PAYLOAD/Focus Studio.app"
    xcrun stapler validate "$PAYLOAD/Focus Studio.app"
fi

STATUS_FILE="$PAYLOAD/Release-Status.plist"
plutil -create xml1 "$STATUS_FILE"
plutil -insert Version -string "$VERSION" "$STATUS_FILE"
plutil -insert Architectures -string 'arm64 x86_64' "$STATUS_FILE"
plutil -insert MinimumMacOS -string '15.0' "$STATUS_FILE"
plutil -insert Signing -string "$RELEASE_KIND" "$STATUS_FILE"
plutil -insert Notarized -bool "$([[ "$RELEASE_KIND" == notarized ]] && echo true || echo false)" "$STATUS_FILE"
plutil -insert IncludesUserData -bool false "$STATUS_FILE"

DMG="$PACKAGE_STAGE/$PACKAGE_NAME.dmg"
ZIP="$PACKAGE_STAGE/$PACKAGE_NAME.zip"
hdiutil create -volname "Focus Studio $VERSION" -srcfolder "$PAYLOAD" -format UDZO -fs HFS+ "$DMG"
if [[ "$RELEASE_KIND" != "local" ]]; then
    signature_authority="$(echo "$SIGNATURE_DETAILS" | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -1)"
    codesign --timestamp --sign "$signature_authority" "$DMG"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
ditto -c -k --sequesterRsrc --keepParent "$PAYLOAD" "$ZIP"
hdiutil verify "$DMG"

# Validate the archived copy, not only the original app on the developer's Mac.
mkdir -p "$PACKAGE_STAGE/unpacked"
ditto -x -k "$ZIP" "$PACKAGE_STAGE/unpacked"
"$SCRIPT_DIR/verify-release.sh" "$PACKAGE_STAGE/unpacked/Focus Studio/Focus Studio.app" --require-universal

for artifact in "$DMG" "$ZIP"; do
    destination="$PROJECT_DIR/dist/releases/${artifact:t}"
    if [[ -e "$destination" ]]; then
        mv "$destination" "$PACKAGE_STAGE/previous-${artifact:t}"
    fi
    mv "$artifact" "$destination"
done
(
    cd "$PROJECT_DIR/dist/releases"
    shasum -a 256 "$PACKAGE_NAME.dmg" "$PACKAGE_NAME.zip" > "$PACKAGE_NAME.sha256"
)
echo "Release created: $PROJECT_DIR/dist/releases/$PACKAGE_NAME.dmg"
echo "Release created: $PROJECT_DIR/dist/releases/$PACKAGE_NAME.zip"
if [[ "$RELEASE_KIND" == "local" ]]; then
    echo "This local release is not Apple-notarized. See INSTALL.md for first-launch instructions."
fi
