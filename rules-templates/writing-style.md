---
paths:
  - "**/drafts/**"
  - "**/notion/**"
  - "**/archive/sent/**"
  - "**/exports/**"
---

<!-- harness-ja のテンプレート。利用側の .claude/rules/ へ複製して案件に合わせて編集する -->

# 文章ルール(送付文面の正本)

対象は先方・内部向けの送付文面。返信・チャット文面の文体の正本は Output Style
「Concise JA」(`.claude/output-styles/concise-ja.md`)。文の書き方・構成・言葉の
禁止事項・括弧と識別子・説明の量・成果物報告の型など返信向けの節は同Styleにある
(送付文面にも同じ基準を適用する)。出典は文化庁「公用文作成の考え方」と指摘の
記録。Stop hook (`response-quality.sh`)は機械化できる部分集合を検知する。

## 禁止語と言い換え

避ける言葉の表は `.claude/output-styles/concise-ja.md`「避ける言葉と言い換え」の
1枚が正本。送付文面にも同じ表を適用する。

## 指示語の置換確認

送付文面の指示語は1通あたり目安2回以下。判定基準は同Style「指示語の置換確認」、
件別判定は draft-precheck Skill で行う。全廃への過補正はしない。

## 送付文面

送付文面の禁止項目・型は external-deliverables.md(ドラフト等の編集時に自動
読み込み)と send-draft Skill に従う。送付前チェックは draft-precheck Skill を
必ず通す。
