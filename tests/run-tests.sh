#!/usr/bin/env bash
# gsd-lite-loop.sh のドライランテスト（Claude / Codex をスタブ化、トークン消費なし）
set -u
TESTROOT=$(mktemp -d /tmp/gsd-lite-test.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT
LOOP=$(cd "$(dirname "$0")/.." && pwd)/bin/gsd-lite-loop.sh
REPO_DIR=$(dirname "$(dirname "$LOOP")")
# 呼び出し元のエンジン設定をテストに持ち込まない。
unset GSD_LITE_ENGINE GSD_LITE_CODEX_MODEL GSD_LITE_CODEX_SANDBOX GSD_LITE_TURN_TIMEOUT
# スタブは `codex sandbox` を実装しないので、sandbox probe は専用テスト以外で飛ばす。
export GSD_LITE_CODEX_SANDBOX_PROBE=skip
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [ "$2" = "$3" ] && ok "$1" || ng "$1 (expected [$3], got [$2])"; }

make_project(){ # make_project <dir> — 足場コミット済みの git プロジェクトを作る
  rm -rf "$1"; mkdir -p "$1/.gsd-lite/hooks" "$1/.gsd-lite/logs"
  cd "$1"
  mkdir -p .claude/skills
  cp -r "$REPO_DIR/templates/skills/." .claude/skills/
  git init -q -b main
  git config user.email t@t; git config user.name t
  cat > .gsd-lite/state.json <<'EOF'
{
  "version": 1, "milestone": "toy", "phase": "research",
  "next_command": "/gsd-lite-research",
  "branch": {"name": "gsd-lite/toy", "base": "main"},
  "research": {"targets": ["similar_oss"], "local_search_paths": []},
  "turn": 0, "max_turns": 10, "retry_max": 2,
  "verify_round": 0, "verify_round_max": 2,
  "model": {"research": "sonnet-stub", "plan": "opus-stub", "impl": "sonnet-stub", "verify": "opus-stub"},
  "updated_at": ""
}
EOF
  cat > .gsd-lite/hooks/on-phase.sh <<'EOF'
#!/usr/bin/env bash
echo "phase $1 -> $2" >> .gsd-lite/hooks.log
EOF
  cat > .gsd-lite/hooks/on-exit.sh <<'EOF'
#!/usr/bin/env bash
echo "exit code=$1 phase=$2" >> .gsd-lite/hooks.log
EOF
  chmod +x .gsd-lite/hooks/*.sh
  printf '.gsd-lite/logs/\n.gsd-lite/loop.pid\n.gsd-lite/hooks.log\n.gsd-lite/stub-args.log\n.gsd-lite/tasks_left\n' > .gitignore
  git add -A && git commit -q -m scaffold
}

mkdir -p "$TESTROOT/bin"
# ---- スタブ 1: 正常系。実スキル同様、state 更新までコミットする ----
cat > "$TESTROOT/bin/claude-happy" <<'EOF'
#!/usr/bin/env bash
STATE=.gsd-lite/state.json
echo "ARGS: $*" >> .gsd-lite/stub-args.log
cmd=""
while [ $# -gt 0 ]; do case "$1" in -p) cmd="$2"; shift 2;; *) shift;; esac; done
jqup(){ t=$(mktemp); jq "$1" "$STATE" > "$t" && mv "$t" "$STATE"; }
turn=$(jq -r .turn "$STATE")
case "$cmd" in
  /gsd-lite-research) jqup '.phase="plan" | .next_command="/gsd-lite-plan"' ;;
  /gsd-lite-plan)     jqup '.phase="impl" | .next_command="/gsd-lite-impl"'; echo 2 > .gsd-lite/tasks_left ;;
  /gsd-lite-impl)
    left=$(( $(cat .gsd-lite/tasks_left) - 1 )); echo "$left" > .gsd-lite/tasks_left
    [ "$left" -le 0 ] && jqup '.phase="verify" | .next_command="/gsd-lite-verify"' ;;
  /gsd-lite-verify)   jqup '.phase="done" | .next_command="DONE"' ;;
esac
jqup ".turn=$((turn+1)) | .updated_at=\"now\""
git add -A >/dev/null && git commit -qm "stub turn $((turn+1))"
echo "stub did $cmd"
EOF
# ---- スタブ 2: 何もしない（state を更新せず死ぬ → auto-BLOCKED 期待）----
cat > "$TESTROOT/bin/claude-noop" <<'EOF'
#!/usr/bin/env bash
echo "noop"
EOF
# ---- スタブ 3: BLOCKED を書いてコミットする（実スキルの契約どおり）----
cat > "$TESTROOT/bin/claude-blocker" <<'EOF'
#!/usr/bin/env bash
STATE=.gsd-lite/state.json
t=$(mktemp); jq '.turn+=1 | .next_command="BLOCKED" | .phase="blocked"' "$STATE" > "$t" && mv "$t" "$STATE"
echo "need human" > .gsd-lite/BLOCKED.md
git add -A >/dev/null && git commit -qm "stub blocked"
EOF
# ---- スタブ 3b: rc=0 だが state をコミットしない → 進捗と認めない期待 ----
cat > "$TESTROOT/bin/claude-ok-nocommit" <<'EOF'
#!/usr/bin/env bash
STATE=.gsd-lite/state.json
t=$(mktemp); jq '.turn+=1 | .phase="done" | .next_command="DONE"' "$STATE" > "$t" && mv "$t" "$STATE"
exit 0
EOF
# ---- スタブ 4: state を進めるがコミットせず rc=1 → 進捗と認めない期待 ----
cat > "$TESTROOT/bin/claude-fail-nocommit" <<'EOF'
#!/usr/bin/env bash
STATE=.gsd-lite/state.json
t=$(mktemp); jq '.turn+=1 | .phase="done" | .next_command="DONE"' "$STATE" > "$t" && mv "$t" "$STATE"
exit 1
EOF
# ---- スタブ 5: コミットまで済ませてから rc=1 → コミット済みなので進捗と認める期待 ----
cat > "$TESTROOT/bin/claude-fail-commit" <<'EOF'
#!/usr/bin/env bash
STATE=.gsd-lite/state.json
t=$(mktemp); jq '.turn+=1 | .phase="done" | .next_command="DONE"' "$STATE" > "$t" && mv "$t" "$STATE"
git add -A >/dev/null && git commit -qm "stub done"
exit 1
EOF
chmod +x "$TESTROOT/bin/"claude-*

echo "== Test 1: 正常系フルサイクル =="
make_project "$TESTROOT/p1"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "exit code 0 (DONE)" "$?" "0"
assert_eq "final phase" "$(jq -r .phase .gsd-lite/state.json)" "done"
assert_eq "total turns" "$(jq -r .turn .gsd-lite/state.json)" "5"
assert_eq "log files (per-milestone dir)" "$(ls .gsd-lite/logs/toy/turn-*.log | wc -l)" "5"
assert_eq "phase hooks fired" "$(grep -c '^phase ' .gsd-lite/hooks.log)" "4"
assert_eq "exit hook" "$(grep -c 'exit code=0 phase=done' .gsd-lite/hooks.log)" "1"
grep -q "sonnet-stub" .gsd-lite/stub-args.log && ok "model routing passed" || ng "model routing"
grep -q "permission-mode acceptEdits" .gsd-lite/stub-args.log && ok "permission mode passed" || ng "permission mode"
assert_eq "pidfile cleaned" "$(ls .gsd-lite/loop.pid 2>/dev/null | wc -l)" "0"
assert_eq "worktree clean at end" "$(git status --porcelain | wc -l)" "0"

echo "== Test 2: 進捗なし → リトライ → auto-BLOCKED =="
make_project "$TESTROOT/p2"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-noop" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "exit code 2 (BLOCKED)" "$?" "2"
assert_eq "state is BLOCKED" "$(jq -r .next_command .gsd-lite/state.json)" "BLOCKED"
grep -q "auto" .gsd-lite/BLOCKED.md && ok "BLOCKED.md auto-written" || ng "BLOCKED.md missing"
assert_eq "auto-BLOCKED is committed" "$(git show HEAD:.gsd-lite/state.json | jq -r .next_command)" "BLOCKED"
assert_eq "attempts logged" "$(ls .gsd-lite/logs/toy/turn-001-attempt*.log | wc -l)" "3"
assert_eq "exit hook code=2" "$(grep -c 'exit code=2' .gsd-lite/hooks.log)" "1"

echo "== Test 3: スキル自身が BLOCKED を書いた場合 =="
make_project "$TESTROOT/p3"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-blocker" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "exit code 2" "$?" "2"
assert_eq "turn advanced once" "$(jq -r .turn .gsd-lite/state.json)" "1"

echo "== Test 4: DISCUSS 番兵 =="
make_project "$TESTROOT/p4"
t=$(mktemp); jq '.next_command="DISCUSS" | .phase="discuss"' .gsd-lite/state.json > "$t" && mv "$t" .gsd-lite/state.json
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "exit code 4" "$?" "4"

echo "== Test 5: --status =="
cd "$TESTROOT/p1"
out=$("$LOOP" --status)
echo "$out" | grep -q "phase     : done" && ok "status shows phase" || ng "status phase"
echo "$out" | grep -q "loop      : not running" && ok "status shows not running" || ng "status running state"

echo "== Test 6: max_turns 事前判定と番兵の優先 =="
make_project "$TESTROOT/p6"
t=$(mktemp); jq '.turn=10' .gsd-lite/state.json > "$t" && mv "$t" .gsd-lite/state.json
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "exit 3 without running a turn" "$?" "3"
assert_eq "no turn logs written" "$(ls .gsd-lite/logs/toy/turn-*.log 2>/dev/null | wc -l)" "0"
t=$(mktemp); jq '.next_command="DONE" | .phase="done"' .gsd-lite/state.json > "$t" && mv "$t" .gsd-lite/state.json
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "DONE wins over max_turns (exit 0)" "$?" "0"

echo "== Test 7b2: rc=0 でも未コミットの DONE は信頼しない =="
make_project "$TESTROOT/p7c"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-ok-nocommit" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "uncommitted DONE + rc=0 -> auto-BLOCKED (exit 2)" "$?" "2"
assert_eq "working state normalized then auto-BLOCKED" "$(jq -r .next_command .gsd-lite/state.json)" "BLOCKED"

echo "== Test 7: rc!=0 はコミット済み state だけを信頼する =="
make_project "$TESTROOT/p7a"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-fail-nocommit" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "uncommitted advance + rc=1 -> auto-BLOCKED (exit 2)" "$?" "2"
assert_eq "committed turn stays 0" "$(git show HEAD:.gsd-lite/state.json | jq -r .turn)" "0"
make_project "$TESTROOT/p7b"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-fail-commit" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "committed advance + rc=1 -> DONE (exit 0)" "$?" "0"
assert_eq "committed turn is 1" "$(jq -r .turn .gsd-lite/state.json)" "1"

echo ""

# Codex の argv を行単位で記録し、同じ状態遷移スタブに委譲する。
cat > "$TESTROOT/bin/codex-happy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> .gsd-lite/stub-args.log
[ "$1" = exec ] || exit 91
prompt="${!#}"
case "$prompt" in
  '$gsd-lite-research '*) cmd=/gsd-lite-research ;;
  '$gsd-lite-plan '*) cmd=/gsd-lite-plan ;;
  '$gsd-lite-impl '*) cmd=/gsd-lite-impl ;;
  '$gsd-lite-verify '*) cmd=/gsd-lite-verify ;;
  *) exit 92 ;;
esac
[ -f ".agents/skills/${cmd#/}/SKILL.md" ] || exit 93
# stdin が親の入力を読み込まないことも検証する。
if read -r unexpected; then exit 94; fi
exec "$(dirname "$0")/claude-happy" -p "$cmd"
EOF
chmod +x "$TESTROOT/bin/codex-happy"

make_codex_project(){
  make_project "$1"
  mkdir -p .agents/skills
  cp -r "$REPO_DIR/templates/skills/." .agents/skills/
  t=$(mktemp)
  jq '.engine="codex" | .codex.model={research:"codex-research-stub",plan:"codex-plan-stub",impl:"codex-impl-stub",verify:"codex-verify-stub"} | .codex.reasoning_effort={plan:"high"}' .gsd-lite/state.json > "$t"
  mv "$t" .gsd-lite/state.json
  git add -A && git commit -qm "configure codex"
}
commit_state(){
  t=$(mktemp)
  jq "$1" .gsd-lite/state.json > "$t" && mv "$t" .gsd-lite/state.json
  git add .gsd-lite/state.json && git commit -qm "configure test"
}

echo "== Test 8: Codex フルサイクルとモデル設定 =="
make_codex_project "$TESTROOT/codex project"
GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "Codex DONE" "$?" "0"
assert_eq "Codex turns" "$(jq -r .turn .gsd-lite/state.json)" "5"
for value in exec workspace-write 'approval_policy="never"' 'model_reasoning_effort="high"' codex-research-stub codex-plan-stub codex-impl-stub codex-verify-stub "$(git rev-parse --absolute-git-dir)"; do
  grep -Fxq -- "$value" .gsd-lite/stub-args.log && ok "Codex argv: $value" || ng "Codex argv: $value"
done
grep -Eq 'sonnet-stub|opus-stub|permission-mode' .gsd-lite/stub-args.log && ng "Claude flags leaked" || ok "no Claude flags/models in Codex"
assert_eq "Codex clean worktree" "$(git status --porcelain | wc -l)" "0"
out=$("$LOOP" --status)
echo "$out" | grep -q 'engine    : codex' && ok "status shows engine" || ng "status engine"

echo "== Test 9: 旧 state の Codex override と既定モデル =="
make_codex_project "$TESTROOT/c9"
commit_state 'del(.engine, .codex) | .max_turns=1'
GSD_LITE_ENGINE=codex GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "engine override ran one turn" "$?" "3"
grep -Fxq -- '--model' .gsd-lite/stub-args.log && ng "default model should be omitted" || ok "CLI default model"
commit_state '.max_turns=2'
GSD_LITE_ENGINE=codex GSD_LITE_CODEX_MODEL="custom model" GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "model override ran" "$?" "3"
grep -Fxq 'custom model' .gsd-lite/stub-args.log && ok "model is one argument" || ng "model quoting"

echo "== Test 10: Codex エラーとコミット契約 =="
make_codex_project "$TESTROOT/c10"
GSD_LITE_ENGINE=unknown "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "unknown engine rejected" "$?" "6"
GSD_LITE_CODEX_BIN="$TESTROOT/missing" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "missing Codex rejected" "$?" "6"
GSD_LITE_CODEX_SANDBOX=invalid GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "invalid sandbox rejected" "$?" "6"
commit_state '.retry_max=0'
GSD_LITE_CODEX_BIN="$TESTROOT/bin/claude-ok-nocommit" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "Codex uncommitted progress blocked" "$?" "2"
assert_eq "Codex blocked state committed" "$(git show HEAD:.gsd-lite/state.json | jq -r .next_command)" "BLOCKED"
make_codex_project "$TESTROOT/c10missing"
rm .agents/skills/gsd-lite-research/SKILL.md
GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "missing Codex skill rejected" "$?" "6"
[ ! -f .gsd-lite/loop.pid ] && ok "failed setup cleans pidfile" || ng "stale pidfile"

echo "== Test 11: インストール先の分離と再インストール =="
install_root="$TESTROOT/install root"
GSD_LITE_INSTALL_ROOT="$install_root" "$REPO_DIR/install.sh" --engine codex > "$TESTROOT/install.log" 2>&1
assert_eq "Codex install succeeded" "$?" "0"
[ -f "$install_root/.agents/skills/gsd-lite-init/SKILL.md" ] && ok "Codex init installed" || ng "Codex init missing"
[ ! -e "$install_root/.claude" ] && ok "Codex-only install" || ng "Claude directory created"
[ ! -e "$install_root/.codex/gsd-lite/templates/settings.allowlist.json" ] && ok "no Claude allowlist in Codex" || ng "Claude allowlist copied"
assert_eq "Codex template engine" "$(jq -r .engine "$install_root/.codex/gsd-lite/templates/state.json")" "codex"
mkdir -p "$install_root/.agents/skills/unrelated"
echo keep > "$install_root/.agents/skills/unrelated/SKILL.md"
GSD_LITE_INSTALL_ROOT="$install_root" "$REPO_DIR/install.sh" --engine all > "$TESTROOT/install.log" 2>&1
assert_eq "both engines reinstall" "$?" "0"
assert_eq "unrelated skill preserved" "$(cat "$install_root/.agents/skills/unrelated/SKILL.md")" "keep"
assert_eq "Claude template engine" "$(jq -r .engine "$install_root/.claude/gsd-lite/templates/state.json")" "claude"
GSD_LITE_INSTALL_ROOT="$install_root" "$REPO_DIR/install.sh" --engine invalid > "$TESTROOT/install.log" 2>&1
assert_eq "invalid install option" "$?" "1"


echo "== Test 12: linked worktree の Git 管理パス =="
make_codex_project "$TESTROOT/c12"
commit_state '.max_turns=1'
git worktree add -q -b linked "$TESTROOT/linked project"
cd "$TESTROOT/linked project"
GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "Codex worktree turn completed" "$?" "3"
for value in "$(git rev-parse --absolute-git-dir)" "$(cd "$(git rev-parse --git-common-dir)" && pwd)"; do
  grep -Fxq -- "$value" .gsd-lite/stub-args.log && ok "worktree writable Git path: $value" || ng "worktree Git path missing"
done

echo "== Test 13: Codex timeout =="
cat > "$TESTROOT/bin/codex-hang" <<'EOF'
#!/usr/bin/env bash
exec sleep 10
EOF
chmod +x "$TESTROOT/bin/codex-hang"
make_codex_project "$TESTROOT/c13"
commit_state '.retry_max=0'
GSD_LITE_TURN_TIMEOUT=1 GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-hang" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "Codex timeout -> BLOCKED" "$?" "2"
grep -q 'rc=124' "$TESTROOT/loop-out.log" && ok "timeout exit recognized" || ng "timeout exit missing"
assert_eq "timeout blocked committed" "$(git show HEAD:.gsd-lite/state.json | jq -r .next_command)" "BLOCKED"

echo "== Test 14: Codex 設定値とコマンド検証 =="
make_codex_project "$TESTROOT/c14"
commit_state '.codex.reasoning_effort.research="bad"'
GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "invalid reasoning effort rejected" "$?" "6"
commit_state '.codex.reasoning_effort={} | .next_command="/../../outside"'
GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "skill traversal rejected" "$?" "6"
GSD_LITE_INSTALL_ROOT="$TESTROOT/default install" "$REPO_DIR/install.sh" > "$TESTROOT/install.log" 2>&1
assert_eq "default install unchanged" "$?" "0"
[ -f "$TESTROOT/default install/.claude/skills/gsd-lite-init/SKILL.md" ] && ok "default Claude init" || ng "default init missing"
[ ! -e "$TESTROOT/default install/.codex" ] && ok "default does not install Codex" || ng "default created Codex"


echo "== Test 15: フェーズ別パターン =="
for pattern in impl verify both reverse; do
  make_codex_project "$TESTROOT/mixed-$pattern"
  case "$pattern" in
    impl) mapping='{impl:"codex"}'; expected='2' ;;
    verify) mapping='{verify:"codex"}'; expected='1' ;;
    both) mapping='{impl:"codex",verify:"codex"}'; expected='3' ;;
    reverse) mapping='{research:"codex",plan:"codex"}'; expected='2' ;;
  esac
  commit_state ".engine=\"claude\" | .phase_engines=$mapping"
  GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
  assert_eq "$pattern completes" "$?" "0"
  assert_eq "$pattern Codex turn count" "$(grep -c '^exec$' .gsd-lite/stub-args.log)" "$expected"
  assert_eq "$pattern total turns" "$(jq -r .turn .gsd-lite/state.json)" "5"
  for phase in research plan impl verify; do
    engine=$(jq -r --arg phase "$phase" '.phase_engines[$phase] // .engine' .gsd-lite/state.json)
    grep -Fq "[$engine/$phase]" "$TESTROOT/loop-out.log" && ok "$pattern routes $phase" || ng "$pattern routes $phase"
  done
done

echo "== Test 16: 実行前チェックは変更・起動しない =="
make_codex_project "$TESTROOT/preflight"
commit_state '.engine="claude" | .phase_engines={verify:"codex"}'
before=$(git rev-parse HEAD)
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" --check > "$TESTROOT/loop-out.log" 2>&1
assert_eq "mixed preflight passes" "$?" "0"
assert_eq "check preserves commit" "$(git rev-parse HEAD)" "$before"
assert_eq "check preserves worktree" "$(git status --porcelain | wc -l)" "0"
[ ! -e .gsd-lite/stub-args.log ] && ok "check runs no agents" || ng "check started agent"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" GSD_LITE_CODEX_BIN="$TESTROOT/missing" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "later missing CLI stops before research" "$?" "6"
[ ! -e .gsd-lite/stub-args.log ] && ok "missing later CLI runs no turns" || ng "partial run"
rm .agents/skills/gsd-lite-verify/SKILL.md
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" --check > "$TESTROOT/loop-out.log" 2>&1
assert_eq "later missing skill fails preflight" "$?" "6"
out=$("$LOOP" --status)
echo "$out" | grep -q 'verify -> codex' && ok "status displays phase assignment" || ng "status assignment"

echo "== Test 17: 環境変数の優先順位と設定値検証 =="
make_codex_project "$TESTROOT/override-mixed"
commit_state '.engine="claude" | .phase_engines={verify:"codex"} | .max_turns=1'
GSD_LITE_ENGINE=codex GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" GSD_LITE_CLAUDE_BIN="$TESTROOT/missing" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "global override needs only Codex" "$?" "3"
grep -q '\[codex/research\]' "$TESTROOT/loop-out.log" && ok "override wins over default" || ng "override routing"
commit_state '.phase_engines={review:"codex"}'
GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" --check > "$TESTROOT/loop-out.log" 2>&1
assert_eq "unknown phase rejected" "$?" "6"
commit_state '.phase_engines={verify:"typo"}'
GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" --check > "$TESTROOT/loop-out.log" 2>&1
assert_eq "unknown phase engine rejected" "$?" "6"


echo "== Test 18: ターン終了で中断し次のターンから再開 =="
# 外部から中断依頼するまでコミットせず待つ。上限付きなので失敗時にもハングしない。
for pause_engine in claude codex; do
  cat > "$TESTROOT/bin/$pause_engine-gated" <<EOF
#!/usr/bin/env bash
touch .gsd-lite/logs/started
for ((i=0; i<200; i++)); do
  if [ -f .gsd-lite/logs/release ]; then
    exec "$TESTROOT/bin/$pause_engine-happy" "\$@"
  fi
  sleep 0.05
done
exit 98
EOF
  chmod +x "$TESTROOT/bin/$pause_engine-gated"
  make_codex_project "$TESTROOT/pause-$pause_engine"
  commit_state ".engine=\"$pause_engine\""
  GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-gated" GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-gated" "$LOOP" > "$TESTROOT/pause.log" 2>&1 &
  pause_pid=$!
  for ((i=0; i<100; i++)); do
    [ -f .gsd-lite/logs/started ] && break
    sleep 0.05
  done
  [ -f .gsd-lite/logs/started ] && ok "$pause_engine turn started" || ng "$pause_engine startup"
  "$LOOP" --stop > /dev/null
  assert_eq "$pause_engine request accepted" "$?" "0"
  "$LOOP" --stop > /dev/null
  assert_eq "$pause_engine repeated request accepted" "$?" "0"
  kill -0 "$pause_pid" 2>/dev/null && ok "$pause_engine active turn not killed" || ng "$pause_engine interrupted mid-turn"
  assert_eq "$pause_engine still waiting before commit" "$(jq -r .turn .gsd-lite/state.json)" "0"
  out=$("$LOOP" --status)
  echo "$out" | grep -q 'stop      : requested' && ok "$pause_engine pending status" || ng "$pause_engine pending status"
  GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" --check > /dev/null
  [ -f .gsd-lite/logs/.stop ] && ok "$pause_engine check preserves request" || ng "$pause_engine check cleared request"
  GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/duplicate.log" 2>&1
  assert_eq "$pause_engine duplicate start rejected" "$?" "6"
  [ -f .gsd-lite/logs/.stop ] && ok "$pause_engine duplicate preserves request" || ng "$pause_engine lost request"
  touch .gsd-lite/logs/release
  wait "$pause_pid"
  assert_eq "$pause_engine paused exit" "$?" "7"
  assert_eq "$pause_engine committed current turn" "$(git show HEAD:.gsd-lite/state.json | jq -r .turn)" "1"
  assert_eq "$pause_engine next command preserved" "$(jq -r .next_command .gsd-lite/state.json)" "/gsd-lite-plan"
  assert_eq "$pause_engine exit hook" "$(grep -c 'exit code=7 phase=plan' .gsd-lite/hooks.log)" "1"
  [ ! -e .gsd-lite/loop.pid ] && ok "$pause_engine pid removed" || ng "$pause_engine stale pid"
  assert_eq "$pause_engine stop flag not committed" "$(git status --porcelain | wc -l)" "0"
  GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-happy" "$LOOP" > "$TESTROOT/resume.log" 2>&1
  assert_eq "$pause_engine resumed to DONE" "$?" "0"
  assert_eq "$pause_engine no repeated completed turn" "$(jq -r .turn .gsd-lite/state.json)" "5"
  [ ! -e .gsd-lite/logs/.stop ] && ok "$pause_engine resume clears flag" || ng "$pause_engine stale flag"
  assert_eq "$pause_engine first turn executed once" "$(grep -c 'ARGS:.*-p /gsd-lite-research' .gsd-lite/stub-args.log)" "1"
done

echo "== Test 19: 失敗したターンの後も中断可能、retry を保持 =="
cat > "$TESTROOT/bin/pause-no-progress" <<'EOF'
#!/usr/bin/env bash
touch .gsd-lite/logs/.stop
t=$(mktemp)
jq '.turn+=1' .gsd-lite/state.json > "$t" && mv "$t" .gsd-lite/state.json
exit 1
EOF
chmod +x "$TESTROOT/bin/pause-no-progress"
make_project "$TESTROOT/pause-retry"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/pause-no-progress" "$LOOP" > "$TESTROOT/pause.log" 2>&1
assert_eq "failed attempt pauses before retry" "$?" "7"
assert_eq "uncommitted state normalized before pause" "$(jq -r .turn .gsd-lite/state.json)" "0"
assert_eq "retry preserved" "$(cat .gsd-lite/logs/.retry)" "1"
GSD_LITE_CLAUDE_BIN="$TESTROOT/missing" "$LOOP" > "$TESTROOT/pause.log" 2>&1
assert_eq "failed startup rejected" "$?" "6"
[ -f .gsd-lite/logs/.stop ] && ok "failed startup preserves stop" || ng "failed startup cleared stop"
GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" "$LOOP" > "$TESTROOT/resume.log" 2>&1
assert_eq "failed task can resume" "$?" "0"
[ -f .gsd-lite/logs/toy/turn-001-attempt2.log ] && ok "resume preserves attempt history" || ng "retry overwritten"

echo "== Test 20: 終端は中断より優先 =="
for terminal in done blocked; do
  make_project "$TESTROOT/pause-terminal-$terminal"
  if [ "$terminal" = done ]; then terminal_stub=claude-fail-commit; expected_exit=0
  else terminal_stub=claude-blocker; expected_exit=2
  fi
  cat > "$TESTROOT/bin/pause-terminal" <<EOF
#!/usr/bin/env bash
touch .gsd-lite/logs/.stop
exec "$TESTROOT/bin/$terminal_stub"
EOF
  chmod +x "$TESTROOT/bin/pause-terminal"
  GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/pause-terminal" "$LOOP" > "$TESTROOT/pause.log" 2>&1
  assert_eq "$terminal wins over pause" "$?" "$expected_exit"
done

echo "== Test 21: Codex sandbox の実効性 probe =="
# bubblewrap が使えない環境の Codex を模す（sandbox --help は通るが実行は失敗）
cat > "$TESTROOT/bin/codex-sandbox-broken" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> .gsd-lite/stub-args.log
if [ "$1" = sandbox ]; then
  [ "$2" = --help ] && exit 0
  echo "bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted" >&2; exit 1
fi
exec "$(dirname "$0")/codex-happy" "$@"
EOF
cat > "$TESTROOT/bin/codex-sandbox-ok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> .gsd-lite/stub-args.log
[ "$1" = sandbox ] && exit 0
exec "$(dirname "$0")/codex-happy" "$@"
EOF
cat > "$TESTROOT/bin/codex-no-sandbox-cmd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> .gsd-lite/stub-args.log
[ "$1" = sandbox ] && { echo "error: unrecognized subcommand 'sandbox'" >&2; exit 2; }
exec "$(dirname "$0")/codex-happy" "$@"
EOF
chmod +x "$TESTROOT/bin/"codex-*
make_codex_project "$TESTROOT/c21"
GSD_LITE_CODEX_SANDBOX_PROBE=auto GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-sandbox-broken" "$LOOP" --check > "$TESTROOT/check.log" 2>&1
assert_eq "broken sandbox rejected by --check" "$?" "6"
grep -q 'danger-full-access' "$TESTROOT/check.log" && ok "remedy is suggested" || ng "remedy missing"
GSD_LITE_CODEX_SANDBOX_PROBE=auto GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-sandbox-broken" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "broken sandbox rejected before the first turn" "$?" "6"
assert_eq "no turn ran on broken sandbox" "$(jq -r .turn .gsd-lite/state.json)" "0"
[ ! -f .gsd-lite/loop.pid ] && ok "probe failure cleans pidfile" || ng "stale pidfile after probe"
: > .gsd-lite/stub-args.log
GSD_LITE_CODEX_SANDBOX_PROBE=auto GSD_LITE_CODEX_SANDBOX=danger-full-access GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-sandbox-broken" "$LOOP" --check > "$TESTROOT/check.log" 2>&1
assert_eq "danger-full-access skips the probe" "$?" "0"
grep -qx sandbox .gsd-lite/stub-args.log && ng "probe ran under danger-full-access" || ok "probe not run under danger-full-access"
GSD_LITE_CODEX_SANDBOX_PROBE=skip GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-sandbox-broken" "$LOOP" --check > "$TESTROOT/check.log" 2>&1
assert_eq "PROBE=skip bypasses the probe" "$?" "0"
: > .gsd-lite/stub-args.log
GSD_LITE_CODEX_SANDBOX_PROBE=auto GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-sandbox-ok" "$LOOP" --check > "$TESTROOT/check.log" 2>&1
assert_eq "working sandbox passes --check" "$?" "0"
grep -Fxq 'sandbox_mode="workspace-write"' .gsd-lite/stub-args.log && ok "probe uses the configured sandbox" || ng "probe sandbox arg"
GSD_LITE_CODEX_SANDBOX_PROBE=auto GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-no-sandbox-cmd" "$LOOP" --check > "$TESTROOT/check.log" 2>&1
assert_eq "old codex without sandbox subcommand still passes" "$?" "0"
grep -q 'WARN' "$TESTROOT/check.log" && ok "old codex warns" || ng "no WARN for old codex"
make_project "$TESTROOT/c21claude"
GSD_LITE_CODEX_SANDBOX_PROBE=auto GSD_LITE_CODEX_BIN="$TESTROOT/bin/codex-sandbox-broken" "$LOOP" --check > "$TESTROOT/check.log" 2>&1
assert_eq "claude-only project never probes Codex" "$?" "0"

echo "== Test 22: git 識別の事前検証 =="
make_project "$TESTROOT/p22"
git config --unset user.email; git config --unset user.name; git config user.useConfigOnly true
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$LOOP" --check > "$TESTROOT/check.log" 2>&1
assert_eq "missing identity rejected by --check" "$?" "6"
grep -q 'identity' "$TESTROOT/check.log" && ok "identity message" || ng "identity message missing"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GSD_LITE_CLAUDE_BIN="$TESTROOT/bin/claude-happy" "$LOOP" > "$TESTROOT/loop-out.log" 2>&1
assert_eq "missing identity stops before the first turn" "$?" "6"
assert_eq "no turn ran without identity" "$(jq -r .turn .gsd-lite/state.json)" "0"
[ ! -f .gsd-lite/loop.pid ] && ok "identity failure cleans pidfile" || ng "stale pidfile after identity failure"
git config user.email t@t; git config user.name t
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$LOOP" --check > "$TESTROOT/check.log" 2>&1
assert_eq "identity restored passes --check" "$?" "0"

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
