---
name: harness-init
description: harness-ja を利用側プロジェクトへ初期設定する。.claude/harness.json の作成、rules テンプレートと lessons 台帳の複製、.gitignore の追記を行う。「harness-ja を初期化」「/harness-init」で呼び出す。
---

# harness-ja の初期設定

利用側プロジェクトに、hook が読む設定ファイルと、常時ロードする rules を配置する。
プラグインは rules を自動ロードできないため、テンプレートを複製して使う。

## 手順

1. 現在地がプロジェクトルート(git のトップレベル)であることを `git rev-parse --show-toplevel` で確認する。
2. 設定ファイルを置く。既にあれば上書きしない。

```bash
mkdir -p .claude/rules
[ -f .claude/harness.json ] || cp "${CLAUDE_PLUGIN_ROOT}/examples/harness.json" .claude/harness.json
```

3. rules テンプレートを複製する。既存ファイルがあれば上書きせず、差分を提示して判断を仰ぐ。

```bash
for f in "${CLAUDE_PLUGIN_ROOT}"/rules-templates/*.md; do
  [ -f ".claude/rules/$(basename "$f")" ] || cp "$f" .claude/rules/
done
```

4. lessons の台帳を置く。既にあれば上書きしない。

```bash
mkdir -p docs/logs
[ -f docs/logs/lessons-index.md ] || cp "${CLAUDE_PLUGIN_ROOT}/docs-templates/lessons-index.md" docs/logs/
[ -f docs/logs/lessons-$(date +%Y%m%d).md ] || sed "s/YYYY-MM-DD 起点/$(date +%Y-%m-%d) 起点/" "${CLAUDE_PLUGIN_ROOT}/docs-templates/lessons.md" > "docs/logs/lessons-$(date +%Y%m%d).md"
```

5. `.gitignore` に次の1行を追記する(既にあれば追記しない)。

```
.claude/harness-detections.log
```

6. `.claude/harness.json` を開き、利用者に次の項目を案件に合わせて書き換えてもらう。項目ごとに用途を1行で説明する。
   - `principal`: 承認者の呼び名。hook の通知文に使う
   - `changeGate.projects[]`: 変更ゲートの対象案件。`clis`、`cwdMatch`、`runbookPattern`、`runbookHint`、`guideRef`
   - `draftPrecheck.targets[]`: 送付文面の置き場(bash の case パターン)。`bannedTerms[]` に案件の禁止語
   - `requireReading.rules[]`: 編集前に必読とする資料の対応表
   - 使わない機能は `"enabled": false` で止める
7. Output Style を使う場合は `/config` から「Concise JA」を選ぶよう案内する。
8. 週次のレビューは `/harness-review` で行うことを案内する。
9. 設定内容を要約して報告する。書き換えた・作成したファイルのパスを列挙する。

## 完了条件

- `.claude/harness.json` が存在し `jq . .claude/harness.json` が通る
- `.claude/rules/` にテンプレート2本がある
- `.gitignore` に1行がある
- `docs/logs/lessons-index.md` と当日の `lessons-YYYYMMDD.md` がある
