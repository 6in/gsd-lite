#!/usr/bin/env bash
# gsd-lite-loop.sh のドライランテスト（claude をスタブ化、トークン消費なし）
set -u
TESTROOT=$(mktemp -d /tmp/gsd-lite-test.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT
LOOP=$(cd "$(dirname "$0")/.." && pwd)/bin/gsd-lite-loop.sh
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq(){ [ "$2" = "$3" ] && ok "$1" || ng "$1 (expected [$3], got [$2])"; }

make_project(){ # make_project <dir> — 足場コミット済みの git プロジェクトを作る
  rm -rf "$1"; mkdir -p "$1/.gsd-lite/hooks" "$1/.gsd-lite/logs"
  cd "$1"
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
# ---- スタブ 3: 即 BLOCKED を書く（rc=0 なので未コミットでも信頼される）----
cat > "$TESTROOT/bin/claude-blocker" <<'EOF'
#!/usr/bin/env bash
STATE=.gsd-lite/state.json
t=$(mktemp); jq '.turn+=1 | .next_command="BLOCKED" | .phase="blocked"' "$STATE" > "$t" && mv "$t" "$STATE"
echo "need human" > .gsd-lite/BLOCKED.md
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
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
