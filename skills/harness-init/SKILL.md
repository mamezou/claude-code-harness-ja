---
name: harness-init
description: harness-ja を利用側プロジェクトへ初期設定する。.claude/harness.json の作成、rules テンプレートの複製、.gitignore の追記を行う。「harness-ja を初期化」「/harness-ja:harness-init」で呼び出す。
---

# harness-ja の初期設定

利用側プロジェクトに、hook が読む設定ファイルと、常に読み込む rules を配置する。
プラグインは rules を自動ロードできないため、テンプレートを複製して使う。
`.claude/harness.json` が無い間、hook は何もしない。初期設定で最初に作るのはこのファイル。

## 手順

1. 現在地がプロジェクトルート(git のトップレベル)であることを `git rev-parse --show-toplevel` で確認する。
2. 設定ファイルを置く。既にあれば上書きしない。

```bash
mkdir -p .claude/rules
[ -f .claude/harness.json ] || cp "${CLAUDE_PLUGIN_ROOT}/examples/harness.json" .claude/harness.json
```

3. rules テンプレートを複製する。`cp -n` は既存ファイルを上書きしない。上書きを避けた
   ファイルがあれば、テンプレートとの差分を提示して判断を仰ぐ。

```bash
cp -n "${CLAUDE_PLUGIN_ROOT}"/rules-templates/*.md .claude/rules/
```

4. `.gitignore` に次の1行を追記する(既にあれば追記しない)。

```
.claude/harness-detections.log
```

5. `.claude/harness.json` を開き、利用者に次の項目を案件に合わせて書き換えてもらう。項目ごとに用途を1行で説明する。
   - `principal`: 通知文で使う利用者の呼称
   - `cloudChange.projects[]`: クラウド変更コマンドの停止の対象。`clis`、`cwdMatch`、`runbookPattern`、`runbookHint`、`guideRef`
   - `responseQuality.patterns`: 応答の文体検査で実行するパターン番号(既定 `[3, 4, 8, 19]`)
   - `draftPrecheck.targets[]`: 送付文面の置き場(bash の case パターン)。`bannedTerms[]` に案件の禁止語
   - `requireReading.rules[]`: 編集前に必読とする資料の対応表
   - 使わない機能は `"enabled": false` で止める
6. Output Style を使う場合は `/config` から「Concise JA」を選ぶよう案内する。
7. 週次のレビューは `/harness-ja:harness-review` で行うことを案内する。
8. 設定内容を要約して報告する。書き換えた・作成したファイルのパスを列挙する。

## 完了条件

- `.claude/harness.json` が存在し `jq . .claude/harness.json` が通る
- `.claude/rules/` にテンプレート2本がある
- `.gitignore` に1行がある
