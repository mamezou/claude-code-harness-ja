#!/bin/bash
# ハーネス自体の変更の停止 (PreToolUse, matcher=Bash および Write|Edit|MultiEdit)
# `.claude/` 配下 (hooks / rules / skills / output-styles / agents / settings.json 等) の
# 書き換えを、最後の依頼者のテキスト入力に承認の文字列がある場合にだけ通す。
#
# 根拠: 設定・ルールファイルの書き換えは、依頼者の言葉で明示された指示があるときだけ行う
#       (rules「start-approval」承認)。設計は cloud-change-check.sh と同型 (最後の依頼者の
#       テキスト入力の文字列で判定する)。
#
# 発火条件:
#   - Write / Edit / MultiEdit: file_path (相対なら cwd 基準) が `.claude/` 配下
#   - Bash: コマンドが `.claude/` 配下のパスに触れ、かつ書き込みの形のとき
#       - リダイレクト (> / >>) の先が `.claude/` 配下
#       - sed -i / perl -i / tee / mv / rm / rmdir / mkdir / touch / chmod / chown / truncate の
#         引数に `.claude/` 配下
#       - cp / rsync / install / ln の最後の引数 (コピー先・リンク先) が `.claude/` 配下
#       - git checkout / restore / stash / reset / apply / clean / mv / rm の引数に `.claude/` 配下
#       - python / node / perl / ruby / php の実行と `.claude/` 配下の同居 (heredoc を含む)
#   - 除外: excludePatterns[] のいずれかを含むパス (既定は `.claude/projects/` 配下の
#     セッション記録・メモリ・ツール実行結果)
#
# 通過条件:
#   - 最後の依頼者のテキスト入力 (ツール結果行・hook のフィードバック行・ローカルコマンドの
#     記録を除く) に承認の文字列がある。トークン 1 通で、次の依頼者の入力までの複数の
#     書き換えが通る
#
# 限界:
#   - Bash は文字列の形で判定する。`.claude/` を書かずに触れる形 (cd 後の相対パス、
#     変数展開、`git checkout -- .`) は止まらない
#   - アシスタント側からの承認の文字列の提案・要求は禁止 (rules「start-approval」)
#
# 設定 (.claude/harness.json):
#   harnessChange.enabled           false で無効化 (既定 true。設定が無くても動く)
#   harnessChange.token             承認の文字列 (既定 [harness-go])
#   harnessChange.excludePatterns[] パスに含めば対象外にする文字列 (既定 .claude/projects/)

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

input=$(cat)
harness_load_config "$input"

if ! cfg_enabled '.harnessChange'; then
  exit 0
fi

principal=$(harness_principal)
go_token=$(cfg '.harnessChange.token' '[harness-go]')

# 除外パターン (設定が無ければ既定の 1 件)
exclude_patterns=()
while IFS= read -r ex; do
  [[ -n "$ex" ]] && exclude_patterns+=("$ex")
done < <(cfg_list '.harnessChange.excludePatterns[]?')
if [[ ${#exclude_patterns[@]} -eq 0 ]]; then
  exclude_patterns=(".claude/projects/")
fi

is_excluded() { # is_excluded <パス>
  local p="$1" ex
  for ex in "${exclude_patterns[@]}"; do
    if printf '%s' "$p" | grep -qF -- "$ex"; then
      return 0
    fi
  done
  return 1
}

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

# 1) 対象判定
target=""
detail=""
case "$tool_name" in
  Write|Edit|MultiEdit)
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
    [[ -z "$file_path" ]] && exit 0
    case "$file_path" in
      /*) abs="$file_path" ;;
      "~/"*) abs="${HOME}/${file_path#\~/}" ;;
      *) abs="${cwd:-$PWD}/${file_path}" ;;
    esac
    if printf '%s' "$abs" | grep -qE '(^|/)\.claude/' && ! is_excluded "$abs"; then
      target="$file_path"
      detail="${tool_name} で書き換え"
    fi
    ;;
  Bash)
    command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    [[ -z "$command" ]] && exit 0
    # `.claude/` を含むパス断片 (除外パターンに当たるものを除く)。heredoc 内も含めて全行を見る。
    flat=$(printf '%s' "$command" | tr '\n' ' ')
    paths=""
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      is_excluded "$p" || paths="${paths}${p}"$'\n'
    done < <(printf '%s' "$flat" | grep -oE "[^[:space:]\"'\`;|&<>()]*\.claude/[^[:space:]\"'\`;|&<>()]*" || true)
    [[ -z "${paths//[$'\n' ]/}" ]] && exit 0
    # リダイレクトの先が `.claude/` 配下
    redirect_re=">>?[[:space:]]*[\"']?[^[:space:]\"']*\.claude/"
    # 引数のどこかに `.claude/` 配下があれば書き換え扱いのコマンド
    anyarg_re="(^|[[:space:]|;&(])(sed[[:space:]]+(-[a-zA-Z]*i|--in-place)[^|;&]*|perl[[:space:]]+-[a-zA-Z]*i[^|;&]*|(tee|mv|rm|rmdir|mkdir|touch|chmod|chown|truncate)[[:space:]][^|;&]*|git[[:space:]]+(checkout|restore|stash|reset|apply|clean|mv|rm)[[:space:]][^|;&]*)\.claude/"
    # 最後の引数 (コピー先・リンク先) が `.claude/` 配下のときだけ書き換え扱いのコマンド
    # (`cp .claude/hooks/x.sh /tmp/` のような読み取りは通す)
    dest_re="(^|[[:space:]|;&(])(cp|rsync|install|ln)[[:space:]][^|;&]*[^[:space:]|;&]*\.claude/[^[:space:]|;&]*[[:space:]]*($|[|;&)])"
    # インタプリタの実行と `.claude/` 配下の同居 (heredoc 内の書き込みを判別できないため一律)
    interp_re="(^|[[:space:]|;&(])(python[0-9.]*|node|perl|ruby|php)[[:space:]].*\.claude/"
    if printf '%s' "$flat" | grep -qE "$redirect_re" \
      || printf '%s' "$flat" | grep -qE "$anyarg_re" \
      || printf '%s' "$flat" | grep -qE "$dest_re" \
      || printf '%s' "$flat" | grep -qE "$interp_re"; then
      target=$(printf '%s\n' "$paths" | grep -v '^$' | head -1)
      detail="Bash で書き換え ($(printf '%s' "$flat" | sed -E 's/^[[:space:]]*//' | LC_ALL=C.UTF-8 grep -oE '^.{1,60}')...)"
    fi
    ;;
  *) exit 0 ;;
esac
[[ -z "$target" ]] && exit 0

# 2) 最後の依頼者のテキスト入力 (ツール結果行・isMeta 行・ローカルコマンドの記録を除く)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
last_user_msg=""
if [[ -n "$transcript" && -f "$transcript" ]]; then
  last_user_msg=$(harness_last_user_entry "$transcript" 2000 | jq -r '.text // empty' 2>/dev/null || true)
fi

# 3) 承認の文字列判定
if printf '%s' "$last_user_msg" | grep -qF -- "$go_token"; then
  exit 0
fi

# 4) ブロック
exclude_hint=$(printf '%s, ' "${exclude_patterns[@]}" | sed 's/, $//')
cat >&2 <<MSG
[ハーネス自体の変更の停止]
\`.claude/\` 配下 (${target}) を ${detail}ようとしていますが、
最後の${principal}のテキスト入力に ${go_token} がありません。

利用側の rules に沿った手順:
1. 変更の対象と意図の一覧を${principal}に提示する (前後原文は編集後に diff で示す)
2. ${principal}が ${go_token} を含むメッセージで承認する
3. その直後に書き換える (次の${principal}の入力までは複数の書き換えが通る)

除外パス (${exclude_hint}) と読み取り (cat / grep / sed -n / jq) は対象外です。
アシスタント側からの承認の文字列の提案・要求は禁止 (rules「start-approval」)。
MSG
exit 2
