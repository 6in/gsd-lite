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
   - `.gsd-lite/VERIFICATION.md` に検証結果（観点・確認したこと・残留リスク）を書いてコミット
   - `git remote get-url origin` で**リモートの有無を判定**して分岐:

   **(a) リモートなし（ローカルのみ）→ ベースブランチへ自動マージ**
   - `git checkout <branch.base>` → `git merge --no-ff gsd-lite/<slug>`
   - 衝突したら `git merge --abort` → `git checkout gsd-lite/<slug>` でブランチに戻り、
     衝突内容を BLOCKED.md に書いて BLOCKED にする（人間が解決）
   - マージ成功: ブランチは削除せず残す。`phase: "done"` / `next_command: "DONE"`

   **(b) リモートあり → push + MR/PR 作成（ローカルマージはしない）**
   - origin の URL からホストを判別し、ホスト別の手順で作成する:
     - **github.com**: `git push -u origin gsd-lite/<slug>` →
       `gh pr create --base <branch.base> --title "<milestone の要約>" --body "..."`
       （`gh` が必須。不在・未認証なら push まで行って BLOCKED）
     - **gitlab を含む**: `glab` が使えるなら `git push -u origin gsd-lite/<slug>` →
       `glab mr create --target-branch <branch.base> --title "..." --description "..."`。
       **`glab` が不在なら push オプションでフォールバック**（GitLab サーバー側機能。
       追加ツール・API トークン不要）:
       `git push -u origin gsd-lite/<slug> -o merge_request.create
        -o merge_request.target=<branch.base> -o merge_request.title="<要約>"`
       — push 出力に MR の URL が表示されるのでそれを記録する
   - MR/PR の本文には受け入れ基準の達成状況と VERIFICATION.md の要約を書き、
     末尾に `🤖 Generated with [Claude Code](https://claude.com/claude-code)` を付ける
   - 作成成功: MR/PR の URL を VERIFICATION.md と PROGRESS.md に記録。
     ブランチはそのまま。`phase: "done"` / `next_command: "DONE"`（マージは人間 / CI）
   - push はできたが MR/PR 作成に失敗（CLI 不在・未認証・ホスト不明など）:
     push 済みであることと失敗理由・手動作成の手順を BLOCKED.md に書いて BLOCKED にする
   - push 自体が失敗: 理由を BLOCKED.md に書いて BLOCKED にする

   **指摘ありの場合**
   - 修正タスクを `.gsd-lite/PLAN.md` の Tasks 末尾に `- [ ] F1: ...` 形式で追記
     （完了基準・対象ファイル付き）
   - `verify_round` を +1 する
   - `verify_round <= verify_round_max` なら `phase: "impl"` /
     `next_command: "/gsd-lite-impl"`（差し戻し）
   - 上限超過なら指摘一覧を BLOCKED.md に書いて BLOCKED にする（無限修正ループ防止）

## ターン終了の共通手順（必須・この順で）

1. `.gsd-lite/PROGRESS.md` に 3〜5 行追記（判定 / 指摘数 / マージ・MR 結果）
2. `state.json` を更新: `next_command` と `phase` を上記のとおり、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
3. 成果物・PROGRESS.md・state.json を**まとめて git commit**（`gsd-lite(verify): <要約>`。
   (a) ローカルマージ後はベースブランチ上でコミット。(b) リモート運用ではマイルストーン
   ブランチ上でコミットして再 push し（MR に最終 state が含まれる）、
   **そのあと `git checkout <branch.base>` でベースブランチに戻って終了する** —
   作業ブランチに残ると次のマイルストーンがこのブランチを base にしてしまう）。
   **state 更新 → commit の順序が重要**: 逆にすると最終 state が未コミットで残り、
   git からの復元時に完了済みフェーズを再実行してしまう
4. 判断に迷ったら推測しない: `.gsd-lite/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
   `next_command: "BLOCKED"` / `phase: "blocked"`（turn は +1）にしたうえで
   同様にコミットして終了する
