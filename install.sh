#!/usr/bin/env bash
# gsd-lite installer — 冪等。何度実行してもよい。
#  - bin/gsd-lite-loop.sh  → ~/.local/bin/
#  - skills/gsd-lite-init  → ~/.claude/skills/（Codex: ~/.agents/skills/、OpenCode: ~/.config/opencode/skills/）
#  - templates/            → ~/.claude/gsd-lite/templates/（Codex: ~/.codex/gsd-lite/、OpenCode: ~/.config/opencode/gsd-lite/）
#  - opencode/commands/    → ~/.config/opencode/commands/（OpenCode の /gsd-lite-init, /gsd-lite-discuss, /gsd-lite-reflect）
set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd)

ENGINE=claude
case "$#:$*" in
  0:) ;;
  '2:--engine claude') ENGINE=claude ;;
  '2:--engine codex') ENGINE=codex ;;
  '2:--engine opencode') ENGINE=opencode ;;
  '2:--engine all') ENGINE=all ;;
  '1:--help') echo "Usage: $0 [--engine claude|codex|opencode|all]"; exit 0 ;;
  *) echo "Usage: $0 [--engine claude|codex|opencode|all]" >&2; exit 1 ;;
esac
# テスト・任意配置用。HOME / CODEX_HOME 自体は変更しない。
INSTALL_ROOT="${GSD_LITE_INSTALL_ROOT:-$HOME}"
if [ "$ENGINE" != claude ]; then
  command -v jq >/dev/null || { echo "jq is required for Codex / OpenCode installation" >&2; exit 1; }
fi
install -d "$INSTALL_ROOT/.local/bin"
install -m 0755 "$REPO_DIR/bin/gsd-lite-loop.sh" "$INSTALL_ROOT/.local/bin/gsd-lite-loop.sh"

install_engine() {
  local engine=$1 skill_dir data_dir
  case "$engine" in
    codex)
      skill_dir="$INSTALL_ROOT/.agents/skills"
      data_dir="$INSTALL_ROOT/.codex/gsd-lite" ;;
    opencode)
      skill_dir="$INSTALL_ROOT/.config/opencode/skills"
      data_dir="$INSTALL_ROOT/.config/opencode/gsd-lite" ;;
    *)
      skill_dir="$INSTALL_ROOT/.claude/skills"
      data_dir="$INSTALL_ROOT/.claude/gsd-lite" ;;
  esac
  install -d "$skill_dir" "$data_dir"
  rm -rf "$skill_dir/gsd-lite-init"
  cp -r "$REPO_DIR/skills/gsd-lite-init" "$skill_dir/"
  rm -rf "$data_dir/templates"
  cp -r "$REPO_DIR/templates" "$data_dir/templates"
  if [ "$engine" != claude ]; then
    jq --arg engine "$engine" '.engine = $engine' "$REPO_DIR/templates/state.json" > "$data_dir/templates/state.json"
    rm "$data_dir/templates/settings.allowlist.json"
  fi
  echo "  $engine skill     : $skill_dir/gsd-lite-init"
  echo "  $engine templates : $data_dir/templates"
  if [ "$engine" = opencode ]; then
    # OpenCode はスキルを / コマンドで呼べないので、スキルを読み込む薄いコマンドを置く
    install -d "$INSTALL_ROOT/.config/opencode/commands"
    cp "$REPO_DIR"/opencode/commands/gsd-lite-*.md "$INSTALL_ROOT/.config/opencode/commands/"
    echo "  $engine commands  : $INSTALL_ROOT/.config/opencode/commands/gsd-lite-{init,discuss,reflect}.md"
  fi
}

echo "gsd-lite installed:"
echo "  loop : $INSTALL_ROOT/.local/bin/gsd-lite-loop.sh"
case "$ENGINE" in
  all) install_engine claude; install_engine codex; install_engine opencode ;;
  *) install_engine "$ENGINE" ;;
esac
command -v jq >/dev/null || echo "WARN: jq not found — loop requires jq"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "WARN: ~/.local/bin is not on PATH" ;;
esac
