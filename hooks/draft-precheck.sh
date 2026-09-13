#!/bin/bash
# 送付文面の事前検査 hook (PreToolUse, matcher=Write|Edit|MultiEdit)
# 先方・内部へ送る文面へ、内部表現・造語・組版記号・外部 AI 言及が混入するのを止める。
#
# 発火条件:
#   - 編集対象のパスが draftPrecheck.targets[] のいずれか (bash の case パターン) に一致
#   - excludePatterns[] のいずれかをパスに含む場合は対象外
#   - cwd には依存しない (リポジトリルート起動のセッションでも発火する)
#
# 検査項目 (draftPrecheck.checks.<名前> を false にすると個別に止められる。既定はすべて true):
#   bannedTerms      設定の禁止語
#   internalPaths    内部リポジトリパス断片・絶対パス (URL を含む行は対象外)
#   extensions       ローカルファイル拡張子の素出し (.md / .ps1 / .drawio / .kql)
#   typography       組版記号 (§ ¶ ‡ †)
#   honorific        見出しでの敬称抜け
#   externalAi       外部 AI ツール名の言及
#   longIdentifiers  長い識別子のフル表記の繰り返し
#
# 検査範囲: Write は全文、Edit/MultiEdit は追加・置換後の文字列のみ。
#
# バイパス:
#   - 依頼者の最後のテキスト入力に [hook-bypass: draft-precheck] がそれだけの行としてある
#
# 設定 (.claude/harness.json):
#   draftPrecheck.enabled           false で無効化
#   draftPrecheck.targets[]         対象パスの case パターン (空なら何もしない)
#   draftPrecheck.excludePatterns[] パスに含めば対象外にする文字列
#   draftPrecheck.checks            検査項目ごとの on / off
#   draftPrecheck.bannedTerms[]     禁止語 (既定値は持たない)
#   draftPrecheck.honorific.name    敬称の検査対象名 (空なら検査しない)
#   draftPrecheck.honorific.suffix  付いているべき敬称 (既定「様」)

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

input=$(cat)
harness_load_config "$input"
harness_config_guard pre

if ! cfg_enabled '.draftPrecheck'; then
  exit 0
fi

target_count=$(cfg '.draftPrecheck.targets | length' '0')
if [[ "${target_count:-0}" -eq 0 ]]; then
  exit 0
fi

check_on() { # check_on <検査名>
  cfg_flag ".draftPrecheck.checks.$1" 'true'
}

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
[[ -z "$file_path" ]] && exit 0

# 対象判定 (絶対/相対両対応)
if [[ "$file_path" = /* ]]; then
  target_file_path="$file_path"
else
  target_file_path="${cwd%/}/$file_path"
fi

is_target=0
while IFS= read -r pat; do
  [[ -z "$pat" ]] && continue
  case "$target_file_path" in
    $pat) is_target=1; break ;;
  esac
done < <(cfg_list '.draftPrecheck.targets[]?')
[[ "$is_target" -eq 1 ]] || exit 0

# 除外パターン (内部用・送信済み等) はここで抜ける
while IFS= read -r ex; do
  [[ -z "$ex" ]] && continue
  if printf '%s' "$file_path" | grep -qF -- "$ex"; then
    exit 0
  fi
done < <(cfg_list '.draftPrecheck.excludePatterns[]?')

# tool_input から編集内容を取得
case "$tool_name" in
  Write)
    content=$(printf '%s' "$input" | jq -r '.tool_input.content // empty')
    ;;
  Edit)
    content=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty')
    ;;
  MultiEdit)
    content=$(printf '%s' "$input" | jq -r '[.tool_input.edits[]? | .new_string] | join("\n")')
    ;;
  *) exit 0 ;;
esac
[[ -z "$content" ]] && exit 0

# バイパス判定 (それだけの行にある場合のみ有効)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
if [[ -n "$transcript" && -f "$transcript" ]]; then
  last_user_msg=$(harness_last_user_message "$transcript")
  if harness_has_token "$last_user_msg" '[hook-bypass: draft-precheck]'; then
    exit 0
  fi
fi

# ----- 検査 -----
hits=""
url_re='https?://'

# 1) 禁止語 (設定の bannedTerms[] のみ。誤検知の多い語は rules で人が判断する)
if check_on bannedTerms; then
  while IFS= read -r term; do
    [[ -z "$term" ]] && continue
    if printf '%s' "$content" | grep -qF -- "$term"; then
      matched=$(printf '%s' "$content" | grep -nF -- "$term" | head -3)
      hits="${hits}  - 禁止語「${term}」検出:"$'\n'"${matched}"$'\n'
    fi
  done < <(cfg_list '.draftPrecheck.bannedTerms[]?')
fi

# 2) 内部リポジトリパス断片 / 絶対パス
#    URL を含む行は対象外 (https://example.com/docs/setup を内部パスと読まない)
if check_on internalPaths; then
  internal_paths='(^|[^A-Za-z0-9])(docs|src|scripts|exports)/'
  abs_paths='(/home/|/tmp/|/var/)'
  matched=$(printf '%s' "$content" | grep -nE "$internal_paths" | grep -vE "$url_re" | head -3 || true)
  if [[ -n "$matched" ]]; then
    hits="${hits}  - 内部リポジトリパス検出:"$'\n'"${matched}"$'\n'
  fi
  matched=$(printf '%s' "$content" | grep -nE "$abs_paths" | grep -vE "$url_re" | head -3 || true)
  if [[ -n "$matched" ]]; then
    hits="${hits}  - 絶対パス検出:"$'\n'"${matched}"$'\n'
  fi
fi

# 3) ローカルファイル拡張子の素出し (.md / .ps1 / .drawio / .kql)
if check_on extensions; then
  local_ext='\.(md|ps1|drawio|kql)([[:space:]]|$|[、。)）」])'
  if printf '%s' "$content" | grep -qE "$local_ext"; then
    matched=$(printf '%s' "$content" | grep -nE "$local_ext" | head -3)
    hits="${hits}  - ローカルファイル拡張子検出:"$'\n'"${matched}"$'\n'
  fi
fi

# 4) 組版記号 § ¶ ‡ †
if check_on typography; then
  typo_marks='(§|¶|‡|†)'
  if printf '%s' "$content" | grep -qE "$typo_marks"; then
    matched=$(printf '%s' "$content" | grep -nE "$typo_marks" | head -3)
    hits="${hits}  - 組版記号検出:"$'\n'"${matched}"$'\n'
  fi
fi

# 5) 見出しでの敬称抜け - 見出し行のみ対象 (本文中の引用等は誤検知が多い)
if check_on honorific; then
  hon_name=$(cfg '.draftPrecheck.honorific.name' '')
  hon_suffix=$(cfg '.draftPrecheck.honorific.suffix' '様')
  if [[ -n "$hon_name" && -n "$hon_suffix" ]]; then
    hon_re="^#.*${hon_name}([^${hon_suffix}]|$)"
    if printf '%s' "$content" | grep -qE -- "$hon_re"; then
      matched=$(printf '%s' "$content" | grep -nE -- "$hon_re" | head -3)
      hits="${hits}  - 見出しに「${hon_name}${hon_suffix}」未付与の可能性:"$'\n'"${matched}"$'\n'
    fi
  fi
fi

# 6) 外部 AI ツール言及
if check_on externalAi; then
  external_ai='(Codex|ChatGPT|Gemini|Copilot)'
  if printf '%s' "$content" | grep -qE "$external_ai"; then
    matched=$(printf '%s' "$content" | grep -nE "$external_ai" | head -3)
    hits="${hits}  - 外部 AI ツール言及検出:"$'\n'"${matched}"$'\n'
  fi
fi

# 7) 長い識別子のフル表記の繰り返し (読み手の目が滑る文面の機械的緩和)
#    Write は content が保存後の全文になるため、同一識別子 3 回以上でブロックする。
#    Edit/MultiEdit は追加分のみが対象。
#    バッククォート内は数えない。
if check_on longIdentifiers; then
  ident_text=$(printf '%s' "$content" | sed 's/`[^`]*`//g')
  top_ident=$(printf '%s\n' "$ident_text" \
    | grep -oE '[A-Za-z][A-Za-z0-9_./-]{19,}' | sort | uniq -c | sort -rn | head -1 || true)
  top_count=$(printf '%s' "$top_ident" | awk '{print $1}')
  top_name=$(printf '%s' "$top_ident" | awk '{print $2}')
  if [[ -n "${top_count:-}" && ${top_count:-0} -ge 3 ]]; then
    hits="${hits}  - 長い識別子のフル表記の繰り返し: ${top_name} が ${top_count} 回 (初出のみフル表記し、以後は呼び名で書くか添付へ移す)"$'\n'
  fi
fi

if [[ -z "$hits" ]]; then
  exit 0
fi

cat >&2 <<MSG
[送付文面の事前検査違反]
${file_path} に以下を検出しました:
${hits}
修正してから再試行してください。
緊急時は [hook-bypass: draft-precheck] だけの行で回避できます。
詳細: rules「writing-style」
MSG
exit 2
