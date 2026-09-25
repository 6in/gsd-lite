# gsd-lite

gsd-core のライト版。**対話で仕様を詰め切ったら、あとは無人ループが
research → plan → impl → verify → 仕上げ（ローカルのみなら自動マージ /
リモートありなら push + MR/PR 作成）まで進める**最小構成の自律開発ランナー。

- 毎ターン Claude Code (`claude -p`)、Codex (`codex exec`)、OpenCode (`opencode run`) のいずれかで新規コンテキスト起動。継続性は `.gsd-lite/` + git のみ
- ループ（`gsd-lite-loop.sh`）はダム: `state.json` の `next_command` を実行するだけ
- 1 ターン = 1 タスク。判断に迷ったら推測せず BLOCKED で人間に戻す

設計の全容と利用手順: [docs/SPEC.md](docs/SPEC.md)（§11 がユーザー視点のウォークスルー）

## インストール

```bash
./install.sh
```

## 使い方（要約）

```bash
cd <対象プロジェクト>
claude
```

```
> /gsd-lite-init                       # 足場生成（プロジェクトごとに 1 回）
> /gsd-lite-discuss 決済機能を追加したい   # AUQ で仕様を詰め切る → ループ起動まで面倒を見てくれる
```

進捗確認（トークンゼロ）:

```bash
gsd-lite-loop.sh --status   # 1 回表示
gsd-lite-loop.sh --watch    # 簡易 TUI: 状態・PLAN のタスク・実行中ターンのログを数秒ごとに再描画
```

`--watch` は bash と jq だけで動く読み取り専用の画面で、`q` で終了、`s` で `--stop` と同じ中断依頼、
`+` / `-` でログの表示行数を増減する。間隔は `GSD_LITE_WATCH_INTERVAL`（既定 3 秒）、
ログ行数は `GSD_LITE_WATCH_LOG_LINES`（既定 15）。`--watch-once` は 1 画面ぶんを出力して終了する。

終了コード: 0=DONE（ローカル: マージ済み / リモート: MR 作成済み）/ 2=BLOCKED（`.gsd-lite/BLOCKED.md` 参照）/
3=max_turns / 4=discuss 未完了 / 7=一時中断。通知が欲しければ `.gsd-lite/hooks/on-exit.sh` と
`on-phase.sh` に書く。

## Codex で使う

前提: 認証済みの Codex CLI、git、jq、timeout（coreutils）、flock（util-linux）。

```bash
./install.sh --engine codex   # Codex 用のみ。両方なら --engine all
```

対象プロジェクトで Codex を開き、次を入力する（新しいスキルが見えなければ再起動）。

```text
$gsd-lite-init
$gsd-lite-discuss 追加したい機能
```

Codex 用 init は `~/.agents/skills/`、雛形は `~/.codex/gsd-lite/templates/`、
プロジェクト用スキルは `.agents/skills/` に配置する。
引数なしの `./install.sh` は従来どおり Claude 用。

`.gsd-lite/state.json` の `engine` が `codex` なら、通常の
`gsd-lite-loop.sh` で Codex が起動する。未指定の既存 state は `claude`。
`next_command` はどちらも `/gsd-lite-research` 等のままでよい。

フェーズ別のモデル・推論強度は state に設定してコミットする。例:

```json
{
  "engine": "codex",
  "codex": {
    "model": { "research": "gpt-5.5", "plan": "gpt-5.5", "impl": "gpt-5.5", "verify": "gpt-5.5" },
    "reasoning_effort": { "plan": "high", "verify": "high" }
  }
}
```

これは state に追加するフィールドの例で、state 全体を置き換えるものではない。
未指定のフェーズは Codex CLI の設定を使う。モデルと推論強度は利用環境で
対応する値を指定する。既存の `model` は Claude 専用で、Codex には渡さない。

| 環境変数 | 用途 |
|---|---|
| `GSD_LITE_ENGINE` | 全フェーズを `claude` / `codex` / `opencode` に上書き（phase_engines より優先） |
| `GSD_LITE_CODEX_BIN` | Codex 実行ファイル（既定: `codex`） |
| `GSD_LITE_CODEX_MODEL` | Codex の全フェーズ共通モデル（state より優先） |
| `GSD_LITE_CODEX_SANDBOX` | 既定: `workspace-write`。bubblewrap が使えない環境では `danger-full-access`（sandbox なし。隔離環境向け） |
| `GSD_LITE_CODEX_SANDBOX_PROBE` | 既定: `auto`。Codex を使うフェーズがあれば起動前に `codex sandbox -- true` で sandbox の実効性を検証する。`skip` で省略 |
| `GSD_LITE_TURN_TIMEOUT` | 1 ターンの制限秒数（既定: 3600、両エンジン共通） |
| `GSD_LITE_CLAUDE_TOKEN_VARS` | 任意。Claude のターンで使う `CLAUDE_CODE_OAUTH_TOKEN` を、列挙した環境変数名からターンごとにラウンドロビンで切り替える（下記） |

Codex は `approval_policy=never` で実行し、コミットのために Git 管理ディレクトリを
`--add-dir` で渡す（linked worktree の共通 Git ディレクトリも含む）。
Claude の allowlist は使わない。親環境や組織ポリシーによる制限は引き続き適用される。
ネットワークアクセスが必要な調査・依存取得・push は、起動前に Codex の設定で
必要な権限を用意する。許可不足の場合はログと BLOCKED.md を確認する。

### Linux で Codex sandbox を使う前提（bubblewrap と user namespace）

Codex の Linux sandbox は bubblewrap（bwrap）で作られ、**一般ユーザーが user namespace を
作れること**を前提にする。Ubuntu 24.04 以降は AppArmor の既定
（`kernel.apparmor_restrict_unprivileged_userns=1`）でこれが禁止されているため、
そのままでは workspace-write sandbox 下のシェル実行と `apply_patch` が全て失敗し、
Codex のターンは何も書けずに終わる（macOS は Seatbelt を使うので該当しない）。

`gsd-lite-loop.sh --check` はこの状態を起動前に検出して終了コード 6 で止める。
Codex のフェーズを本来の sandbox で動かすには、起動前に次の設定を行う。

```bash
# 確認（失敗するなら要設定）
codex sandbox -- true && echo OK

# その場で有効化（再起動で元に戻る）
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

# 永続化
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-userns.conf
```

この設定は一般ユーザーの user namespace 作成を許可するもので、bwrap 以外にも
システム全体に効く。設定できない・したくない場合は、隔離された環境に限って
`GSD_LITE_CODEX_SANDBOX=danger-full-access`（sandbox なし）で起動するか、
Codex を使うフェーズを Claude に切り替える。

既存の Claude プロジェクトでは、Codex から `$gsd-lite-init` でスキルを追加・更新し、
ループ停止中に `engine` と `codex` 設定を追加してコミットする。
進行中の phase・turn・成果物は保持する。

仕様の参照: [OpenAI公式・非対話実行](https://learn.chatgpt.com/docs/non-interactive-mode)、
[スキル](https://learn.chatgpt.com/docs/build-skills)。

## OpenCode で使う

前提: 認証済みの [OpenCode](https://opencode.ai) CLI（`opencode`）、git、jq、timeout（coreutils）、flock（util-linux）。

```bash
./install.sh --engine opencode   # OpenCode 用のみ。Claude / Codex も含めるなら --engine all
```

対象プロジェクトで OpenCode を開き、次を入力する（新しいコマンドが見えなければ再起動）。

```text
/gsd-lite-init
/gsd-lite-discuss 追加したい機能
```

OpenCode はスキルをスラッシュコマンドで直接呼べない（モデルが `skill` ツールで読み込む）ため、
install.sh は `~/.config/opencode/commands/gsd-lite-{init,discuss}.md` にスキルを読み込む薄い
コマンドを置く。init スキル本体は `~/.config/opencode/skills/`、雛形は
`~/.config/opencode/gsd-lite/templates/`、プロジェクト用スキルは `.opencode/skills/` に配置する。

`.gsd-lite/state.json` の `engine` が `opencode` なら、通常の `gsd-lite-loop.sh` で
`opencode run` が起動する。`next_command` は `/gsd-lite-research` 等のままでよく、
ループが「スキル `gsd-lite-research` を読み込んで 1 ターン実行せよ」というメッセージに変換する。

フェーズ別のモデル・推論強度・エージェントは state に設定してコミットする。例:

```json
{
  "engine": "opencode",
  "opencode": {
    "model": { "research": "anthropic/claude-sonnet-5", "impl": "anthropic/claude-opus-5" },
    "variant": { "plan": "high", "verify": "high" },
    "agent": { "impl": "build" }
  }
}
```

モデルは OpenCode の `provider/model` 形式（`opencode models` で一覧）。
`variant` は `opencode run --variant`（プロバイダ固有の推論強度。high / max / minimal など）、
`agent` は `opencode run --agent` に渡す。未指定のフェーズは OpenCode の設定を使う。
既存の `model` は Claude 専用、`codex` は Codex 専用で、OpenCode には渡さない。

| 環境変数 | 用途 |
|---|---|
| `GSD_LITE_OPENCODE_BIN` | OpenCode 実行ファイル（既定: `opencode`） |
| `GSD_LITE_OPENCODE_MODEL` | OpenCode の全フェーズ共通モデル（state より優先。`provider/model` 形式） |

無人ターンは承認プロンプトに応答できないため、ループは `opencode run --dangerously-skip-permissions`
で起動し、明示的に `deny` されていない権限を自動承認する。`opencode.json` の `permission` で
`deny` にした操作はそのまま拒否されるので、無人実行で使う bash / edit / webfetch 等は
`deny` にしない。Claude の allowlist や Codex の sandbox 設定は使わない。

既存の Claude / Codex プロジェクトでは、OpenCode から `/gsd-lite-init` でスキルを追加・更新し、
ループ停止中に `engine` と `opencode` 設定を追加してコミットする。
進行中の phase・turn・成果物は保持する。

## フェーズ別モデルの変更（init 後）

各フェーズで使うモデルは `.gsd-lite/state.json` に保存され、`/gsd-lite-init` が
テンプレートの既定値を書き込む。**init 後にいつでも state.json を直接編集して変えられる**。
手順は 3 つ。

1. ループを止める（実行中なら `gsd-lite-loop.sh --stop` で現在のターンの完了を待つ）
2. `.gsd-lite/state.json` の該当キーを編集する（フェーズは `research` / `plan` / `impl` / `verify`）
3. **コミットする**。ループはコミット済みの state しか信頼せず、未コミットの編集は
   ターン失敗時に巻き戻る

```bash
gsd-lite-loop.sh --stop
$EDITOR .gsd-lite/state.json
git add .gsd-lite/state.json && git commit -m "gsd-lite: モデル変更"
gsd-lite-loop.sh --status     # route 行で各フェーズのエンジンとモデルを確認
```

エンジンごとにキーが分かれており、そのフェーズを実行するエンジンのキーだけが使われる。

| エンジン | モデル | 推論強度など | 値の形式 |
|---|---|---|---|
| Claude Code | `model.<phase>` | （なし） | `claude -p --model` に渡す名前。例 `claude-opus-5`、`claude-fable-5-1` |
| Codex | `codex.model.<phase>` | `codex.reasoning_effort.<phase>`（`low` / `medium` / `high` / `xhigh` など） | `codex exec --model` に渡す名前。例 `gpt-5.5` |
| OpenCode | `opencode.model.<phase>` | `opencode.variant.<phase>`、`opencode.agent.<phase>` | `provider/model`。例 `anthropic/claude-opus-5`（`opencode models` で一覧） |

3 エンジンぶんを書いた例（実際に使われるのは `engine` / `phase_engines` で選ばれたエンジンの分だけ）:

```json
{
  "engine": "claude",
  "phase_engines": { "impl": "opencode", "verify": "codex" },
  "model":    { "research": "claude-fable-5-1", "plan": "claude-fable-5-1", "impl": "claude-opus-5", "verify": "claude-fable-5-1" },
  "codex":    { "model": { "verify": "gpt-5.5" }, "reasoning_effort": { "verify": "high" } },
  "opencode": { "model": { "impl": "anthropic/claude-opus-5" }, "variant": {}, "agent": {} }
}
```

キーを削除するか空文字にすると、そのフェーズはその CLI の既定モデルで動く。
`GSD_LITE_CODEX_MODEL` / `GSD_LITE_OPENCODE_MODEL` を設定して起動すると、
そのエンジンの全フェーズが state より優先してそのモデルになる（一時的な切り替え用）。
テンプレートの既定値（新規プロジェクトに配られる値）を変えたい場合は
`templates/state.json` を編集して `./install.sh` を再実行する。既存プロジェクトの
state.json には反映されないので、上の手順で個別に変更する。

## Claude のトークンを組織ごとに切り替える（任意）

複数の組織（グループ）に所属していて、`claude setup-token` で取得したトークンを
ターンごとに順番に使いたい場合の機能。**未設定なら何も変わらない**（親環境の
`CLAUDE_CODE_OAUTH_TOKEN` がそのまま使われる）。

トークンの値ではなく、**値を保持している環境変数の名前**を `GSD_LITE_CLAUDE_TOKEN_VARS` に
空白区切りで列挙する。ループは Claude のターンを起動するたびに次の変数を選び、その値を
`CLAUDE_CODE_OAUTH_TOKEN` として `claude -p` に渡す。

手順:

1. 組織ごとにトークンを取得する。対話の `claude` で `/login` してその組織を選び、
   ログイン状態で `claude setup-token` を実行すると長期トークンが表示される。これを組織の数だけ繰り返す
2. 取得したトークンを、組織ごとに別名の環境変数へ入れる（シェルの rc や secret manager から export。
   リポジトリや `.gsd-lite/` には書かない）
3. 変数名を `GSD_LITE_CLAUDE_TOKEN_VARS` に列挙してループを起動する

```bash
# 2. 各組織のトークンを環境変数に入れておく
export CLAUDE_TOKEN_ORG_A='sk-ant-oat01-...'   # 組織 A でログインして claude setup-token
export CLAUDE_TOKEN_ORG_B='sk-ant-oat01-...'   # 同、組織 B
export CLAUDE_TOKEN_ORG_C='sk-ant-oat01-...'   # 同、組織 C

# 3. 変数名を列挙して起動（値ではなく名前を渡す）
export GSD_LITE_CLAUDE_TOKEN_VARS="CLAUDE_TOKEN_ORG_A CLAUDE_TOKEN_ORG_B CLAUDE_TOKEN_ORG_C"
gsd-lite-loop.sh --check    # 3 変数がすべて非空か確認
gsd-lite-loop.sh            # ターンごとに A → B → C → A … と切り替えて実行
gsd-lite-loop.sh --status   # token 行に「次に使う変数名」が出る
```

- 順番は A → B → C → A … で、リトライも 1 回と数えて次に進む。位置は `.gsd-lite/logs/.token_index`
  に保存され（gitignore 済み）、ループを再開しても続きから回る
- 値はログにも画面にも出さず、`turn N [claude/impl] ... (token: CLAUDE_TOKEN_ORG_B)` のように
  変数名だけを表示する。`--status` / `--watch` の `token` 行で次に使う変数が分かる
- `--check` と通常起動は、Claude を使うフェーズがある場合に列挙された変数がすべて非空であることを
  確認し、欠けていれば終了コード 6 で止める（途中で空トークンに当たって無進捗になるのを防ぐ）
- Codex / OpenCode のターンには影響しない。全フェーズが Codex / OpenCode なら無視される
- 各トークンは自分のマシン用に取得したもので、値の管理・失効は利用者側の責任。
  `.gsd-lite/` や state.json にトークンを書かないこと

## サブエージェントによる並列実装・並列レビュー（任意）

Claude Code の Agent ツールや OpenCode の task ツールのように、実行エンジンがサブエージェントを
使える場合、impl と verify のターン内で作業を並列化できる。state.json の `subagents` で切り替える
（テンプレートの既定は `auto`。古い state にキーがなければ `auto` 扱い）。

| 値 | 動作 |
|---|---|
| `auto` | plan が各タスクに「並列サブ作業」（対象ファイルが重ならない独立した作業単位）を書き、impl はサブ作業が 2 つ以上あればサブ作業ごとにサブエージェントを起動して並行実装する。verify はコードレビューとセキュリティチェックを別のサブエージェントに並行させる |
| `off` | 従来通り 1 エージェントが順に実装・検証する（コスト重視・小規模向け） |

守られるルール（スキルに書かれている）:

- サブエージェントは **git commit・state.json・PLAN.md・PROGRESS.md に触らない**。テスト・コミット・
  state 更新・マージ・push は親のターンだけが行う（ループの「コミット済み state で進捗判定」は変わらない）
- 並列サブ作業は対象ファイルを互いに重ねない。分けられないタスクは `なし` として順に実装する
- 対応していないエンジン（Codex の `exec` 等）のフェーズでは自動的に従来動作になる
- ターンあたりのトークン消費は増える。1 ターンの制限時間（`GSD_LITE_TURN_TIMEOUT`）は変わらない

値は discuss の実行パターン選択で聞かれるほか、ループ停止中に `.gsd-lite/state.json` の
`subagents` を編集してコミットしても変えられる。`--status` / `--watch` の `subagents` 行で確認できる。

## ループ開始前に実行パターンを選ぶ

discuss の最後に、実行パターンを選んでからループを開始する。
対話するホストは自由で、Claude Code で仕様を詰めて Codex や OpenCode に実装させることもできる。

| パターン | 調査 | 計画 | 実装 | レビュー |
|---|---|---|---|---|
| すべて Claude | Claude | Claude | Claude | Claude |
| すべて Codex | Codex | Codex | Codex | Codex |
| 実装だけ Codex | Claude | Claude | Codex | Claude |
| レビューだけ Codex | Claude | Claude | Claude | Codex |
| 実装・レビューは Codex | Claude | Claude | Codex | Codex |
| すべて OpenCode | OpenCode | OpenCode | OpenCode | OpenCode |
| 実装だけ OpenCode | Claude | Claude | OpenCode | Claude |

カスタム指定（フェーズごとに `claude` / `codex` / `opencode` を選ぶ）や、現在の設定を維持する選択も可能。
選択結果は `state.json` に保存して要件と一緒にコミットする。
モデルはそのフェーズを実行するエンジンの設定を使う。

レビューだけ Codex の保存例（state の一部）:

```json
{
  "engine": "claude",
  "phase_engines": { "verify": "codex" }
}
```

優先順位は `GSD_LITE_ENGINE` → `phase_engines.<phase>` → `engine` → `claude`。
プリセット変更時は `phase_engines` を置き換えるため、前回の割り当ては残らない。
指定できるフェーズは `research` / `plan` / `impl` / `verify`。

混在させる場合は `install.sh --engine all` で全エンジンのテンプレートを導入する。
discuss が選択したエンジン用のプロジェクトスキルを配置する
（Claude: `.claude/skills/`、Codex: `.agents/skills/`、OpenCode: `.opencode/skills/`）。
CLI の認証と権限も起動前に準備しておく。

```bash
gsd-lite-loop.sh --check    # 全フェーズのCLI・スキル配置を確認（変更・起動なし）
gsd-lite-loop.sh --status   # フェーズ別の実行先・モデルと進捗を表示
```

通常のループ起動でも実行前チェックを行う。後半で使うCLIやスキルが不足していれば
最初のターンより前に終了コード6で停止する。認証・通信の疎通確認は含まない。

チェックには次も含まれる（どちらも見落とすと「全ターン無進捗 → auto-BLOCKED」になる）。

- **git 識別**: `git var GIT_COMMITTER_IDENT` が通ること。ループ自身も各ターンも
  state.json をコミットするため、`user.name` / `user.email` 未設定では進捗を残せない
- **Codex sandbox の実効性**: Codex を使うフェーズがあり sandbox が `danger-full-access`
  以外なら `codex sandbox -c sandbox_mode=... -- true` を実行する。bubblewrap が
  unprivileged user namespace を作れない環境（Ubuntu 24.04 の
  `kernel.apparmor_restrict_unprivileged_userns=1` など）では Codex のシェル実行も
  `apply_patch` も全て失敗するため、ここで止めて対処（`GSD_LITE_CODEX_SANDBOX=danger-full-access`、
  カーネル設定の変更、または impl / verify を Claude に切り替え）を案内する
ループ自体は対話せず、保存された組み合わせで毎ターン実行先を切り替える。
既存プロジェクトは再インストール後、init でスキルを更新すると選択手順が反映される。

## 中断と再開

対象プロジェクトの別ターミナルから中断を依頼する。

```bash
gsd-lite-loop.sh --stop
```

実行中のタスクはコミット・後処理まで完了させ、次のタスクを開始する前に中断する。
`--stop` 自体は依頼を記録してすぐ終了する。停止したかは
`gsd-lite-loop.sh --status` の `loop` と `stop` を確認する（`--watch` 画面の `s` キーでも同じ依頼ができる）。

通常と同じコマンドで、保存された次のタスクから再開する。

```bash
gsd-lite-loop.sh
```

中断フラグは `.gsd-lite/logs/.stop`。手動の `touch .gsd-lite/logs/.stop` でも依頼できる。
正常に起動して排他ロックを取得した時点で、前回のフラグを削除する。
二重起動や事前チェックの失敗、`--status` / `--check` はフラグを消さない。
停止中に依頼したフラグも、次回起動時に削除される。

中断時のループ終了コードは **7**。`on-exit.sh` にもコード7と現在のフェーズを渡す。
phase・next_command・ターン数を中断用に変更せず、完了済みのタスクは再実行しない。
失敗した試行でも終了後に中断でき、未コミットstateを復元したうえでリトライ回数を保持する。
DONE・BLOCKED（リトライ上限到達を含む）は中断より優先する。
実行中の処理がハングした場合は、従来どおりターンタイムアウトまで待つ。
フラグは既存の logs/ の除外設定によりGitには入らない。

## テスト

```bash
bash tests/run-tests.sh
```

Claude / Codex / OpenCode をスタブ化し、実モデルへの接続やトークン消費なしで検証する。

## リモート運用（MR/PR の作成手段）

`origin` があるプロジェクトでは、verify 合格時にローカルマージせず
**push + MR/PR 作成**で DONE になる（マージは人間 / CI に委ねる）:

- **GitHub**: `gh pr create`。事前にマシンごとに一度 `gh auth login` が必要
- **GitLab**: `glab mr create`（要 `glab auth login`）。**`glab` がなくても**
  push オプション `-o merge_request.create -o merge_request.target=<base>` で
  MR を作成する（GitLab サーバー側機能・追加ツール不要）
- CLI 不在・未認証などで作成できないときは push まで行って BLOCKED（人間が作る）
