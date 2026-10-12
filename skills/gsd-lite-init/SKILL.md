---
name: gsd-lite-init
description: gsd-lite をセットアップする。対象リポジトリ内に直接（従来の in-repo 形）か、対象を work/ に clone して state と成果物だけを持つ制御リポジトリ（gsd-control 形）を生成してコミットする（要件の中身には踏み込まない）。プロジェクトごとに 1 回、対話セッションで実行する。
disable-model-invocation: true
---

# gsd-lite-init — 足場の生成（プロジェクトごとに 1 回）

足場の生成のみを行う。要件の中身には踏み込まない（それは /gsd-lite-discuss の仕事）。
実行中のホストに応じて以下を使う（install.sh が配置済み）。

**Claude Code のプラグインとして入れた場合**（このスキルを `/gsd-lite:gsd-lite-init` で呼んだ場合）は、
install.sh をまだ実行していないので、手順 1 の前提確認が最初にプラグイン同梱の install.sh を呼んで
ループ本体（`~/.local/bin/gsd-lite-loop.sh`）と雛形（`~/.claude/gsd-lite/templates/`）を配置する
（出力に `PLUGIN_SYNCED`）。プラグインを更新した後も、このスキルを呼べば同じ手順で最新に揃う。
以降の手順・パスは install.sh で入れた場合と同じ。

2 つの形がある。どちらも `state.target.path` が「コードを書く対象」を指す:

| 形 | 場所 | 向いている状況 |
|---|---|---|
| **in-repo**（従来・既定） | 対象リポジトリのルートで実行。`.gsd-lite/` とスキルが対象の git に入る | 1 人で使う。`.gsd-lite/` を対象の main に入れてよい |
| **gsd-control**（制御リポジトリ） | 対象とは別の空ディレクトリで実行。対象は `work/<name>` に clone（gitignore）し、state・成果物・スキル・allowlist は制御側の git に入る。マイルストーンごとに制御側にも `gsd-lite/<slug>` ブランチを切り、state は `.gsd-lite/milestones/<slug>/` | 複数人が同じ対象で gsd-lite を使う（`.gsd-lite/` の衝突を避ける）。対象の main にコードだけを入れたい |

`FRESH` のとき（下の手順 1）は AUQ でどちらにするかを聞く（推奨は in-repo。対象リポジトリの
中で実行しているなら in-repo、空ディレクトリなら gsd-control を先頭に）。gsd-control を選んだら
手順 C へ。

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
   [ -x "${CLAUDE_PLUGIN_ROOT}/install.sh" ] && "${CLAUDE_PLUGIN_ROOT}/install.sh" --skip-init-skill --engine claude >/dev/null && echo "PLUGIN_SYNCED"
   git rev-parse --show-toplevel 2>/dev/null || echo "NOT_GIT"
   git var GIT_COMMITTER_IDENT >/dev/null 2>&1 && echo "IDENT_OK" || echo "NO_IDENT"
   command -v jq >/dev/null && echo "JQ_OK" || echo "NO_JQ"
   command -v gsd-lite-loop.sh >/dev/null && echo "LOOP_OK" || echo "NO_LOOP"
   test -f .gsd-lite/state.json && echo "ALREADY_INIT" || { test -f .gsd-lite/config.json && echo "ALREADY_CONTROL" || echo "FRESH"; }
   ls ~/.claude/gsd-lite/templates/skills 2>/dev/null | tr '\n' ' '
   ```
   - カレントがプロジェクトルート（toplevel と一致）であること。違えばユーザーに一言確認
   - `NOT_GIT` なら `git init` を提案して実行
   - `NO_IDENT` ならループも各ターンも state をコミットできず無進捗で止まるので、
     この時点で `user.name` / `user.email` を設定してもらう
   - `NO_JQ` / `NO_LOOP` なら導入方法を案内して中断。`PLUGIN_SYNCED` が出たのに `NO_LOOP` なら
     `~/.local/bin` が PATH に無い（ループは無人ターンの外、ユーザーのターミナルから起動するので PATH に要る）。
     `export PATH="$HOME/.local/bin:$PATH"` をシェルの設定に足してもらう
2. **既存チェック**: `.gsd-lite/state.json`（in-repo）または `.gsd-lite/config.json`（gsd-control）が
   既にあればセットアップ済み。その場合は
   AskUserQuestion で「**スキル・allowlist を最新テンプレートに更新するか**」を確認する
   （gsd-control では加えて「**対象リポジトリを追加登録するか**」も選べる → 手順 C1〜C2 の対象登録部分だけを行う）:
   - 更新する → 手順 3 のスキルコピーと手順 4 の allowlist マージ**だけ**を行い
     （`cp -r` で上書き。`.gsd-lite/PLAN.template.md` も上書きしてよい）、
     その変更だけをコミット（`gsd-lite: update skills`）。
     **`.gsd-lite/state.json`（gsd-control では `.gsd-lite/milestones/*/` と `config.json` の `defaults`）と
     成果物には一切触れない**（進行中マイルストーンを壊さない）
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
     .[0] as $cur | .[1].permissions.allow as $tpl | (.[1].permissions.deny // []) as $deny |
     $cur | .permissions.allow = (($cur.permissions.allow // []) + $tpl + $extra | unique)
          | .permissions.deny = (($cur.permissions.deny // []) + $deny | unique)
   ' .claude/settings.json ~/.claude/gsd-lite/templates/settings.allowlist.json > .claude/settings.json.tmp \
     && mv .claude/settings.json.tmp .claude/settings.json
   ```
   `EXTRA` はテストランナー・パッケージマネージャに応じて決める。判定はファイルの**有無**だけで行い
   中身は読まない: `package.json` → `Bash(npm test:*)` `Bash(npm run:*)`（`pnpm-lock.yaml` /
   `yarn.lock` / `bun.lockb` があればそのコマンドに読み替え）/ `pyproject.toml` や `pytest.ini` →
   `Bash(pytest:*)` `Bash(uv run:*)` / `Cargo.toml` → `Bash(cargo:*)` / `go.mod` → `Bash(go:*)` /
   `Makefile` → `Bash(make:*)`。該当なしなら `[]`。分からなければユーザーに 1 回聞く。
   雛形の `deny` にある `mcp__lean-ctx` は、ユーザー設定で lean-ctx の MCP を登録している環境で無人ターンが
   `ctx_shell` などを呼び、承認待ちで拒否されるのを防ぐ（上の allow は `Bash(...)` 向けで MCP ツールには当たらない）。
   ほかにも無人ターンに見える MCP サーバがあるなら、使わせるものは allow に、使わせないものは deny に足す。
   ループは拒否されたツールを `turns.jsonl` の `permission_denials` と WARN で知らせる
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
7. **Claude Code の trust 確認**（Claude を使う場合）: 無人ターンの `claude -p` は、このディレクトリが trust 済み
   でないと `.claude/settings.json` の allowlist を**すべて無視**する（ログ冒頭に「Ignoring N permissions.allow
   entries ... this workspace has not been trusted」）。対話の `claude` を bypass モードで起動した場合はダイアログが
   出ず未 trust のまま残るので、ここで確認する:
   ```bash
   jq --arg d "$PWD" '.projects[$d].hasTrustDialogAccepted // false' ~/.claude.json
   ```
   `true` でなければユーザーに伝える: 「別ターミナルでこのディレクトリの `claude` を対話起動して trust を受け入れる。
   または claude を終了した状態で `~/.claude.json` の `projects["<絶対パス>"].hasTrustDialogAccepted` を true にする」。
   `gsd-lite-loop.sh --check` も同じ検証を行い、未 trust なら起動しない
8. **案内**: 「次は同じセッションで `/gsd-lite-discuss <やりたいこと>`」と伝えて終了

## 手順 C — gsd-control 形（制御リポジトリを生成する）

前提: カレントは対象リポジトリの**外**の空ディレクトリ（または制御リポジトリにしたい既存の
空に近い git リポジトリ）。対象リポジトリの中で選ばれたら in-repo を勧め直す。

- **C1. 対象の指定**（AUQ / 対話で 1 回にまとめて聞く）: 対象の clone URL（推奨。ローカルパスも可だが、
  `work/<name>` の origin がそのパスになるので verify のリモート判定はその origin で行われる）、
  名前 `<name>`（既定は URL 末尾から `.git` を除いたもの）、base ブランチ（既定 `main`）。
  すでに `work/<name>` に clone 済みならそれを登録するだけでよい
- **C2. 足場生成**（1 回の Bash。テンプレートは読まずにコピーする）:
  ```bash
  T=~/.claude/gsd-lite/templates            # Codex: ~/.codex/gsd-lite/templates, OpenCode: ~/.config/opencode/gsd-lite/templates
  S=.claude/skills                          # Codex: .agents/skills, OpenCode: .opencode/skills
  NAME=<name>; URL=<url>; BASE=<base>
  git rev-parse --git-dir >/dev/null 2>&1 || git init -q -b main
  mkdir -p .gsd-lite/milestones .gsd-lite/logs .gsd-lite/hooks .gsd-lite/reflect work "$S"
  [ -f .gsd-lite/config.json ] || cp "$T/config.json" .gsd-lite/config.json
  jq --arg n "$NAME" --arg u "$URL" --arg b "$BASE" '.targets[$n] = {path: ("work/" + $n), url: $u, base: $b}' \
    .gsd-lite/config.json > .gsd-lite/config.json.tmp && mv .gsd-lite/config.json.tmp .gsd-lite/config.json
  touch .gsd-lite/milestones/.gitkeep
  cp "$T/PLAN.template.md" .gsd-lite/PLAN.template.md
  cp -r "$T/skills/." "$S/"
  for l in 'work/' '.gsd-lite/logs/' '.gsd-lite/loop.pid'; do grep -qxF "$l" .gitignore 2>/dev/null || echo "$l" >> .gitignore; done
  [ -d "work/$NAME/.git" ] || git clone "$URL" "work/$NAME"
  git -C "work/$NAME" var GIT_COMMITTER_IDENT >/dev/null 2>&1 && echo "TARGET_IDENT_OK" || echo "TARGET_NO_IDENT"
  ls "work/$NAME" | head -20
  ```
  - `state.json` はここでは作らない（マイルストーンごとに discuss が `config.json` の `defaults` から
    `.gsd-lite/milestones/<slug>/state.json` を作る）。エンジン・モデルの既定を変えたい指示があれば
    `config.json` の `defaults`（キーは state.json と同じ）を `jq` で書き換える
  - `work/` は **gitignore が必須**。ループは対象が制御側 git に入っていない（ignore か submodule）ことを
    起動前に検証し、違えば止まる。`TARGET_NO_IDENT` なら対象側でも `user.name` / `user.email` を設定してもらう
- **C3. allowlist マージ**（Claude のみ）: 手順 4 と同じ jq マージを行う。ただし `EXTRA` は広くする:
  `"Bash(git:*)"` `"Bash(gh:*)"` `"Bash(glab:*)"` に加え、**対象側**のファイルの有無で決めるテストランナー
  （`work/<name>/package.json` → `Bash(npm test:*)` `Bash(npm run:*)` ... 手順 4 の判定表を `work/<name>/` に
  対して適用）。無人ターンは制御側のカレントから `git -C work/<name> ...` を実行するので、
  サブコマンド単位の許可では足りない
- **C4. コミット**: 制御側の現在のブランチ（通常 main = 制御側の base）に `gsd-lite: scaffold (control)`
- **C5. trust 確認と案内**: 手順 7 と同じ trust 確認を行う（制御リポジトリのディレクトリが対象）。
  そのうえで「次は同じセッションで `/gsd-lite-discuss <やりたいこと>`。対象の CLAUDE.md /
  AGENTS.md は自動では読まれないので、discuss / plan / impl が `work/<name>/CLAUDE.md` を明示的に読む」と伝える。
  ループは**制御リポジトリのルートで**制御ブランチ `gsd-lite/<slug>` にいる状態で起動する
  （`work/<name>` の中で起動すると state が見つからず終了コード 6）

## 実行パターン

実行するエンジンの組み合わせは discuss の終了時、ループ開始前に選択する。
init ではホスト用の足場だけでよい。discuss で混在を選んだら必要な両ホスト用スキルと
Claude の allowlist を追加する。既存プロジェクトは init でスキル更新して反映する。
