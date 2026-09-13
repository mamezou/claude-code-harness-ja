#!/bin/bash
# harness-ja: 検知ログの集計。harness-review Skill から呼ぶ。
#
# 使い方: summarize.sh [--log <path>] [--days <N>] [--root <project root>]
#   --log   検知ログ。省略時は <root>/.claude/harness.json の responseQuality.logPath、
#           それも無ければ <root>/.claude/harness-detections.log
#   --days  集計期間の日数 (既定 28)。前期間 (同じ長さ) と比較する
#   --root  プロジェクトルート (既定: git のトップレベル、無ければカレント)
#
# 出力 (Markdown): 期間と総件数 / 週別件数 / 種別ごとの件数と前期間比 /
#   種別ごとの直近の検出例 / 検出語の頻度 / 常に読み込まれる指示の行数
# ログの形式: <ISO時刻>\t[session:<id>] [input:<uuid>] <種別: [検出語] (根拠)>|<種別...>
#   先頭に [regen-limit] が付く行は差し戻し上限での通過記録。タグの無い旧形式の行も読む

set -uo pipefail
export LC_ALL=C.UTF-8

days=28; log=""; root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) log="$2"; shift 2 ;;
    --days) days="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$root" ]] && root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [[ -z "$log" ]]; then
  rel=$(jq -r '.responseQuality.logPath // empty' "$root/.claude/harness.json" 2>/dev/null || true)
  rel="${rel:-.claude/harness-detections.log}"
  [[ "$rel" = /* ]] && log="$rel" || log="$root/$rel"
fi
if [[ ! -f "$log" ]]; then
  echo "検知ログがありません: $log"
  exit 0
fi

now=$(date +%s)
since=$(( now - days*86400 ))
prev_since=$(( now - days*2*86400 ))

# 1行を「epoch<TAB>skip(0/1)<TAB>本文」に正規化
norm=$(grep -av '^[[:space:]]*$' "$log" | awk -F'\t' '
  NF >= 2 {
    ts=$1; body=$2; skip=0
    if (body ~ /^\[regen-limit\] /) { skip=1; sub(/^\[regen-limit\] /, "", body) }
    sub(/^\[session:[^]]*\] \[input:[^]]*\] /, "", body)
    cmd="date -d \"" ts "\" +%s 2>/dev/null"; cmd | getline ep; close(cmd)
    if (ep == "") ep=0
    printf "%s\t%d\t%s\n", ep, skip, body
  }')

in_range() { awk -F'\t' -v a="$1" -v b="$2" '$1>=a && $1<b' <<< "$norm"; }
cur=$(in_range "$since" "$((now+1))")
prev=$(in_range "$prev_since" "$since")

count() { grep -c . <<< "$1" || true; }
cur_n=$(count "$cur"); prev_n=$(count "$prev")
cur_skip=$(awk -F'\t' '$2==1' <<< "$cur" | grep -c . || true)

echo "# 検知ログの集計"
echo
echo "- ログ: \`$log\`"
echo "- 期間: 直近 ${days} 日 ($(date -d @$since +%Y-%m-%d) 〜 $(date +%Y-%m-%d))"
echo "- 件数: ${cur_n} 件 (前期間 ${prev_n} 件)。うち差し戻し上限に達して通過した記録 ${cur_skip} 件"
echo

echo "## 週別件数 (月曜起点)"
echo
echo "| 週 | 件数 |"
echo "|---|---|"
awk -F'\t' '$1>0 {print $1}' <<< "$cur" | while read -r ep; do date -d @"$ep" +%G-W%V; done \
  | sort | uniq -c | awk '{printf "| %s | %s |\n", $2, $1}'
echo

# 種別 = 本文を | で分けた各要素の「: [」より前
types_of() { awk -F'\t' '{print $3}' <<< "$1" | tr '|' '\n' | sed -E 's/: .*$//; s/ \(.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'; }
cur_types=$(types_of "$cur" | sort | uniq -c | sort -rn)
prev_types=$(types_of "$prev" | sort | uniq -c | sort -rn)

echo "## 種別ごとの件数"
echo
echo "| 種別 | 今期間 | 前期間 | 増減 |"
echo "|---|---|---|---|"
while read -r n t; do
  [[ -z "$t" ]] && continue
  p=$(awk -v t="$t" '{c=$1; $1=""; sub(/^ /,""); if ($0==t) print c}' <<< "$prev_types")
  p=${p:-0}
  printf "| %s | %s | %s | %+d |\n" "$t" "$n" "$p" $((n-p))
done <<< "$cur_types"
echo

echo "## 種別ごとの直近の検出例 (各3件まで)"
echo
while read -r n t; do
  [[ -z "$t" ]] && continue
  echo "### $t ($n 件)"
  echo
  awk -F'\t' '{print $1 "\t" $3}' <<< "$cur" | sort -rn | awk -F'\t' '{print $2}' | tr '|' '\n' \
    | grep -F "$t" | grep -oE '\[[^]]*\]' | head -3 | sed 's/^/- /'
  echo
done <<< "$cur_types"

echo "## 検出語の頻度 (辞書と閾値の調整材料、上位15)"
echo
echo "| 検出語 | 件数 |"
echo "|---|---|"
awk -F'\t' '{print $3}' <<< "$cur" | tr '|' '\n' | grep -oE '\[[^]]*\]' | tr -d '[]' | tr ',' '\n' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | sort | uniq -c | sort -rn | head -15 \
  | awk '{c=$1; $1=""; sub(/^ /,""); printf "| %s | %s |\n", $0, c}'
echo

echo "## 常に読み込まれる指示の行数"
echo
echo "| ファイル | 行数 |"
echo "|---|---|"
total=0
for f in "$root/CLAUDE.md" "$root"/.claude/rules/*.md "$HOME/.claude/CLAUDE.md"; do
  [[ -f "$f" ]] || continue
  n=$(wc -l < "$f"); total=$((total+n))
  tilde="~"; printf "| %s | %s |\n" "${f/#$HOME/$tilde}" "$n"
done
echo "| 合計 | $total |"
