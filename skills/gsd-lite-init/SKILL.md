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

以下のパス例は Claude 用。Codex では上表の対応先に読み替える。
Codex の質問は利用可能な質問ツールを使い、なければ通常の対話で聞く。
Claude の AskUserQuestion や allowlist を Codex に要求しない。

## 手順

1. **前提確認**:
   - カレントがプロジェクトルートであること（ユーザーに一言確認してよい）
   - git リポジトリであること。違えば `git init` を提案して実行
   - `jq` と `gsd-lite-loop.sh`（PATH 上）が使えること。なければ導入方法を案内して中断
2. **既存チェック**: `.gsd-lite/state.json` が既にあればセットアップ済み。その場合は
   AskUserQuestion で「**スキル・allowlist を最新テンプレートに更新するか**」を確認する:
   - 更新する → `.claude/skills/gsd-lite-*` をテンプレートで上書きし、allowlist の
     不足エントリをマージして、その変更だけをコミット（`gsd-lite: update skills`）。
     **`.gsd-lite/` には一切触れない**（進行中マイルストーンを壊さない）
   - 更新しない → 何もせず終了
   （gsd-lite 本体を更新した後、既存プロジェクトに反映するのはこの手順。
   install.sh はテンプレートを更新するだけで、配布済みプロジェクトには届かない）
   Codex への追加導入でもスキル更新は可能。既存 state の engine / model は変更しない。
   エンジン切り替えを依頼された場合だけ、ループ停止中に `engine: "codex"` を設定し、
   `codex.model` / `codex.reasoning_effort`（未設定なら空オブジェクト）を追加して
   別途コミットする。既存の phase・turn・成果物・Claude 用 model は保持する。
3. **足場生成**:
   - `mkdir -p .gsd-lite/logs .gsd-lite/hooks .gsd-lite/archive`
   - `~/.claude/gsd-lite/templates/state.json` → `.gsd-lite/state.json`
     （`updated_at` を現在時刻に）
     Codex では `engine: "codex"` を確認。モデル未指定なら CLI の既定値を使う。
     指定があれば `codex.model.<phase>` と `codex.reasoning_effort.<phase>` に設定する。
   - `~/.claude/gsd-lite/templates/PLAN.template.md` → `.gsd-lite/PLAN.template.md`
   - `~/.claude/gsd-lite/templates/skills/` 配下 5 スキル → `.claude/skills/`
4. **allowlist マージ**: `~/.claude/gsd-lite/templates/settings.allowlist.json` の
   `permissions.allow` を `.claude/settings.json` にマージする（`_comment` キーは
   持ち込まない）。既存の settings.json がある場合は既存エントリを壊さず追記。
   このプロジェクトのテストランナー・パッケージマネージャ（npm / pytest / cargo 等）を
   確認し、該当する `Bash(...)` 許可を足す
   **Codex ではこの手順をスキップ**。ループは workspace-write sandbox と
   approval_policy=never で動き、コミット用に Git 管理ディレクトリを追加する。
   ネットワークや追加パスなど必要な権限は起動前に環境側で用意する。
5. **.gitignore**: `.gsd-lite/logs/` と `.gsd-lite/loop.pid` を追記（なければ作成）
6. **コミット**: 現在のブランチ（= 以後の base ブランチ）に
   `gsd-lite: scaffold` としてコミット
7. **案内**: 「次は同じセッションで `/gsd-lite-discuss <やりたいこと>`」と伝えて終了
