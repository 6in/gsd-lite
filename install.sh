#!/usr/bin/env bash
# gsd-lite installer — 冪等。何度実行してもよい。
#  - bin/gsd-lite-loop.sh  → ~/.local/bin/
#  - skills/gsd-lite-init  → ~/.claude/skills/
#  - templates/            → ~/.claude/gsd-lite/templates/
set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd)

install -d ~/.local/bin ~/.claude/skills ~/.claude/gsd-lite

install -m 0755 "$REPO_DIR/bin/gsd-lite-loop.sh" ~/.local/bin/gsd-lite-loop.sh

rm -rf ~/.claude/skills/gsd-lite-init
cp -r "$REPO_DIR/skills/gsd-lite-init" ~/.claude/skills/

rm -rf ~/.claude/gsd-lite/templates
cp -r "$REPO_DIR/templates" ~/.claude/gsd-lite/templates

echo "gsd-lite installed:"
echo "  loop      : ~/.local/bin/gsd-lite-loop.sh"
echo "  skill     : ~/.claude/skills/gsd-lite-init"
echo "  templates : ~/.claude/gsd-lite/templates"
command -v jq >/dev/null || echo "WARN: jq not found — loop requires jq"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "WARN: ~/.local/bin is not on PATH" ;;
esac
