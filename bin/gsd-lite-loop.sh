#!/usr/bin/env bash
# gsd-lite-loop.sh — gsd-lite のダムループ。
# state.json の next_command を実行し続けるだけで、フェーズ遷移の判断は一切持たない。
# 仕様: docs/SPEC.md §7
#
# 使い方:
#   gsd-lite-loop.sh            # ループ実行（対象プロジェクトの直下で）
#   gsd-lite-loop.sh --status   # 進捗の整形表示（トークンゼロの覗き窓）
#
# 環境変数:
#   GSD_LITE_CLAUDE_BIN        claude バイナリの上書き（テスト用スタブ差し込み）
#   GSD_LITE_PERMISSION_MODE   claude -p の --permission-mode（デフォルト acceptEdits）
#
# 終了コード: 0=DONE / 2=BLOCKED / 3=max_turns / 4=discuss未完了 / 5=state異常 / 6=前提エラー

set -u

GSD_DIR=".gsd-lite"
STATE="$GSD_DIR/state.json"
PIDFILE="$GSD_DIR/loop.pid"
CLAUDE_BIN="${GSD_LITE_CLAUDE_BIN:-claude}"
PERMISSION_MODE="${GSD_LITE_PERMISSION_MODE:-acceptEdits}"

die() { echo "gsd-lite-loop: $*" >&2; exit 6; }

sget() { jq -r "$1" "$STATE"; }

supdate() { # supdate '<jq filter>' — state.json をインプレース更新
  local tmp
  tmp=$(mktemp) || die "mktemp failed"
  jq "$1" "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

run_hook() { # run_hook <name> <args...> — フックの失敗は無視
  local hook="$GSD_DIR/hooks/$1"; shift
  [ -x "$hook" ] && "$hook" "$@" || true
}

finish() { # finish <exit_code> — on-exit フックを呼んで終了
  local code=$1 phase
  phase=$(sget '.phase' 2>/dev/null || echo unknown)
  rm -f "$PIDFILE"
  run_hook on-exit.sh "$code" "$phase"
  exit "$code"
}

status() {
  [ -f "$STATE" ] || die "no $STATE here (run /gsd-lite-init first)"
  echo "== gsd-lite status =="
  jq -r '"milestone : \(.milestone)\nphase     : \(.phase)\nturn      : \(.turn)/\(.max_turns)\nnext      : \(.next_command)\nretry     : \(.retry)/\(.retry_max)\nverify    : round \(.verify_round)/\(.verify_round_max)\nbranch    : \(.branch.name) (base: \(.branch.base))\nupdated   : \(.updated_at)"' "$STATE"
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "loop      : RUNNING (pid $(cat "$PIDFILE"))"
  else
    echo "loop      : not running"
  fi
  if [ -f "$GSD_DIR/PLAN.md" ]; then
    echo "-- current task --"
    grep -m1 '^- \[ \]' "$GSD_DIR/PLAN.md" || echo "(no unchecked task)"
  fi
  if [ -f "$GSD_DIR/PROGRESS.md" ]; then
    echo "-- recent progress --"
    tail -n 6 "$GSD_DIR/PROGRESS.md"
  fi
  if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "-- recent commits --"
    git log --oneline -5 2>/dev/null || true
  fi
}

# ---- entry ----

case "${1:-}" in
  --status) status; exit 0 ;;
  "") ;;
  *) die "unknown option: $1 (supported: --status)" ;;
esac

command -v jq >/dev/null || die "jq is required"
command -v "$CLAUDE_BIN" >/dev/null || die "claude binary not found: $CLAUDE_BIN"
[ -f "$STATE" ] || die "no $STATE here (run /gsd-lite-init first, from the project root)"

# 二重起動ガード
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  die "loop already running (pid $(cat "$PIDFILE"))"
fi
echo $$ > "$PIDFILE"
trap 'finish 130' INT TERM

mkdir -p "$GSD_DIR/logs"

while true; do
  cmd=$(sget '.next_command')
  case "$cmd" in
    /*) ;;
    DONE)    echo "gsd-lite: milestone complete"; finish 0 ;;
    BLOCKED) echo "gsd-lite: human input needed — see $GSD_DIR/BLOCKED.md"; finish 2 ;;
    DISCUSS) echo "gsd-lite: run /gsd-lite-discuss in an interactive session first"; finish 4 ;;
    *)       echo "gsd-lite: unknown next_command: $cmd" >&2; finish 5 ;;
  esac

  turn_before=$(sget '.turn')
  phase=$(sget '.phase')
  retry=$(sget '.retry')
  model=$(sget ".model.\"$phase\" // empty")
  log="$GSD_DIR/logs/turn-$(printf '%03d' $((turn_before + 1)))-attempt$((retry + 1)).log"

  echo "gsd-lite: turn $((turn_before + 1)) [$phase] $cmd (attempt $((retry + 1)))"
  # 親が Claude Code セッションでもネスト起動できるよう、セッション由来の環境変数を除去
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    "$CLAUDE_BIN" -p "$cmd" \
    ${model:+--model "$model"} \
    --permission-mode "$PERMISSION_MODE" \
    > "$log" 2>&1

  turn_after=$(sget '.turn')

  # ターンの生存確認: turn が進んでいなければ Claude が state を更新せずに死んだ
  if [ "$turn_after" -le "$turn_before" ]; then
    retry=$((retry + 1))
    retry_max=$(sget '.retry_max')
    if [ "$retry" -gt "$retry_max" ]; then
      echo "gsd-lite: turn made no progress after $retry attempts — auto-BLOCKED" >&2
      supdate '.next_command = "BLOCKED" | .phase = "blocked"'
      {
        echo "# BLOCKED (auto)"
        echo ""
        echo "ループが自動生成した BLOCKED です。ターンが state.json を更新せずに"
        echo "$retry 回連続で終了しました。最後のログ: $log"
      } > "$GSD_DIR/BLOCKED.md"
      finish 2
    fi
    supdate ".retry = $retry"
    sleep 2
    continue
  fi
  supdate '.retry = 0'

  # フェーズ遷移フック
  phase_after=$(sget '.phase')
  if [ "$phase_after" != "$phase" ]; then
    echo "gsd-lite: phase $phase -> $phase_after"
    run_hook on-phase.sh "$phase" "$phase_after"
  fi

  max_turns=$(sget '.max_turns')
  if [ "$turn_after" -ge "$max_turns" ]; then
    echo "gsd-lite: max_turns ($max_turns) reached" >&2
    finish 3
  fi

  sleep 1
done
