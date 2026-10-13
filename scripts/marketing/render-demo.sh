#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$ROOT/.artifacts/studio-launch"
mkdir -p "$OUT" "$ROOT/website/public/media"
cd "$ROOT"
ffmpeg -hide_banner -loglevel error -loop 1 -i scripts/marketing/assets/aster-source.jpg -t 16 -r 30 -c:v libx264 -pix_fmt yuv420p -y "$OUT/aster-source.mp4"
swift run FocusStudioE2E --marketing-demo "$ROOT/scripts/marketing/assets/aster-source.jpg" --output-dir "$OUT"
ffmpeg -hide_banner -loglevel error -i "$OUT/focus-studio-demo-native.mp4" -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p -movflags +faststart -an -y website/public/media/focus-studio-demo.mp4
ffmpeg -hide_banner -loglevel error -ss 2.4 -i website/public/media/focus-studio-demo.mp4 -frames:v 1 -y website/public/media/focus-studio-demo.jpg
