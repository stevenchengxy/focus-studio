#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_ICON="$PROJECT_DIR/Resources/Brand/FocusStudioIcon.png"
[[ -s "$SOURCE_ICON" ]] || { echo "Missing Focus Studio icon master" >&2; exit 1; }
mkdir -p "$PROJECT_DIR/.artifacts"
ICON_STAGE="$(mktemp -d "$PROJECT_DIR/.artifacts/icon-build.XXXXXX")"
ICONSET="$ICON_STAGE/FocusStudio.iconset"
mkdir -p "$ICONSET"
# Resampling is only packaging: the generated master is preserved untouched.
for point_size in 16 32 128 256 512; do
    sips -z "$point_size" "$point_size" "$SOURCE_ICON" --out "$ICONSET/icon_${point_size}x${point_size}.png" >/dev/null
    pixel_size=$((point_size * 2))
    sips -z "$pixel_size" "$pixel_size" "$SOURCE_ICON" --out "$ICONSET/icon_${point_size}x${point_size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PROJECT_DIR/Resources/FocusStudio.icns"
echo "Built Resources/FocusStudio.icns from the preserved generated master."
