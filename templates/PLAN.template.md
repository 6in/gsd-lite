# PLAN — <milestone slug>

- 作成: <日付> / gsd-lite-plan
- 入力: REQUIREMENTS.md / DECISIONS.md / RESEARCH.md

## 検証コマンド

impl の各ターンがテストに使うコマンド（プロジェクトに合わせて plan が確定する）:

```bash
<例: npm test / cargo test / pytest>
```

## Tasks

<!--
タスク粒度の品質基準: 各タスクは「1 ターン（新規コンテキスト 1 回）で
実装+テスト+コミットまで完結する」大きさであること。迷ったら分割する。
verify の差し戻しタスクは F1, F2... として末尾に追記される。
-->

- [ ] T1: <タスク名>
  - 完了基準: <テストで機械検証可能な形で>
  - 対象: <ファイルパス>
  - 依存: なし

## メモ

<plan が impl に申し送りたい設計上の注意点>
