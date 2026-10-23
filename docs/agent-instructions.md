# AGENTS.md と CLAUDE.md の構成方針

gsd-lite の無人ループは、フェーズごとに Claude Code・Codex・OpenCode を使い分けられる。
エンジンごとに自動で読む指示ファイルが違うので、そのままでは一部のエンジンのターンだけが
プロジェクトの決まりを知らずに動く。どのエンジンも同じ決まりで動くよう、gsd-lite を使うプロジェクトでは
エージェント向けの指示ファイルを次の方針で置く（gsd-lite が init・`--check`・スキルでどう扱うかは末尾の節）。

## 構成

| ファイル | 中身 | 読むエンジン |
|---|---|---|
| `AGENTS.md` | **本体**。全エンジン共通の指示をすべてここに書く | Codex・OpenCode が直接読む。Claude Code は CLAUDE.md 経由で読む |
| `CLAUDE.md` | 1 行目に `@AGENTS.md`。その下には Claude Code だけに要る指示を書く（今は無い） | Claude Code |

- 共通の指示は AGENTS.md にだけ書く。CLAUDE.md に同じ内容を写さない（二重管理になり、片方だけ直して食い違う）
- CLAUDE.md の `@AGENTS.md` は消さない。消すと、Claude Code は AGENTS.md を読まなくなる（下の「各エンジンの読み方」）
- シンボリックリンク（`CLAUDE.md -> AGENTS.md`）は使わない。Claude Code の Edit / Write ツールはリンク経由の書き込みを拒否するので、無人ターンが指示ファイルを直せなくなる
- Claude Code の `/config` の Project instructions（AGENTS.md も読む設定）には頼らない。マシンごとの設定でリポジトリに残らず、`claude -p` を動かすほかのマシンでは効かない

## 各エンジンの読み方（2026-10-23 に確認）

| エンジン | 読むもの | 確認した方法 |
|---|---|---|
| Claude Code 2.1.309 | CLAUDE.md。CLAUDE.md があるディレクトリでは AGENTS.md を読まない（2.1.277 からの既定）。`@パス` で書いたファイルは起動時に展開する（相対パスは書いたファイル基準、最大 4 段） | `claude -p` で AGENTS.md の文を引用させた（ツールを使わず答えた） |
| Codex CLI 0.163.0 | リポジトリのルートから作業ディレクトリまで、各ディレクトリの AGENTS.md。CLAUDE.md は読まない。上限は合計 32 KiB（`project_doc_max_bytes`） | `codex exec --sandbox read-only` で AGENTS.md の文を引用させた（ツールを使わず答えた） |
| OpenCode | AGENTS.md。無いときは CLAUDE.md | 公式文書（https://opencode.ai/docs/rules/）のみ |

出典: https://code.claude.com/docs/en/memory.md 、https://learn.chatgpt.com/docs/agent-configuration/agents-md

Codex が CLAUDE.md を読まないことは実害につながった。plugin-viewer（CLAUDE.md だけを置いていたプロジェクト）では、Codex のターンは gsd-lite のスキルの手順に従って `cat CLAUDE.md` するまで決まりを知らなかった。そのため最初の `gsd-lite-loop.sh --where` を相対パスで呼び、6 回とも失敗した（plugin-viewer の `.gsd-lite/reflect/20261023-0334-plugin-viewer.md`）。本体を AGENTS.md に置くのはこのため。

## 何をどこに書くか

| 書く場所 | 書くもの | 例 |
|---|---|---|
| `AGENTS.md` | エンジンに関係なく守ってほしい作業上の決まり | 無人ターンで承認待ちにならないコマンドの形、テスト・依存追加の呼び方、読めないファイル（`.env*`） |
| `CLAUDE.md`（`@AGENTS.md` の下） | Claude Code の機能に依存する指示だけ | （今は無い）特定のスキルやサブエージェントの使い方など |
| `README.md` | 人向けの説明。使い方・構成・プラグインの書き方 | AGENTS.md からは参照するだけで、写さない |
| `.gsd-lite/` | マイルストーンの要件・決定・計画・申し送り | 一時的な申し送りは PROGRESS.md。繰り返し効く決まりになったら AGENTS.md に移す |
| `~/.claude/CLAUDE.md` など利用者の設定 | 個人の好み（応答言語など） | リポジトリには入れない |

書かないもの: 秘密情報、コードを読めば分かる構造の説明、一度きりの作業メモ。

## 書き方

- 1 項目 1 行の箇条書きにし、「何をする / しない」と「しないとどうなるか」を書く（例: 「`git -C` は許可リストに当たらず承認待ちで止まる」）
- エンジンで呼び名が違うものは併記する（例: 「編集ツール（Claude は Edit / Write、Codex は apply_patch）」）
- エンジンが最初の操作でつまずきやすい決まりほど上に置く（例: `gsd-lite-loop.sh` の呼び方）
- Codex の上限（32 KiB）を超えないよう短く保つ。長い説明は README や docs に置き、パスだけ書く

## サブディレクトリに置くとき

`web/` のように、そこだけの決まりが要るディレクトリには、ルートと同じ組を置く:
そのディレクトリの `AGENTS.md`（本体）と、`@AGENTS.md` だけの `CLAUDE.md`。
Claude Code は CLAUDE.md の有無で AGENTS.md を読むかを決めるので、組で置けばどの階層でも同じ読み方になる。

## 変えたときの確認

指示ファイルを変えたら、両方のエンジンで読み込まれていることを確かめる（どちらもツールを使わずに答えさせる）:

```
claude -p --model haiku "ツールを使わず、コンテキストにあるプロジェクトの指示だけで答えて。<確かめたい決まり>について何と書かれているか 1 行で引用して。無ければ「なし」"
codex exec --sandbox read-only "ツールやコマンドは使わず、読み込まれている AGENTS.md だけで答えて。<確かめたい決まり>について何と書かれているか 1 行で引用して。無ければ「なし」"
```

gsd-lite の振り返り（`.gsd-lite/reflect/`）で「次回への提案」に挙がった作業上の決まりは、次の discuss で採否を決め、採るものを AGENTS.md に足す。

## gsd-lite での扱い

| 場面 | すること |
|---|---|
| `/gsd-lite-init`（in-repo 形） | 指示ファイルの組を確かめる。どちらも無ければ組を作る。AGENTS.md だけなら `@AGENTS.md` の CLAUDE.md を足す。CLAUDE.md だけ・取り込み行が無い・シンボリックリンクのときは、直し方を提案して承認を得てから直す（勝手に書き換えない）。スキル更新モードでも同じ確認をする |
| `gsd-lite-loop.sh --check` と起動時 | ループを動かすディレクトリの組を見て、使うエンジンが読めない形なら WARN を出す（止めない）。Codex のフェーズがあるのに CLAUDE.md だけ / Claude のフェーズがあるのに CLAUDE.md が `@AGENTS.md` を取り込んでいない・CLAUDE.md が無い / CLAUDE.md がシンボリックリンク。`GSD_LITE_INSTRUCTIONS_CHECK=skip` で省略 |
| 各フェーズのスキル | 規約は AGENTS.md を本体として読む（無ければ CLAUDE.md）。CLAUDE.md の `@AGENTS.md` より下は Claude 固有の指示 |
| gsd-control 形 | 対象（`work/<name>`）の指示ファイルは自動では読まれないので、スキルが `work/<name>/AGENTS.md` を明示的に読む。制御リポジトリのルートに指示ファイルを置くときも同じ組にする。init は対象リポジトリの指示ファイルを書き換えない |
| reflect → discuss | reflect は「次回への提案」のうち、プロジェクトで繰り返し効く作業上の決まりに `（AGENTS.md 候補）` と付ける。discuss はそれを AUQ で採否確認し、採ったものを AGENTS.md に足してマイルストーンのコミットに含める（採否は DECISIONS.md） |
