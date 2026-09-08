# Lessons Index

`docs/logs/lessons-*.md` に蓄積した失敗パターン(F-NN)の索引。lessons へ起票したら
本ファイルにも1行追記する。hook や辞書を変えたら「機械的緩和策の経緯」にも1行残す。

更新日: YYYY-MM-DD

## 一覧

| ID | 概要 | 出典 | 機械的緩和策 |
|----|------|------|-----------|
| F-01 | (例) 承認前に成果物を書き始めた | `docs/logs/lessons-YYYYMMDD.md` | rules「start-approval」の承認の一覧 |
| F-02 | (例) 装飾語で文を締めた | `docs/logs/lessons-YYYYMMDD.md` | `response-quality.sh` 装飾語辞書。`harness.json` の `fluffTerms` へ追加 |

## 機械的緩和策の経緯

hook・辞書・閾値の変更履歴。停止・再稼働の判断材料が「再発したか」の記憶に
頼らないよう、変えた日・変えた内容・理由を残す。

- YYYY-MM-DD: (例) `harness.json` の `uiTerms` から「Logs」を除外。正式サービス名との誤検知が3件
