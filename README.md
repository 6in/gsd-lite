# gsd-lite

gsd-core のライト版。**対話で仕様を詰め切ったら、あとは無人ループが
research → plan → impl → verify → 自動マージまで進める**最小構成の自律開発ランナー。

- 毎ターン `claude -p "/スキル名"` で新規コンテキスト起動。継続性は `.gsd-lite/` + git のみ
- ループ（`gsd-lite-loop.sh`）はダム: `state.json` の `next_command` を実行するだけ
- 1 ターン = 1 タスク。判断に迷ったら推測せず BLOCKED で人間に戻す

設計の全容と利用手順: [docs/SPEC.md](docs/SPEC.md)（§11 がユーザー視点のウォークスルー）

## インストール

```bash
./install.sh
```

## 使い方（要約）

```bash
cd <対象プロジェクト>
claude
```

```
> /gsd-lite-init                       # 足場生成（プロジェクトごとに 1 回）
> /gsd-lite-discuss 決済機能を追加したい   # AUQ で仕様を詰め切る → ループ起動まで面倒を見てくれる
```

進捗確認（トークンゼロ）:

```bash
gsd-lite-loop.sh --status
```

終了コード: 0=DONE（マージ済み）/ 2=BLOCKED（`.gsd-lite/BLOCKED.md` 参照）/
3=max_turns / 4=discuss 未完了。通知が欲しければ `.gsd-lite/hooks/on-exit.sh` と
`on-phase.sh` に書く。
