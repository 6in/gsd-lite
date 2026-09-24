#!/usr/bin/env bash
# gsd-lite-loop.sh — gsd-lite のダムループ。
# state.json の next_command を実行し続けるだけで、フェーズ遷移の判断は一切持たない。
# 仕様: docs/SPEC.md §7
#
# 使い方:
#   gsd-lite-loop.sh            # ループ実行（対象プロジェクトの直下で）
#   gsd-lite-loop.sh --check    # 全フェーズの実行前提を検証（起動・変更なし）
#   gsd-lite-loop.sh --status   # 進捗の整形表示（トークンゼロの覗き窓）
#   gsd-lite-loop.sh --stop     # 現在のターン終了後に中断を依頼
#   gsd-lite-loop.sh --watch    # 進捗・タスク・実行中ログを数秒ごとに再描画する簡易 TUI（q で終了）
#   gsd-lite-loop.sh --watch-once # --watch の 1 画面ぶんを出力して終了（非対話・テスト用）
#
# 環境変数:
#   GSD_LITE_ENGINE            claude / codex / opencode（未指定時 state.engine、旧 state は claude）
#   GSD_LITE_CODEX_BIN         codex バイナリの上書き
#   GSD_LITE_CODEX_MODEL       Codex の全フェーズ共通モデル（state.codex.model より優先）
#   GSD_LITE_CODEX_SANDBOX     Codex sandbox（デフォルト workspace-write）
#   GSD_LITE_CODEX_SANDBOX_PROBE auto / skip（デフォルト auto）。Codex を使うフェーズがあり
#                              sandbox が danger-full-access 以外なら、起動前に
#                              `codex sandbox -- true` で sandbox が実際に動くか検証する
#                              （bubblewrap が user namespace を作れない環境の早期検出）
#   GSD_LITE_OPENCODE_BIN      opencode バイナリの上書き
#   GSD_LITE_OPENCODE_MODEL    OpenCode の全フェーズ共通モデル（provider/model 形式。state.opencode.model より優先）
#   GSD_LITE_CLAUDE_BIN        claude バイナリの上書き（テスト用スタブ差し込み）
#   GSD_LITE_PERMISSION_MODE   claude -p の --permission-mode（デフォルト acceptEdits）
#   GSD_LITE_WATCH_INTERVAL    --watch の再描画間隔秒（デフォルト 3）
#   GSD_LITE_WATCH_LOG_LINES   --watch で表示するログ末尾の行数（デフォルト 15。+/- キーで増減）
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
#             7=一時中断（通常起動でフラグを消して再開）

set -u

GSD_DIR=".gsd-lite"
STATE="$GSD_DIR/state.json"
PIDFILE="$GSD_DIR/loop.pid"        # 情報表示用（排他は flock が担う）
LOCKFILE="$GSD_DIR/logs/.lock"     # logs/ は gitignore 済み
RETRYFILE="$GSD_DIR/logs/.retry"
STOPFILE="$GSD_DIR/logs/.stop"    # 実行時情報。gitignore 済み logs/ に置く
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

engine_for() {
  if [ -n "${GSD_LITE_ENGINE:-}" ]; then
    printf '%s\n' "$GSD_LITE_ENGINE"
  else
    jq -r --arg phase "$1" '.phase_engines[$phase] // .engine // "claude"' "$STATE"
  fi
}

select_engine() {
  ENGINE=$(engine_for "$1") || die "cannot read engine for $1"
  case "$ENGINE" in
    claude) AGENT_BIN="$CLAUDE_BIN" ;;
    codex) AGENT_BIN="${GSD_LITE_CODEX_BIN:-codex}" ;;
    opencode) AGENT_BIN="${GSD_LITE_OPENCODE_BIN:-opencode}" ;;
    *) die "unknown engine: $ENGINE (expected claude, codex or opencode)" ;;
  esac
}

skill_dir_for() { # skill_dir_for <engine> — エンジンがプロジェクト内で探すスキル配置先
  case "$1" in
    codex) echo .agents/skills ;;
    opencode) echo .opencode/skills ;;
    *) echo .claude/skills ;;
  esac
}

model_for() { # model_for <engine> <phase> — そのフェーズに渡すモデル（空なら CLI 既定）
  case "$1" in
    codex) printf '%s\n' "${GSD_LITE_CODEX_MODEL:-$(jq -r --arg phase "$2" '.codex.model[$phase] // empty' "$STATE")}" ;;
    opencode) printf '%s\n' "${GSD_LITE_OPENCODE_MODEL:-$(jq -r --arg phase "$2" '.opencode.model[$phase] // empty' "$STATE")}" ;;
    *) jq -r --arg phase "$2" '.model[$phase] // empty' "$STATE" ;;
  esac
}

check_config() {
  local check_phase skill_dir
  jq -e '
    (.engine // "claude" | . == "claude" or . == "codex" or . == "opencode") and
    ((.phase_engines // {}) | type == "object" and
      all(to_entries[];
        (.key == "research" or .key == "plan" or .key == "impl" or .key == "verify") and
        (.value == "claude" or .value == "codex" or .value == "opencode")))
  ' "$STATE" >/dev/null || die "invalid engine / phase_engines configuration"
  CODEX_SANDBOX="${GSD_LITE_CODEX_SANDBOX:-workspace-write}"
  for check_phase in research plan impl verify; do
    select_engine "$check_phase"
    command -v "$AGENT_BIN" >/dev/null || die "$ENGINE binary not found: $AGENT_BIN (phase: $check_phase)"
    skill_dir=$(skill_dir_for "$ENGINE")
    if [ "$ENGINE" = codex ]; then
      case "$CODEX_SANDBOX" in
        read-only|workspace-write|danger-full-access) ;;
        *) die "invalid Codex sandbox: $CODEX_SANDBOX" ;;
      esac
    fi
    [ -f "$skill_dir/gsd-lite-$check_phase/SKILL.md" ] ||
      die "missing $skill_dir/gsd-lite-$check_phase/SKILL.md (update project skills before starting)"
  done
  check_git_identity
  check_codex_sandbox
}

check_git_identity() {
  # ループ自身（auto-BLOCKED）も各ターンのエージェントも state.json をコミットする。
  # 識別が無いと「state は書いたがコミットできない」ターンが続き、無進捗扱いで止まる
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
  git var GIT_COMMITTER_IDENT >/dev/null 2>&1 ||
    die "git identity is not configured — set user.name / user.email (git config user.email you@example.com) before starting; the loop and every turn commit $STATE"
}

check_codex_sandbox() {
  # sandbox の値が妥当でも、bubblewrap が user namespace を作れない環境では
  # Codex のシェル実行も apply_patch も全て失敗する（--check が通ったのに全ターン無進捗になる）。
  # danger-full-access は sandbox を使わないので検証不要
  local probe_phase uses_codex=0 codex_bin
  [ "${GSD_LITE_CODEX_SANDBOX_PROBE:-auto}" = skip ] && return 0
  [ "$CODEX_SANDBOX" = danger-full-access ] && return 0
  for probe_phase in research plan impl verify; do
    [ "$(engine_for "$probe_phase")" = codex ] && uses_codex=1
  done
  [ "$uses_codex" -eq 1 ] || return 0
  codex_bin="${GSD_LITE_CODEX_BIN:-codex}"
  if ! "$codex_bin" sandbox --help </dev/null >/dev/null 2>&1; then
    echo "gsd-lite: WARN $codex_bin has no 'sandbox' subcommand — skipping the sandbox probe（sandbox が動かない環境では最初の Codex ターンが無進捗で止まる）" >&2
    return 0
  fi
  local timeout_cmd=()
  command -v timeout >/dev/null && timeout_cmd=(timeout -k 5 60)
  if ! "${timeout_cmd[@]}" "$codex_bin" sandbox -c "sandbox_mode=\"$CODEX_SANDBOX\"" -- true </dev/null >/dev/null 2>&1; then
    die "Codex sandbox '$CODEX_SANDBOX' cannot run commands on this machine (bubblewrap / unprivileged user namespace が使えない環境の可能性。Ubuntu 24.04 では kernel.apparmor_restrict_unprivileged_userns=1 が典型).
  対処: (a) GSD_LITE_CODEX_SANDBOX=danger-full-access で起動（sandbox なし。無人ターンが FS 全体に書けるので隔離環境向け）
        (b) unprivileged user namespace を許可する（例: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0）
        (c) impl / verify を Claude に切り替える（state の phase_engines）
  この検証を飛ばすには GSD_LITE_CODEX_SANDBOX_PROBE=skip"
  fi
}

status() {
  [ -f "$STATE" ] || die "no $STATE here (run /gsd-lite-init first)"
  echo "== gsd-lite status =="
  echo "engine    : ${GSD_LITE_ENGINE:-$(sget '.engine // "claude"')}"
  jq -r '"milestone : \(.milestone)\nphase     : \(.phase)\nturn      : \(.turn)/\(.max_turns)\nnext      : \(.next_command)\nverify    : round \(.verify_round)/\(.verify_round_max)\nbranch    : \(.branch.name) (base: \(.branch.base))\nupdated   : \(.updated_at)"' "$STATE"
  for display_phase in research plan impl verify; do
    display_engine=$(engine_for "$display_phase")
    display_model=$(model_for "$display_engine" "$display_phase")
    echo "route     : $display_phase -> $display_engine (model: ${display_model:-CLI default})"
  done
  echo "retry     : $(get_retry)/$(sget '.retry_max')"
  if [ -f "$STOPFILE" ]; then
    echo "stop      : requested (cleared on next start)"
  else
    echo "stop      : not requested"
  fi
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

# ---- watch（簡易 TUI）----
# --status の内容に PLAN のタスク一覧と実行中ターンのログ tail を足し、数秒ごとに再描画する。
# 読み取り専用。state.json や git には触らない（`s` キーだけが --stop と同じフラグを置く）。

WATCH_LOG_LINES="${GSD_LITE_WATCH_LOG_LINES:-15}"

latest_turn_log() { # 最新のターンログ（マイルストーン別ディレクトリ内で更新時刻が最新のもの）
  local milestone
  milestone=$(sget '.milestone // empty')
  ls -t "$GSD_DIR/logs/${milestone:-default}"/turn-*.log 2>/dev/null | head -n 1
}

watch_render() { # 1 画面ぶんを標準出力に描く
  local cols log line n
  cols=$(tput cols 2>/dev/null || echo 120)
  status
  if [ -f "$GSD_DIR/PLAN.md" ]; then
    echo "-- tasks --"
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      [ "$n" -gt 20 ] && { echo "  ..."; break; }
      case "$line" in
        '- [ ]'*) printf '  %s\n' "$line" ;;
        *) printf '  \033[2m%s\033[0m\n' "$line" ;;
      esac
    done < <(grep -E '^- \[( |x)\]' "$GSD_DIR/PLAN.md")
  fi
  log=$(latest_turn_log)
  if [ -n "$log" ]; then
    echo "-- log: ${log#$GSD_DIR/logs/} (last $WATCH_LOG_LINES lines) --"
    tail -n "$WATCH_LOG_LINES" "$log" | cut -c1-"$cols"
  fi
}

watch() {
  [ -f "$STATE" ] || die "no $STATE here (run /gsd-lite-init first)"
  local interval="${GSD_LITE_WATCH_INTERVAL:-3}" key rc
  trap 'tput cnorm 2>/dev/null; echo' EXIT
  tput civis 2>/dev/null
  while true; do
    printf '\033[H\033[2J'
    watch_render 2>&1
    echo
    echo "[q] quit  [s] request stop  [+/-] log lines  (refresh every ${interval}s)"
    key=
    read -r -t "$interval" -n 1 -s key
    rc=$?
    if [ "$rc" -eq 0 ]; then
      case "$key" in
        q|Q) break ;;
        s|S) mkdir -p "$GSD_DIR/logs" && touch "$STOPFILE" ;;
        +) WATCH_LOG_LINES=$((WATCH_LOG_LINES + 5)) ;;
        -) [ "$WATCH_LOG_LINES" -gt 5 ] && WATCH_LOG_LINES=$((WATCH_LOG_LINES - 5)) ;;
      esac
    elif [ "$rc" -le 128 ]; then
      break   # stdin が閉じた（端末ではない）→ 終了
    fi
  done
}

# ---- entry ----

case "${1:-}" in
  --stop)
    [ -f "$STATE" ] || die "no $STATE here"
    mkdir -p "$GSD_DIR/logs" || die "cannot create logs directory"
    touch "$STOPFILE" || die "cannot create $STOPFILE"
    echo "gsd-lite: stop requested; the active turn will finish before stopping"
    exit 0 ;;
  --status) status; exit 0 ;;
  --watch) command -v jq >/dev/null || die "jq is required"; watch; exit 0 ;;
  --watch-once) command -v jq >/dev/null || die "jq is required"; [ -f "$STATE" ] || die "no $STATE here"; watch_render; exit 0 ;;
  --check)
    command -v jq >/dev/null || die "jq is required"
    [ -f "$STATE" ] || die "no $STATE here"
    check_config
    echo "gsd-lite: execution configuration ready"
    exit 0 ;;
  "") ;;
  *) die "unknown option: $1 (supported: --status, --watch, --check, --stop)" ;;
esac

command -v jq >/dev/null || die "jq is required"
command -v timeout >/dev/null || die "timeout (coreutils) is required"
command -v flock >/dev/null || die "flock (util-linux) is required"
[ -f "$STATE" ] || die "no $STATE here (run /gsd-lite-init first, from the project root)"
check_config
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
git show "HEAD:$STATE" >/dev/null 2>&1 || die "$STATE is not committed (commit it first — the loop trusts committed state only)"
if ! git diff --quiet -- "$STATE" 2>/dev/null; then
  echo "gsd-lite: WARN state.json has uncommitted changes — 再開のための編集はコミットしてから起動してください（ターン失敗時に巻き戻ります）" >&2
fi

mkdir -p "$GSD_DIR/logs"

# 二重起動ガード: flock はプロセス終了で自動解放されるため stale 問題も競合窓もない
exec 9>"$LOCKFILE"
flock -n 9 || die "loop already running (lock: $LOCKFILE)"
# 必ず排他取得後に消す。二重起動の失敗で稼働中ループへの中断依頼を消さない。
rm -f "$STOPFILE" || die "cannot clear $STOPFILE"
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
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

  # ターン境界だけで中断する。state の正規化・commit 検証は前ターンで完了済み。
  # DONE / BLOCKED 等の終端を優先し、phase / next_command / retry は変更しない。
  if [ -f "$STOPFILE" ]; then
    echo "gsd-lite: paused; run gsd-lite-loop.sh to resume from $cmd"
    finish 7
  fi

  # 実行前に上限を判定する（DONE / BLOCKED の番兵は上で判定済みなので終端状態が優先される。
  # 上限到達済み state からの再起動で 1 ターン余計に実行しない）
  turn_before=$(sget '.turn')
  max_turns=$(sget '.max_turns')
  if [ "$turn_before" -ge "$max_turns" ]; then
    echo "gsd-lite: max_turns ($max_turns) reached" >&2
    finish 3
  fi

  phase=$(sget '.phase')
  select_engine "$phase"
  retry=$(get_retry)
  model=$(model_for "$ENGINE" "$phase")
  milestone=$(sget '.milestone // empty')
  logdir="$GSD_DIR/logs/${milestone:-default}"   # マイルストーン別に分けて上書きを防ぐ
  mkdir -p "$logdir"
  log="$logdir/turn-$(printf '%03d' $((turn_before + 1)))-attempt$((retry + 1)).log"

  agent_args=()
  if [ "$ENGINE" != claude ]; then
    # state の /command 表現は共有。Codex / OpenCode には明示的なスキル参照を渡す。
    skill_name="${cmd#/}"
    case "$skill_name" in
      ''|*[!a-zA-Z0-9_-]*) die "invalid $ENGINE skill command: $cmd" ;;
    esac
    skill_file="$(skill_dir_for "$ENGINE")/$skill_name/SKILL.md"
    [ -f "$skill_file" ] || die "missing $skill_file (run gsd-lite-init with $ENGINE first)"
  fi
  if [ "$ENGINE" = codex ]; then
    agent_args=(exec --sandbox "$CODEX_SANDBOX" -c 'approval_policy="never"')
    # state の commit が進捗の契約。通常 repo と linked worktree の両方を扱う。
    agent_args+=(--add-dir "$(git rev-parse --absolute-git-dir)")
    git_common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd)
    agent_args+=(--add-dir "$git_common_dir")
    effort=$(jq -r --arg phase "$phase" '.codex.reasoning_effort[$phase] // empty' "$STATE")
    if [ -n "$effort" ]; then
      case "$effort" in
        none|minimal|low|medium|high|xhigh|max|ultra) ;;
        *) die "invalid Codex reasoning effort: $effort" ;;
      esac
      agent_args+=(-c "model_reasoning_effort=\"$effort\"")
    fi
    [ -z "$model" ] || agent_args+=(--model "$model")
    agent_args+=("\$$skill_name — Read $skill_file and execute exactly one unattended turn. Follow its state update and git commit procedure. If blocked, record the reason in .gsd-lite/BLOCKED.md and commit the blocked state.")
  elif [ "$ENGINE" = opencode ]; then
    # 無人ターンは承認プロンプトに応答できないので、明示的に deny されていない権限を自動承認する
    # （opencode.json の deny ルールはそのまま効く）。スキルは skill ツール経由で読み込ませる。
    agent_args=(run --dangerously-skip-permissions)
    variant=$(jq -r --arg phase "$phase" '.opencode.variant[$phase] // empty' "$STATE")
    agent=$(jq -r --arg phase "$phase" '.opencode.agent[$phase] // empty' "$STATE")
    [ -z "$model" ] || agent_args+=(--model "$model")
    [ -z "$variant" ] || agent_args+=(--variant "$variant")
    [ -z "$agent" ] || agent_args+=(--agent "$agent")
    agent_args+=("Load the skill named $skill_name with the skill tool (its file is $skill_file) and execute exactly one unattended turn. Follow its state update and git commit procedure. If blocked, record the reason in .gsd-lite/BLOCKED.md and commit the blocked state.")
  else

    agent_args=(-p "$cmd" --permission-mode "$PERMISSION_MODE")
    [ -z "$model" ] || agent_args+=(--model "$model")
  fi
  echo "gsd-lite: turn $((turn_before + 1)) [$ENGINE/$phase] $cmd (attempt $((retry + 1)))"
  # 親が Claude Code セッションでもネスト起動できるよう、セッション由来の環境変数を除去。
  # timeout でハングを検知し（超過は kill）、進捗なし→リトライ経路に乗せる
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    timeout -k 30 "${GSD_LITE_TURN_TIMEOUT:-3600}" \
    "$AGENT_BIN" "${agent_args[@]}" \
    < /dev/null > "$log" 2>&1 9>&-
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
        git commit -qm "gsd-lite(loop): auto-BLOCKED (no progress after $retry attempts)" ||
        echo "gsd-lite: WARN failed to commit the auto-BLOCKED state（git 識別や hook を確認。作業ツリーの $STATE は blocked のまま）" >&2
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
