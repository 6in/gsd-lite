---
name: gsd-lite-research
description: gsd-lite のリサーチフェーズ（無人ループから Claude Code / Codex / OpenCode で起動）。discuss の決定を類似 OSS・公式ドキュメント・過去プロジェクトの調査で補強し、RESEARCH.md を産出する。
disable-model-invocation: true
---

# gsd-lite-research — 要件を事実で補強する（無人ターン）

これは無人ターン。**ユーザーに質問できない**。discuss の決定を事実で補強するのが
役目で、要件を書き換える権限は原則ない。成果は RESEARCH.md に集約して plan に渡す。

## 手順

1. `.gsd-lite/state.json` / `REQUIREMENTS.md` / `DECISIONS.md` を読む
2. `state.json` の `research.targets` にある対象だけを調査する:
   - `similar_oss`: 同じ課題を解く既存 OSS・プロダクト・記事を Web 検索。
     「作らなくてよいもの」と「盗める設計」を探す
   - `official_docs`: 採用技術の公式ドキュメント・ベストプラクティス・既知の
     落とし穴を調査し、plan の技術前提を固める
   - `local_projects`: `research.local_search_paths` 配下の過去プロジェクトから
     同型の実装・雛形を探す（パス付きで記録）
3. `.gsd-lite/RESEARCH.md` に産出:
   - 参考実装（ローカルパス / URL 付き）
   - 盗める設計・使えるライブラリ
   - 落とし穴と回避策
   - 要件への影響（受け入れ基準に足すべき観点があれば**提案として**記載。
     REQUIREMENTS.md 本文は書き換えない）
4. **重大発見の扱い**: discuss の決定を覆しうる発見（例: 要件をほぼ満たす既存 OSS が
   あった）は、要旨と選択肢+推奨を `.gsd-lite/BLOCKED.md` に書いて BLOCKED で停止する
   （下記手順で `next_command: "BLOCKED"`）。「作るか使うか」は投資判断なので人間に戻す。
   覆さない発見は RESEARCH.md に記録して続行
5. 正常終了時は `phase: "plan"` / `next_command: "/gsd-lite-plan"` にする

## ターン終了の共通手順（必須・この順で）

1. `.gsd-lite/PROGRESS.md` に 3〜5 行追記（やったこと / 次 / 注意点）
2. `state.json` を更新: `next_command` と `phase` を上記のとおり、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
3. 成果物・PROGRESS.md・state.json を**まとめて git commit**（`gsd-lite(research): <要約>`）。
   **state 更新 → commit の順序が重要**: 逆にすると最終 state が未コミットで残り、
   git からの復元時に完了済みフェーズを再実行してしまう
4. 判断に迷ったら推測しない: `.gsd-lite/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
   `next_command: "BLOCKED"` / `phase: "blocked"`（turn は +1）にしたうえで
   同様にコミットして終了する
