# claude-code-harness-ja

Claude Code の hook で、日本語の応答品質とクラウド運用のガードレールを機械的に強制する
プラグインです。複数案件の SRE 業務で積み上げた再発防止策を、案件に依存しない形に
まとめました。案件固有の値は利用側の `.claude/harness.json` で指定します。

## 収録物

| 種別 | 内容 |
|---|---|
| hooks(5本) | 応答品質ゲート、クラウド変更コマンドのゲート、送付文面の事前検査、資料先読みの強制、インライン PowerShell の禁止 |
| Output Style | `Concise JA`。簡潔な日本語応答と、依頼者への返信文体の規則 |
| rules テンプレート(4本) | 着手と承認、サブエージェント委任、送付文面、外部送付物のチェック |
| Skills(5本) | `harness-init`(初期設定)、`draft-precheck`、`send-draft`、`work-log`、`codex-review` |
| agents(3本) | `repo-survey`、`doc-review`、`draft-check`(いずれも読み取り専用、低コストモデル指定) |
| git-hooks(2本) | 承認済み一覧と一致するコミットのみ許可、gitleaks によるシークレット検査 |

## 動作環境

- Linux(bash、GNU coreutils、`jq`)。macOS は未検証
- gitleaks は任意(無ければ警告して通す)
- Codex CLI は `codex-review` Skill を使う場合のみ

## インストール

```
/plugin marketplace add mamezou/claude-code-harness-ja
/plugin install harness-ja@claude-code-harness-ja
```

利用側プロジェクトで初期設定を行います。

```
/harness-init
```

`.claude/harness.json` の作成、rules テンプレートの複製、git-hooks の配置、`.gitignore` の追記を
行います。作成された `harness.json` を案件に合わせて書き換えてください。Output Style は
`/config` から「Concise JA」を選びます。

## hook の一覧

| hook | イベント | 止める条件 | バイパス |
|---|---|---|---|
| `response-quality.sh` | Stop | 応答本文に18種の文体違反(装飾語で締める、見出し・表・箇条書きが文で終わる、指示語の多用、逃げの締め 等) | `[hook-bypass: response-quality]` |
| `change-gate.sh` | PreToolUse(Bash) | az / aws / cdk の変更系コマンドで、手順書の Read と `[change-go: <案件>]` のいずれかが無い | `[hook-bypass: change-gate]` |
| `draft-precheck.sh` | PreToolUse(Write / Edit) | 送付文面に内部パス・ローカル拡張子・組版記号・外部 AI 言及・禁止語・長い識別子の繰り返し | `[hook-bypass: draft-precheck]` |
| `require-reading.sh` | PreToolUse(Write / Edit) | 必読資料を直近で Read せずに対象ファイルを編集 | `[hook-bypass: resource-reading]` |
| `no-inline-powershell.sh` | Stop | 5行以上の PowerShell をファイル化せずにコードブロックで提示 | なし |

バイパストークンは利用者が自分のメッセージに書く運用です。Claude 側からの提案・要求は
rules テンプレートで禁止しています。

応答品質ゲートは、直近30分に2回差し戻していれば3回目以降を `[regen-skip]` 付きで通します
(体裁の差し戻しの反復で読みやすさが下がるのを防ぐため)。検知の記録は
`.claude/harness-detections.log` に1行1件で残ります。週次で件数と種別を見て、誤検知の多い
パターンの閾値を調整する運用を想定しています。

## 設定ファイル `.claude/harness.json`

`examples/harness.json` が全キーの例です。使わない機能は `"enabled": false` で止めます。

| キー | 用途 |
|---|---|
| `principal` | 承認者の呼び名。hook の通知文に使う(既定「依頼者」) |
| `responseQuality.uiTerms` / `fluffTerms` / `bannedLeads` | 検知語の追加。既定の辞書に加算 |
| `responseQuality.logPath` | 検知ログの置き場(プロジェクトルートからの相対パス) |
| `responseQuality.regenSkipWindowSec` / `regenSkipThreshold` | 再生成ループ防止の窓と閾値 |
| `changeGate.projects[]` | 変更ゲートの対象。`clis`(az / aws / cdk)、`cwdMatch`、`runbookPattern`、`runbookHint`、`guideRef` |
| `draftPrecheck.targets[]` | 送付文面の置き場(bash の case パターン)。`excludePatterns[]`、`bannedTerms[]`、`honorific` |
| `requireReading.rules[]` | 編集対象(`target`)と必読資料(`requiredReadPattern`)の対応表。`mode: "logs"` で作業ログの特例 |
| `noInlinePowershell.scriptDirHint` | ファイル化先の案内文 |

設定ファイルは `HARNESS_CONFIG` 環境変数、`$CLAUDE_PROJECT_DIR/.claude/harness.json`、
hook 実行時の cwd から上へ辿った `.claude/harness.json` の順で探します。設定が無い場合、
応答品質ゲートと PowerShell 禁止は既定値で動き、残り3本は何もしません。

## rules テンプレートについて

プラグインは `.claude/rules/` 相当の常時ロード指示を配布できないため、`rules-templates/` を
`/harness-init` で利用側へ複製します。複製後は利用側で自由に編集してください。

## git-hooks

`prepare-commit-msg` は、`.claude/commit-plan.txt` に書かれた承認済みのファイル一覧と
ステージ内容が完全一致するときだけコミットを許可します(`--no-verify` でも動きます)。
続けて `pre-commit-checks.sh` が gitleaks でシークレットを検査し、送付文面の対象ファイルには
`draft-precheck.sh` を適用します。

## ライセンス

MIT
