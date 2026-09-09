---
name: gsd-lite-impl
description: gsd-lite の実装フェーズ（無人ループから claude -p で起動）。PLAN.md の先頭の未完了タスクを 1 つだけ実装し、テストを通してコミットする。
disable-model-invocation: true
---

# gsd-lite-impl — タスクを 1 つだけ進める（無人ターン）

これは無人ターン。**1 ターン = 1 タスク**が鉄則。複数タスクをまとめてやらない
（コンテキストが溢れて品質が落ちる。次のタスクは次のターンの自分がやる）。

## 手順

1. `.gsd-lite/PLAN.md` の**先頭の未完了タスク（`- [ ]`）を 1 つだけ**選ぶ。
   `.gsd-lite/PROGRESS.md` の直近の申し送りを読む。
   未完了タスクが 1 つもなければ実装せず、`phase: "verify"` /
   `next_command: "/gsd-lite-verify"` にして共通手順で終了する
2. タスクの完了基準・対象ファイルに従って実装する。必要な範囲のコードだけ読む
3. PLAN.md の**検証コマンド**でテストを実行し、green を確認する
   - 通らない場合、このターン内で最大 2 回まで立て直しを試みる。それでも
     だめなら変更を stash せずそのままコミットはせず、BLOCKED にする
     （何をどう試したかを BLOCKED.md に書く）
4. コミットし（`gsd-lite(impl): <タスクID> <要約>`）、PLAN.md のチェックボックスを
   `- [x]` にする（この変更もコミットに含める）
5. まだ未完了タスクが残っていれば `next_command: "/gsd-lite-impl"`（自分自身・
   phase は "impl" のまま）、全タスク完了なら `phase: "verify"` /
   `next_command: "/gsd-lite-verify"` にする

## ターン終了の共通手順（必須・この順で）

1. 成果物を git commit（上記 4 で済んでいれば state/PROGRESS 分を追加コミット）
2. `.gsd-lite/PROGRESS.md` に 3〜5 行追記（やったタスク / 次 / 注意点・ハマりどころ）
3. `state.json` を更新: `next_command` と `phase` を上記のとおり、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
4. 判断に迷ったら推測しない: `.gsd-lite/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
   `next_command: "BLOCKED"` / `phase: "blocked"` にして（turn は +1）終了する
