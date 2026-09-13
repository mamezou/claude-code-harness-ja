# claude-code-harness-ja

クラウド変更コマンドの停止と、設定・規則ファイルの保護を中心に、応答の文体検査を任意で
加える Claude Code プラグインです。hook が実行前・応答終了時に検査し、条件を満たさない
操作と応答を止めます。日本語で応答するプロジェクト向けで、案件固有の値は利用側の
`.claude/harness.json` に置きます。

止める対象は次の3つです。

1. az / aws / cdk の変更系コマンド。手順書の Read と、利用者の承認の文字列の両方が必要
2. `.claude/` 配下(設定・hook・rules・skills)の書き換え。利用者の承認の文字列が必要
3. 応答の文体違反。既定は4種類のみで、設定で増やせる

`.claude/harness.json` が無い間、hook は何もしません。まず `/harness-ja:harness-init` を
実行してください。

## 収録物

| 種別 | 内容 |
|---|---|
| hooks(6本) | クラウド変更コマンドの停止、設定・規則ファイルの保護、応答の文体検査、送付文面の事前検査、必読資料の先読みの強制、インライン PowerShell の禁止 |
| Output Style | `Concise JA`。簡潔な日本語応答と、返信文体の規則 |
| rules テンプレート(2本) | 着手と承認、文章の書き方 |
| Skills(2本) | `/harness-ja:harness-init`(初期設定)、`/harness-ja:harness-review`(検知ログのレビュー) |
| tests | hook 6本の合成入力テスト。`bash tests/run.sh` |

## 用語

| 語 | 意味 |
|---|---|
| 差し戻し | hook が終了コード2を返し、Claude に応答を作り直させること |
| Stop | 返信の終了時に走る検査 |
| PreToolUse | ツールの実行直前に走る検査。終了コード2でツールを実行させない |
| 承認の文字列 | 利用者が書くと操作が通る文字列(`[change-go: <案件>]`、`[harness-go]`)。それだけの行に書いたときだけ有効 |
| バイパスの文字列 | 利用者が書くと検査を飛ばす文字列(`[hook-bypass: <検査名>]`)。それだけの行に書いたときだけ有効 |
| `principal` | 通知文で使う利用者の呼称(既定「依頼者」)。権限を識別する設定ではない |
| `cwdMatch` | 案件を選ぶためのパスの一部。パス区切り単位で cwd かコマンド中のパスと照合する(`/work/project-a-old` は `project-a` に一致しない) |
| `runbookPattern` | 手順書のパスに当てる `grep -E` 形式の正規表現 |

承認の文字列とバイパスの文字列は、利用者が自分のメッセージに書く運用です。Claude 側からの
提案・要求は rules テンプレートで禁止しています。引用・質問の中に書いた場合
(「`[harness-go]` とは何ですか」)は無効です。

## 動作環境

- Linux(bash、GNU coreutils、`jq`)。macOS は未検証

## インストール

```
/plugin marketplace add mamezou/claude-code-harness-ja
/plugin install harness-ja@claude-code-harness-ja
```

利用側プロジェクトで初期設定を行います。

```
/harness-ja:harness-init
```

`.claude/harness.json` の作成、rules テンプレートの複製、`.gitignore` の追記を行います。
作成された `harness.json` を案件に合わせて書き換えてください。Output Style は `/config`
から「Concise JA」を選びます。

## hook の一覧

| hook | イベント | 止める条件 | バイパス |
|---|---|---|---|
| `cloud-change-check.sh` | PreToolUse(Bash) | az / aws / cdk の変更系コマンドで、手順書の Read と `[change-go: <案件>]` のいずれかが無い。変更系を検知したのに設定のどの案件にも一致しないときも止める | `[hook-bypass: cloud-change]` |
| `harness-change-check.sh` | PreToolUse(Bash / Write / Edit) | `.claude/` 配下(hooks / rules / skills / settings 等)の書き換えで、`[harness-go]` が無い。例外として、プラグイン配下からの `cp`、`mkdir`、`.claude/harness.json` の新規作成は初期設定のため通す | なし(承認の文字列がバイパスを兼ねる) |
| `response-quality.sh` | Stop | 応答本文に文体違反(既定は4種類。下の表を参照) | `[hook-bypass: response-quality]` |
| `draft-precheck.sh` | PreToolUse(Write / Edit) | 送付文面に内部パス・ローカル拡張子・組版記号・外部 AI 言及・禁止語・長い識別子の繰り返し | `[hook-bypass: draft-precheck]` |
| `require-reading.sh` | PreToolUse(Write / Edit) | 必読資料を直近で Read せずに対象ファイルを編集 | `[hook-bypass: resource-reading]` |
| `no-inline-powershell.sh` | Stop | 5行以上の PowerShell をファイル化せずにコードブロックで提示(既定は無効) | なし |

設定ファイルが見つからない場合、6本とも何もしません。設定ファイルはあるが JSON として
読めない場合、PreToolUse の4本は「設定ファイルが読めません: <パス>」を出してツールを止め、
Stop の2本は同じ文を出して応答は止めません。

## 応答の文体検査

`responseQuality.patterns` に書いた番号のパターンだけを実行します。既定は
`[3, 4, 8, 19]` です。

| No. | 名前 | 既定 |
|---:|---|---|
| 1 | 選択肢の羅列 + 末尾の確認質問 | 無効 |
| 2 | 英語 UI 名の和訳なしの使用 | 無効 |
| 3 | ひな形・叩きを完了扱い | 有効 |
| 4 | 組版記号(§ ¶ ‡ †)の使用 | 有効 |
| 5 | 装飾語・抽象語での文末(文末にある語だけを見る) | 無効 |
| 6 | 言い換え対象語を2語以上 | 無効 |
| 7 | 指示語が3回以上 | 無効 |
| 8 | 空約束・態度の宣言 | 有効 |
| 9 | 質問への応答での無指示の作業宣言 | 無効 |
| 10 | 長い識別子のフル表記を3回以上 | 無効 |
| 11 | 整理用ラベル(通1 / 2通目)での報告 | 無効 |
| 12 | 指示待ちで締める | 無効 |
| 13 | 送付文面の1文が60字超 | 無効 |
| 14 | 指摘への理由なしの撤回・同意 | 無効 |
| 15 | 見出し・表のセルが文で終わる | 無効 |
| 16 | 表のセルと本文の重複 | 無効 |
| 17 | 括弧の中の述語 | 無効 |
| 18 | 前置き・自己評価の定型句(文頭・行頭にある語だけを見る) | 無効 |
| 19 | 確認質問への根拠なしの否定断定 | 有効 |

差し戻し後の再生成(`stop_hook_active=true`)も検査します。同じ利用者入力への差し戻しが
3回に達したら、4回目の生成を `[regen-limit]` 付きで通します(無限ループ防止)。

検知の記録は `.claude/harness-detections.log` に1行1件で残り、
`/harness-ja:harness-review` の集計元になります。行の形式は
`<時刻>\t[session:<ID>] [input:<UUID>] <検知内容>` です。タグの無い旧形式の行は集計に
入りません。

## 設定ファイル `.claude/harness.json`

`examples/harness.json` が全キーの例です。使わない機能は `"enabled": false` で止めます。

| キー | 用途 |
|---|---|
| `principal` | 通知文で使う利用者の呼称(既定「依頼者」) |
| `responseQuality.patterns` | 実行するパターン番号の配列(既定 `[3, 4, 8, 19]`) |
| `responseQuality.uiTerms` / `fluffTerms` / `bannedLeads` | パターン2 / 5 / 18 の辞書への追加 |
| `responseQuality.logPath` | 検知ログの置き場(プロジェクトルートからの相対パス) |
| `responseQuality.regenLimitPerInput` | 同じ利用者入力への差し戻しの上限回数(既定3) |
| `cloudChange.projects[]` | クラウド変更コマンドの停止の対象。`clis`(az / aws / cdk)、`cwdMatch`、`runbookPattern`、`runbookHint`、`guideRef` |
| `harnessChange.token` / `excludePatterns[]` | 設定・規則ファイルの保護で使う承認の文字列(既定 `[harness-go]`)と除外パス(既定 `.claude/projects/`) |
| `draftPrecheck.targets[]` | 送付文面の置き場(bash の case パターン)。`excludePatterns[]`、`bannedTerms[]`、`honorific` |
| `draftPrecheck.checks` | 検査項目ごとの on / off。`bannedTerms` / `internalPaths` / `extensions` / `typography` / `externalAi` / `honorific` / `longIdentifiers`(既定すべて true) |
| `requireReading.rules[]` | 編集対象(`target`)と必読資料(`requiredReadPattern`)の対応表。`mode: "logs"` で作業ログの特例 |
| `noInlinePowershell.enabled` | 既定は `false`。使う場合だけ `true` にする |
| `noInlinePowershell.cwdMatch` | 指定すると、cwd がそのディレクトリ名を含むときだけ検査する(案件を限る用途) |

設定ファイルは `HARNESS_CONFIG` 環境変数、`$CLAUDE_PROJECT_DIR/.claude/harness.json`、
hook 実行時の cwd から上へ辿った `.claude/harness.json` の順で探します。

## rules テンプレートについて

プラグインは `.claude/rules/` 相当の常に読み込まれる指示を配布できないため、
`rules-templates/` を `/harness-ja:harness-init` で利用側へ複製します。複製後は利用側で
自由に編集してください。`start-approval.md` は作者の作業様式です。破壊的操作・クラウド
変更・根拠確認の項目以外は削ってかまいません。

文章の規則のうち、次の3つは grep や hook で検知できないため、`writing-style.md` の
手順で読み取り専用のサブエージェント(model: sonnet)へ主語と述語の抜き出しを委任して
確かめます。

- 文は主語と述語だけを抜き出して読み、対応しない文を直す
- 短くするときは文を分ける。主語・目的語を削って短くしない
- 段落は「読み手がこの段落を読んで次に何をするか」で組む

## 検知ログのレビュー `/harness-ja:harness-review`

`skills/harness-review/summarize.sh` が検知ログを集計し、Markdown で出します。

| 節 | 内容 |
|---|---|
| 期間と件数 | 直近28日(`--days` で変更)と前期間の件数、差し戻し上限で通過した件数 |
| 週別件数 | 月曜起点の週ごとの件数 |
| 種別ごとの件数 | 今期間・前期間・増減 |
| 種別ごとの検出例 | 各3件。誤検知か実違反かを読んで判断する材料 |
| 検出語の頻度 | 辞書から外す語、閾値を上げる語の候補 |
| 常に読み込まれる指示の行数 | CLAUDE.md と rules の合計。増え続けていないかの確認 |

Skill は集計を読んだ上で、`harness.json` の変更前後と規則の追記文を【確認点】の型で提示し、
承認された項目だけ反映します。1回のレビューで変える項目は3件までとし、効果を次回の件数で
確かめてから次を変えます。

## テスト

リポジトリを clone した開発者向けです(インストールした利用側プロジェクトには
`tests/` が入りません)。

```bash
bash tests/run.sh
```

hook 6本に合成の会話履歴 JSONL と入力 JSON を与え、差し戻し(終了コード2)と通過
(終了コード0)、承認の文字列、バイパスの文字列、設定なし、設定の壊れ、差し戻し回数の
上限、検知ログの UTF-8 を確認します。hook や辞書を変えたら実行してください。

## ライセンス

MIT
