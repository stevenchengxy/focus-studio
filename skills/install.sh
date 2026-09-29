#!/usr/bin/env bash
# Install discoverable skills for Codex (default), Claude Code, or both.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="link"
CLIENT="codex"
NAMES=()
AVAILABLE="_shared ark-video-clip ark-still-image demo-storyboard product-demo-composer focus-studio-mcp focus-demo-editing"
usage() {
  cat <<'USAGE'
Usage: bash skills/install.sh [--codex|--claude|--all] [--copy] [--skill NAME ...]

Defaults to symlinks in ${CODEX_HOME:-$HOME/.codex}/skills.
--claude installs in ${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}.
--all installs in both locations; --skill selects named skills and their required dependencies.
Existing unrelated files are moved outside the skills directory to skill-backups, never deleted.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex) CLIENT="codex"; shift ;;
    --claude) CLIENT="claude"; shift ;;
    --all) CLIENT="all"; shift ;;
    --copy) MODE="copy"; shift ;;
    --skill)
      [[ $# -ge 2 ]] || { echo "--skill needs a name" >&2; exit 1; }
      case " $AVAILABLE " in
        *" $2 "*) NAMES+=("$2") ;;
        *) echo "Unknown skill: $2" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done
if [[ ${#NAMES[@]} -eq 0 ]]; then
  NAMES=(_shared ark-video-clip ark-still-image demo-storyboard product-demo-composer focus-studio-mcp focus-demo-editing)
else
  for name in "${NAMES[@]}"; do
    case "$name" in
      ark-video-clip|ark-still-image) NAMES+=("_shared") ;;
      demo-storyboard|product-demo-composer) NAMES+=("demo-storyboard" "product-demo-composer" "_shared") ;;
      focus-demo-editing) NAMES+=("focus-studio-mcp") ;;
    esac
  done
fi
DESTINATIONS=()
if [[ "$CLIENT" == "codex" || "$CLIENT" == "all" ]]; then
  DESTINATIONS+=("${CODEX_HOME:-$HOME/.codex}/skills")
fi
if [[ "$CLIENT" == "claude" || "$CLIENT" == "all" ]]; then
  DESTINATIONS+=("${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}")
fi
for dest in "${DESTINATIONS[@]}"; do
  mkdir -p "$dest"
  installed=" "
  for name in "${NAMES[@]}"; do
    case "$installed" in *" $name "*) continue ;; esac
    installed="$installed$name "
    src="$HERE/$name"
    dst="$dest/$name"
    [[ -d "$src" ]] || { echo "Missing skill directory: $src" >&2; exit 1; }
    if [[ ! -L "$dst" && -d "$dst" && "$src" -ef "$dst" ]]; then
      echo "Refusing to replace the source skill directory: $dst" >&2
      exit 1
    fi
    if [[ "$MODE" == "link" && -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
      echo "already linked: $dst"
      continue
    fi
    if [[ -e "$dst" || -L "$dst" ]]; then
      backup_root="$(dirname "$dest")/skill-backups"
      mkdir -p "$backup_root"
      backup="$backup_root/$name-$(date +%Y%m%d-%H%M%S)"
      suffix=1
      while [[ -e "$backup" || -L "$backup" ]]; do
        backup="$backup_root/$name-$(date +%Y%m%d-%H%M%S)-$suffix"
        suffix=$((suffix + 1))
      done
      mv "$dst" "$backup"
      echo "preserved: $backup"
    fi
    if [[ "$MODE" == "copy" ]]; then cp -R "$src" "$dst"; else ln -s "$src" "$dst"; fi
    echo "$MODE: $dst"
  done
done
echo 'Done. Reopen the client session to refresh skill discovery.'
echo 'Focus Studio skills use the focus-studio MCP connection in Settings > AI tools.'
echo 'Ark asset generation is optional; recording and native demo editing need no Ark key.'
