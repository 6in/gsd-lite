# gsd-lite 改善案 — reservation-component の 7 マイルストーンから

- 作成: 2026-10-02
- 材料: `reservation-component/.gsd-lite/` の PROGRESS.md / VERIFICATION.md 7 組（archive 6 本 + turnover-status）、
  state.json の git 履歴、`logs/<milestone>/turn-*.log`
- 対象: gsd-lite の型紙（`templates/`）・5 スキル・`bin/gsd-lite-loop.sh`。DB 設計の中身は扱わない

## 1. 数字で見た経過

| マイルストーン | ターン | verify | 差し戻しの中身 |
|---|---|---|---|
| reservation-core | 39 | round 2 | 実装の欠陥 4（ロック順序 40P01・抜け道・契約外 SQLSTATE・曜日順）/ テストの弱さ 1 / backlog 化 1 |
| hardening | 21 | round 2 | 文書と実装の不一致 1（古い ERRCODE 字面を含む）/ テストの抜け 1 |
| backlog-owner-decisions | 11 | round 2 | 番号の振り直し漏れ 1 / 決定の改訂に UC が追随していない 1 |
| usage-actuals | 19 | round 2 | 実装の回帰 1（DST）/ 本数の書き換え漏れ 1 |
| industry-scenarios | 15 | round 2 | 文書の書きすぎ 2 / 要約と本文の食い違い 1 / 誤字・古い識別子 2 |
| quota-freebusy | 15 | **round 1** | — |
| turnover-status | 13 | **round 1** | —（指摘 0） |

差し戻しは計 17 件。そのうち**実装の欠陥は 5 件**で、残る 12 件は文書の陳腐化・ずれ・テストの弱さ。
差し戻し 1 回あたり +2 ターン（修正 1 + 再 verify 1）。core は指摘 1 件 = 1 ターンで +7 ターン。

round 1 合格に効いたと読めるもの（すべてプロジェクト側で自然発生した工夫。gsd-lite には入っていない）:

- plan で「決めた事項」を列挙して確定し、impl は再議論しない（quota 22 項目、turnover 13 点）
- research で落とし穴を列挙し、**テスト計画に先に入れる**（usage の DST 回帰を quota で先回り）
- 完了基準を `rg -c '<古い字面>'` が 0 件のような**機械照合**で書く
- 既存テストの期待値を変えた箇所を impl が毎ターン列挙し、verify がその一覧で確かめる
- 最終判定を 1 本のスクリプトにまとめる（`scripts/t28-final-check.sh`。core T28 以降すべての verify で使用）

## 2. 改善案（優先度順）

### P1. `updated_at` をモデルの見積もりで書かせない【loop / 全スキル / allowlist】

**事実**: turnover-status の impl ターンは、`updated_at` がコミット時刻より先にずれ、その幅がターンごとに広がった
（T1 +42 分 → T10 **+9 時間**。値は `:00` / `:05` に丸めてある）。quota-freebusy でも +3 時間、
usage-actuals では最大 +14.7 時間で、途中から `Z` 表記が `+09:00` に変わっている。
discuss / research / plan / verify の各ターンは秒単位で正しい。industry-scenarios の plan では
`date -Iseconds` が承認待ちで止まっている。`date` は allowlist に無く、impl のモデルが時刻を見積もって書いたと推測される。

**案**:
- (a) `settings.allowlist.json` に `Bash(date:*)` を足す。スキルの共通手順を
  「`date -Iseconds` の出力をそのまま書く。見積もりで書かない」に改める
- (b) さらに確実にするなら、ループがターン後に `HEAD` のコミット時刻と比べ、未来の値なら WARN を出す
  （値の補正は state を書き換えて追加コミットが要るので、警告だけにとどめる）

### P2. 無人ターンが承認待ちで止まらない書き方をスキルに入れる【全スキル / allowlist】

**事実**: 次のものが承認待ちで止まった。shellcheck（core T17）、変数代入つきのコマンド `RSV_BIND=… make`（hardening T7）、
`git commit -m "$(printf …)"`（industry F1）、`date`（上記）、作業ディレクトリの外へのコピー（hardening / backlog の VERIFICATION
「ログ」節では、最終判定ログを目視で転記するしかなかった）。プロジェクト側で allowlist に 15 項目を足している
（`head` / `tail` / `wc` / `diff` / `sed` / `make` / `python3` / `bash` …）。

**案**:
- allowlist の雛形に、読み取り系で汎用のもの（`date` / `head` / `tail` / `wc` / `diff` / `sort` / `uniq`）を入れる
- スキルの共通手順に「無人ターンのシェルの作法」を 1 節足す:
  - 1 回の呼び出しには 1 コマンドだけ書く。`;` / `&&` / サブシェル / `$(...)` / 先頭の変数代入を使わない
  - コミットメッセージはファイルに書き、`git commit -F <file>` で渡す
  - 一時ファイルは `.gsd-lite/logs/<milestone>/` に置き、名前に turn 番号を入れる
    （turnover T2 では前のマイルストーンの `t2-commit-msg.txt` を誤って使い、amend する羽目になった）。
    `mktemp -d` で作ったディレクトリはそのターン内で消す（今のプロジェクトには `test-deploy.*` が 32 個残っている）

### P3. 計画に書く事実は実物から引く。食い違ったら実装を正として PLAN を直す【plan / impl】

**事実**: PLAN に書かれた事実の誤りを impl が直した手戻りが、前半 3 本だけで 10 件以上ある。
存在しない引数名（hardening T2 / T11、backlog T3 で 3 回）、件数、節番号、観測できない完了基準などである。
後半でも「PLAN の期待が実測と違った」が 6 回出てくる（quota T7 では PLAN は RV009、実測は RV005）。
扱いはその都度、申し送りで説明されている。

**案**:
- plan スキル: シグネチャ・件数・節番号・エラーコードを PLAN に書くときは、宣言や grep の結果から**引用**する
  （引いた元のファイルと行を併記する）。記憶や要約から書かない
- impl スキル: 「PLAN の記述が実物や実測と食い違ったら、要件や決定に反しない範囲で**実装と実測を正とし**、
  PLAN の該当箇所を直して PROGRESS に『PLAN 訂正: 旧 → 新（根拠）』と残す。
  要件や決定に触れるなら BLOCKED」を明文化する

### P4. 型紙に「追従先チェックリスト」と「数値の正の置き場」欄を足す【PLAN.template / plan】

**事実**: 同じ種類の漏れが、マイルストーンをまたいで繰り返した。
- 公開 SP を足すたびに登録先 4〜5 か所の漏れ（usage T4 / T6、quota T3 / T5 / T6、turnover T2 / T3）
- 本数の字面が PLAN の対象外に残る（usage F2 で `conventions.md:24` を直したのに、turnover T10 で同じ行がまた古くなった）
- `plan(n)` / 件数 / スライドの定数を 4〜5 か所に手で写す作業が、文書タスクと最終タスクを重くしている

**案**（gsd-lite には枠だけ置き、中身はプロジェクトが持つ）:
- PLAN.template に `## 追従先チェックリスト` 節を常設する。plan が、プロジェクトの CLAUDE.md などから
  「X を足したら直す場所」を写す。impl は該当タスクの完了時に全項目を確かめる
- PLAN.template の「検証コマンド」節に、次の 2 つを**必須項目**として置く:
  - **最終判定コマンド 1 本**（t28-final-check.sh 相当。クリーンな状態から全検査）
  - **数値の照合**: 件数・本数を書いた文書の置き場を列挙し、`rg` で古い値が 0 件になることを完了基準にする。
    できればプロジェクト側で生成や機械照合に置き換えることを、plan の「メモ」で提案する

### P5. 完了基準に「各タスクのテストでは拾えない観点」を割り当てる【plan】

**事実**: verify で初めて見つかった実装の欠陥 5 件は、すべて並行性・境界値・暦の端（DST・曜日の並び）・
契約外のエラーコード漏れだった。各タスクが「リトライ・BLOCKED なし」と自己申告していても、
タスク単体の完了基準ではこれらを拾えていない。quota 以降は、research で列挙した落とし穴をテスト計画に入れることで防げている。

**案**: plan のゴール逆算チェックに次の 2 点を足す。
- RESEARCH.md の「落とし穴」が、それぞれどのタスクの完了基準で検証されるかを対応づける
  （対応先の無い落とし穴を残さない）
- 並行・境界値・異常系の観点を、どのタスクが担うかを明記する

### P6. verify の観点を「文書の主張」と「前回の取りこぼし」に広げる【verify】

**事実**: industry-scenarios の差し戻し 5 件は、すべて文書の問題だった（実態より広い主張、要約と本文のずれ、古い識別子）。
hardening T14 では、前のマイルストーンの `plan(n)` のずれが 5 本見つかった。
backlog-owner-decisions の verify がこれを見逃したと推測される。

**案**:
- verify の観点に次を足す:
  - 文書の主張が実態より広くないか（「全部流した」「すべて」などの言い切り）
  - 冒頭の要約と本文が一致しているか
  - P4 の数値照合の再実行
- 軽微な文書の指摘は、1 つの F タスクにまとめてよいと書く（core は指摘 1 件 = 1 ターンで +7 ターンだった）

### P7. impl ターンの冒頭で作業ツリーと環境を確かめる【impl】

**事実**: 前のターンが作業ツリーに残した成果物を、次のターンが検証し直した（core T19）。
デモや再現の後に DB にデータが残り、テストが落ちた（hardening T15、core round 1）。

**案**: impl の手順 1 の前に次を入れる。
- `git status` が dirty なら、まず内容を確かめる。前のタスクの続きなら検証してから取り込み、
  無関係なら BLOCKED にする
- PLAN の検証コマンドの前に、環境を初期化するコマンドを走らせる（PLAN.template の「検証コマンド」節に欄を作る）

### P8. 利用上限で落ちたターンをリトライ回数から外す【loop】

**事実**: quota-freebusy では turn 2 / 4 / 6 / 8 の attempt 1 が `You've hit your session limit` で落ちた。
backlog-owner-decisions の research も、利用枠切れで 2 回とも成果物ゼロだった。
`retry_max` を使い切ると auto-BLOCKED になるので、本当の詰まりと区別できない。

**案**: ターンログに上限到達の文言があれば、`retry` を増やさない。そのうえで待機（またはトークンのラウンドロビンで次へ切替）してから再試行し、loop.log にその旨を残す。

### P9. マイルストーンの振り返りを成果物として残す【verify または discuss 0-b】

**事実**: 1〜8 の材料は PROGRESS の申し送りに散らばっていて、マイルストーンをまたいで集約する場所が無い。
今回は 7 本を読み直してまとめた。「`plan(n)` は仮の数で流す」は core の中だけで約 12 回、
「実装の引数宣言を先に見る」は 3 回、同じ注意が再掲されている。

**案**: verify の合格時（または次の discuss の退避時）に、`archive/<milestone>/RETRO.md` を 10〜20 行で書く。
中身は、差し戻しの原因の分類、ターン数を押し上げたもの、次回へ持ち越す注意。
次の research / plan は、直近の RETRO.md を入力として読む。
繰り返し出る注意は、プロジェクトの CLAUDE.md か型紙へ昇格させる（申し送りでの再掲をやめる）。

### P10. 細かい整え【全体】

- PROGRESS の見出しの書式を `## <YYYY-MM-DD> <phase> <タスク ID>（turn N → N+1）` に固定して、型紙に書く
  （core では「turn 38」と「turn 38 → 39」が混在し、F6 と verify の番号が重なっている）。日付は JST などに固定する
- `state.json` の既定 `model.impl` が `claude-opus-5` のまま。現行の Opus 5.5 に上げるかを確かめる

## 3. プロジェクト側に残すもの（gsd-lite には入れない）

次のものは reservation-component 固有なので、プロジェクトの CLAUDE.md や型紙に置くのが適切。P4 の「追従先チェックリスト」の中身として plan が写す。

- 公開 SP を足したときの登録先（`030` / `500` / `503` / `504` / `900`）と、旧シグネチャの DROP
- テストの定石: `now()` 相対の枠の衝突、sweep 用の専用テナント、`checked_in_at` を状態と同時に書く
- 文書だけに効く規則（表の中に `|` を書かない、型見出しの下の表は 1 つまで、参照できる ID の範囲）は、
  TEMPLATE か validate に入れる

## 4. 修正パッチ

同じディレクトリの `2026-10-02-from-reservation-component.patch` が上記の案を実装した修正案（未適用）。
`git apply --check` が通ることと、`tests/run-tests.sh` が PASS=268 / FAIL=0（追加 11 件を含む）であることを確認済み。

```bash
git apply docs/proposals/2026-10-02-from-reservation-component.patch
bash tests/run-tests.sh
./install.sh --engine all   # 反映後、既存プロジェクトの .claude/skills/ は gsd-lite-init か discuss の手順で更新する
```

| 案 | 変更したファイル | 中身 |
|---|---|---|
| P1 | `settings.allowlist.json` / 4 スキルの共通手順 / `bin/gsd-lite-loop.sh` | `Bash(date:*)` を許可。`updated_at` は `date -Iseconds` の出力をそのまま書く。ループは HEAD のコミット時刻より 5 分以上先なら WARN（`check_updated_at`） |
| P2 | `settings.allowlist.json` / 4 スキル末尾の新節 | `head` / `tail` / `wc` / `diff` / `sort` / `uniq` を許可。「無人ターンのシェルの作法」（1 呼び出し 1 コマンド、`git commit -F`、一時ファイルの置き場と名前、`mktemp -d` の掃除） |
| P3 | `gsd-lite-plan` / `gsd-lite-impl` | 事実は実物から引用し、元を併記する。食い違ったら実物を正として PLAN を直し、`PLAN 訂正:` を残す |
| P4 | `PLAN.template.md` / `gsd-lite-plan` | 「追従先チェックリスト」節、検証コマンド節に「環境の初期化」「最終判定」の欄 |
| P5 | `gsd-lite-research` / `gsd-lite-plan` / `PLAN.template.md` | 落とし穴ごとに検証方法を書く。ゴール逆算チェックで落とし穴とタスクを対応づける。並行・境界値を担うタスクを明記する |
| P6 | `gsd-lite-verify` | 文書の主張・古い値・期待値変更一覧の観点を追加。軽微な文書指摘は 1 つの F タスクにまとめる |
| P7 | `gsd-lite-impl` | 手順 0「前のターンの残りを確かめる」。テストの前に環境を初期化する。既存テストの期待値を変えたら列挙する |
| P8 | `bin/gsd-lite-loop.sh` / `tests/run-tests.sh` / README / SPEC | 利用上限の文言が出た無進捗ターンは retry を増やさず `GSD_LITE_LIMIT_WAIT` 秒待つ。連続 `GSD_LITE_LIMIT_MAX` 回で auto-BLOCKED。auto-BLOCKED の書き出しは `auto_block` に共通化 |
| P9 | `gsd-lite-verify` / `gsd-lite-discuss` / `gsd-lite-research` / `gsd-lite-plan` | 合格時に `RETRO.md` を書く。discuss が archive へ移し、次の research / plan が直近の RETRO.md を読む |
| P10 | 4 スキルの共通手順 | PROGRESS の見出しの書式を固定する |

パッチに入れていないもの:

- `state.json` の既定 `model.impl`（`claude-opus-5`）の見直し。意図して選んだ可能性があるので判断を待つ
- 3 章のプロジェクト固有の項目（reservation-component 側の CLAUDE.md で扱う）

注意: `GSD_LITE_LIMIT_PATTERN` の既定には `rate limit` を含めている。レート制限を実装するプロジェクトでは、
無進捗のターンのログにこの語が出ると、利用上限と誤認して待機することがある。そのときはパターンを狭める。

## 5. 適用記録（2026-10-03）

4 章のパッチは reflect フェーズ・gsd-control（`$MS` / `$TARGET`）が入る前の版に対するもので、
現行の main にはそのまま当たらなかった（11 ファイル中 7 ファイルで衝突）。3-way で取り込み、
衝突は現行の構成に合わせて手で解いた。`tests/run-tests.sh` は PASS=370 / FAIL=0（追加 15 件）。

| 案 | 扱い | 現行に合わせて変えた点 |
|---|---|---|
| P1 | 適用 | reflect スキルにも `date -Iseconds` の規則を入れた |
| P2 | 適用 | 一時ファイルの置き場は既存の規則に合わせて `.gsd-lite/logs/<slug>/scratch/`。reflect スキルにも同じ節を入れた |
| P3 | 適用 | 引用元・洗い出し元は `$TARGET` 配下と明記 |
| P4 | 適用 | 「決めた事項」は PLAN の専用の節に書く |
| P5 | 適用 | — |
| P6 | 適用 | 既存の「期待結果は 1 つの表にまとめる」規則と併記 |
| P7 | 適用 | 手順 0 は `git -C $TARGET status`（gsd-control 形では制御側も） |
| P8 | 適用 | `auto_block` は `$MS_DIR/BLOCKED.md` に書く（gsd-control 形のテストを追加）。テストは 37 / 38 番 |
| P9 | **見送り** | reflect フェーズ（`.gsd-lite/reflect/` に蓄積し、discuss / plan が直近 2 件を読む）が同じ役割を既に担っている。RETRO.md を足すと振り返りが 2 系統になる |
| P10 | **見送り** | PROGRESS の見出しは `## turn <N> — <phase> — <要約>` + 固定 4 項目で既に固定済み。`model.impl` の既定は未変更 |
