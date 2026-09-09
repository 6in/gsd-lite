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
#   GSD_LITE_TURN_TIMEOUT      1 ターンの制限秒数（デフォルト 3600。超過はハング扱いで
#                              kill し、進捗なし→リトライ経路に乗せる）
#
# 状態管理の原則: 信頼するのは「コミット済みの state」だけ。進捗判定は rc に依らず
# HEAD の state で行い、各ターンの後に作業ツリーの state を HEAD へ正規化する
# （「state は書いたがコミットしなかった」ターンを成功扱いしない）。ループ自身が
# 書く auto-BLOCKED もコミットする。リトライ回数は実行時情報なので追跡対象外
# （logs/.retry）に置く。人間が再開のために state を編集した場合も、必ずコミット
# してから起動すること（未コミットの編集はターン失敗時に巻き戻る）。
#
# 終了コード: 0=DONE / 2=BLOCKED / 3=max_turns / 4=discuss未完了 / 5=state異常 / 6=前提エラー

set -u

GSD_DIR=".gsd-lite"
STATE="$GSD_DIR/state.json"
PIDFILE="$GSD_DIR/loop.pid"        # 情報表示用（排他は flock が担う）
LOCKFILE="$GSD_DIR/logs/.lock"     # logs/ は gitignore 済み
RETRYFILE="$GSD_DIR/logs/.retry"
CLAUDE_BIN="${GSD_LITE_CLAUDE_BIN:-claude}"
PERMISSION_MODE="${GSD_LITE_PERMISSION_MODE:-acceptEdits}"

die() { echo "gsd-lite-loop: $*" >&2; exit 6; }

sget() { jq -r "$1" "$STATE"; }

supdate() { # supdate '<jq filter>' — state.json をインプレース更新
  local tmp
  tmp=$(mktemp) || die "mktemp failed"
  jq "$1" "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

get_retry() { cat "$RETRYFILE" 2>/dev/null || echo 0; }
set_retry() { echo "$1" > "$RETRYFILE"; }

run_hook() { # run_hook <name> <args...> — フックの失敗は無視。ロック FD は継承させない
  local hook="$GSD_DIR/hooks/$1"; shift
  [ -x "$hook" ] && "$hook" "$@" 9>&- || true
}

committed_state() { # コミット済み (HEAD) の state から値を読む
  git show "HEAD:$STATE" 2>/dev/null | jq -r "$1"
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
  jq -r '"milestone : \(.milestone)\nphase     : \(.phase)\nturn      : \(.turn)/\(.max_turns)\nnext      : \(.next_command)\nverify    : round \(.verify_round)/\(.verify_round_max)\nbranch    : \(.branch.name) (base: \(.branch.base))\nupdated   : \(.updated_at)"' "$STATE"
  echo "retry     : $(get_retry)/$(sget '.retry_max')"
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
command -v timeout >/dev/null || die "timeout (coreutils) is required"
command -v flock >/dev/null || die "flock (util-linux) is required"
command -v "$CLAUDE_BIN" >/dev/null || die "claude binary not found: $CLAUDE_BIN"
[ -f "$STATE" ] || die "no $STATE here (run /gsd-lite-init first, from the project root)"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
git show "HEAD:$STATE" >/dev/null 2>&1 || die "$STATE is not committed (commit it first — the loop trusts committed state only)"
if ! git diff --quiet -- "$STATE" 2>/dev/null; then
  echo "gsd-lite: WARN state.json has uncommitted changes — 再開のための編集はコミットしてから起動してください（ターン失敗時に巻き戻ります）" >&2
fi

mkdir -p "$GSD_DIR/logs"

# 二重起動ガード: flock はプロセス終了で自動解放されるため stale 問題も競合窓もない
exec 9>"$LOCKFILE"
flock -n 9 || die "loop already running (lock: $LOCKFILE)"
echo $$ > "$PIDFILE"
trap 'finish 130' INT TERM

while true; do
  cmd=$(sget '.next_command')
  case "$cmd" in
    /*) ;;
    DONE)    echo "gsd-lite: milestone complete"; finish 0 ;;
    BLOCKED) echo "gsd-lite: human input needed — see $GSD_DIR/BLOCKED.md"; finish 2 ;;
    DISCUSS) echo "gsd-lite: run /gsd-lite-discuss in an interactive session first"; finish 4 ;;
    *)       echo "gsd-lite: unknown next_command: $cmd" >&2; finish 5 ;;
  esac

  # 実行前に上限を判定する（DONE / BLOCKED の番兵は上で判定済みなので終端状態が優先される。
  # 上限到達済み state からの再起動で 1 ターン余計に実行しない）
  turn_before=$(sget '.turn')
  max_turns=$(sget '.max_turns')
  if [ "$turn_before" -ge "$max_turns" ]; then
    echo "gsd-lite: max_turns ($max_turns) reached" >&2
    finish 3
  fi

  phase=$(sget '.phase')
  retry=$(get_retry)
  model=$(sget ".model.\"$phase\" // empty")
  milestone=$(sget '.milestone // empty')
  logdir="$GSD_DIR/logs/${milestone:-default}"   # マイルストーン別に分けて上書きを防ぐ
  mkdir -p "$logdir"
  log="$logdir/turn-$(printf '%03d' $((turn_before + 1)))-attempt$((retry + 1)).log"

  echo "gsd-lite: turn $((turn_before + 1)) [$phase] $cmd (attempt $((retry + 1)))"
  # 親が Claude Code セッションでもネスト起動できるよう、セッション由来の環境変数を除去。
  # timeout でハングを検知し（超過は kill）、進捗なし→リトライ経路に乗せる
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    timeout -k 30 "${GSD_LITE_TURN_TIMEOUT:-3600}" \
    "$CLAUDE_BIN" -p "$cmd" \
    ${model:+--model "$model"} \
    --permission-mode "$PERMISSION_MODE" \
    > "$log" 2>&1 9>&-
  rc=$?

  # 進捗判定は rc に依らず「コミット済み (HEAD) の state」で行う。
  # 正常終了でも commit まで到達していなければ成功と認めない
  turn_after=$(committed_state '.turn')
  [ -n "$turn_after" ] || die "cannot read committed state (HEAD:$STATE)"
  # ターン境界の正規化: 作業ツリーの state を HEAD に揃える（未コミットの書きかけを残さない）
  git checkout HEAD -- "$STATE" || die "failed to restore $STATE from HEAD"

  if [ "$turn_after" -le "$turn_before" ]; then
    retry=$((retry + 1))
    retry_max=$(sget '.retry_max')
    echo "gsd-lite: no committed progress (rc=$rc, attempt $retry/$((retry_max + 1))) — see $log" >&2
    if [ "$retry" -gt "$retry_max" ]; then
      echo "gsd-lite: turn made no progress after $retry attempts — auto-BLOCKED" >&2
      supdate '.next_command = "BLOCKED" | .phase = "blocked"'
      {
        echo "# BLOCKED (auto)"
        echo ""
        echo "ループが自動生成した BLOCKED です。ターンが state.json を（コミットまで含めて）"
        echo "更新せずに $retry 回連続で終了しました。最後のログ: $log"
      } > "$GSD_DIR/BLOCKED.md"
      git add "$STATE" "$GSD_DIR/BLOCKED.md" 2>/dev/null && \
        git commit -qm "gsd-lite(loop): auto-BLOCKED (no progress after $retry attempts)" || true
      finish 2
    fi
    set_retry "$retry"
    sleep 2
    continue
  fi
  set_retry 0
  if [ "$rc" -ne 0 ]; then
    echo "gsd-lite: WARN turn advanced in committed state but rc=$rc — push 等の後処理が失敗した可能性。$log を確認" >&2
  fi

  # フェーズ遷移フック
  phase_after=$(sget '.phase')
  if [ "$phase_after" != "$phase" ]; then
    echo "gsd-lite: phase $phase -> $phase_after"
    run_hook on-phase.sh "$phase" "$phase_after"
  fi

  sleep 1
done
