---
name: codex-review
description: 成果物のクロスレビューを Codex CLI (OpenAI) に依頼する。draw.io XML 構成図 / コスト試算 / ヒアリングシート / セキュリティ評価等の検証で実績あり。ユーザー運用の判断で呼び出し、Claude 側からの自発提案・義務化はしない。
disable-model-invocation: true
argument-hint: <対象ファイルパス> <レビュー観点>
allowed-tools: Bash(codex exec:*) Bash(codex --help)
---

# Codex CLI レビュー

引数:

- `$0`: レビュー対象ファイルのパス
- `$1`: レビュー観点 (例: 「セキュリティ評価」「コスト試算の妥当性」「先方提出
  資料としての敬称・造語チェック」)

## コマンド

```bash
codex exec -s read-only -o /tmp/codex-review-${CLAUDE_SESSION_ID}.md "対象ファイルを読んで $1 の観点でレビューしてくれ。ファイル: $0。ファイルは編集しないこと。" < /dev/null
```

結果確認:

```bash
cat /tmp/codex-review-${CLAUDE_SESSION_ID}.md
```

## 注意点

- `codex exec` を使う (対話モードの `codex` は stdin 問題で動かない)
- `< /dev/null` を必ず付ける。プロンプトを引数で渡していても、バックグラウンド実行等で
  stdin が非 TTY だと codex が「追加入力」として stdin を読もうとし、EOF が来ずハングする
  (`Reading additional input from stdin...` の表示のまま進まなくなる)
- `--full-auto` は非推奨 (現行版の `codex exec --help` に存在しない)。読み取り専用の
  レビュー用途は `-s read-only` を使う (書き込みが要る用途は `-s workspace-write`)
- 「ファイルは編集しないこと」を必ず指示に含める
- 複数ファイルを参照させる場合はプロンプト内にパスを列挙する
- 結果を 1 つずつ評価して採否を示す (鵜呑み禁止)
- 推奨は 1 つに絞る。選択肢羅列で依頼者に選ばせるのは禁止
- 外部送付物に「Codex CLI を使った事実」を書かない
  (`.claude/rules/external-deliverables.md` より)。レビュー反映を伝える必要が
  あれば「内部レビュー反映」「クロスレビュー反映」の中立表現で

## 過去の実績

- 構成図 (draw.io XML) のレイアウト・整合性レビュー
- コスト試算のチェック
- 先方ヒアリングシートの観点漏れチェック
- 先方向けドキュメントの造語・敬称チェック (ただし観点を明示しないと漏れる。
  4 回通しても敬称の抜けが検出されなかった事例あり)
