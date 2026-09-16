---
name: gsd-lite-plan
description: gsd-lite のプランニングフェーズ（無人ループから Claude Code / Codex で起動）。REQUIREMENTS / DECISIONS / RESEARCH から 1 ターン粒度のタスク列 PLAN.md を作成する。
disable-model-invocation: true
---

# gsd-lite-plan — 1 ターン粒度の計画を作る（無人ターン）

これは無人ターン。**ユーザーに質問できない**。仕様の曖昧さを見つけても、discuss の
決定範囲内で解釈できなければ BLOCKED にする（勝手に決めない）。

## 手順

1. `.gsd-lite/REQUIREMENTS.md` / `DECISIONS.md` / `RESEARCH.md` とコードベースを読む
2. `.gsd-lite/PLAN.template.md` の形式で `.gsd-lite/PLAN.md` を作成する:
   - **タスク粒度の品質基準**: 各タスクは「1 ターン（新規コンテキスト 1 回）で
     実装+テスト+コミットまで完結する」大きさを上限とする。手順は 2 段階: ①まず細かく分割して
     洗い出す（受け入れ基準からの漏れを防ぐ）→ ②同種・同ファイル群を統合して**マイルストーン
     全体で 8〜15 タスク**に収める（20 を超えたら統合してから確定。詳細は PLAN.template.md のコメント）
   - 各タスクに: 完了基準（テストで機械検証可能な形）/ 対象ファイル / 依存タスク
   - 依存順に並べる（impl は常に先頭の未完了タスクを取る）
   - **検証コマンド**セクションにこのプロジェクトでテストを回すコマンドを確定させる
   - RESEARCH.md の参考実装・落とし穴をタスク設計に反映する
3. ゴール逆算チェック: 全タスク完了 = REQUIREMENTS.md の受け入れ基準がすべて
   満たされる状態か確認。漏れがあればタスクを足す
4. `phase: "impl"` / `next_command: "/gsd-lite-impl"` にする

## ターン終了の共通手順（必須・この順で）

1. `.gsd-lite/PROGRESS.md` に 3〜5 行追記（やったこと / 次 / 注意点）
2. `state.json` を更新: `next_command` と `phase` を上記のとおり、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
3. 成果物・PROGRESS.md・state.json を**まとめて git commit**（`gsd-lite(plan): <要約>`）。
   **state 更新 → commit の順序が重要**: 逆にすると最終 state が未コミットで残り、
   git からの復元時に完了済みフェーズを再実行してしまう
4. 判断に迷ったら推測しない: `.gsd-lite/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
   `next_command: "BLOCKED"` / `phase: "blocked"`（turn は +1）にしたうえで
   同様にコミットして終了する
