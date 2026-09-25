---
name: gsd-lite-init
description: gsd-lite をプロジェクトにセットアップする。雛形スキル・allowlist・.gsd-lite/ の足場を生成してコミットする（要件の中身には踏み込まない）。プロジェクトごとに 1 回、対話セッションで実行する。
disable-model-invocation: true
---

# gsd-lite-init — 足場の生成（プロジェクトごとに 1 回）

足場の生成のみを行う。要件の中身には踏み込まない（それは /gsd-lite-discuss の仕事）。
実行中のホストに応じて以下を使う（install.sh が配置済み）。

| ホスト | テンプレート | プロジェクトのスキル配置先 | 呼び出し |
|---|---|---|---|
| Claude Code | `~/.claude/gsd-lite/templates/` | `.claude/skills/` | `/gsd-lite-discuss` |
| Codex | `~/.codex/gsd-lite/templates/` | `.agents/skills/` | `$gsd-lite-discuss` |
| OpenCode | `~/.config/opencode/gsd-lite/templates/` | `.opencode/skills/` | `/gsd-lite-discuss`（install.sh が置くコマンド経由） |

以下のパス例は Claude 用。Codex / OpenCode では上表の対応先に読み替える。
Codex / OpenCode の質問は利用可能な質問ツールを使い、なければ通常の対話で聞く。
Claude の AskUserQuestion や allowlist を Codex / OpenCode に要求しない。

## 速く終わらせるための原則

- **テンプレートの中身は読まない**。スキル・雛形はシェルの `cp` でコピーし、state.json は
  `jq` で書き換える。Read / Write で 1 ファイルずつ写さない（内容を知る必要はない）
- 確認コマンドは**1 回の Bash にまとめる**。1 項目ずつ別コマンドで叩かない
- プロジェクト内のファイルは、テストランナー判定に必要な数個（`package.json` 等の有無）
  以外は読まない。コードベースの探索は discuss / research の仕事

## 手順

1. **前提確認**（1 回の Bash でまとめて実行し、結果を見てから進む）:
   ```bash
   git rev-parse --show-toplevel 2>/dev/null || echo "NOT_GIT"
   git var GIT_COMMITTER_IDENT >/dev/null 2>&1 && echo "IDENT_OK" || echo "NO_IDENT"
   command -v jq >/dev/null && echo "JQ_OK" || echo "NO_JQ"
   command -v gsd-lite-loop.sh >/dev/null && echo "LOOP_OK" || echo "NO_LOOP"
   test -f .gsd-lite/state.json && echo "ALREADY_INIT" || echo "FRESH"
   ls ~/.claude/gsd-lite/templates/skills 2>/dev/null | tr '\n' ' '
   ```
   - カレントがプロジェクトルート（toplevel と一致）であること。違えばユーザーに一言確認
   - `NOT_GIT` なら `git init` を提案して実行
   - `NO_IDENT` ならループも各ターンも state をコミットできず無進捗で止まるので、
     この時点で `user.name` / `user.email` を設定してもらう
   - `NO_JQ` / `NO_LOOP` なら導入方法を案内して中断
2. **既存チェック**: `.gsd-lite/state.json` が既にあればセットアップ済み。その場合は
   AskUserQuestion で「**スキル・allowlist を最新テンプレートに更新するか**」を確認する:
   - 更新する → 手順 3 のスキルコピーと手順 4 の allowlist マージ**だけ**を行い
     （`cp -r` で上書き。`.gsd-lite/PLAN.template.md` も上書きしてよい）、
     その変更だけをコミット（`gsd-lite: update skills`）。
     **`.gsd-lite/state.json` と成果物には一切触れない**（進行中マイルストーンを壊さない）
   - 更新しない → 何もせず終了
   （gsd-lite 本体を更新した後、既存プロジェクトに反映するのはこの手順。
   install.sh はテンプレートを更新するだけで、配布済みプロジェクトには届かない）
   Codex / OpenCode への追加導入でもスキル更新は可能。既存 state の engine / phase_engines / model は変更しない。
   エンジン切り替えを依頼された場合だけ、ループ停止中に `engine: "codex"` または
   `engine: "opencode"` を設定し、`codex.model` / `codex.reasoning_effort`、または
   `opencode.model` / `opencode.variant` / `opencode.agent`（未設定なら空オブジェクト）を
   追加して別途コミットする。既存の phase・turn・成果物・Claude 用 model は保持する。
3. **足場生成**（1 回の Bash。テンプレートは読まずにコピーする）:
   ```bash
   T=~/.claude/gsd-lite/templates            # Codex: ~/.codex/gsd-lite/templates, OpenCode: ~/.config/opencode/gsd-lite/templates
   S=.claude/skills                          # Codex: .agents/skills, OpenCode: .opencode/skills
   mkdir -p .gsd-lite/logs .gsd-lite/hooks .gsd-lite/archive .gsd-lite/reflect "$S"
   jq --arg now "$(date -Iseconds)" '.updated_at = $now' "$T/state.json" > .gsd-lite/state.json
   cp "$T/PLAN.template.md" .gsd-lite/PLAN.template.md
   cp -r "$T/skills/." "$S/"
   ls "$S" | grep -c '^gsd-lite-' # 6 になること（discuss / research / plan / impl / verify / reflect）
   ```
   - state.json はテンプレートの既定値のままでよい（`updated_at` だけ現在時刻）。
     以下の項目は**ユーザーから指定があった場合だけ** `jq` で書き換える:
     Codex では `engine: "codex"` を確認。モデル未指定なら CLI の既定値を使う。
     指定があれば `codex.model.<phase>` と `codex.reasoning_effort.<phase>` に設定する。
     OpenCode では `engine: "opencode"` を確認。モデルは `opencode.model.<phase>` に
     `provider/model` 形式（例 `anthropic/claude-opus-5`）で、推論強度は
     `opencode.variant.<phase>`、エージェントは `opencode.agent.<phase>` に設定する。
     フェーズ別モデルは後から `.gsd-lite/state.json` を直接編集して変えられる
     （README「フェーズ別モデルの変更」）。
     `subagents`（`auto` / `off`）はテンプレートの `auto` のままでよい。discuss がループ起動前に
     確認する。古い state にキーがなければ `auto` として扱われる。
     `reflect`（既定 `true`）は verify 合格後に振り返りフェーズを挟むかどうか。古い state に
     キーがなければ `true` 扱い。手動の振り返りは `/gsd-lite-reflect`（Codex は
     `$gsd-lite-reflect`、OpenCode は install.sh が置く `/gsd-lite-reflect` コマンド）
4. **allowlist マージ**（Claude のみ。`jq` 1 コマンドで行い、既存エントリは壊さない）:
   ```bash
   mkdir -p .claude
   [ -f .claude/settings.json ] || echo '{}' > .claude/settings.json
   EXTRA='[]'   # 下の判定で決めた追加許可。例: '["Bash(npm test:*)","Bash(npm run:*)"]'
   jq -s --argjson extra "$EXTRA" '
     .[0] as $cur | .[1].permissions.allow as $tpl |
     $cur | .permissions.allow = (($cur.permissions.allow // []) + $tpl + $extra | unique)
   ' .claude/settings.json ~/.claude/gsd-lite/templates/settings.allowlist.json > .claude/settings.json.tmp \
     && mv .claude/settings.json.tmp .claude/settings.json
   ```
   `EXTRA` はテストランナー・パッケージマネージャに応じて決める。判定はファイルの**有無**だけで行い
   中身は読まない: `package.json` → `Bash(npm test:*)` `Bash(npm run:*)`（`pnpm-lock.yaml` /
   `yarn.lock` / `bun.lockb` があればそのコマンドに読み替え）/ `pyproject.toml` や `pytest.ini` →
   `Bash(pytest:*)` `Bash(uv run:*)` / `Cargo.toml` → `Bash(cargo:*)` / `go.mod` → `Bash(go:*)` /
   `Makefile` → `Bash(make:*)`。該当なしなら `[]`。分からなければユーザーに 1 回聞く
   **Codex ではこの手順をスキップ**。ループは workspace-write sandbox と
   approval_policy=never で動き、コミット用に Git 管理ディレクトリを追加する。
   ネットワークや追加パスなど必要な権限は起動前に環境側で用意する。
   sandbox は bubblewrap の unprivileged user namespace に依存する。使えない環境
   （`codex sandbox -- true` が失敗する）では `--check` が止めるので、
   `GSD_LITE_CODEX_SANDBOX=danger-full-access`（隔離環境向け）かカーネル設定で対処する。
   無人ターンは MCP の承認プロンプトに応答できないため、Codex 側で承認必須の
   MCP ツールは使えない点にも注意する。
   **OpenCode でもこの手順をスキップ**。ループは `opencode run --dangerously-skip-permissions`
   で動き、明示的に `deny` されていない権限を自動承認する（`opencode.json` の
   `permission` で `deny` にしたものはそのまま拒否される。`ask` は無人ターンでは
   応答できないので自動承認扱い）。

5. **.gitignore**: `.gsd-lite/logs/` と `.gsd-lite/loop.pid` を追記（なければ作成）
6. **コミット**: 現在のブランチ（= 以後の base ブランチ）に
   `gsd-lite: scaffold` としてコミット
7. **案内**: 「次は同じセッションで `/gsd-lite-discuss <やりたいこと>`」と伝えて終了

## 実行パターン

実行するエンジンの組み合わせは discuss の終了時、ループ開始前に選択する。
init ではホスト用の足場だけでよい。discuss で混在を選んだら必要な両ホスト用スキルと
Claude の allowlist を追加する。既存プロジェクトは init でスキル更新して反映する。
