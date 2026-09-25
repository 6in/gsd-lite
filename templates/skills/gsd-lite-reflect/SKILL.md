---
name: gsd-lite-reflect
description: gsd-lite の振り返りフェーズ（verify 合格後に無人ループから起動。手動でも呼べる）。記録（PROGRESS / turns.jsonl / git log / PLAN / VERIFICATION）だけを根拠に PMI（Plus / Minus / Interesting）形式の振り返りを .gsd-lite/reflect/ に書き、次回への提案を残す。
disable-model-invocation: true
---

# gsd-lite-reflect — 記録に基づく振り返り（PMI）

これは新規コンテキストで動く。**作業の記憶はない**。あるのは記録だけなので、
記録から言えることだけを書く。記録にないことは書かない。推測は「推測:」と明記する。
Minus と Interesting の各項目には**根拠**（ターン番号 / コミット / ファイル名）を必ず添える。

## 2 つの呼ばれ方

| 状況 | 判定 | ふるまい |
|---|---|---|
| ループから | `state.json` の `phase` が `reflect` | 振り返りを書き、state を DONE にしてまとめてコミット（下の共通手順） |
| 手動（`/gsd-lite-reflect`、Codex は `$gsd-lite-reflect`） | `phase` が `done`（または reflect 以外） | 追加の振り返りを書き、**ファイルと PROGRESS.md だけ**をコミット。state の `phase` / `next_command` / `turn` には触らない |

手動のときは「対象範囲」を前回の振り返り以降のコミット（`<前回の head>..HEAD`）にする。
前回の振り返りがなければマイルストーンブランチ全体（`branch.base...HEAD`）。

## 読む記録（この順で。全部読んでから書く）

1. `.gsd-lite/state.json`: milestone / branch / turn / verify_round / fix_round /
   engine / phase_engines / model・codex・opencode / subagents
2. `.gsd-lite/logs/<milestone>/turns.jsonl`: ループが 1 試行ごとに記録した客観データ
   （phase / engine / model / attempt / 所要秒 / rc / progressed / commits）。
   ここから**フェーズ別の所要時間・リトライが起きたターン・無進捗の試行**を集計する。
   `jq` でまとめて読む（例: `jq -s 'group_by(.phase) | map({phase: .[0].phase, turns: length, sec: (map(.duration_s) | add), retries: map(select(.attempt > 1)) | length})'`）
3. `.gsd-lite/PROGRESS.md`: 各ターンの申し送り（やったこと / 想定外 / やり直し / 次への注意）。
   「想定外」と「やり直し」の欄が Minus の主材料
4. `git log --format='%h %ad %s' --date=iso <branch.base>...HEAD`（または対象範囲）と
   `git diff --stat <範囲>`: コミットの粒度、`F1` 等の差し戻し修正、BLOCKED からの再開、
   人間の介入コミット
5. `.gsd-lite/PLAN.md`: 計画タスク数と実際の impl ターン数の差、追加・分割されたタスク、
   並列サブ作業が使われたか
6. `.gsd-lite/VERIFICATION.md`: verify の指摘と残留リスク。修正ラウンドなら
   「なぜ最初の verify で見つからなかったか」を考える
7. `git log --all --oneline -- .gsd-lite/BLOCKED.md` と各時点の内容: 何で止まり、
   人間がどう解決したか
8. `.gsd-lite/REQUIREMENTS.md` / `DECISIONS.md` / `RESEARCH.md`: 決定が守られたか、
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

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | エンジン / モデル |
|---|---|---|---|---|---|
| research | 1 | 1 | 4 | 0 | claude / ... |
| ... | | | | | |

- 計画タスク数 / impl ターン数: N / M
- verify 差し戻し: verify_round 回（指摘 K 件）/ BLOCKED: 回数と原因の要約
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
```

- 「次回への提案」は plan と discuss が読む。**具体的で、やるかどうかを判断できる粒度**で書く
  （「もっと注意する」は不可。「T3 のような DB マイグレーション込みタスクは 2 分割する」は可）
- 記録に矛盾があれば（PROGRESS が成功と言うが turns.jsonl は 3 試行など）それ自体を
  Interesting に書く
- 書けるほどの記録がない（PROGRESS が空、turns.jsonl がない等）場合は、その事実と
  「記録の不足」を Minus に書く。作文で埋めない

## ターン終了の共通手順（ループから呼ばれた場合。必須・この順で）

1. `.gsd-lite/PROGRESS.md` に追記（固定項目。次の項を参照。`<N>` はこのターンで +1 した後の
   `state.turn` = ループの表示番号）
2. `state.json` を更新: `phase: "done"` / `next_command: "DONE"`、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
3. 振り返りファイル・PROGRESS.md・state.json を**まとめて git commit**
   （`gsd-lite(reflect): <slug> 振り返り`）。
   verify がリモート運用（MR/PR 作成済み）なら **再 push** する（MR にこのコミットが載る）。
   push の成否を確認し、失敗したら 1 回リトライ、それでも失敗なら DONE のまま終わらせず
   `next_command: "BLOCKED"` / `phase: "blocked"` にして BLOCKED.md に理由を書き
   追加コミットして終了する。**マイルストーンブランチに残ったまま終了する**（checkout しない）。
   ローカル運用（verify がベースへマージ済み）ならベースブランチ上でコミットするだけ
4. 判断に迷ったら推測しない: `.gsd-lite/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
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
