# claude-code-harness-ja

Claude Code の hook で、日本語の応答品質とクラウド運用のガードレールを機械的に強制し、
差し戻しの記録から規則を直す週次の改善を回すプラグインです。複数案件の SRE 業務で
積み上げた再発防止策を、案件に依存しない形にまとめました。案件固有の値は利用側の
`.claude/harness.json` で指定します。

## 改善の回し方

1. hook が応答を差し戻し、検知した種別と語を `.claude/harness-detections.log` に記録する
2. 週次で `/harness-review` を実行し、種別ごとの件数・前週比・検出例を集計する
3. 検出例を読んで「誤検知 / 実違反 / 規則の曖昧さ」に分け、辞書と閾値(`harness.json`)、
   規則(rules と Output Style)、失敗の台帳(`docs/logs/lessons-*.md`)への反映案を出す
4. 承認された項目だけ反映し、変更の日付と理由を `lessons-index.md` に残す
5. 次の週の件数で効果を確かめる

機械で止められる違反は hook へ、止められない判断は規則へ、判断の根拠は台帳へ、と置き場を
分けています。hook と規則の両方に同じ違反を書くのは、規則の側が「なぜ止めるか」を
説明するためです。

## 収録物

| 種別 | 内容 |
|---|---|
| hooks(6本) | 応答品質ゲート、クラウド変更コマンドのゲート、ハーネス変更のゲート、送付文面の事前検査、資料先読みの強制、インライン PowerShell の禁止 |
| Output Style | `Concise JA`。簡潔な日本語応答と、依頼者への返信文体の規則 |
| rules テンプレート(2本) | 着手と承認、文章の書き方 |
| Skills(2本) | `harness-init`(初期設定)、`harness-review`(週次レビュー) |
| docs テンプレート(2本) | 失敗の台帳 `lessons.md` と索引 `lessons-index.md` |
| tests | hook 6本の合成入力テスト。`bash tests/run.sh` |

## 動作環境

- Linux(bash、GNU coreutils、`jq`)。macOS は未検証

## インストール

```
/plugin marketplace add mamezou/claude-code-harness-ja
/plugin install harness-ja@claude-code-harness-ja
```

利用側プロジェクトで初期設定を行います。

```
/harness-init
```

`.claude/harness.json` の作成、rules テンプレートと lessons 台帳の複製、
`.gitignore` の追記を行います。作成された `harness.json` を案件に合わせて書き換えてください。Output Style は
`/config` から「Concise JA」を選びます。

## hook の一覧

| hook | イベント | 止める条件 | バイパス |
|---|---|---|---|
| `response-quality.sh` | Stop | 応答本文に19種の文体違反(装飾語で締める、見出し・表・箇条書きが文で終わる、指示語の多用、逃げの締め、確認質問への根拠なしの否定断定 等) | `[hook-bypass: response-quality]` |
| `change-gate.sh` | PreToolUse(Bash) | az / aws / cdk の変更系コマンドで、手順書の Read と `[change-go: <案件>]` のいずれかが無い | `[hook-bypass: change-gate]` |
| `harness-change-gate.sh` | PreToolUse(Bash / Write / Edit) | `.claude/` 配下(hooks / rules / skills / settings 等)の書き換えで、`[harness-go]` が無い | なし(トークンが承認を兼ねる) |
| `draft-precheck.sh` | PreToolUse(Write / Edit) | 送付文面に内部パス・ローカル拡張子・組版記号・外部 AI 言及・禁止語・長い識別子の繰り返し | `[hook-bypass: draft-precheck]` |
| `require-reading.sh` | PreToolUse(Write / Edit) | 必読資料を直近で Read せずに対象ファイルを編集 | `[hook-bypass: resource-reading]` |
| `no-inline-powershell.sh` | Stop | 5行以上の PowerShell をファイル化せずにコードブロックで提示 | なし |

バイパストークンは利用者が自分のメッセージに書く運用です。Claude 側からの提案・要求は
rules テンプレートで禁止しています。

応答品質ゲートは、差し戻し後の再生成(`stop_hook_active=true`)も検査します。同じ依頼者入力
への差し戻しが3回に達したら、4回目の生成を `[regen-limit]` 付きで通します(無限ループ防止を
兼ねます)。加えて、同じセッションで直近30分に別の入力を2件差し戻していれば、次の差し戻しを
`[regen-skip]` 付きで通します(体裁の差し戻しの反復で読みやすさが下がるのを防ぐため)。

検知の記録は `.claude/harness-detections.log` に1行1件で残り、`/harness-review` の集計元に
なります。行の形式は `<時刻>\t[session:<ID>] [input:<UUID>] <検知内容>` で、上の2つの集計は
セッションと入力の単位で数えます。タグの無い旧形式の行は集計に入りません。

## 設定ファイル `.claude/harness.json`

`examples/harness.json` が全キーの例です。使わない機能は `"enabled": false` で止めます。

| キー | 用途 |
|---|---|
| `principal` | 承認者の呼び名。hook の通知文に使う(既定「依頼者」) |
| `responseQuality.uiTerms` / `fluffTerms` / `bannedLeads` | 検知語の追加。既定の辞書に加算 |
| `responseQuality.logPath` | 検知ログの置き場(プロジェクトルートからの相対パス) |
| `responseQuality.regenLimitPerInput` | 同じ依頼者入力への差し戻しの上限回数(既定3) |
| `responseQuality.regenSkipWindowSec` / `regenSkipThreshold` | 再生成ループ防止の窓と閾値。窓内に差し戻した他の入力の数で判定 |
| `changeGate.projects[]` | 変更ゲートの対象。`clis`(az / aws / cdk)、`cwdMatch`、`runbookPattern`、`runbookHint`、`guideRef` |
| `harnessGate.token` / `excludePatterns[]` | ハーネス変更ゲートの GO トークン(既定 `[harness-go]`)と除外パス(既定 `.claude/projects/`) |
| `draftPrecheck.targets[]` | 送付文面の置き場(bash の case パターン)。`excludePatterns[]`、`bannedTerms[]`、`honorific` |
| `requireReading.rules[]` | 編集対象(`target`)と必読資料(`requiredReadPattern`)の対応表。`mode: "logs"` で作業ログの特例 |
| `noInlinePowershell.scriptDirHint` | ファイル化先の案内文 |

設定ファイルは `HARNESS_CONFIG` 環境変数、`$CLAUDE_PROJECT_DIR/.claude/harness.json`、
hook 実行時の cwd から上へ辿った `.claude/harness.json` の順で探します。設定が無い場合、
応答品質ゲート、ハーネス変更ゲート、PowerShell 禁止は既定値で動き、残り3本は何もしません。

## rules テンプレートについて

プラグインは `.claude/rules/` 相当の常時ロード指示を配布できないため、`rules-templates/` を
`/harness-init` で利用側へ複製します。複製後は利用側で自由に編集してください。

文章の規則のうち、次の3つは grep や hook で検知できないため、`writing-style.md` の
手順で読み取り専用のレビューエージェントに主語と述語の抜き出しを委任して確かめます。

- 文は主語と述語だけを抜き出して読み、対応しない文を直す
- 短くするときは文を分ける。主語・目的語を削って短くしない
- 段落は「読み手がこの段落を読んで次に何をするか」で組む

## 週次レビュー `/harness-review`

`skills/harness-review/summarize.sh` が検知ログを集計し、Markdown で出します。

| 節 | 内容 |
|---|---|
| 期間と件数 | 直近28日(`--days` で変更)と前期間の件数、再生成ループ防止で通過した件数 |
| 週別件数 | 月曜起点の週ごとの件数 |
| 種別ごとの件数 | 今期間・前期間・増減 |
| 種別ごとの検出例 | 各3件。誤検知か実違反かを読んで判断する材料 |
| 検出語の頻度 | 辞書から外す語、閾値を上げる語の候補 |
| 常時ロード指示の行数 | CLAUDE.md と rules の合計。増え続けていないかの確認 |

Skill は集計を読んだ上で、`harness.json` の変更前後、規則の追記文、lessons への起票案を
【確認点】の型で提示し、承認された項目だけ反映します。1回のレビューで変える項目は3件までとし、
効果を次回の件数で確かめてから次を変えます。

## 失敗の台帳 lessons

`docs/logs/lessons-YYYYMMDD.md` に1件1節(起きたこと / 原因 / 再発防止 / 機械的緩和策)で
起票し、`docs/logs/lessons-index.md` の一覧に1行追記します。hook・辞書・閾値を変えたときは
同じ索引の「機械的緩和策の経緯」に日付と理由を残します。テンプレートは `docs-templates/` にあり、
`/harness-init` が複製します。

## テスト

```bash
bash tests/run.sh
```

hook 6本に合成の transcript と入力 JSON を与え、差し戻し(exit 2)と通過(exit 0)、バイパス、
設定なし、差し戻し回数の上限、再生成ループ防止、検知ログの UTF-8 を確認します。hook や辞書を
変えたら実行してください。

## ライセンス

MIT
