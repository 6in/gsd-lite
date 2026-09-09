---
name: gsd-lite-verify
description: gsd-lite の検証フェーズ（無人ループから claude -p で起動）。マイルストーンの diff 全体をレビュー + セキュリティチェックし、合格ならベースブランチへ自動マージする。
disable-model-invocation: true
---

# gsd-lite-verify — レビュー + セキュリティ + マージ（無人ターン）

これは無人ターン。マイルストーンの成果全体を検証し、合格なら自動マージまで行う。

## 手順

1. `.gsd-lite/state.json` から `branch.base` / `verify_round` / `verify_round_max` を
   読み、`git diff <branch.base>...HEAD` でマイルストーン全体の差分を対象にする
2. `REQUIREMENTS.md` の受け入れ基準・PLAN.md の完了基準と突き合わせて検証する:
   - **コードレビュー**: バグ / 設計の歪み / テストの妥当性（テストが完了基準を
     実際に検証しているか）/ 要件の取りこぼし
   - **セキュリティチェック**: 入力検証 / 認可 / 秘密情報のハードコード /
     インジェクション / 依存の危険な使い方
   - PLAN.md の検証コマンドでテストがすべて green なことも再確認する
3. 結果で分岐:

   **合格の場合**
   - `.gsd-lite/VERIFICATION.md` に検証結果（観点・確認したこと・残留リスク）を書く
   - コミットしてから**ベースブランチへ自動マージ**:
     `git checkout <branch.base>` → `git merge --no-ff gsd-lite/<slug>`
   - マージが衝突したら `git merge --abort` → `git checkout gsd-lite/<slug>` で
     ブランチに戻り、衝突内容を BLOCKED.md に書いて BLOCKED にする（人間が解決）
   - マージ成功: ブランチは削除せず残す。`phase: "done"` / `next_command: "DONE"`

   **指摘ありの場合**
   - 修正タスクを `.gsd-lite/PLAN.md` の Tasks 末尾に `- [ ] F1: ...` 形式で追記
     （完了基準・対象ファイル付き）
   - `verify_round` を +1 する
   - `verify_round <= verify_round_max` なら `phase: "impl"` /
     `next_command: "/gsd-lite-impl"`（差し戻し）
   - 上限超過なら指摘一覧を BLOCKED.md に書いて BLOCKED にする（無限修正ループ防止）

## ターン終了の共通手順（必須・この順で）

1. 成果物を git commit（`gsd-lite(verify): <要約>`。マージした場合はベースブランチ上で
   state/PROGRESS の更新をコミット）
2. `.gsd-lite/PROGRESS.md` に 3〜5 行追記（判定 / 指摘数 / マージ結果）
3. `state.json` を更新: `next_command` と `phase` を上記のとおり、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
4. 判断に迷ったら推測しない: `.gsd-lite/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
   `next_command: "BLOCKED"` / `phase: "blocked"` にして（turn は +1）終了する
