#!/usr/bin/env bash
# gsd-lite-loop.sh — gsd-lite のダムループ。
# state.json の next_command を実行し続けるだけで、フェーズ遷移の判断は一切持たない。
# 仕様: docs/SPEC.md §7
#
# 使い方:
#   gsd-lite-loop.sh            # ループ実行（対象プロジェクトの直下で。gsd-control 形は制御リポジトリの直下・制御ブランチ gsd-lite/<slug> で）
#   gsd-lite-loop.sh --check    # 全フェーズの実行前提を検証（起動・変更なし）
#   gsd-lite-loop.sh --status   # 進捗の整形表示（トークンゼロの覗き窓）
#   gsd-lite-loop.sh --stop     # 現在のターン終了後に中断を依頼
#   gsd-lite-loop.sh --watch    # 進捗・タスク・実行中ログを数秒ごとに再描画する簡易 TUI（q で終了）
#   gsd-lite-loop.sh --watch-once # --watch の 1 画面ぶんを出力して終了（非対話・テスト用）
#   gsd-lite-loop.sh --where    # 作業場所の解決結果（mode / milestone_dir / state / target / slug）を key=value で表示。
#                               # スキルが最初に 1 回呼び、以降はその値をリテラルで使う（Bash ツールはコール間で変数を保持しない）
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
#   GSD_LITE_CLAUDE_TRUST_CHECK auto / skip（デフォルト auto）。Claude を使うフェーズがあれば、このディレクトリが
#                              Claude Code で trust 済み（~/.claude.json の projects[<cwd>].hasTrustDialogAccepted）か
#                              起動前に確認する。未 trust だと claude -p は .claude/settings.json の allowlist を全部
#                              無視するので、無人ターンが権限拒否で無進捗になる
#   GSD_LITE_CLAUDE_TOKEN_VARS 任意。Claude のターンで CLAUDE_CODE_OAUTH_TOKEN に使うトークンを
#                              保持している環境変数「名」の空白区切りリスト（例 "TOK_ORG_A TOK_ORG_B"）。
#                              設定すると Claude のターンごとにラウンドロビンで切り替える
#                              （`claude setup-token` で取得した組織ごとのトークンを順番に使う用途）。
#                              未設定なら従来通り親環境の CLAUDE_CODE_OAUTH_TOKEN をそのまま使う。
#                              値はログ・出力に出さず、変数名だけを表示する。次に使う位置は logs/.token_index
#   GSD_LITE_WATCH_INTERVAL    --watch の再描画間隔秒（デフォルト 3）
#   GSD_LITE_WATCH_LOG_LINES   --watch で表示するログ末尾の行数（デフォルト 15。+/- キーで増減）
#   GSD_LITE_TURN_TIMEOUT      1 ターンの制限秒数（デフォルト 3600。超過はハング扱いで
#                              kill し、進捗なし→リトライ経路に乗せる）
#   GSD_LITE_LIMIT_WAIT        利用上限（session / usage / rate limit）で進捗なしに終わったターンの
#                              再試行までの待機秒数（デフォルト 900）。このときは retry を増やさない
#   GSD_LITE_LIMIT_MAX         利用上限による連続の待機回数の上限（デフォルト 8）。超えたら auto-BLOCKED
#   GSD_LITE_LIMIT_PATTERN     利用上限と見なすターンログの拡張正規表現（大文字小文字は区別しない。
#                              デフォルト 'hit your (session|usage) limit|usage limit reached|rate limit'）
#   GSD_LITE_CLAUDE_STREAM     on / off（デフォルト on）。on なら Claude のターンを
#                              `--output-format stream-json --verbose` で起動し、イベント列を
#                              turn-NNN-attemptN.jsonl に残す。ターン後に最終メッセージを従来の
#                              turn-NNN-attemptN.log に書き出し、トークン量などを turns.jsonl に記録する。
#                              off なら従来どおり平文の .log だけ（トークン量は記録されない）
#
# 計測: 各試行の phase / engine / model / attempt / 開始・終了時刻 / 所要秒 / rc / 進捗有無 /
# 増えたコミット数を logs/<milestone>/turns.jsonl に 1 行ずつ追記する（reflect フェーズの客観材料）。
# エンジンが報告した場合は usage（トークン量）/ cost_usd / num_turns / permission_denials（承認待ちで
# 拒否されたツール）/ rate_limit（利用枠の使用率）も同じ行に入る（Claude: stream-json の result、
# Codex: ログ末尾の「tokens used」の合計のみ、OpenCode: なし）。
#
# 作業場所（2 つの形。どちらも state.target.path が「コードを書く対象」を指す）:
#   in-repo（従来）: .gsd-lite/state.json があるリポジトリ。target.path は "."（未指定も同じ）。
#                   state・成果物・コードが同じ git に入る
#   control（gsd-control）: .gsd-lite/config.json があり state.json がない制御リポジトリ。
#                   マイルストーンは制御側ブランチ gsd-lite/<slug> で、state と成果物は
#                   .gsd-lite/milestones/<slug>/ に、コードは target.path（work/<name>、gitignore 済み）
#                   の対象リポジトリに入る。進捗判定は制御側のコミット済み state で行い、対象側の
#                   ブランチ・マージ・push は各ターンのスキルが `git -C <target>` で行う
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
PHASES="research plan impl verify reflect"   # ループが扱うフェーズ（スキル gsd-lite-<phase> に対応）
CONFIG="$GSD_DIR/config.json"      # 制御リポジトリの印（既定値 + 対象登録）。in-repo 形には無い
MODE=repo                          # repo | control（resolve_state が決める）
MS_DIR="$GSD_DIR"                  # マイルストーンディレクトリ（state.json と成果物の置き場）
STATE="$MS_DIR/state.json"
SLUG=""                            # control のときの制御ブランチ gsd-lite/<slug> の slug
TARGET=.                           # コードを書く対象リポジトリ（state.target.path。"." は今いるリポジトリ）
PIDFILE="$GSD_DIR/loop.pid"        # 情報表示用（排他は flock が担う）
LOCKFILE="$GSD_DIR/logs/.lock"     # logs/ は gitignore 済み
RETRYFILE="$GSD_DIR/logs/.retry"
usage_json="{}"                    # 直近のターンでエンジンが報告した使用量（turn_usage が埋める）
LIMITFILE="$GSD_DIR/logs/.limit_retry"   # 利用上限による連続待機の回数（実行時情報）
LIMIT_PATTERN="${GSD_LITE_LIMIT_PATTERN:-hit your (session|usage) limit|usage limit reached|rate limit}"
TOKENFILE="$GSD_DIR/logs/.token_index"   # トークンのラウンドロビン位置（実行時情報）
TOKEN_VARS=()                           # check_claude_tokens が GSD_LITE_CLAUDE_TOKEN_VARS から埋める
STOPFILE="$GSD_DIR/logs/.stop"    # 実行時情報。gitignore 済み logs/ に置く
CLAUDE_BIN="${GSD_LITE_CLAUDE_BIN:-claude}"
PERMISSION_MODE="${GSD_LITE_PERMISSION_MODE:-acceptEdits}"

die() { echo "gsd-lite-loop: $*" >&2; exit 6; }

resolve_state() { # MODE / MS_DIR / STATE / SLUG / TARGET を決める（state が無くても die しない。有無は呼び手が見る）
  MODE=repo; MS_DIR="$GSD_DIR"; STATE="$MS_DIR/state.json"; SLUG=""; TARGET=.
  if [ ! -f "$STATE" ] && [ -f "$CONFIG" ]; then
    MODE=control
    local br
    br=$(git branch --show-current 2>/dev/null || echo "")
    case "$br" in
      gsd-lite/?*) SLUG="${br#gsd-lite/}" ;;
      *) return 0 ;;   # 制御ブランチにいない: STATE は存在しないパスのまま（require_state が案内する）
    esac
    MS_DIR="$GSD_DIR/milestones/$SLUG"; STATE="$MS_DIR/state.json"
  fi
  if [ -f "$STATE" ] && command -v jq >/dev/null; then
    TARGET=$(jq -r '.target.path // "."' "$STATE" 2>/dev/null || echo .)
    [ -n "$TARGET" ] || TARGET=.
  fi
}

require_state() { # state.json が無ければ場所に応じた案内で die
  [ -f "$STATE" ] && return 0
  if [ "$MODE" = control ]; then
    if [ -z "$SLUG" ]; then
      die "control repository: not on a milestone branch (gsd-lite/<slug>) — run /gsd-lite-discuss to start a milestone, or git checkout gsd-lite/<slug>"
    fi
    die "no $STATE for milestone '$SLUG' (run /gsd-lite-discuss on this branch first)"
  fi
  die "no $STATE here (run /gsd-lite-init first, from the project root)"
}

tgit() { git -C "$TARGET" "$@"; }   # 対象リポジトリへの git（in-repo では今いるリポジトリ）

sget() { jq -r "$1" "$STATE"; }

supdate() { # supdate '<jq filter>' — state.json をインプレース更新
  local tmp
  tmp=$(mktemp) || die "mktemp failed"
  jq "$1" "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

get_retry() { cat "$RETRYFILE" 2>/dev/null || echo 0; }
set_retry() { echo "$1" > "$RETRYFILE"; }
get_limit_retry() { cat "$LIMITFILE" 2>/dev/null || echo 0; }
set_limit_retry() { echo "$1" > "$LIMITFILE"; }

auto_block() { # auto_block <BLOCKED.md の本文> <commit の要約> — ループ自身が BLOCKED を書いてコミットして終了
  supdate '.next_command = "BLOCKED" | .phase = "blocked"'
  {
    echo "# BLOCKED (auto)"
    echo ""
    echo "$1"
  } > "$MS_DIR/BLOCKED.md"
  git add "$STATE" "$MS_DIR/BLOCKED.md" 2>/dev/null && \
    git commit -qm "gsd-lite(loop): auto-BLOCKED ($2)" ||
    echo "gsd-lite: WARN failed to commit the auto-BLOCKED state（git 識別や hook を確認。作業ツリーの $STATE は blocked のまま）" >&2
  finish 2
}

check_updated_at() { # コミット済み state の updated_at が HEAD のコミット時刻より先なら警告する（値は直さない）
  local stamp stamp_s commit_s
  stamp=$(committed_state '.updated_at // empty')
  [ -n "$stamp" ] || return 0
  stamp_s=$(date -d "$stamp" +%s 2>/dev/null) || return 0   # ISO 8601 でなければ判定しない
  commit_s=$(git show -s --format=%ct HEAD 2>/dev/null) || return 0
  if [ "$stamp_s" -gt $((commit_s + 300)) ]; then
    echo "gsd-lite: WARN state.updated_at ($stamp) is $(( (stamp_s - commit_s) / 60 )) min after the commit time — the turn likely estimated the time instead of running date" >&2
  fi
}

run_hook() { # run_hook <name> <args...> — フックの失敗は無視。ロック FD は継承させない
  local hook="$GSD_DIR/hooks/$1"; shift
  [ -x "$hook" ] && "$hook" "$@" 9>&- || true
}

committed_state() { # コミット済み (HEAD) の state から値を読む
  git show "HEAD:$STATE" 2>/dev/null | jq -r "$1"
}

count_commits() { # count_commits <before> <after> [<repo dir>] — 2 つの HEAD の間に増えたコミット数
  local before=$1 after=$2 dir=${3:-.}
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    git -C "$dir" rev-list --count "$before..$after" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# stream-json の 1 行を人が読める行にする jq フィルタ（--watch と、result の無いログの平文化で共用）。
# JSON でない行（stderr・テスト用スタブの出力）はそのまま通す
STREAM_RENDER='. as $l | try (fromjson
  | if type != "object" then $l
    elif .type == "assistant" then (.message.content[]?
      | if .type == "text" then .text
        elif .type == "tool_use" then "[tool] \(.name) \(.input | tostring | .[0:160])"
        else empty end)
    elif .type == "system" and .subtype == "permission_denied" then "[denied] \(.tool_name)"
    elif .type == "result" then "[result] \(.result // "")"
    else empty end) catch $l'

finalize_turn_log() { # Claude の stream-json（$rawlog）から従来の平文ログ（$log）を作る
  [ "$rawlog" != "$log" ] || return 0
  # 最終メッセージ（result）と JSON でない行だけを残す。result が無い（timeout で kill 等）なら途中経過を平文化する
  jq -Rr '. as $l | try (fromjson | if type != "object" then $l
      elif .type == "result" then (.result // empty) else empty end) catch $l' "$rawlog" > "$log" 2>/dev/null
  if ! jq -Re 'fromjson? | select(type == "object" and .type == "result")' "$rawlog" >/dev/null 2>&1; then
    jq -Rr "$STREAM_RENDER" "$rawlog" > "$log" 2>/dev/null || cp "$rawlog" "$log"
  fi
}

turn_usage() { # このターンでエンジンが報告した使用量を JSON 1 個で出す（取れなければ {}）
  local total
  case "$ENGINE" in
    claude)
      [ "$rawlog" != "$log" ] || { echo '{}'; return 0; }
      jq -Rnc 'reduce (inputs | fromjson? | select(type == "object")) as $e ({};
          if $e.type == "result" then . + {
            usage: {input_tokens: $e.usage.input_tokens, output_tokens: $e.usage.output_tokens,
                    cache_read_input_tokens: $e.usage.cache_read_input_tokens,
                    cache_creation_input_tokens: $e.usage.cache_creation_input_tokens},
            cost_usd: $e.total_cost_usd, num_turns: $e.num_turns, duration_api_ms: $e.duration_api_ms,
            is_error: $e.is_error, permission_denials: [$e.permission_denials[]?.tool_name]}
          elif $e.type == "rate_limit_event" then . + {rate_limit: ($e.rate_limit_info
            | {status, type: .rateLimitType, resets_at: .resetsAt,
               five_hour: .unifiedWindows.five_hour.utilization, seven_day: .unifiedWindows.seven_day.utilization})}
          else . end)' "$rawlog" 2>/dev/null || echo '{}' ;;
    codex)
      # codex exec は平文ログの末尾に「tokens used」と合計値（桁区切りあり）を出す。内訳は無い
      total=$(awk 'tolower($0) == "tokens used" { getline; gsub(/[^0-9]/, ""); v = $0 } END { if (v != "") print v }' "$log" 2>/dev/null)
      if [ -n "$total" ]; then jq -nc --argjson t "$total" '{usage: {total_tokens: $t}}'; else echo '{}'; fi ;;
    *) echo '{}' ;;
  esac
}

report_usage() { # 使用量と権限拒否を 1 行で知らせる（loop.log に残る）
  [ "$usage_json" != '{}' ] || return 0
  echo "gsd-lite: turn $((turn_before + 1)) usage $(echo "$usage_json" | jq -r '
    [ (.usage // {} | to_entries[] | select(.value != null) | "\(.key | sub("_input_tokens$"; "") | sub("_tokens$"; ""))=\(.value)"),
      (if .cost_usd != null then "cost=$\(.cost_usd * 10000 | round / 10000)" else empty end),
      (if .rate_limit.five_hour != null then "5h=\(.rate_limit.five_hour * 100 | round)%" else empty end),
      (if .rate_limit.seven_day != null then "7d=\(.rate_limit.seven_day * 100 | round)%" else empty end) ] | join(" ")')"
  local denied
  denied=$(echo "$usage_json" | jq -r '(.permission_denials // []) | if length > 0 then "\(length) (\(unique | join(", ")))" else empty end')
  [ -z "$denied" ] || echo "gsd-lite: WARN turn $((turn_before + 1)) had permission denials: $denied — allowlist（.claude/settings.json）に足すか、そのツールを deny して使わせない" >&2
}

record_turn() { # 1 試行ぶんの計測値を logs/<milestone>/turns.jsonl に追記（reflect の客観材料）
  local head_after finished_epoch commits progressed target_head_after target_commits target_json
  head_after=$(git rev-parse HEAD 2>/dev/null || echo "")
  finished_epoch=$(date +%s)
  commits=$(count_commits "$head_before" "$head_after")
  progressed=false
  [ "$turn_after" -gt "$turn_before" ] && progressed=true
  # 対象が別リポジトリ（control）のときは、対象側に増えたコード側のコミット数も残す
  target_json='{}'
  if [ "$TARGET" != . ]; then
    target_head_after=$(tgit rev-parse HEAD 2>/dev/null || echo "")
    target_commits=$(count_commits "$target_head_before" "$target_head_after" "$TARGET")
    target_json=$(jq -nc --arg t "$TARGET" --arg b "$target_head_before" --arg a "$target_head_after" \
      --argjson c "${target_commits:-0}" '{target:$t, target_head_before:$b, target_head_after:$a, target_commits:$c}')
  fi
  jq -nc \
    --argjson turn "$((turn_before + 1))" --arg phase "$phase" --arg engine "$ENGINE" \
    --arg model "$model" --argjson attempt "$((retry + 1))" --arg started "$started_at" \
    --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson duration "$((finished_epoch - started_epoch))" \
    --argjson rc "$rc" --argjson progressed "$progressed" --argjson commits "${commits:-0}" \
    --arg head_before "$head_before" --arg head_after "$head_after" --arg log "$log" \
    --arg token_var "$token_var" --argjson target "$target_json" --argjson usage "$usage_json" \
    '{turn:$turn, phase:$phase, engine:$engine, model:$model, attempt:$attempt,
      started_at:$started, finished_at:$finished, duration_s:$duration, rc:$rc,
      progressed:$progressed, commits:$commits, head_before:$head_before, head_after:$head_after,
      log:$log, token_var:$token_var} + $target + $usage' >> "$logdir/turns.jsonl" 2>/dev/null || true
}

usage_summary() { # --status 用: このマイルストーンの turns.jsonl に記録された使用量の合計（記録が無ければ何も出さない）
  local f
  f="$GSD_DIR/logs/$(sget '.milestone // "default"')/turns.jsonl"
  [ -f "$f" ] || return 0
  jq -rs 'map(select(.usage != null)) | if length == 0 then empty else
      "usage     : \(length) attempts — in=\(map(.usage.input_tokens // 0) | add) out=\(map(.usage.output_tokens // 0) | add) cache_read=\(map(.usage.cache_read_input_tokens // 0) | add) cache_creation=\(map(.usage.cache_creation_input_tokens // 0) | add)"
      + (map(.usage.total_tokens // 0) | add | if . > 0 then " total=\(.)" else "" end)
      + (map(.cost_usd // 0) | add | if . > 0 then " cost=$\(. * 100 | round / 100)" else "" end)
      + (map(.permission_denials // [] | length) | add | if . > 0 then " denials=\(.)" else "" end)
    end' "$f" 2>/dev/null || true
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
        (.key == "research" or .key == "plan" or .key == "impl" or .key == "verify" or .key == "reflect") and
        (.value == "claude" or .value == "codex" or .value == "opencode")))
  ' "$STATE" >/dev/null || die "invalid engine / phase_engines configuration"
  CODEX_SANDBOX="${GSD_LITE_CODEX_SANDBOX:-workspace-write}"
  for check_phase in $PHASES; do
    # reflect: false のプロジェクトは reflect ターンが来ないので、そのスキル・CLI は要求しない
    # （jq の // は false も未設定扱いにするので == false で判定する）
    if [ "$check_phase" = reflect ] && [ "$(sget '.reflect == false')" = true ]; then
      continue
    fi
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
  check_target
  check_codex_sandbox
  check_claude_tokens
  check_claude_trust
}

check_target() {
  # state.target.path が "." 以外（対象が別リポジトリ）のときの前提。in-repo 形では何もしない。
  # 対象は制御リポジトリ配下の相対パスで、制御側 git に入らない（gitignore か submodule）こと。
  # 無人ターンは `git add -A` 相当の操作をするので、対象ツリーが制御側に混入する事故をここで防ぐ
  [ "$TARGET" != . ] || return 0
  case "$TARGET" in
    /*|../*|*/../*|*/..|..) die "target.path must be a relative path inside this repository (got: $TARGET)" ;;
  esac
  if [ ! -d "$TARGET" ]; then
    local url
    url=$(jq -r --arg p "$TARGET" '[.targets[]? | select(.path == $p) | .url] | first // empty' "$CONFIG" 2>/dev/null || echo "")
    die "target repository $TARGET is missing — clone it first: git clone ${url:-<url>} $TARGET"
  fi
  tgit rev-parse --git-dir >/dev/null 2>&1 || die "target $TARGET is not a git repository"
  if ! git check-ignore -q -- "$TARGET" 2>/dev/null && \
     ! git ls-files --stage -- "$TARGET" 2>/dev/null | grep -q '^160000 '; then
    die "target $TARGET must be gitignored (or a submodule) in this repository — add '${TARGET%%/*}/' to .gitignore so unattended commits never pull the target tree into the control repository"
  fi
  tgit var GIT_COMMITTER_IDENT >/dev/null 2>&1 ||
    die "git identity is not configured in target $TARGET — set user.name / user.email there too (every turn commits code in the target)"
  check_target_branch
}

check_target_branch() {
  # research / plan / impl / verify のあいだ、対象は state.branch.name（マイルストーンブランチ）にいなければならない。
  # 別ブランチ（特に base）にいると、次のターンがそこへ直接コミットしてしまう。
  # reflect と終端（done / blocked）は、ローカル運用の verify が base へマージした後なので確認しない
  [ "$TARGET" != . ] || return 0
  local want have phase
  phase=$(sget '.phase')
  case "$phase" in research|plan|impl|verify) ;; *) return 0 ;; esac
  want=$(sget '.branch.name // empty')
  [ -n "$want" ] || return 0
  have=$(tgit branch --show-current 2>/dev/null || echo "")
  [ "$have" = "$want" ] ||
    die "target $TARGET is on branch '${have:-<detached>}' but the milestone expects '$want' — git -C $TARGET checkout $want (or fix state.branch) before starting"
}

check_claude_tokens() {
  # 任意機能。Claude を使うフェーズがあり GSD_LITE_CLAUDE_TOKEN_VARS が設定されていれば、
  # 列挙された変数名が妥当で、すべて非空であることを起動前に確認する（途中で空トークンに当たって
  # 無進捗 → auto-BLOCKED になるのを防ぐ）。値は一切表示しない
  local name uses_claude=0 p
  TOKEN_VARS=()
  [ -n "${GSD_LITE_CLAUDE_TOKEN_VARS:-}" ] || return 0
  for p in $PHASES; do
    [ "$(engine_for "$p")" = claude ] && uses_claude=1
  done
  [ "$uses_claude" -eq 1 ] || return 0
  read -r -a TOKEN_VARS <<< "$GSD_LITE_CLAUDE_TOKEN_VARS"
  [ "${#TOKEN_VARS[@]}" -gt 0 ] || die "GSD_LITE_CLAUDE_TOKEN_VARS is set but lists no variable names"
  for name in "${TOKEN_VARS[@]}"; do
    case "$name" in
      [A-Za-z_]*) ;;
      *) die "invalid variable name in GSD_LITE_CLAUDE_TOKEN_VARS: $name" ;;
    esac
    case "$name" in
      *[!A-Za-z0-9_]*) die "invalid variable name in GSD_LITE_CLAUDE_TOKEN_VARS: $name" ;;
    esac
    [ -n "${!name:-}" ] || die "token variable $name (listed in GSD_LITE_CLAUDE_TOKEN_VARS) is unset or empty — export it (e.g. from \`claude setup-token\`) before starting"
  done
}

token_index() { # 次に使うトークン変数の添字（0 始まり）
  local idx
  idx=$(cat "$TOKENFILE" 2>/dev/null || echo 0)
  case "$idx" in ''|*[!0-9]*) idx=0 ;; esac
  echo $((idx % ${#TOKEN_VARS[@]}))
}

next_token_var() { # ラウンドロビンで変数名を返し、位置を進める
  local idx
  idx=$(token_index)
  echo $(( (idx + 1) % ${#TOKEN_VARS[@]} )) > "$TOKENFILE"
  printf '%s\n' "${TOKEN_VARS[$idx]}"
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
  for probe_phase in $PHASES; do
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

where() { # 作業場所の解決結果を key=value で表示（スキル向け。値はそのままリテラルパスとして使える）
  require_state
  echo "mode=$MODE"
  echo "milestone_dir=$MS_DIR"
  echo "state=$STATE"
  echo "target=$TARGET"
  echo "slug=${SLUG:-$(sget '.milestone // empty')}"
}

claude_config_file() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"; }

claude_trusted() { # 0=trust 済み / 1=未 trust / 2=判定できない（設定ファイルなし）
  local cfg
  cfg=$(claude_config_file)
  [ -f "$cfg" ] || return 2
  [ "$(jq -r --arg d "$PWD" '.projects[$d].hasTrustDialogAccepted // false' "$cfg" 2>/dev/null)" = true ]
}

check_claude_trust() {
  # claude -p は、そのディレクトリで trust ダイアログを受け入れていないと .claude/settings.json の
  # permissions.allow を「Ignoring N permissions.allow entries ... this workspace has not been trusted」として
  # 全部無視する。無人ターンでは権限拒否に応答できないので、起動前に止めて対処を案内する
  local uses_claude=0 p
  [ "${GSD_LITE_CLAUDE_TRUST_CHECK:-auto}" = skip ] && return 0
  for p in $PHASES; do
    [ "$(engine_for "$p")" = claude ] && uses_claude=1
  done
  [ "$uses_claude" -eq 1 ] || return 0
  claude_trusted
  case $? in
    0) return 0 ;;
    2) echo "gsd-lite: WARN $(claude_config_file) not found — cannot verify that this workspace is trusted by Claude Code" >&2; return 0 ;;
  esac
  die "this workspace is not trusted by Claude Code, so claude -p will ignore every permissions.allow entry in .claude/settings.json (unattended turns then stall on permission prompts).
  対処（どちらか）: (a) このディレクトリで対話の claude を一度起動して trust ダイアログを受け入れる（bypass モードで起動した場合はダイアログが出ないので (b)）
              (b) claude を終了した状態で: jq --arg d \"$PWD\" '.projects[\$d].hasTrustDialogAccepted = true' $(claude_config_file) > /tmp/claude.json && mv /tmp/claude.json $(claude_config_file)
  この検証を飛ばすには GSD_LITE_CLAUDE_TRUST_CHECK=skip"
}

trust_summary() { # --status / --check 用の 1 行
  claude_trusted
  case $? in
    0) echo "trust     : accepted (Claude Code allowlist active)" ;;
    1) echo "trust     : NOT accepted — claude -p ignores .claude/settings.json allowlist (see --check)" ;;
    *) echo "trust     : unknown ($(claude_config_file) not found)" ;;
  esac
}

token_summary() { # トークン切り替えの状態 1 行（値は出さない。未設定でも出して気づけるようにする）
  if [ -n "${GSD_LITE_CLAUDE_TOKEN_VARS:-}" ]; then
    # 表示だけなので値の検証はしない（検証は --check / 起動時）
    read -r -a TOKEN_VARS <<< "$GSD_LITE_CLAUDE_TOKEN_VARS"
    if [ "${#TOKEN_VARS[@]}" -gt 0 ]; then
      echo "token     : rotating ${#TOKEN_VARS[@]} vars (next: ${TOKEN_VARS[$(token_index)]})"
      return
    fi
  fi
  echo "token     : rotation off (GSD_LITE_CLAUDE_TOKEN_VARS unset; parent CLAUDE_CODE_OAUTH_TOKEN / login is used)"
}

status() {
  require_state
  echo "== gsd-lite status =="
  if [ "$MODE" = control ]; then
    echo "mode      : control ($MS_DIR)"
  else
    echo "mode      : in-repo"
  fi
  if [ "$TARGET" != . ]; then
    if [ -d "$TARGET" ] && tgit rev-parse --git-dir >/dev/null 2>&1; then
      echo "target    : $TARGET (branch: $(tgit branch --show-current 2>/dev/null || echo '?'))"
    else
      echo "target    : $TARGET (MISSING — clone it first)"
    fi
  fi
  echo "engine    : ${GSD_LITE_ENGINE:-$(sget '.engine // "claude"')}"
  jq -r '"milestone : \(.milestone)\nphase     : \(.phase)\nturn      : \(.turn)/\(.max_turns)\nnext      : \(.next_command)\nverify    : round \(.verify_round)/\(.verify_round_max)\nbranch    : \(.branch.name) (base: \(.branch.base))\nupdated   : \(.updated_at)"' "$STATE"
  for display_phase in $PHASES; do
    display_engine=$(engine_for "$display_phase")
    display_model=$(model_for "$display_engine" "$display_phase")
    echo "route     : $display_phase -> $display_engine (model: ${display_model:-CLI default})"
  done
  echo "retry     : $(get_retry)/$(sget '.retry_max')"
  echo "subagents : $(sget '.subagents // "auto"')"
  token_summary
  trust_summary
  usage_summary
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
  if [ -f "$MS_DIR/PLAN.md" ]; then
    echo "-- current task --"
    grep -m1 '^- \[ \]' "$MS_DIR/PLAN.md" || echo "(no unchecked task)"
  fi
  if [ -f "$MS_DIR/PROGRESS.md" ]; then
    echo "-- recent progress --"
    tail -n 6 "$MS_DIR/PROGRESS.md"
  fi
  if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "-- recent commits --"
    git log --oneline -5 2>/dev/null || true
  fi
  if [ "$TARGET" != . ] && tgit rev-parse --git-dir >/dev/null 2>&1; then
    echo "-- recent target commits ($TARGET) --"
    tgit log --oneline -5 2>/dev/null || true
  fi
}

# ---- watch（簡易 TUI）----
# --status の内容に PLAN のタスク一覧と実行中ターンのログ tail を足し、数秒ごとに再描画する。
# 読み取り専用。state.json や git には触らない（`s` キーだけが --stop と同じフラグを置く）。

WATCH_LOG_LINES="${GSD_LITE_WATCH_LOG_LINES:-15}"

latest_turn_log() { # 最新のターンログ（マイルストーン別ディレクトリ内で更新時刻が最新のもの）
  local milestone
  milestone=$(sget '.milestone // empty')
  ls -t "$GSD_DIR/logs/${milestone:-default}"/turn-*.log "$GSD_DIR/logs/${milestone:-default}"/turn-*-attempt*.jsonl 2>/dev/null | head -n 1
}

watch_render() { # 1 画面ぶんを標準出力に描く
  local cols log line n
  cols=$(tput cols 2>/dev/null || echo 120)
  status
  if [ -f "$MS_DIR/PLAN.md" ]; then
    echo "-- tasks --"
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      [ "$n" -gt 20 ] && { echo "  ..."; break; }
      case "$line" in
        '- [ ]'*) printf '  %s\n' "$line" ;;
        *) printf '  \033[2m%s\033[0m\n' "$line" ;;
      esac
    done < <(grep -E '^- \[( |x)\]' "$MS_DIR/PLAN.md")
  fi
  log=$(latest_turn_log)
  if [ -n "$log" ]; then
    echo "-- log: ${log#$GSD_DIR/logs/} (last $WATCH_LOG_LINES lines) --"
    case "$log" in
      *.jsonl) jq -Rr "$STREAM_RENDER" "$log" 2>/dev/null | tail -n "$WATCH_LOG_LINES" | cut -c1-"$cols" ;;   # 実行中の Claude ターン
      *) tail -n "$WATCH_LOG_LINES" "$log" | cut -c1-"$cols" ;;
    esac
  fi
}

watch() {
  require_state
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

resolve_state
case "${1:-}" in
  --stop)
    require_state
    mkdir -p "$GSD_DIR/logs" || die "cannot create logs directory"
    touch "$STOPFILE" || die "cannot create $STOPFILE"
    echo "gsd-lite: stop requested; the active turn will finish before stopping"
    exit 0 ;;
  --status) status; exit 0 ;;
  --where) command -v jq >/dev/null || die "jq is required"; where; exit 0 ;;
  --watch) command -v jq >/dev/null || die "jq is required"; watch; exit 0 ;;
  --watch-once) command -v jq >/dev/null || die "jq is required"; require_state; watch_render; exit 0 ;;
  --check)
    command -v jq >/dev/null || die "jq is required"
    require_state
    check_config
    token_summary
    trust_summary
    echo "gsd-lite: execution configuration ready"
    exit 0 ;;
  "") ;;
  *) die "unknown option: $1 (supported: --status, --watch, --watch-once, --where, --check, --stop)" ;;
esac

command -v jq >/dev/null || die "jq is required"
command -v timeout >/dev/null || die "timeout (coreutils) is required"
command -v flock >/dev/null || die "flock (util-linux) is required"
require_state
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
echo "gsd-lite: start $(date -Iseconds) pid $$ mode=$MODE${SLUG:+ slug=$SLUG}$([ "$TARGET" = . ] || echo " target=$TARGET") (append to logs/loop.log with >> so restarts keep earlier lines)"
trap 'rm -f "$PIDFILE"' EXIT
trap 'finish 130' INT TERM

while true; do
  cmd=$(sget '.next_command')
  case "$cmd" in
    /*) ;;
    DONE)    echo "gsd-lite: milestone complete"; finish 0 ;;
    BLOCKED) echo "gsd-lite: human input needed — see $MS_DIR/BLOCKED.md"; finish 2 ;;
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
  check_target_branch   # 対象が別リポジトリなら、毎ターン起動前にマイルストーンブランチにいることを確認する
  select_engine "$phase"
  retry=$(get_retry)
  model=$(model_for "$ENGINE" "$phase")
  milestone=$(sget '.milestone // empty')
  logdir="$GSD_DIR/logs/${milestone:-default}"   # マイルストーン別に分けて上書きを防ぐ
  mkdir -p "$logdir"
  log="$logdir/turn-$(printf '%03d' $((turn_before + 1)))-attempt$((retry + 1)).log"
  rawlog="$log"   # エンジンの出力先。Claude の stream-json のときだけ .jsonl に分け、ターン後に .log を作る

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
    if [ "$TARGET" != . ]; then
      # 対象リポジトリ（control）の Git 管理ディレクトリも書けるようにする（clone なら workspace 内だが worktree に備える）
      agent_args+=(--add-dir "$(tgit rev-parse --absolute-git-dir)")
      agent_args+=(--add-dir "$(cd "$(tgit rev-parse --git-common-dir)" 2>/dev/null && pwd || tgit rev-parse --absolute-git-dir)")
    fi
    effort=$(jq -r --arg phase "$phase" '.codex.reasoning_effort[$phase] // empty' "$STATE")
    if [ -n "$effort" ]; then
      case "$effort" in
        none|minimal|low|medium|high|xhigh|max|ultra) ;;
        *) die "invalid Codex reasoning effort: $effort" ;;
      esac
      agent_args+=(-c "model_reasoning_effort=\"$effort\"")
    fi
    [ -z "$model" ] || agent_args+=(--model "$model")
    agent_args+=("\$$skill_name — Read $skill_file and execute exactly one unattended turn. Follow its state update and git commit procedure. If blocked, record the reason in $MS_DIR/BLOCKED.md and commit the blocked state.")
  elif [ "$ENGINE" = opencode ]; then
    # 無人ターンは承認プロンプトに応答できないので、明示的に deny されていない権限を自動承認する
    # （opencode.json の deny ルールはそのまま効く）。スキルは skill ツール経由で読み込ませる。
    agent_args=(run --dangerously-skip-permissions)
    variant=$(jq -r --arg phase "$phase" '.opencode.variant[$phase] // empty' "$STATE")
    agent=$(jq -r --arg phase "$phase" '.opencode.agent[$phase] // empty' "$STATE")
    [ -z "$model" ] || agent_args+=(--model "$model")
    [ -z "$variant" ] || agent_args+=(--variant "$variant")
    [ -z "$agent" ] || agent_args+=(--agent "$agent")
    agent_args+=("Load the skill named $skill_name with the skill tool (its file is $skill_file) and execute exactly one unattended turn. Follow its state update and git commit procedure. If blocked, record the reason in $MS_DIR/BLOCKED.md and commit the blocked state.")
  else

    agent_args=(-p "$cmd" --permission-mode "$PERMISSION_MODE")
    [ -z "$model" ] || agent_args+=(--model "$model")
    if [ "${GSD_LITE_CLAUDE_STREAM:-on}" != off ]; then
      agent_args+=(--output-format stream-json --verbose)
      rawlog="${log%.log}.jsonl"
    fi
  fi
  # 任意: Claude のターンは GSD_LITE_CLAUDE_TOKEN_VARS のトークンをラウンドロビンで使う。
  # 値は env の引数に載せず（ps に見えない）、サブシェルで export してから起動する
  token_var=
  if [ "$ENGINE" = claude ] && [ "${#TOKEN_VARS[@]}" -gt 0 ]; then
    token_var=$(next_token_var)
  fi
  echo "gsd-lite: turn $((turn_before + 1)) [$ENGINE/$phase] $cmd (attempt $((retry + 1)))${token_var:+ (token: $token_var)}"
  head_before=$(git rev-parse HEAD 2>/dev/null || echo "")
  target_head_before=""
  [ "$TARGET" = . ] || target_head_before=$(tgit rev-parse HEAD 2>/dev/null || echo "")
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  started_epoch=$(date +%s)
  # 親が Claude Code セッションでもネスト起動できるよう、セッション由来の環境変数を除去。
  # timeout でハングを検知し（超過は kill）、進捗なし→リトライ経路に乗せる
  (
    [ -z "$token_var" ] || export CLAUDE_CODE_OAUTH_TOKEN="${!token_var}"
    exec env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
      timeout -k 30 "${GSD_LITE_TURN_TIMEOUT:-3600}" \
      "$AGENT_BIN" "${agent_args[@]}" \
      < /dev/null > "$rawlog" 2>&1 9>&-
  )
  rc=$?
  finalize_turn_log
  usage_json=$(turn_usage)
  [ -n "$usage_json" ] && echo "$usage_json" | jq -e 'type == "object"' >/dev/null 2>&1 || usage_json='{}'

  # 進捗判定は rc に依らず「コミット済み (HEAD) の state」で行う。
  # 正常終了でも commit まで到達していなければ成功と認めない
  turn_after=$(committed_state '.turn')
  [ -n "$turn_after" ] || die "cannot read committed state (HEAD:$STATE)"
  record_turn
  report_usage
  # ターン境界の正規化: 作業ツリーの state を HEAD に揃える（未コミットの書きかけを残さない）
  git checkout HEAD -- "$STATE" || die "failed to restore $STATE from HEAD"

  if [ "$turn_after" -le "$turn_before" ]; then
    # 利用上限で落ちたターンは詰まりではないので retry を増やさず、待ってから同じターンをやり直す
    if grep -Eqi -- "$LIMIT_PATTERN" "$log" 2>/dev/null ||
       [ "$(echo "$usage_json" | jq -r '.rate_limit.status // empty')" = rejected ]; then
      limit_retry=$(( $(get_limit_retry) + 1 ))
      limit_max="${GSD_LITE_LIMIT_MAX:-8}"
      if [ "$limit_retry" -gt "$limit_max" ]; then
        echo "gsd-lite: usage limit persisted for $limit_max waits — auto-BLOCKED (see $MS_DIR/BLOCKED.md)" >&2
        set_limit_retry 0
        auto_block "利用上限（session / usage / rate limit）で $limit_max 回続けて待機しても進捗がありませんでした。最後のログ: $log" "usage limit persisted"
      fi
      set_limit_retry "$limit_retry"
      echo "gsd-lite: usage limit hit (wait $limit_retry/$limit_max, retry stays $retry) — sleeping ${GSD_LITE_LIMIT_WAIT:-900}s — see $log" >&2
      sleep "${GSD_LITE_LIMIT_WAIT:-900}"
      continue
    fi
    set_limit_retry 0
    retry=$((retry + 1))
    retry_max=$(sget '.retry_max')
    echo "gsd-lite: no committed progress (rc=$rc, attempt $retry/$((retry_max + 1))) — see $log" >&2
    if [ "$retry" -gt "$retry_max" ]; then
      echo "gsd-lite: turn made no progress after $retry attempts — auto-BLOCKED (see $MS_DIR/BLOCKED.md)" >&2
      auto_block "ループが自動生成した BLOCKED です。ターンが state.json を（コミットまで含めて）
更新せずに $retry 回連続で終了しました。最後のログ: $log" "no progress after $retry attempts"
    fi
    set_retry "$retry"
    sleep 2
    continue
  fi
  set_retry 0
  set_limit_retry 0
  check_updated_at
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
