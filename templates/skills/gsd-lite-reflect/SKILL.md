---
name: gsd-lite-reflect
description: gsd-lite の振り返りフェーズ（verify 合格後に無人ループから起動。手動でも呼べる）。記録（PROGRESS / turns.jsonl / git log / PLAN / VERIFICATION）だけを根拠に PMI（Plus / Minus / Interesting）形式の振り返りを .gsd-lite/reflect/ に書き、次回への提案を残す。
disable-model-invocation: true
---

# gsd-lite-reflect — 記録に基づく振り返り（PMI）

これは新規コンテキストで動く。**作業の記憶はない**。あるのは記録だけなので、
記録から言えることだけを書く。記録にないことは書かない。推測は「推測:」と明記する。
Minus と Interesting の各項目には**根拠**（ターン番号 / コミット / ファイル名）を必ず添える。

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
- **このフェーズ**: 下の「achat に残す」

## 2 つの呼ばれ方

| 状況 | 判定 | ふるまい |
|---|---|---|
| ループから | `state.json` の `phase` が `reflect` | 振り返りを書き、state を DONE にしてまとめてコミット（下の共通手順） |
| 手動（`/gsd-lite-reflect`、Codex は `$gsd-lite-reflect`） | `phase` が `done`（または reflect 以外） | 追加の振り返りを書き、**ファイルと PROGRESS.md だけ**をコミット。state の `phase` / `next_command` / `turn` には触らない |

手動のときは「対象範囲」を前回の振り返り以降のコミット（`<前回の head>..HEAD`）にする。
前回の振り返りがなければマイルストーンブランチ全体（`branch.base...HEAD`）。範囲は対象リポジトリ
（`git -C $TARGET`）のコミットで数える。

## 読む記録（この順で。全部読んでから書く）

1. `$MS/state.json`: milestone / branch / turn / verify_round / fix_round /
   engine / phase_engines / model・codex・opencode / subagents / limits
2. `.gsd-lite/logs/<milestone>/turns.jsonl`: ループが 1 試行ごとに記録した客観データ
   （phase / engine / model / attempt / 所要秒 / rc / progressed / commits。gsd-control 形では
   対象側に増えたコード側のコミット数 `target_commits` も）。エンジンが報告したターンには
   `usage`（`input_tokens` / `output_tokens` / `cache_read_input_tokens` / `cache_creation_input_tokens`。
   Codex は `total_tokens` だけ）/ `cost_usd` / `num_turns` / `permission_denials`（承認待ちで拒否された
   ツール名）/ `permission_denial_heads`（ツール名 ＋ Bash ならコマンドの先頭 1 語）/ `permission_denial_inputs`（入力の先頭）/
   `rate_limit`（利用枠の使用率）、`agentmem`（そのターンにつないだ achat のサーバー。つながなかったターンには無い）も入る。無い行は「記録なし」として扱い、推定で埋めない。
   バックグラウンド実行の完了通知で再開したターンは、ループが全区間を合計して記録し、`segments` に区間数を残す
   （`segments` が無い行は 2026-10-23 より前の記録で、`usage` / `num_turns` / `permission_denials` が最後の区間だけの
   ことがある。`cost_usd` は当時から全区間の累積）。`segments` が無い行の過小な値を「作業量が少ない」根拠にしない
   **承認待ちの件数は turns.jsonl の `permission_denials` を正とする**。ループは 1 件以上あった進んだターンについて
   PROGRESS の末尾に `- 承認待ち（ループ計測・turn N）: K 件 — …` を追記してコミットする（`gsd-lite(loop):`）。
   エージェントの自己申告と食い違うのは、サブエージェントの分や失敗した試行の分が自己申告に入らないためで、指摘の対象にしない
   ここから**フェーズ別の所要時間・リトライが起きたターン・無進捗の試行**を集計する。
   `jq` でまとめて読む（例: `jq -s 'group_by(.phase) | map({phase: .[0].phase, turns: length, sec: (map(.duration_s) | add), retries: map(select(.attempt > 1)) | length, out_tokens: (map(.usage.output_tokens // 0) | add), cache_read: (map(.usage.cache_read_input_tokens // 0) | add), cost_usd: (map(.cost_usd // 0) | add), denials: (map(.permission_denials // []) | add | group_by(.) | map("\(.[0]) x\(length)"))})'`）。
   `permission_denials` が出ているターンは Minus の材料（allowlist に足すか deny するかを提案に書く）
3. `$MS/PROGRESS.md`: 各ターンの申し送り（やったこと / 想定外 / やり直し / 次への注意）。
   「想定外」と「やり直し」の欄が Minus の主材料
4. `git -C $TARGET log --format='%h %ad %s' --date=iso <branch.base>...HEAD`（または対象範囲）と
   `git -C $TARGET diff --stat <範囲>`: コミットの粒度、`F1` 等の差し戻し修正、BLOCKED からの再開、
   人間の介入コミット。gsd-control 形では制御側の `git log --oneline -- $MS` も読む
   （state・成果物のコミット列 = ターンの列。対象側のコード履歴と突き合わせる）
5. `$MS/PLAN.md`: 計画タスク数と実際の impl ターン数の差、追加・分割されたタスク、
   並列サブ作業が使われたか
6. `$MS/VERIFICATION.md`: verify の指摘と残留リスク。修正ラウンドなら
   「なぜ最初の verify で見つからなかったか」を考える
7. `git log --all --oneline -- $MS/BLOCKED.md` と各時点の内容: 何で止まり、
   人間がどう解決したか
8. `$MS/REQUIREMENTS.md` / `DECISIONS.md` / `RESEARCH.md`: 決定が守られたか、
   調査が計画に活かされたか（PLAN.md のメモが RESEARCH を参照しているか）
9. `.gsd-lite/reflect/` の既存ファイル（あれば直近 2 件）: 前回の「次回への提案」が
   今回守られたかを必ず確認する

`turns.jsonl` / `loop.log` / PROGRESS.md の見出しはいずれも「research = turn 1」の同じ番号を
使う（state.turn はそのターン完了後の値なので、ターン中に読むと 1 小さい）。
ターンログ（`turn-NNN-attemptN.log`）は最終出力しか含まないので、リトライが起きた
ターンだけ読めばよい（attempt2 以降のファイルがある turn）。全部は読まない。

## 書くもの

`.gsd-lite/reflect/<YYYYMMDD-HHMM>-<slug>.md`（`<slug>` は state の `milestone`。
`.gsd-lite/reflect/` がなければ作る）:

```markdown
# 振り返り — <slug>（<YYYY-MM-DD HH:MM>）

- 種別: ループ（verify 合格後） | 手動 | 修正ラウンド <fix_round>
- 対象範囲: <base>...<head>（コミット N 件）/ ターン <a>〜<b>
- 前回の振り返り: <ファイル名> | なし

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 4 | 0 | 3,200 | 410,000 | 0.42 | claude / ... |
| ... | | | | | | | | |

- 権限拒否（permission_denials）: なし | <ツール名 × 回数（どのターン）>

- 計画タスク数 / impl ターン数: N / M
- verify 差し戻し: verify_round 回（指摘 K 件）/ BLOCKED: 回数と原因の要約
  （`verify_round` は**差し戻しの回数**で、VERIFICATION の round 番号は「差し戻し ＋ 1」。合格した round = `verify_round + 1` なので
  「state 2 / VERIFICATION round 3」はずれではない。`fix_round` は discuss から始めた**人の修正ラウンド**の番号で、verify の差し戻しで
  足した F タスクでは増えない）
- 前回の提案の反映: 守られた / 守られなかった（どれが）

## Plus（うまくいったこと）

- <事実>（根拠: turn 3 / コミット abc1234 / PROGRESS の T2 の欄）

## Minus（問題・無駄・やり直し）

- <事実>（根拠: ...）— 原因の見立て（推測なら「推測:」）

## Interesting（気づき・意外だったこと）

- <事実>（根拠: ...）

## 次回への提案（実行可能な形で）

- [ ] <PLAN 粒度 / allowlist / スキル・テンプレート / discuss で聞くべきこと などの具体的な変更>
  （根拠になった Minus / Interesting）
- [ ] <どのエンジンにも守ってほしい作業上の決まり 1 行>（根拠: ...）（AGENTS.md 候補）

## achat への書き込み

- record_task: <id> | remember: <id>（<決まりの要約>）| スレッド: 新規 <thread_id> <題名> / 追記 <thread_id> <題名>
  （`agentmem=off` なら「achat 未接続」）
```

- 「次回への提案」は plan と discuss が読む。**具体的で、やるかどうかを判断できる粒度**で書く
  （「もっと注意する」は不可。「T3 のような DB マイグレーション込みタスクは 2 分割する」は可）
- 提案のうち、マイルストーンをまたいで**このプロジェクトで繰り返し効く作業上の決まり**（コマンドの呼び方、
  テストの走らせ方、触ってはいけないファイルなど。どのエンジンのターンにも守ってほしいもの）には、
  末尾に `（AGENTS.md 候補）` と付ける。discuss がそれを採否確認し、採ったものを対象の AGENTS.md
  （全エンジン共通の指示の本体）に足す。reflect 自身は AGENTS.md を書き換えない。既に AGENTS.md に
  書かれているのに守られなかった決まりは、候補にせず Minus に「AGENTS.md にあるが守られなかった」と書く
- 記録に矛盾があれば（PROGRESS が成功と言うが turns.jsonl は 3 試行など）それ自体を
  Interesting に書く
- 書けるほどの記録がない（PROGRESS が空、turns.jsonl がない等）場合は、その事実と
  「記録の不足」を Minus に書く。作文で埋めない

## achat に残す（`agentmem=on` のときだけ。振り返りファイルを書いた後、コミットの前に）

正本は振り返りファイル。achat には要約と、ほかのリポジトリでも効く学びだけを出す（上の「achat」の節の決まりに従う）。
手動で呼ばれたときも同じ。

1. `agentmem` の `record_task` を 1 回: title `<slug> マイルストーン完了`（手動なら `<slug> 手動振り返り`、修正ラウンドなら
   `<slug> 修正ラウンド <fix_round>`）、outcome `success`、summary に 何を作ったか / Plus と Minus の要点 / 次回への提案の要約、
   tags `["gsd-lite", "reflect", "<slug>"]`、`context` は「文脈」と同じ値
2. `（AGENTS.md 候補）` の提案を、`agentmem` の `remember` に 1 件ずつ: kind `lesson`、scope `repo`（先に `set_context`）、
   importance `3`。`duplicate_of` が返ったら内容を比べ、同じなら見送り、新しい方が正しければ `replaces_id` で置き換える
3. **ほかのリポジトリでも効く学び**を `agentmem-gsd` の掲示板に出す。対象は、このリポジトリのコードを知らなくても役に立つもの
   （gsd-lite のループ・スキルの癖、エンジンや CLI の挙動、allowlist・承認待ち、sandbox など）。**1 回の振り返りで 3 件まで**:
   - 先に `search_board` で探す。近いスレッドがあれば `add_supplement` で足す（別の環境で再現した・別の解決策があったなど）
   - 無ければ `set_context` で categories を得てから `create_thread`。kind は `trouble`（`symptom` / `cause` / `solution` /
     `environment`。environment にはエンジンと CLI のバージョン）か `tip`（`content` / `applies_when`）。各項目は 20 文字以上。
     category は set_context の一覧から選び、tags に `gsd-lite` とエンジン名を入れる
   - `similar_threads` が返ったら新しく立てず、そのスレッドに `add_supplement` する。`force: true` は使わない
   - 根拠（turn 番号・permission_denials の件数など）は要約して書く。リポジトリ名・ファイルパス・顧客の情報は書かない
4. 振り返りファイルの末尾に「## achat への書き込み」を足し、record_task・remember の id と、スレッド（新規 / 追記）の
   thread_id と題名を並べる（失敗したものは「失敗: <エラーコード>」）。`agentmem=off` なら「achat 未接続」と 1 行だけ書く

## ターン終了の共通手順（ループから呼ばれた場合。必須・この順で）

1. `$MS/PROGRESS.md` に追記（固定項目。次の項を参照。`<N>` はこのターンで +1 した後の
   `state.turn` = ループの表示番号）
2. `state.json` を更新: `phase: "done"` / `next_command: "DONE"`、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**時刻は `date -Iseconds` を実行した出力をそのまま書く**（見積もりや丸めた値を書かない。ループはコミット時刻より先の値を警告する）。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
3. 振り返りファイル・PROGRESS.md・state.json を**まとめて git commit**
   （`gsd-lite(reflect): <slug> 振り返り`）。
   in-repo 形で verify がリモート運用（MR/PR 作成済み）なら **再 push** する（MR にこのコミットが載る）。
   gsd-control 形では制御側にコミットするだけで、対象側には触らない。
   push の成否を確認し、失敗したら 1 回リトライ、それでも失敗なら DONE のまま終わらせず
   `next_command: "BLOCKED"` / `phase: "blocked"` にして BLOCKED.md に理由を書き
   追加コミットして終了する。**マイルストーンブランチに残ったまま終了する**（checkout しない）。
   ローカル運用（verify がベースへマージ済み）ならベースブランチ上でコミットするだけ
4. 判断に迷ったら推測しない: `$MS/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
   `next_command: "BLOCKED"` / `phase: "blocked"`（turn は +1）にしたうえで
   同様にコミットして終了する

手動で呼ばれた場合は 1 と、振り返りファイル + PROGRESS.md だけのコミット
（`gsd-lite(reflect): <slug> 手動振り返り`）を行い、state は変更しない。リモートがあれば push する。

## PROGRESS.md の申し送り形式（全フェーズ共通）

```markdown
## turn <N> — reflect — <slug>
- やったこと: 振り返りを .gsd-lite/reflect/<file> に作成（提案 K 件）
- 想定外: なし | <記録の不足など>
- やり直し: 0 回
- 次への注意: <提案の要約 1 行>
```

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
