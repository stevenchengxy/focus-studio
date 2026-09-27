#!/usr/bin/env bash
# Install the Focus Studio skills into ~/.claude/skills (symlink by default, --copy to copy).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
MODE="link"
[[ "${1:-}" == "--copy" ]] && MODE="copy"
mkdir -p "$DEST"
for name in _shared ark-video-clip ark-still-image demo-storyboard product-demo-composer focus-studio-mcp; do
  src="$HERE/$name"; dst="$DEST/$name"
  [[ -d "$src" ]] || { echo "missing $src" >&2; exit 1; }
  if [[ -e "$dst" || -L "$dst" ]]; then rm -rf "$dst"; fi
  if [[ "$MODE" == "copy" ]]; then cp -R "$src" "$dst"; else ln -s "$src" "$dst"; fi
  echo "$MODE: $dst"
done
echo "done. Skills: ark-video-clip, ark-still-image, demo-storyboard, product-demo-composer (shared client in _shared), focus-studio-mcp."
echo "focus-studio-mcp needs Focus Studio 1.12+ connected to Claude Code: Focus Studio > Settings > AI tools > Connect."
echo "Key file: ~/.config/focus-studio/ark.env (ARK_API_KEY=..., ARK_BASE_URL=...), chmod 600. Never commit it."
