# 変更履歴

gsd-lite の利用者から見た変更を、新しい順に記録する。バージョン番号は付けていないので、`main` に入った日付で区切る。
各項目の詳細は README / `docs/SPEC.md` と、括弧内のコミット（マージ）を参照。

- 書き方: 変更を `main` に入れるときに、その日付の見出しの下へ「追加 / 変更 / 修正」に分けて 1 項目ずつ足す
- 反映: ループ本体（`bin/gsd-lite-loop.sh`）の変更は `install.sh` で入れ直し、ループを再起動したときから効く。
  スキル・雛形の変更は、既存プロジェクトでは `gsd-lite-init` のスキル更新モードで取り込む

## 2026-11-01

### 追加
- **achat（agentmem MCP）との連携**（任意）。state の `agentmem`（`url` / `project` / `shared_project`）と環境変数
  `AGENTMEM_TOKEN` があるターンにだけ、ループが MCP サーバー `agentmem`（対象リポジトリの project）と `agentmem-gsd`
  （gsd-lite を使う全リポジトリで共有する project）をエンジンに渡す。Claude は `--mcp-config`、Codex は `-c mcp_servers.*`
  （承認なしで呼べるよう `default_tools_approval_mode="approve"`）、OpenCode は `OPENCODE_CONFIG_CONTENT`。トークンの値は
  どの設定にも書かない（Issue #2）
- スキルが achat を使う: discuss は過去の知見を引いて質問の材料にし、採った決まりを記憶に残す。research は調査対象
  `agentmem`（RESEARCH.md の「achat の過去知見」）。impl / verify は作業記録（`record_task`）。reflect はマイルストーンの
  作業記録、AGENTS.md 候補の記憶、ほかのリポジトリでも効く学びを共有側の掲示板へ（3 件まで。近いスレッドがあれば追記）。
  どれも `--where` の `agentmem=on` のときだけで、achat が使えなくても BLOCKED にしない（Issue #2）
- `--check` / `--status` の `agentmem` 行。`--check` と起動時は、値の形の誤りで止め、トークン無し・achat に届かない
  （`/healthz`）・achat のフックが無人ターンでも動く形のときは WARN だけ出す（Issue #2）
- ターンの環境に `GSD_LITE_UNATTENDED=1`（無人ターンでだけ止めたいフックの目印）。`--where` の `agentmem=` /
  `agentmem_servers=`、`turns.jsonl` の `agentmem`（Issue #2）
- allowlist の雛形に `mcp__agentmem` / `mcp__agentmem-gsd`（Issue #2）

## 2026-10-28

### 追加
- **Claude の接続先をフェーズごとに変える**（任意）。`state.json` の `claude.provider.<phase>` にプロファイル名を書くと、
  そのフェーズの Claude のターンだけを `~/.config/gsd-lite/providers/<名前>.json` の設定（`env` / `secret_env` /
  `model` / `limit_pattern`）で起動する（例: impl だけ Bedrock・他社の Anthropic 互換 API）。親環境の認証・接続先の
  変数は外し、トークンの切り替えは使わない。キーの値は環境変数で渡し、プロファイルには変数名だけを書く。
  `--check` / `--status` に `provider` 行、`turns.jsonl` に `provider`。サンプルは `templates/providers/`
  （`bedrock.json` / `anthropic-compatible.json`）。discuss が必要なときに選んで state に保存する

## 2026-10-23

### 追加
- **Codex の sandbox を `state.json` の `codex.sandbox` に保存する**。優先順位は `GSD_LITE_CODEX_SANDBOX` → `codex.sandbox`
  → `workspace-write`。discuss が選び、次のマイルストーンにも引き継がれる（起動コマンドの環境変数を付け忘れて、
  verify が Docker を使えずに BLOCKED になったため）。`--status` / `--check` の `sandbox` 行と loop.log の開始行に
  実効値を出し、環境変数が state と食い違えば WARN（Issue #1）
- **BLOCKED の通知フック**: このループのターンで BLOCKED になったとき（auto-BLOCKED とエージェントが書いた BLOCKED）と、
  ループ開始後の前提エラーで止まったときに、`.gsd-lite/hooks/on-blocked.sh` と `GSD_LITE_ON_BLOCKED`（マシン共通の
  スクリプトのパス）を `<BLOCKED.md のパス> <理由の 1 行> <終了コード>` で呼ぶ。サンプルは `templates/hooks/on-blocked.sh`
  （ntfy / Slack / メール / デスクトップ通知）。`--status` / `--check` の `notify` 行に通知先を出す（無ければ `none`）（Issue #1）
- discuss は前回の DECISIONS にある環境変数付きの起動コマンドを見せ、state に移せるものは移し、残りを今回も付けるか確認する。
  `notify` 行が `none` なら BLOCKED の通知をどうするか聞く（Issue #1）
- `turns.jsonl` の `segments`（そのターンの `result` の数）
- **エージェント向けの指示ファイルの方針**（`docs/agent-instructions.md`）。AGENTS.md を全エンジン共通の本体にし、
  CLAUDE.md は 1 行目の `@AGENTS.md` で取り込む組を推奨する（Claude Code は CLAUDE.md、Codex は AGENTS.md しか
  自動で読まないため）
- **init が指示ファイルの組を整える**（in-repo 形）。どちらも無ければ組を作り（雛形 `templates/AGENTS.template.md`）、
  AGENTS.md だけなら CLAUDE.md を足す。CLAUDE.md だけ・取り込み行が無い・シンボリックリンクのときは直し方を
  提案し、承認されたときだけ直す。スキル更新モードでも確認する
- **`--check` と起動時に指示ファイルの組を警告**（止めない）。Codex のフェーズがあるのに CLAUDE.md しか無い /
  Claude のフェーズがあるのに CLAUDE.md が `@AGENTS.md` を取り込んでいない・CLAUDE.md が無い / CLAUDE.md が
  シンボリックリンク。`GSD_LITE_INSTRUCTIONS_CHECK=skip` で省略
- reflect は「次回への提案」のうち繰り返し効く作業上の決まりに `（AGENTS.md 候補）` と付け、discuss がそれを
  採否確認して AGENTS.md に足す（採否は DECISIONS.md。gsd-control 形では対象側のマイルストーンブランチにコミット）

### 変更
- 各フェーズのスキルは規約を AGENTS.md（無ければ CLAUDE.md）から読む。plan は AGENTS.md を書き換えない
- Codex sandbox の検証で止まったときの案内は、環境変数ではなく state の `codex.sandbox` を勧める

### 修正
- バックグラウンド実行の完了通知で再開した Claude のターンで、`turns.jsonl` の `usage` / `num_turns` /
  `permission_denials` が最後の区間だけになっていた。全区間を合計・連結して記録する（`cost_usd` は従来どおり累積値）。
  PROGRESS への承認待ちの追記も全区間の件数になる（Issue #1）
- ループ開始後の前提エラー（対象のブランチ違い等で終了コード 6）で `on-exit.sh` が呼ばれていなかった

## 2026-10-20

### 追加
- **トークンを使用率で選ぶ**（`GSD_LITE_TOKEN_PICK`、既定 `usage`）。`GSD_LITE_CLAUDE_TOKEN_VARS` のトークンから、
  利用枠の使用率（5 時間枠と 7 日枠の大きい方。リセット済みの枠・記録なしは 0）が最も低いものを選ぶ。
  同率なら従来の順番。`round-robin` で従来どおり順番に回す（!4, `78278b2`）
- **トークンの利用枠の共有ファイル**（`GSD_LITE_TOKEN_LIMITS`、既定 `~/.local/state/gsd-lite/token-limits.json`）。
  Claude のターンごとに、変数名をキーに使用率・リセット時刻・最後に使ったプロジェクトを書く（値は書かない）。
  同じマシンの全プロジェクトのループが互いの消費を見て選ぶ（!4）
- **`gsd-lite-loop.sh --tokens`**: 各トークンの使用率とリセットまでの時間を表で表示する。どのディレクトリからでも
  実行できる（!4）
- `turns.jsonl` の `rate_limit` に枠ごとのリセット時刻（`five_hour_resets_at` / `seven_day_resets_at`）（!4）

### 変更
- **利用上限に当たったら待たずに次のトークンへ**。トークンを切り替えているとき、上限で無進捗に終わったターンは
  `GSD_LITE_LIMIT_WAIT` 秒待たずに次のトークンでやり直す。全トークンが続けて上限に当たったときだけ待ち、
  その待機回数を `GSD_LITE_LIMIT_MAX` と比べる（!3, `c06da96`）
- `--status` の token 行に選び方（`pick: usage` / `round-robin`）を表示する（!4）

## 2026-10-18

### 追加
- **ループのメモリと CPU に上限を付ける**（`GSD_LITE_MEMORY_MAX` / `GSD_LITE_CPU_QUOTA` / `GSD_LITE_MEMORY_SWAP_MAX`）。
  設定するとループは自分を `systemd-run --user --scope` の中で起動し直し、ターンの CLI・テスト・ビルドを含めて
  上限を付ける。swap の既定は 0。効かない環境では警告して上限を外して続行する。`--status` / `--check` に limits 行（`f2f4e0e`）
- 上限を discuss で選び、`state.json` の `limits` に保存する。優先順位は 環境変数 → `state.limits` → なし（`a681e78`）

## 2026-10-12

### 追加
- 承認待ち（権限拒否）のあった進んだターンは、`PROGRESS.md` の末尾に件数と要約を追記してコミットする（`7c717e6`）

### 変更
- `--status` の verify 行で `verify_round` を差し戻し回数として表示する（`7c717e6`）

## 2026-10-05

### 修正
- allowlist の雛形に `gsd-lite-loop.sh --where` を追加。無人ターンで権限拒否になり BLOCKED になっていた（`2831f7a`）

## 2026-10-04

### 追加
- Claude Code のプラグイン（マーケットプレイス）として入れられるようにした。`install.sh --skip-init-skill`（`ebe83c4`）

## 2026-10-03

### 追加
- Claude のターンを stream-json で起動し、トークン量・コスト・権限拒否・利用枠の使用率を `turns.jsonl` に記録する。
  `--status` に usage 行、`--watch` はイベント列を整形表示。`GSD_LITE_CLAUDE_STREAM=off` で従来の平文だけ（`a216c78`）
- 利用上限（session / usage / rate limit）で無進捗に終わったターンは retry を増やさず待って再試行する
  （`GSD_LITE_LIMIT_WAIT` / `GSD_LITE_LIMIT_MAX` / `GSD_LITE_LIMIT_PATTERN`）（`9eefe3a`）
- `updated_at` がコミット時刻より 5 分以上先なら警告する（`9eefe3a`）

### 変更
- reservation-component の 7 マイルストーンからの改善案（各フェーズのスキルの作法、allowlist の追加）を取り込んだ（`9eefe3a`）
- allowlist の雛形で `mcp__lean-ctx` を deny し、init のマージで deny も取り込む（`a216c78`）

## 2026-09-26 〜 2026-09-27

### 追加
- **gsd-control（制御リポジトリ方式）**。`state.target.path` で「コードを書く対象」を指し、state と成果物は
  制御リポジトリ、コードは対象リポジトリに置く（`a74ef7f`）
- `gsd-lite-loop.sh --where`（作業場所を key=value で表示）（`25b4560`）
- Claude Code の trust 検証（`GSD_LITE_CLAUDE_TRUST_CHECK`）。未 trust だと allowlist が無視されるため `--check` で止める（`25b4560`）
- **reflect フェーズ**（PMI 形式の振り返り）、修正ラウンド（`state.fix_round`）、手動 `/gsd-lite-reflect`（`3d47075`）
- ループが 1 試行ごとの計測値を `logs/<milestone>/turns.jsonl` に追記する（`3d47075`）

### 変更
- init を高速化（テンプレートを読まず 1 回の Bash で足場生成）（`3d47075`）
- `verify_round_max` の既定を 2 → 3（`25b4560`）
- 起動時に日時・pid・mode の開始行を出す（`25b4560`）

## 2026-09-24 〜 2026-09-25

### 追加
- **OpenCode をエンジンに追加**（`install.sh --engine opencode / all`）（`d19bbdb`）
- `gsd-lite-loop.sh --watch` / `--watch-once`（進捗・PLAN のタスク・実行中ログを再描画する簡易 TUI）（`062aad4`）
- **Claude のトークンを組織ごとに切り替える**（`GSD_LITE_CLAUDE_TOKEN_VARS`）（`2133acd`）
- サブエージェントによる並列実装・並列レビュー（`state.subagents`、既定 `auto`）（`1b06de5`）

### 変更
- 既定モデルを research / plan / verify = fable-5-1、impl = opus-5 に変更（`647b835`）

## 2026-09-14 〜 2026-09-17

### 追加
- **Codex をエンジンに追加**し、スキルをインストールできるようにした（`f5cab01`）
- ループ開始前にフェーズごとの実行パターンを選ぶ（`bcc4d0f`）
- `--stop` でターン境界で中断し、次の起動で再開する（`ced1d89`）
- `--check` で Codex sandbox の実効性と git の識別（user.name / email）を事前検証する（`8ef7d56`）

### 変更
- plan のタスク粒度を「まず分割して洗い出し、その後 8〜15 に統合」の 2 段階にした（`f447410`）

## 2026-09-09

### 追加
- **初版**: `next_command` を実行するだけのダムループ、6 つのスキル（init / discuss / research / plan / impl / verify）、
  雛形、スタブによるドライランテスト（`3b6d23f`）
- verify の完了処理をリモートの有無で分岐（ローカル = 自動マージ / リモート = push と MR/PR 作成。
  GitLab で glab が無ければ push オプションで MR を作る）（`3a36d74`, `ede7c3f`）

### 修正
- Codex による敵対的レビュー 3 ラウンドの指摘（計 19 件）を修正。進捗判定を「コミット済みの state だけ」に統一、
  排他を flock に置換、ターンのタイムアウト（`GSD_LITE_TURN_TIMEOUT`）、max_turns の実行前判定など
  （`2506442`, `cfde54f`, `ebfa7f2`）
