---
name: gsd-lite-discuss
description: gsd-lite のディスカッションフェーズ。マイルストーンの仕様をユーザーと詰め切り、REQUIREMENTS.md / DECISIONS.md を確定してマイルストーンブランチを作成し、無人ループを起動する。対話セッション専用（ループからは実行されない）。
disable-model-invocation: true
---

# gsd-lite-discuss — 仕様を詰め切る（grilling × AskUserQuestion）

マイルストーンの仕様をユーザーと詰め切る対話フェーズ。ここが人間の判断を注入する
唯一の定常ポイントであり、以降の無人ループ（research → plan → impl → verify）の
品質はこのフェーズの網羅性で決まる。

引数があればそれがマイルストーンの初期要望。なければまず要望を聞く。

## ホストへの適応

- Claude Code は `/gsd-lite-discuss`、Codex は `$gsd-lite-discuss` で呼び出す。
- 以下の AskUserQuestion / AUQ は対話による確認を意味する。Codex では利用可能な
  質問ツールの制限に合わせて分割し、利用できなければ通常の対話で質問する。
  multiSelect がなければ複数項目をテキストで答えてもらう。
- state の `next_command` はエンジン共通で `/gsd-lite-...` のまま。
  ループが Codex のスキル参照へ変換する。
- state の `engine` とモデル設定を確認してから起動する。Codex のモデルは
  `codex.model.<phase>`、推論強度は `codex.reasoning_effort.<phase>`。
  空なら Codex CLI の設定を使用する。
- 次のマイルストーンに移るときも `engine` / `phase_engines` / `model` / `codex` は保持する。
- 監視用サブエージェントが利用できない場合は `gsd-lite-loop.sh --status` で
  確認する方法を案内する。

## 0. 進行中チェック → ブランチ整理 → 退避（この順で）

**0-0. 進行中チェック（ブランチを動かす前に最初に行う）**: 現在の
`.gsd-lite/state.json` を読む。`phase` が `done` / `discuss` 以外
（research / plan / impl / verify / blocked）なら**進行中のマイルストーンがある**。
ブランチの切り替えも退避もせず、ユーザーに状況を確認して指示を仰ぐ
（checkout してから確認すると、移動先の古い state を見て進行中を見逃す）。
`done` または初期状態のときだけ 0-a へ進む。

**0-a. ブランチ整理（archive より先に行う）**: いま前回の作業ブランチ（`gsd-lite/*`）に
いる場合（前回がリモート運用で MR 待ちのケース）は、state の `branch.base` へ
`git checkout` で戻る。リモート（origin）があれば `git pull --ff-only origin <base>` で
base を最新化する。**前回マイルストーンの MR が未マージ**（pull しても前回の成果が
base に含まれない）場合は、AUQ で「マージを待つ / 前回成果を含まない base のまま
進める」を確認する。

**0-b. 退避**: （base に移った後の）`.gsd-lite/state.json` の `phase` が `done` なら、
`.gsd-lite/` 直下の成果物（REQUIREMENTS / DECISIONS / RESEARCH / PLAN / PROGRESS /
VERIFICATION 等）を `.gsd-lite/archive/<前回のmilestone>/` へ移動し、state.json を
テンプレート初期値で作り直してから始める。`phase` が `discuss` 以外で done でもない
場合は進行中のマイルストーンがあるので、ユーザーに状況を確認する（勝手に上書きしない）。

## 1. プロトコル: デザインツリーとフロンティア

議論全体を**デザインツリー**として扱う。すべての決定は、その決定に依存する子の
決定を持つ（例: 「認証方式」が決まって初めて「セッション有効期限」を聞ける）。

- **フロンティア** = 前提がすべて確定済みで「今すぐ聞ける」質問の集合
- ラウンドごとにフロンティア全体を一度に問い、回答でツリーを更新し、
  新しく聞けるようになった質問で次のラウンドを組む
- 別の未回答質問に依存する質問は、同じラウンドに**入れない**（後のラウンドへ）

初期フロンティアの種（この 5 観点から始める）:
スコープ境界（やらないことの確認）/ 受け入れ基準 / 技術選定 /
既存コードとの整合 / エッジケース・異常系の扱い

## 2. AskUserQuestion でのラウンドの組み方

- フロンティアの質問を AskUserQuestion で提示する。1 回につき最大 4 問なので、
  フロンティアが大きい場合は影響の大きい順に複数回に分割してよい
  （同一ラウンド内の質問はすべて独立なので連続して聞ける）
- 各質問は **2〜4 個の選択肢 + 推奨を先頭に置き「(推奨)」を明記**。
  description にトレードオフを書く。「Other」は自動で付くので選択肢に含めない
- 排他的でない論点（対応したいエッジケース群など）は multiSelect にする

## 3. 事実と決定の分離

- **事実を調べるのは自分の仕事**: コードベースの現状・既存の規約・ライブラリの
  有無など、環境から調べられることをユーザーに聞かない。必要ならサブエージェントで
  調査し、調査中でも依存しない質問は先に聞く
- **決定はユーザーの仕事**: トレードオフのある選択は必ず AUQ で委ね、勝手に確定しない

## 4. インライン文書化

決定が確定するたびに、ラウンドの合間に**その場で**反映する（最後にまとめて書かない）:

- `.gsd-lite/REQUIREMENTS.md` — WHAT: 要求・受け入れ基準・スコープ外リスト・用語集
- `.gsd-lite/DECISIONS.md` — WHY: 選んだ案 / 検討して却下した案とその理由
  （ユーザーが Other で答えた文脈も残す）

用語の揺れに気づいたら、その場で正準の用語を確定して用語集に記録する。

## 5. 終了シーケンス

1. フロンティアが空になるまでラウンドを繰り返す
2. 仕上げチェック: 「plan フェーズのエージェントが新規コンテキストで REQUIREMENTS.md と
   DECISIONS.md **だけ**を読んで、ユーザーに質問せず計画を立てられるか」を自問し、
   足りなければフロンティアに戻す
3. 最終 AUQ で以下を確認する:
   - 確定内容サマリーへの合意
   - research の調査対象（similar_oss / official_docs / local_projects、
     multiSelect・デフォルト全選択）→ state.json の `research.targets` へ
4. **実行パターンを選ぶ（ループ起動前に毎回）**:
   - 対話しているホストと実行エンジンは独立。Claude Code から Codex に任せてもよい。
   - 現在の設定をフェーズ別に表示し、次のパターンを対話で選んでもらう。
     選択肢数の上限に合わせて「すべて同じ / 役割を分ける / 現在の設定を使う」
     → 具体的なパターンの順に分けてもよい。未回答のまま起動しない。
     初回の推奨は現在のホストで全フェーズ実行、既存設定があればその維持。
   - パターンと保存値（省略されるフェーズは `engine` を使用）:

     | パターン | engine | phase_engines |
     |---|---|---|
     | すべて Claude | claude | `{}` |
     | すべて Codex | codex | `{}` |
     | 実装だけ Codex、ほかは Claude | claude | `{"impl":"codex"}` |
     | レビューだけ Codex、ほかは Claude | claude | `{"verify":"codex"}` |
     | 実装・レビューは Codex、調査・計画は Claude | claude | `{"impl":"codex","verify":"codex"}` |
     | カスタム | 現在の既定値 | research / plan / impl / verify を個別に選択 |

   - プリセット選択時は `phase_engines` を表の値で**置き換える**。
     前回の割り当てを残さない。現在の設定を維持する場合だけ変更しない。
   - 各フェーズのエンジンとモデル（未指定なら CLI 既定）を一覧で提示する。
     モデル変更希望があれば Claude は `model.<phase>`、
     Codex は `codex.model.<phase>` / `codex.reasoning_effort.<phase>` に設定する。
   - **選択したエンジンの準備**: 現在のホストのインストール済みテンプレートを使い、
     Claude が含まれれば `.claude/skills/`、Codex が含まれれば `.agents/skills/` に
     5 スキルを配置する。既存スキルに独自変更があれば無断で上書きせず確認する。
     Claude が含まれる場合は Claude 用 init の allowlist マージ手順も行う。
     テンプレートがなければ `install.sh --engine all` を案内して準備完了まで待つ。
     Codex ホストのテンプレートに allowlist がない場合は
     `~/.claude/gsd-lite/templates/settings.allowlist.json` を使う。
   - どちらのホストでも、必要な CLI が PATH 上にあり、認証・権限が準備済みか確認する。
     `GSD_LITE_ENGINE` が設定されていれば**全フェーズを上書きする**ので、
     選択と違う場合はその変数を外した起動コマンドを使う（黙って無視しない）。
   - 決定を DECISIONS.md に記録し、state の `engine` / `phase_engines` を更新。
     同じ環境で `gsd-lite-loop.sh --check` を実行し、不足があれば起動せず解消する。
     このチェックは CLI / スキル配置 / git 識別 / Codex sandbox の実効性の検証で、
     認証や外部サービス疎通の保証ではない。Codex sandbox の検証で止まった場合は
     表示された対処（`GSD_LITE_CODEX_SANDBOX=danger-full-access` で起動、カーネル設定、
     impl / verify を Claude に切り替え）のどれにするかを AUQ で選んでもらい、
     環境変数で起動する場合は DECISIONS.md に記録して起動コマンドにも付ける。

5. **マイルストーンブランチ作成**（base の整理は手順 0-a で済んでいる前提）:
   - discuss で作成した要件・設定・スキル以外の未コミット変更を確認し、
     関係ない変更があれば扱いを相談する。今回生成したファイルは次のコミットに含める
   - 現在のブランチ（= base）名を控え、`git checkout -b gsd-lite/<slug>`
   - state.json を**すべて更新してから**コミットする: `milestone`（kebab-case の
     スラッグ）/ `branch`（name と base）/ `research.targets` / `phase: "research"` /
     `next_command: "/gsd-lite-research"` / `engine` / `phase_engines` / `updated_at`。
     そのうえで REQUIREMENTS.md / DECISIONS.md / state.json と追加・更新したスキル・設定を一括コミット
     （`gsd-lite(discuss): <slug> 要件確定`）。
     **遷移（next_command）までコミットに含めるのが重要** — コミット後に state を
     いじると、git 復元時に要件確定済みなのに DISCUSS へ戻ってしまう
6. 最後の AUQ で「今すぐループを起動するか」「起動する場合、このセッションで
   進捗を見守るか」を確認する:
   - **起動する**: `setsid gsd-lite-loop.sh > .gsd-lite/logs/loop.log 2>&1 &` で
     デタッチ起動し、`gsd-lite-loop.sh --status` などの監視コマンドを提示して
     **即座に手を離す**。以後このセッションでログをポーリングしない
   - **見守る**: バックグラウンドのサブエージェントを 1 体起動する。指示は
     「.gsd-lite/state.json の phase の変化と loop.pid の消滅を Bash の
     until ループで待ち、変化のたびに 1 行（例: `research → plan (turn 3)`）、
     終了時に最終状態を報告して終わる。ログ全文は読まない。
     state の複数フィールドは 1 回の jq でまとめて読むこと
     （別々に読むとターン更新中の値が混ざる読み取りレースがある）」
   - **自分で起動する**: 起動コマンドを提示して終了

## 起動後の中断・再開の案内

起動時には次の操作も案内する:
- 別ターミナルの `gsd-lite-loop.sh --stop` で現在のタスク終了後の中断を依頼できる。
- `gsd-lite-loop.sh --status` で依頼・稼働状態を確認する。
- 再開は `gsd-lite-loop.sh`。排他取得後に前回のフラグを消し、保存された次のタスクから続ける。
- 中断は終了コード7で、phase / next_command は維持される。
  中断からの再開に discuss のやり直しや state の初期化は不要。
