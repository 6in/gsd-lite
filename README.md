# gsd-lite

gsd-core のライト版。**対話で仕様を詰め切ったら、あとは無人ループが
research → plan → impl → verify → 仕上げ（ローカルのみなら自動マージ /
リモートありなら push + MR/PR 作成）まで進める**最小構成の自律開発ランナー。

- 毎ターン Claude Code (`claude -p`) または Codex (`codex exec`) で新規コンテキスト起動。継続性は `.gsd-lite/` + git のみ
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
gsd-lite-loop.sh --status
```

終了コード: 0=DONE（ローカル: マージ済み / リモート: MR 作成済み）/ 2=BLOCKED（`.gsd-lite/BLOCKED.md` 参照）/
3=max_turns / 4=discuss 未完了。通知が欲しければ `.gsd-lite/hooks/on-exit.sh` と
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
| `GSD_LITE_ENGINE` | 全フェーズを `claude` / `codex` に上書き（phase_engines より優先） |
| `GSD_LITE_CODEX_BIN` | Codex 実行ファイル（既定: `codex`） |
| `GSD_LITE_CODEX_MODEL` | Codex の全フェーズ共通モデル（state より優先） |
| `GSD_LITE_CODEX_SANDBOX` | 既定: `workspace-write` |
| `GSD_LITE_TURN_TIMEOUT` | 1 ターンの制限秒数（既定: 3600、両エンジン共通） |

Codex は `approval_policy=never` で実行し、コミットのために Git 管理ディレクトリを
`--add-dir` で渡す（linked worktree の共通 Git ディレクトリも含む）。
Claude の allowlist は使わない。親環境や組織ポリシーによる制限は引き続き適用される。
ネットワークアクセスが必要な調査・依存取得・push は、起動前に Codex の設定で
必要な権限を用意する。許可不足の場合はログと BLOCKED.md を確認する。

既存の Claude プロジェクトでは、Codex から `$gsd-lite-init` でスキルを追加・更新し、
ループ停止中に `engine` と `codex` 設定を追加してコミットする。
進行中の phase・turn・成果物は保持する。

仕様の参照: [OpenAI公式・非対話実行](https://learn.chatgpt.com/docs/non-interactive-mode)、
[スキル](https://learn.chatgpt.com/docs/build-skills)。

## ループ開始前に実行パターンを選ぶ

discuss の最後に、実行パターンを選んでからループを開始する。
対話するホストは自由で、Claude Code で仕様を詰めて Codex に実装させることもできる。

| パターン | 調査 | 計画 | 実装 | レビュー |
|---|---|---|---|---|
| すべて Claude | Claude | Claude | Claude | Claude |
| すべて Codex | Codex | Codex | Codex | Codex |
| 実装だけ Codex | Claude | Claude | Codex | Claude |
| レビューだけ Codex | Claude | Claude | Claude | Codex |
| 実装・レビューは Codex | Claude | Claude | Codex | Codex |

カスタム指定や、現在の設定を維持する選択も可能。
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

混在させる場合は `install.sh --engine all` で両方のテンプレートを導入する。
discuss が選択したエンジン用のプロジェクトスキルを配置する
（Claude: `.claude/skills/`、Codex: `.agents/skills/`）。
CLI の認証と権限も起動前に準備しておく。

```bash
gsd-lite-loop.sh --check    # 全フェーズのCLI・スキル配置を確認（変更・起動なし）
gsd-lite-loop.sh --status   # フェーズ別の実行先と進捗を表示
```

通常のループ起動でも実行前チェックを行う。後半で使うCLIやスキルが不足していれば
最初のターンより前に終了コード6で停止する。認証・通信の疎通確認は含まない。
ループ自体は対話せず、保存された組み合わせで毎ターン実行先を切り替える。
既存プロジェクトは再インストール後、init でスキルを更新すると選択手順が反映される。

## テスト

```bash
bash tests/run-tests.sh
```

Claude / Codex をスタブ化し、実モデルへの接続やトークン消費なしで検証する。

## リモート運用（MR/PR の作成手段）

`origin` があるプロジェクトでは、verify 合格時にローカルマージせず
**push + MR/PR 作成**で DONE になる（マージは人間 / CI に委ねる）:

- **GitHub**: `gh pr create`。事前にマシンごとに一度 `gh auth login` が必要
- **GitLab**: `glab mr create`（要 `glab auth login`）。**`glab` がなくても**
  push オプション `-o merge_request.create -o merge_request.target=<base>` で
  MR を作成する（GitLab サーバー側機能・追加ツール不要）
- CLI 不在・未認証などで作成できないときは push まで行って BLOCKED（人間が作る）
