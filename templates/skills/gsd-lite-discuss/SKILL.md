---
name: gsd-lite-discuss
description: gsd-lite のディスカッションフェーズ。マイルストーンの仕様をユーザーと詰め切り、REQUIREMENTS.md / DECISIONS.md を確定してマイルストーンブランチを作成し、無人ループを起動する。対話セッション専用（ループからは実行されない）。
disable-model-invocation: true
---

# gsd-lite-discuss — 仕様を詰め切る（grilling × AskUserQuestion）

マイルストーンの仕様をユーザーと詰め切る対話フェーズ。ここが人間の判断を注入する
唯一の定常ポイントであり、以降の無人ループ（research → plan → impl → verify → reflect）の
品質はこのフェーズの網羅性で決まる。

引数があればそれがマイルストーンの初期要望。なければまず要望を聞く。

## ホストへの適応

- Claude Code は `/gsd-lite-discuss`、Codex は `$gsd-lite-discuss`、OpenCode は
  `/gsd-lite-discuss`（install.sh が置くコマンドが本スキルを読み込む）で呼び出す。
- 以下の AskUserQuestion / AUQ は対話による確認を意味する。Codex では利用可能な
  質問ツールの制限に合わせて分割し、利用できなければ通常の対話で質問する。
  multiSelect がなければ複数項目をテキストで答えてもらう。
- state の `next_command` はエンジン共通で `/gsd-lite-...` のまま。
  ループが Codex のスキル参照へ変換する。
- state の `engine` とモデル設定を確認してから起動する。Codex のモデルは
  `codex.model.<phase>`、推論強度は `codex.reasoning_effort.<phase>`。
  OpenCode のモデルは `opencode.model.<phase>`（`provider/model` 形式）、
  推論強度は `opencode.variant.<phase>`、エージェントは `opencode.agent.<phase>`。
  空ならその CLI の設定を使用する。
- 次のマイルストーンに移るときも `engine` / `phase_engines` / `model` / `codex`（`codex.sandbox` を含む）/ `opencode` /
  `claude`（`claude.provider` を含む）/
  `subagents` / `reflect` / `limits` / `agentmem` は保持する（gsd-control 形では `.gsd-lite/config.json` の `defaults` が
  次のマイルストーンの初期値。選んだパターンを次回以降の既定にしたいときは `defaults` も更新してコミットする）。
- 監視用サブエージェントが利用できない場合は `gsd-lite-loop.sh --status` で
  確認する方法を案内する。

## 作業場所の判定（最初に 1 回）

| 状況 | 形 | `$MS`（state と成果物） | `$TARGET`（コードを書くリポジトリ） |
|---|---|---|---|
| `.gsd-lite/state.json` がある | **in-repo**（従来） | `.gsd-lite` | `.`（今いるリポジトリ） |

（既存マイルストーンの場所は `gsd-lite-loop.sh --where` でも表示できる。以下の `$MS` / `$TARGET` は
「ここにその値をリテラルで書く」印で、シェル変数としては使わない — Bash ツールはコール間で変数を保持しない）
| なくて `.gsd-lite/config.json` がある | **gsd-control**（制御リポジトリ） | `.gsd-lite/milestones/<slug>` | `work/<name>`（config.json の `targets`） |
| どちらもない | 未セットアップ | `/gsd-lite-init` を案内して終了 | |

in-repo 形では以下の「gsd-control 形」の注記を無視し、従来どおり進める。gsd-control 形では:

- **今いる制御ブランチが `gsd-lite/<slug>`** なら、そのマイルストーン（`$MS/state.json`）が 0-0 / 0-a の対象。
  それ以外（main 等）にいるなら新しいマイルストーンを始める（進行中のものはない）
- **対象の選択**: `config.json` の `targets` から選ぶ（1 つなら確認だけ、複数なら AUQ。未登録なら
  `/gsd-lite-init` で追加してもらう）。`TARGET=work/<name>`、対象 base は `targets.<name>.base`
- **対象の準備**: `[ -d $TARGET/.git ] || git clone <targets.<name>.url> $TARGET`。
  `git -C $TARGET checkout <base>`、リモートがあれば `git -C $TARGET pull --ff-only origin <base>`。
  対象の作業ツリーが dirty なら扱いを相談する
- **対象の規約を読む**: `$TARGET/AGENTS.md`（全エンジン共通の本体。無ければ `CLAUDE.md`）と README は
  自動では読み込まれないので、要望を聞く前に読み、既存コードとの整合の質問に活かす（plan / impl も同じファイルを読む）
- **slug を早く決める**: 要望を聞いたら最初の AUQ で kebab-case の slug を確認し、
  `git checkout -b gsd-lite/<slug>`（制御側。いまいたブランチが制御側の base）と `mkdir -p $MS` を
  作ってから議論を始める（4 のインライン文書化の書き先が必要なため）。
  state は `jq -s '.[0] * .[1].defaults' <テンプレート>/state.json .gsd-lite/config.json > $MS/state.json`
  で作り、`target: {name: "<name>", path: "work/<name>"}` を入れる（`targets.<name>.agentmem_project` があれば
  `agentmem.project` にも写す。achat の project は対象ごとに違うため）（テンプレートはホスト用の
  `~/.claude/gsd-lite/templates/` 等。init と同じ場所）
- **0-b の退避は行わない**（マイルストーンごとにディレクトリが分かれている）。`.gsd-lite/reflect/` の
  直近 2 件の「次回への提案」は同様に読む
- 完了後の制御側ブランチ（`gsd-lite/<slug>`）の扱いは人間が選ぶ（制御 main にマージ / reflect だけ
  取り込む / 放置）。discuss は触らない

## 0. 進行中チェック → ブランチ整理 → 退避（この順で）

**0-0. 進行中チェック（ブランチを動かす前に最初に行う）**: 現在の
`$MS/state.json` を読む（gsd-control 形で制御ブランチにいなければ進行中はなく、0-a も飛ばして 1 へ）。`phase` が `done` / `discuss` 以外
（research / plan / impl / verify / blocked）なら**進行中のマイルストーンがある**。
ブランチの切り替えも退避もせず、ユーザーに状況を確認して指示を仰ぐ
（checkout してから確認すると、移動先の古い state を見て進行中を見逃す）。
`done` または初期状態のときだけ 0-a へ進む。

**0-a. ブランチ整理（archive より先に行う）**: いま前回の作業ブランチ（`gsd-lite/*`）に
いる場合（前回がリモート運用で MR 待ちのケース。gsd-control 形では制御側と対象側の両方が
`gsd-lite/<slug>` にいる）は、まず AUQ で次を選んでもらう:

- **前回 MR の指摘を修正する（修正ラウンド）**: 要望が前回マイルストーンの MR/PR レビュー
  対応や手直しなら、`gsd-lite/<slug>` に**留まり**、archive も state の作り直しもしない。
  `.gsd-lite/reflect/` の直近の振り返りがあれば読む。REQUIREMENTS.md と DECISIONS.md に
  「## 修正ラウンド N」（N = `fix_round` + 1）の節を追記し、指摘内容・対応方針・受け入れ基準を
  そこに書く（以降の 1〜3 の議論はこの節が対象）。手順 5 では**ブランチを作らず**、
  state を `fix_round: N` / `phase: "plan"` / `next_command: "/gsd-lite-plan"`
  （調査が必要なら research から）/ `verify_round: 0` にしてコミットする。plan は修正タスクを
  `F<N>-k` として末尾に追記し、verify は既存 MR/PR に push だけ行い、reflect が
  修正ラウンドの振り返りを残す
- **新しいマイルストーンを始める**: state の `branch.base` へ `git checkout` で戻る。
  リモート（origin）があれば `git pull --ff-only origin <base>` で base を最新化する
  （gsd-control 形: 対象側は `git -C $TARGET checkout <base>` と pull、制御側は制御側の base
  ブランチ（通常 main）へ戻る。以降は「作業場所の判定」の新規マイルストーン手順へ）。
  **前回マイルストーンの MR が未マージ**（pull しても前回の成果が base に含まれない）場合は、
  AUQ で「マージを待つ / 前回成果を含まない base のまま進める」を確認する

手動で直した後に振り返りだけ残したい場合は `/gsd-lite-reflect` を案内する（state は変えない）。

**0-b. 退避**（修正ラウンドと gsd-control 形では行わない）: （base に移った後の）`.gsd-lite/state.json` の
`phase` が `done` なら、`.gsd-lite/` 直下の成果物（REQUIREMENTS / DECISIONS / RESEARCH / PLAN /
PROGRESS / VERIFICATION 等）を `.gsd-lite/archive/<前回のmilestone>/` へ移動し、state.json を
テンプレート初期値で作り直してから始める（`.gsd-lite/reflect/` は移動せず蓄積する。
新しいマイルストーンの要望を聞く前に直近 2 件の「次回への提案」を読み、discuss で
確認すべき項目があれば初期フロンティアに加える）。`phase` が `discuss` 以外で done でもない
場合は進行中のマイルストーンがあるので、ユーザーに状況を確認する（勝手に上書きしない）。

**0-c. AGENTS.md 候補の採否**（修正ラウンドでも行う。gsd-control 形でも同じ）: 直近 2 件の振り返りの
「次回への提案」のうち `（AGENTS.md 候補）` の付いたもので、まだ `$TARGET/AGENTS.md` に無く、過去の
DECISIONS.md でも不採用になっていないものを、最初の AUQ のラウンドに 1 問ずつ（多ければ multiSelect で
まとめて）入れて「AGENTS.md に足す / 足さない」を聞く。AGENTS.md は全エンジン共通の指示の本体で、
どのエンジンのターンも自動で（gsd-control 形ではスキルが明示的に）読む。
- 足すものは `$TARGET/AGENTS.md` の該当節に 1 項目 1 行で書く（「何をする / しない」と「しないとどうなるか」）。
  AGENTS.md が無ければ作り、`$TARGET/CLAUDE.md` が無ければ 1 行目に `@AGENTS.md` だけの CLAUDE.md も作る
  （CLAUDE.md があって `@AGENTS.md` を取り込んでいなければ、1 行目に足すかを同じ AUQ で聞く）。
  CLAUDE.md には同じ内容を写さない
- 採否は DECISIONS.md に「AGENTS.md: <決まり> — 採用 / 不採用（理由）」として残す
- コミットは手順 5 のマイルストーンのコミットに含める。gsd-control 形では AGENTS.md は対象側のファイルなので、
  手順 5 で対象側のブランチ `gsd-lite/<slug>` を切った直後に、対象側にだけ
  `git -C $TARGET add AGENTS.md CLAUDE.md` → `git -C $TARGET commit -m "gsd-lite(discuss): <slug> AGENTS.md に作業上の決まりを追加"`
  でコミットする（対象の base には直接コミットしない。MR / マージで base に入る）

**0-d. achat の過去知見**（このセッションで achat のツール `agentmem` / `agentmem-gsd` が見えるときだけ。見えなければ
飛ばす）: 要望を聞いたら最初のラウンドの前に、要望の主題をクエリにして `recall`、`search_board`（つながっている
サーバー全部）、`search_tasks`（scope `project`）を引く。当たったものは質問の材料にする（「以前この型で〇〇が問題に
なっている（スレッド: <題名>）が、今回はどうするか」）。結果をそのまま並べて見せない。掲示板は achat の project の中で
しか検索できないので、gsd-lite 共有の project（`agentmem-gsd`）も引く。`rate_thread` はしない

## 1. プロトコル: デザインツリーとフロンティア

議論全体を**デザインツリー**として扱う。すべての決定は、その決定に依存する子の
決定を持つ（例: 「認証方式」が決まって初めて「セッション有効期限」を聞ける）。

- **フロンティア** = 前提がすべて確定済みで「今すぐ聞ける」質問の集合
- ラウンドごとにフロンティア全体を一度に問い、回答でツリーを更新し、
  新しく聞けるようになった質問で次のラウンドを組む
- 別の未回答質問に依存する質問は、同じラウンドに**入れない**（後のラウンドへ）

初期フロンティアの種（この 5 観点から始める。加えて**堅牢性の受け入れ基準を入れるか**を 1 問聞く —
例「どの入力・出力状態でもトレースバックを出さず、既存データを失わない」。入れるなら plan が初回タスクに
含め、入れないなら verify は該当指摘を残留リスクに留めて差し戻さない）:
スコープ境界（やらないことの確認）/ 受け入れ基準 / 技術選定 /
既存コードとの整合 / エッジケース・異常系の扱い

## 2. AskUserQuestion でのラウンドの組み方

- フロンティアの質問を AskUserQuestion で提示する。1 回につき最大 4 問なので、
  フロンティアが大きい場合は影響の大きい順に複数回に分割してよい
  （同一ラウンド内の質問はすべて独立なので連続して聞ける）
- 各質問は **2〜4 個の選択肢 + 推奨を先頭に置き「(推奨)」を明記**。
  description にトレードオフを書く。「Other」は自動で付くので選択肢に含めない
- 排他的でない論点（対応したいエッジケース群など）は multiSelect にする

## 3. 事実と決定の分離

- **事実を調べるのは自分の仕事**: コードベースの現状・既存の規約・ライブラリの
  有無など、環境から調べられることをユーザーに聞かない。必要ならサブエージェントで
  調査し、調査中でも依存しない質問は先に聞く
- **決定はユーザーの仕事**: トレードオフのある選択は必ず AUQ で委ね、勝手に確定しない

## 4. インライン文書化

決定が確定するたびに、ラウンドの合間に**その場で**反映する（最後にまとめて書かない）:

- `$MS/REQUIREMENTS.md` — WHAT: 要求・受け入れ基準・スコープ外リスト・用語集
- `$MS/DECISIONS.md` — WHY: 選んだ案 / 検討して却下した案とその理由
  （ユーザーが Other で答えた文脈も残す）

用語の揺れに気づいたら、その場で正準の用語を確定して用語集に記録する。

## 5. 終了シーケンス

1. フロンティアが空になるまでラウンドを繰り返す
2. 仕上げチェック: 「plan フェーズのエージェントが新規コンテキストで REQUIREMENTS.md と
   DECISIONS.md **だけ**を読んで、ユーザーに質問せず計画を立てられるか」を自問し、
   足りなければフロンティアに戻す
3. 最終 AUQ で以下を確認する:
   - 確定内容サマリーへの合意
   - research の調査対象（similar_oss / official_docs / local_projects、achat がつながっていれば agentmem も。
     multiSelect・デフォルト全選択）→ state.json の `research.targets` へ。`agentmem` は achat の掲示板・記憶・
     過去の作業記録で、他の人・他のマシンの知見まで届く（手順 4 の achat の設定が `--check` で接続になっているときだけ出す）
4. **実行パターンを選ぶ（ループ起動前に毎回）**:
   - 対話しているホストと実行エンジンは独立。Claude Code から Codex や OpenCode に任せてもよい。
   - 現在の設定をフェーズ別に表示し、次のパターンを対話で選んでもらう。
     選択肢数の上限に合わせて「すべて同じ / 役割を分ける / 現在の設定を使う」
     → 具体的なパターンの順に分けてもよい。未回答のまま起動しない。
     初回の推奨は現在のホストで全フェーズ実行、既存設定があればその維持。
   - パターンと保存値（省略されるフェーズは `engine` を使用）:

     | パターン | engine | phase_engines |
     |---|---|---|
     | すべて Claude | claude | `{}` |
     | すべて Codex | codex | `{}` |
     | 実装だけ Codex、ほかは Claude | claude | `{"impl":"codex"}` |
     | レビューだけ Codex、ほかは Claude | claude | `{"verify":"codex"}` |
     | 実装・レビューは Codex、調査・計画は Claude | claude | `{"impl":"codex","verify":"codex"}` |
     | すべて OpenCode | opencode | `{}` |
     | 実装だけ OpenCode、ほかは Claude | claude | `{"impl":"opencode"}` |
     | カスタム | 現在の既定値 | research / plan / impl / verify を個別に `claude` / `codex` / `opencode` から選択 |

   - プリセット選択時は `phase_engines` を表の値で**置き換える**。
     前回の割り当てを残さない。現在の設定を維持する場合だけ変更しない。
   - 各フェーズのエンジンとモデル（未指定なら CLI 既定）を一覧で提示する。
     モデル変更希望があれば Claude は `model.<phase>`、
     Codex は `codex.model.<phase>` / `codex.reasoning_effort.<phase>`、
     OpenCode は `opencode.model.<phase>`（`provider/model`）/ `opencode.variant.<phase>` に設定する。
   - **Claude の接続先（モデルの選択肢に入れる）**: Claude のフェーズがあれば `gsd-lite-loop.sh --providers` を実行する
     （1 行 1 プロファイル、タブ区切りで「名前 / モデル / 表示名 / `ok` か `NG: 理由`」。何も出なければこの項は飛ばす）。
     出たプロファイルは、Claude のフェーズのモデルの選択肢として Claude のモデルと並べて見せる
     （例: 「DeepSeek V4.1 Flash 1017（接続先 fixstars）」。表示名が空ならモデル名）。
     - 選び方を AUQ で聞く。プロファイルが 1 つなら「<表示名>（接続先 <名前>）で動かすフェーズ」を multiSelect で
       （選択肢は Claude で動くフェーズ。今そのプロファイルが入っているフェーズを説明に「現在」と書く）。
       2 つ以上ならフェーズごとに「Claude（`model.<phase>`）/ 各プロファイル」から選ぶ。
     - 選ばれたフェーズは `claude.provider.<phase>` にプロファイル名を書く。選ばれなかったフェーズは
       `claude.provider.<phase>` を**消す**（`del(.claude.provider.<phase>)`。親環境のログインと `model.<phase>` に戻る）。
       `model.<phase>` は書き換えない（戻したときにそのまま使えるように）。
     - state はリポジトリで共有される。プロファイルを持たない人のマシンでは、そのフェーズは警告付きで普段の Claude に
       戻って動く（止まらない）ことを、選ぶときに一言添える。
     - `claude.provider` はマイルストーンをまたいで残るので、**空でなければ毎回この AUQ を出して**続けるか戻すかを確かめる
       （一時的に別の接続先で動かしている利用者が、戻し忘れないようにするため）。
     - `NG: 理由` のプロファイルも選択肢には出し、説明に理由を書く。選ばれたら直し方を伝える
       （変数が空なら起動するシェルで export、trust が無ければ下記）。
     - プロファイルが無く、ユーザーが Bedrock・他社の Anthropic 互換 API で動かしたいと言ったら、
       `~/.config/gsd-lite/providers/<名前>.json`（`GSD_LITE_PROVIDERS_DIR`）に作る手順を示す。
       インストール済みテンプレートの `providers/` のサンプルから作り、URL・リージョン・モデル名はユーザーに確かめる。
       **キーの値はプロファイルにも state にも書かない**（`secret_env` には変数の名前だけ。値は起動するシェルで export）。
       接続先を Claude Code の `settings.json` の形で別フォルダに持っているなら、プロファイルは
       `{"config_dir": "<そのフォルダ>"}` だけでよい（そのターンだけ `CLAUDE_CONFIG_DIR` になる）。
     - そのフェーズのモデルは、プロファイルの `model` → `config_dir` の `settings.json` の `model` → `model.<phase>` の順。
     - `config_dir` のフォルダでは対象リポジトリをまだ trust していないことが多い。`--check` が trust で止まったら、
       `CLAUDE_CONFIG_DIR=<フォルダ> claude` を対象リポジトリで一度起動して trust を受け入れてもらう。
     - 保存後の `--check` の `provider` 行・`route` 行を見せ、止まったら表示された理由を伝える
   - **サブエージェントの利用**を AUQ で選ぶ（state の `subagents`。既存値があればそれを既定に）:
     - `auto`（推奨）: impl はタスクの並列サブ作業をサブエージェントで並行実装し、verify は
       レビューとセキュリティチェックを並列化する。ターンあたりのトークン消費は増える。
       対応していないエンジン（Codex exec 等）のフェーズでは自動的に従来動作になる
     - `off`: 従来通り 1 エージェントが順に実装・検証する（コスト重視・小規模向け）
   - **振り返り（reflect）**: state の `reflect`（既定 `true`）を確認する。`true` なら verify 合格後に
     reflect ターンが記録に基づく PMI の振り返りを `.gsd-lite/reflect/` に書いてから DONE になる。
     不要なら `false`（AUQ で聞くのは初回か変更希望があるときだけ）
   - **資源の上限（limits）**: ループ全体（ターンの CLI・テスト・ビルド）のメモリと CPU の上限を AUQ で選ぶ
     （state の `limits`。既存値があればそれを既定に）。テストやビルドの暴走でマシンが固まるのを防ぐ保険。
     先に `nproc` と `free -g` でマシンの CPU 数とメモリを調べ、選択肢の値に使う:
     - **上限なし**（`{"memory_max": "", "cpu_quota": ""}`。初回で、マシンに余裕があり他に重い作業が無いとき）
     - **メモリ半分・CPU 半分**（推奨。例: 16GB・4 コアなら `{"memory_max": "8G", "cpu_quota": "200%"}`）
     - **現在の設定を使う**（既存値があるとき）
     - カスタム（Other で値を書いてもらう。メモリは `8G` / `512M` / `75%`、CPU は `200%` の形）
     上限を付けるなら、保存後の `gsd-lite-loop.sh --check` の `limits` 行を見せる。WARN が出ていれば
     そのまま伝える（systemd が無い環境では上限なしで動く。CPU は管理者が delegate.conf を入れて OS を
     再起動するまで効かず、メモリだけ効く）。環境変数 `GSD_LITE_MEMORY_MAX` / `GSD_LITE_CPU_QUOTA` が
     設定されていれば state より優先されるので、選択と違うなら外した起動コマンドを使う（`off` は「付けない」）
   - **Codex の sandbox**（Codex を使うフェーズがあるときだけ）: state の `codex.sandbox` を AUQ で選ぶ
     （既存値があればそれを既定に。空なら `workspace-write`）。verify や impl が Docker・外部ネットワーク・
     ワークスペース外への書き込みを使うなら `workspace-write` では失敗し、そのターンが BLOCKED になる:
     - **workspace-write**（既定。テスト・ビルドがワークスペース内で完結するとき）
     - **danger-full-access**（Docker / docker compose・外部 API・ワークスペース外のキャッシュ等を使うとき。
       sandbox なしで無人ターンが FS 全体に書けるので、隔離された開発環境に限る）
     - **現在の設定を使う**（既存値があるとき）
     state に保存すれば次のマイルストーンにも引き継がれる（起動コマンドに `GSD_LITE_CODEX_SANDBOX` を付ける
     必要はない。付いていれば state より優先される）。保存後の `--check` の `sandbox` 行で実効値を見せる
   - **起動時の環境変数の引き継ぎ**: 前回のマイルストーン（`.gsd-lite/archive/<前回>/DECISIONS.md`、gsd-control 形は
     制御側の前回分）に、環境変数付きの起動コマンド（`GSD_LITE_...=... gsd-lite-loop.sh`）が書かれていれば
     一覧にして見せる。state に持てるもの（`GSD_LITE_CODEX_SANDBOX` → `codex.sandbox`、`GSD_LITE_MEMORY_MAX` /
     `GSD_LITE_CPU_QUOTA` → `limits`）は state に移し、残り（`GSD_LITE_CLAUDE_TOKEN_VARS` 等）は今回も付けるかを
     AUQ で確認する。付けるなら今回の DECISIONS.md に**起動コマンドを環境変数込みで**書き、手順 6 の起動にも付ける
   - **BLOCKED の通知**: ループが BLOCKED で止まっても、通知の仕組みが無ければ誰にも知らされない（人が気づくまで
     止まったまま）。`gsd-lite-loop.sh --check` の `notify` 行が `none` なら、AUQ で選ぶ:
     - **フックを置く**: サンプル（インストール済みテンプレートの `hooks/on-blocked.sh`）を
       `.gsd-lite/hooks/on-blocked.sh` にコピーして `chmod +x` し、ユーザーが選んだ送信手段（ntfy / Slack / メール /
       デスクトップ通知）の行を有効にする。Webhook URL などの宛先はリポジトリに書かず環境変数で渡す
       （スクリプトごとリポジトリの外に置くなら `GSD_LITE_ON_BLOCKED=<パス>` で起動する）
     - **通知なし**（短時間で見守る、またはこまめに `--status` を見る。確認する頻度を DECISIONS.md に書く）
   - **achat（agentmem MCP。任意）**: 学びをリポジトリ・マシンをまたいで共有する。`gsd-lite-loop.sh --check` の
     `agentmem` 行を見る:
     - `off` で、利用者が achat を使っている（`AGENTMEM_TOKEN` が設定されている、またはプロジェクトの `.mcp.json` に
       agentmem がある）なら、AUQ で「使う / 使わない」を聞く（初回か変更希望があるときだけ）。使うなら次を聞いて
       state の `agentmem` に保存する: `url`（achat ポータルの MCP 設定タブにある接続先。`/mcp` まで）、`project`
       （このリポジトリの achat project の slug。gsd-control 形で `targets.<name>.agentmem_project` があればそれ）、
       `shared_project`（gsd-lite を使う全リポジトリで共有する project の slug。gsd-control 形で config.json の
       `defaults.agentmem.shared_project` があればそれ。無ければ案として `gsd-lite`）。掲示板は project の中でしか
       検索できないので、gsd-lite 自体の学びは共有側に書く。両方の project に参加しておく必要がある
       （AM012 / AM013 は未参加。achat ポータルで参加する）
     - ループは state の `agentmem` と環境変数 `AGENTMEM_TOKEN` があるターンにだけ、MCP サーバー `agentmem` と
       `agentmem-gsd` をエンジンに渡す（トークンの値はどこにも書かない）。保存後の `--check` の WARN をそのまま伝える:
       トークン未設定 → ループを起動するシェルで `export AGENTMEM_TOKEN=...`（DECISIONS.md には変数名だけ書く）/
       届かない → url を確かめる（届かなくてもループは止まらず、achat なしで進む）/
       フックの WARN → `.claude/settings.json` の achat のフック（`/api/digest` / `/api/suggest` の curl）を、無人ターンでは
       動かない形に直すかを AUQ で聞く。直すなら各 command の先頭に `[ -n "${GSD_LITE_UNATTENDED:-}" ] || ` を足す
       （ループはターンに `GSD_LITE_UNATTENDED=1` を渡す。対話のセッションではこれまでどおり動く）
     - 決めたことは DECISIONS.md に記録する
   - **選択したエンジンの準備**: 現在のホストのインストール済みテンプレートを使い、
     Claude が含まれれば `.claude/skills/`、Codex が含まれれば `.agents/skills/`、
     OpenCode が含まれれば `.opencode/skills/` に
     6 スキル（research / plan / impl / verify / reflect / discuss）を配置する。
     既存スキルに独自変更があれば無断で上書きせず確認する。
     Claude が含まれる場合は Claude 用 init の allowlist マージ手順も行う。
     テンプレートがなければ `install.sh --engine all` を案内して準備完了まで待つ。
     Codex / OpenCode ホストのテンプレートに allowlist がない場合は

     `~/.claude/gsd-lite/templates/settings.allowlist.json` を使う。
   - どちらのホストでも、必要な CLI が PATH 上にあり、認証・権限が準備済みか確認する。
     `GSD_LITE_ENGINE` が設定されていれば**全フェーズを上書きする**ので、
     選択と違う場合はその変数を外した起動コマンドを使う（黙って無視しない）。
   - 決定を DECISIONS.md に記録し、state の `engine` / `phase_engines` を更新。
     同じ環境で `gsd-lite-loop.sh --check` を実行し、不足があれば起動せず解消する。
     このチェックは CLI / スキル配置 / git 識別 / Codex sandbox の実効性 / **Claude Code の trust** の検証で、
     認証や外部サービス疎通の保証ではない。Codex sandbox の検証で止まった場合は
     表示された対処（state の `codex.sandbox` を `danger-full-access` に、カーネル設定、
     impl / verify を Claude に切り替え）のどれにするかを AUQ で選んでもらい、DECISIONS.md に記録する
     （`danger-full-access` は環境変数ではなく state に保存する。次のマイルストーンにも引き継がれる）。
     **trust の検証で止まった場合**（「this workspace is not trusted by Claude Code」）: このディレクトリが
     Claude Code で trust 済みでないと、無人ターンの `claude -p` は `.claude/settings.json` の allowlist を
     すべて無視し、WebSearch / WebFetch / テスト実行などが権限拒否になる（対話の起動を bypass モードで
     行うとダイアログが出ず未 trust のまま残る）。対処は表示どおり: 別ターミナルでこのディレクトリの `claude` を
     対話起動して trust を受け入れるか、claude を終了した状態で `~/.claude.json` の
     `projects["<絶対パス>"].hasTrustDialogAccepted` を true にする。解消してから再度 `--check`

5. **マイルストーンブランチ作成**（base の整理は手順 0-a で済んでいる前提）:
   - gsd-control 形: 制御側ブランチ `gsd-lite/<slug>` は「作業場所の判定」で作成済み。ここでは
     **対象側**に `git -C $TARGET checkout -b gsd-lite/<slug>`（対象の base から。base にコミットが
     あることを `git -C $TARGET rev-parse --verify HEAD` で確認）を作る。state の `branch` は
     対象側のブランチ名と base。state・REQUIREMENTS / DECISIONS は制御側にコミットし、対象側には
     0-c で採った AGENTS.md / CLAUDE.md の変更だけをコミットする（以下の in-repo 向け手順のうちブランチ作成は
     対象側、コミットは制御側と読み替える）
   - discuss で作成した要件・設定・スキル以外の未コミット変更を確認し、
     関係ない変更があれば扱いを相談する。今回生成したファイルは次のコミットに含める
   - 現在のブランチ（= base）名を控え、**base にコミットが存在することを確認する**
     （`git rev-parse --verify HEAD >/dev/null 2>&1`）。unborn（初回コミット前）なら、
     ブランチを切る前に `.gsd-lite/` の足場と REQUIREMENTS / DECISIONS を base 上で
     `gsd-lite: scaffold` としてコミットする（init がコミットし損ねたケース。base が無いと
     verify が差分範囲を取れず、マージ先も存在しない）。そのうえで `git checkout -b gsd-lite/<slug>`
   - state.json を**すべて更新してから**コミットする: `milestone`（kebab-case の
     スラッグ）/ `target`（`name` と `path`。in-repo 形は `{"name": "", "path": "."}` のままでよい）/
     `branch`（name と base）/ `research.targets` / `phase: "research"` /
     `next_command: "/gsd-lite-research"` / `engine` / `phase_engines` / `codex` / `claude` / `subagents` / `reflect` / `limits` / `agentmem` /
     `fix_round: 0` / `updated_at`（修正ラウンドは 0-a の記載どおり、ブランチを作らず
     `fix_round` / `phase` / `next_command` / `verify_round` / `updated_at` を更新）。
     そのうえで REQUIREMENTS.md / DECISIONS.md / state.json と追加・更新したスキル・設定
     （in-repo 形では 0-c で更新した AGENTS.md / CLAUDE.md も）を一括コミット
     （`gsd-lite(discuss): <slug> 要件確定`）。
     **遷移（next_command）までコミットに含めるのが重要** — コミット後に state を
     いじると、git 復元時に要件確定済みなのに DISCUSS へ戻ってしまう
   - achat のツールが見えるなら、コミットの後に 0-c で採った AGENTS.md の決まりを `agentmem` の `remember` に
     1 件ずつ残す（kind `preference`、scope `repo`。先に `set_context` で repo_url（`git -C $TARGET remote get-url origin`）・
     base_path・branch を登録する）。正本は AGENTS.md で、achat は横断検索のための写し。秘密や顧客名は書かない
6. 最後の AUQ で「今すぐループを起動するか」「起動する場合、このセッションで
   進捗を見守るか」を確認する:
   - **起動する**: `setsid gsd-lite-loop.sh >> .gsd-lite/logs/loop.log 2>&1 &` で（手順 4 で付けると決めた
     環境変数があれば先頭に付ける。`>>` で追記。`>` だと
     再起動のたびに前回のループログが消える）
     デタッチ起動し、`gsd-lite-loop.sh --status` などの監視コマンドを提示して
     **即座に手を離す**。以後このセッションでログをポーリングしない。
     state の `limits`（手順 4 で選んだもの）があればループ自身が systemd の scope に入り直すので、
     起動コマンドは同じ（`--status` の `limits` 行で確認できる）
   - **見守る**: バックグラウンドのサブエージェントを 1 体起動する。指示は
     「$MS/state.json の phase の変化と loop.pid の消滅を Bash の
     until ループで待ち、変化のたびに 1 行（例: `research → plan (turn 3)`）、
     終了時に最終状態を報告して終わる。ログ全文は読まない。
     state の複数フィールドは 1 回の jq でまとめて読むこと
     （別々に読むとターン更新中の値が混ざる読み取りレースがある）」
   - **自分で起動する**: 起動コマンドを提示して終了

## 起動後の中断・再開の案内

起動時には次の操作も案内する:
- 別ターミナルの `gsd-lite-loop.sh --stop` で現在のタスク終了後の中断を依頼できる。
- `gsd-lite-loop.sh --status` で依頼・稼働状態を確認する。
- 再開は `gsd-lite-loop.sh`。排他取得後に前回のフラグを消し、保存された次のタスクから続ける。
- 中断は終了コード7で、phase / next_command は維持される。
  中断からの再開に discuss のやり直しや state の初期化は不要。
