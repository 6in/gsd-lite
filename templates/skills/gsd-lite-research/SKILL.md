---
name: gsd-lite-research
description: gsd-lite のリサーチフェーズ（無人ループから Claude Code / Codex / OpenCode で起動）。discuss の決定を類似 OSS・公式ドキュメント・過去プロジェクトの調査で補強し、RESEARCH.md を産出する。
disable-model-invocation: true
---

# gsd-lite-research — 要件を事実で補強する（無人ターン）

これは無人ターン。**ユーザーに質問できない**。discuss の決定を事実で補強するのが
役目で、要件を書き換える権限は原則ない。成果は RESEARCH.md に集約して plan に渡す。

## 作業場所の解決（最初に 1 回。全エンジン共通）

最初の Bash で **`gsd-lite-loop.sh --where` を 1 回だけ実行**し、出力を読む:

```
mode=control            # in-repo | control
milestone_dir=.gsd-lite/milestones/<slug>   # 以下「$MS」と書く場所。in-repo 形では .gsd-lite
state=.gsd-lite/milestones/<slug>/state.json
target=work/<name>      # 以下「$TARGET」と書く場所。in-repo 形では .
slug=<slug>
agentmem=on             # on | off（achat を使えるか。下の「achat」の節）
agentmem_servers=agentmem agentmem-gsd   # このターンにつながっている achat の MCP サーバー
```

**以降のコマンドでは、この出力の値をそのままリテラルで書く**（例: `cat .gsd-lite/milestones/todo-mvp/PLAN.md`、
`git -C work/todo-cli status`）。本文の `$MS` / `$TARGET` は「ここに --where の値を書く」という印であり、
シェル変数として使わない。Bash ツールはコール間でシェル変数を保持せず、環境によってはコマンド書き換えの
フックが `$VAR` を空にするため、`MS=...; ...` と変数に入れてから使う書き方は失敗する。

- `$MS` = マイルストーンディレクトリ。state.json と成果物（REQUIREMENTS / DECISIONS / RESEARCH / PLAN /
  PROGRESS / VERIFICATION / BLOCKED）はここ。従来の in-repo 形では `.gsd-lite/` そのもの。
  制御リポジトリ（gsd-control）形では `.gsd-lite/milestones/<slug>/`（slug は今いる制御ブランチ `gsd-lite/<slug>`）
- `$TARGET` = コードを書く対象リポジトリ。`.` なら今いるリポジトリ（従来どおり）。`work/<name>` なら
  gsd-control 形で、**コードの読み書き・テスト・コミット・ブランチ・マージ・push は `git -C <target>` /
  `cd <target>` で対象側に**、**`$MS/` の成果物と state.json はこのリポジトリ（制御側）に**コミットする。
  対象側の指示ファイルと README は自動では読み込まれないので、最初に `<target>/AGENTS.md`（全エンジン共通の本体。
  無ければ `<target>/CLAUDE.md`）を読んで規約に従う。CLAUDE.md の `@AGENTS.md` より下は Claude 固有の指示。`<target>` の中身を制御側に `git add` しない（gitignore 済み）
- `.gsd-lite/logs/` と `.gsd-lite/reflect/` はどちらの形でも共通の場所（マイルストーンをまたいで蓄積）。
  一時ファイル（プローブ用スクリプト等）が必要なら `/tmp` ではなく `.gsd-lite/logs/<slug>/scratch/` に置く
  （`/tmp` への書き込みは allowlist 外で権限拒否になる。logs/ は gitignore 済み）
- 環境メモ: lean-ctx 等の MCP ツールが未接続でも通常のツールで進めてよい。未接続であることは
  PROGRESS の「想定外」に書かなくてよい（毎ターン同じ行が並ぶだけで振り返りの材料にならない）
- achat（agentmem MCP）: `--where` の `agentmem=on` のときだけ、下の「achat」の節に従って使う。`off` なら
  achat には触れず、そのことを PROGRESS に書かない。`on` でもツールが見えない・エラーになる（AM001 = トークン、
  接続できないなど）なら、そのターンは achat なしで進める。**achat が原因で BLOCKED にしない**

## achat（`agentmem=on` のときだけ）

achat は作業の記録・記憶・掲示板を持つ MCP サーバー。ループがこのターンにつないでいる（`agentmem_servers=` の名前だけ）:

| サーバー | achat の project | 書くもの |
|---|---|---|
| `agentmem` | このリポジトリの project | このリポジトリ固有の作業記録・記憶 |
| `agentmem-gsd` | gsd-lite を使う全リポジトリで共有 | gsd-lite・エンジン・CLI の挙動のように、どのリポジトリでも効く学び |

掲示板と作業記録は project の中でしか検索できないので、読むときは両方を引く。正本は git（PROGRESS / RESEARCH /
VERIFICATION / reflect / AGENTS.md）で、achat は横断検索と共有の層。achat にだけ書いて済ませない。

- **文脈**: `set_context` は、repo / branch が要る操作（`remember` の repo・branch、`scope=repo` の検索・投稿）の前に、
  そのサーバーで 1 回だけ呼ぶ。`repo_url` は `git -C $TARGET remote get-url origin` の出力（origin が無ければ repo
  範囲の操作はしない）、`base_path` は `$TARGET` の絶対パス、`branch` は state の `branch.name`、`client_session_id` は
  `gsd-lite/<slug>/<phase>/turn-<N>`（N はこのターンで +1 した後の turn）
- **本文は要約だけ**: PROGRESS・ログ・diff・コマンドの出力をそのまま貼らない。トークン・パスワード・顧客名・個人名を
  書かない（本文は埋め込みのために外部の API に送られ、project のメンバー全員に見える）
- **エラー**: `AM011` は、エラーに出た項目名と制約を読んで 1 回だけ直して再試行する。だめならそのまま先へ進む
- **`rate_thread` は使わない**（無人ターンの評価は、verified の判定に要る「投稿者以外の 2 人」を本人の名前で使ってしまう）
- **このフェーズ**: 読むだけで書かない。手順 2 の `agentmem` を参照

## 手順

1. `$MS/state.json` / `REQUIREMENTS.md` / `DECISIONS.md` を読む。既存コードとの整合を見るときの
   コードベースは `$TARGET` 配下（`$TARGET/AGENTS.md`、無ければ `CLAUDE.md` を先に読む）
2. `state.json` の `research.targets` にある対象だけを調査する:
   - `similar_oss`: 同じ課題を解く既存 OSS・プロダクト・記事を Web 検索。
     「作らなくてよいもの」と「盗める設計」を探す
   - `official_docs`: 採用技術の公式ドキュメント・ベストプラクティス・既知の
     落とし穴を調査し、plan の技術前提を固める
   - `local_projects`: `research.local_search_paths` 配下の過去プロジェクトから
     同型の実装・雛形を探す（パス付きで記録）
   - `agentmem`: achat の過去の知見（上の「achat」の節。`agentmem=off` なら調べず、RESEARCH.md に
     「achat 未接続のため調べていない」と 1 行書く）。両方のサーバーで `search_board` を、主題・採用技術・懸念点を
     クエリにして 2〜4 回引く。`agentmem` では `search_tasks`（scope `project`）と `recall` も引く。
     `local_projects` と違い、他の人・他のマシンの作業まで届く
3. `$MS/RESEARCH.md` に産出:
   - 参考実装（ローカルパス / URL 付き）
   - 盗める設計・使えるライブラリ
   - 落とし穴と回避策。**各項目に「どう検証すれば踏んでいないと分かるか」**（テストの観点・
     境界値・並行時の観測方法）を添える。plan はこれを完了基準に写す。
     タスク単体のテストで拾いにくい種類（並行性・境界値・暦の端（DST・曜日・月末）・契約外の
     エラー漏れ・権限）は意識して探す
   - 要件への影響（受け入れ基準に足すべき観点があれば**提案として**記載。
     REQUIREMENTS.md 本文は書き換えない）
   - `agentmem` を調べたら「## achat の過去知見」: 使えるものだけを、thread_id / タスクの title 付きで要約し、
     今回どう効くか（落とし穴なら上と同じく検証方法も）を書く。status が `obsolete` のものや、versions が今と違うものは
     外すか、そう明記する
4. **重大発見の扱い**: discuss の決定を覆しうる発見（例: 要件をほぼ満たす既存 OSS が
   あった）は、要旨と選択肢+推奨を `$MS/BLOCKED.md` に書いて BLOCKED で停止する
   （下記手順で `next_command: "BLOCKED"`）。「作るか使うか」は投資判断なので人間に戻す。
   覆さない発見は RESEARCH.md に記録して続行
5. 正常終了時は `phase: "plan"` / `next_command: "/gsd-lite-plan"` にする

## ターン終了の共通手順（必須・この順で）

1. `$MS/PROGRESS.md` に追記（**固定項目**。reflect フェーズの材料になるので、想定外と
   やり直しは正直に書く。なければ「なし」「0 回」と書く。`<N>` は**このターンで +1 した後の
   `state.turn`**（= ループが `turn N [...]` と表示する番号、research が turn 1）。
   やり直しの原因が次のターンでも起こり得るなら、**同じ内容を「次への注意」にも書く**）:
   ```markdown
   ## turn <N> — research — <調査の要約>
   - やったこと: <1〜2 行>
   - 想定外: なし | <想定と違ったこと、ハマったこと>
   - やり直し: 0 回 | <N 回（何を・なぜ）>
   - 次への注意: <次のターンへの申し送り>
   ```
2. `state.json` を更新: `next_command` と `phase` を上記のとおり、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**時刻は `date -Iseconds` を実行した出力をそのまま書く**（見積もりや丸めた値を書かない。ループはコミット時刻より先の値を警告する）。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
3. 成果物・PROGRESS.md・state.json を**まとめて git commit**（`gsd-lite(research): <要約>`）。
   **state 更新 → commit の順序が重要**: 逆にすると最終 state が未コミットで残り、
   git からの復元時に完了済みフェーズを再実行してしまう
4. 判断に迷ったら推測しない: `$MS/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
   `next_command: "BLOCKED"` / `phase: "blocked"`（turn は +1）にしたうえで
   同様にコミットして終了する

## 無人ターンのシェルの作法（承認待ちで止まらないために）

無人ターンは承認プロンプトに応答できない。allowlist に当たらない形のコマンドは止まり、
ターンが無進捗で終わる。次の形を守る:

- 1 回の Bash 呼び出しに 1 コマンドだけ書く。`;` / `&&` の連結、サブシェル、`$(...)`、
  先頭の変数代入（`FOO=1 make ...`）を使わない（パイプ `|` は両側が allowlist にあるときだけ）。
  環境変数が要るなら `--env-file` など引数で渡す
- コミットメッセージは一時ファイルに書いて `git commit -F <file>` で渡す（`-m "$(...)"` は使わない）
- 一時ファイルは `.gsd-lite/logs/<slug>/scratch/` に置き、名前に turn 番号を入れる
  （例 `turn-012-commit-msg.txt`。前のターンや前のマイルストーンのファイルを使い回さない）。
  `mktemp -d` で作ったディレクトリはそのターン内で消す
- 作業ディレクトリの外へは書かない（証跡は `.gsd-lite/` 配下に置く）
