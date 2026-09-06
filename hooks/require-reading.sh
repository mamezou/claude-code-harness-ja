#!/bin/bash
# クリティカルファイルの編集前に関連資料の Read を強制する hook
# (PreToolUse, matcher=Write|Edit|MultiEdit)
#
# 発火条件:
#   - 編集対象のパスが requireReading.rules[] の target (bash の case パターン) に一致
#     配列順に照合し、最初に一致した要素を使う
#   - cwd には依存しない (リポジトリルート起動のセッションでも発火する)
#
# 通過条件:
#   - 通常: requiredReadPattern に一致する資料を直近 200 行の transcript で Read
#   - mode="logs" の既存ファイル編集: そのファイル自身の Read
#   - mode="logs" の新規作成: requiredReadPattern に一致する任意のファイルの Read
#
# バイパス:
#   - 直前のユーザーメッセージに [hook-bypass: resource-reading]
#
# 設定 (.claude/harness.json):
#   requireReading.enabled  false で無効化
#   requireReading.rules[]  target / requiredReadPattern / hint / mode
#   設定ファイルが無い、または rules が空なら何もしない

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

input=$(cat)
harness_load_config "$input"

if ! cfg_enabled '.requireReading'; then
  exit 0
fi

rule_count=$(cfg '.requireReading.rules | length' '0')
if [[ "${rule_count:-0}" -eq 0 ]]; then
  exit 0
fi

# 1) cwd 取得 (相対パス解決にのみ使用。cwd では発火制限しない)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

# 2) 編集対象ファイルパス抽出
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
if [[ -z "$file_path" ]]; then
  exit 0
fi

if [[ "$file_path" = /* ]]; then
  target_file_path="$file_path"
else
  target_file_path="${cwd%/}/$file_path"
fi

# 3) クリティカル判定 (target_file_path で cwd 非依存に判定)
related_pattern=""
target_name=""
is_logs=0

while IFS= read -r rule; do
  [[ -z "$rule" ]] && continue
  pat=$(printf '%s' "$rule" | jq -r '.target // empty')
  [[ -z "$pat" ]] && continue
  case "$target_file_path" in
    $pat)
      related_pattern=$(printf '%s' "$rule" | jq -r '.requiredReadPattern // empty')
      target_name=$(printf '%s' "$rule" | jq -r '.hint // empty')
      [[ "$(printf '%s' "$rule" | jq -r '.mode // empty')" == "logs" ]] && is_logs=1
      break
      ;;
  esac
done < <(cfg_list '.requireReading.rules[]? | @json')

if [[ -z "$related_pattern" ]]; then
  exit 0
fi
[[ -n "$target_name" ]] || target_name="対象資料"

# 4) transcript 取得
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
if [[ -z "$transcript" || ! -f "$transcript" ]]; then
  cat >&2 <<MSG
[資料先読みゲート違反]
transcript が取得できないため、直近の資料参照を確認できません。
新規セッションでは、最初に対象資料 (${target_name}) を Read してから編集してください。
MSG
  exit 2
fi

# 5) バイパス判定
last_user_msg=$(harness_last_user_text "$transcript")

if printf '%s' "$last_user_msg" | grep -q '\[hook-bypass: resource-reading\]'; then
  exit 0
fi

# 6) Read 済みファイル一覧 (直近 200 行)
read_files=$(tail -200 "$transcript" \
  | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Read") | .input.file_path // .input.path // empty' 2>/dev/null || true)

# 7) logs 特例 (既存編集 vs 新規作成で分岐)
if [[ "$is_logs" -eq 1 ]]; then
  if [[ -f "$target_file_path" ]]; then
    # 既存ファイル編集: 対象ファイル自身の Read が必要
    file_basename=$(basename "$target_file_path")
    self_read=""
    while IFS= read -r read_path; do
      [[ -z "$read_path" ]] && continue
      read_basename=$(basename "$read_path")
      if [[ "$read_basename" == "$file_basename" ]]; then
        self_read="$read_path"
        break
      fi
    done <<< "$read_files"

    if [[ -n "$self_read" ]]; then
      exit 0
    fi

    cat >&2 <<MSG
[資料先読みゲート違反]
既存ログファイル ${file_path} を編集しようとしていますが、
このファイル自身を直近で Read していません。

追記前にファイル内容を確認してください。
緊急時のみ [hook-bypass: resource-reading] を含めて回避可能です。
MSG
    exit 2
  else
    # 新規作成: 同じ資料群の任意の Read で OK
    logs_dir_read=$(printf '%s\n' "$read_files" | grep -E -- "$related_pattern" || true)
    if [[ -n "$logs_dir_read" ]]; then
      exit 0
    fi

    cat >&2 <<MSG
[資料先読みゲート違反]
新規ログファイル ${file_path} を作成しようとしていますが、
直近で ${target_name} 配下の既存ログを Read していません。

前回までの作業記録を確認してから新規ログを作成してください。
緊急時のみ [hook-bypass: resource-reading] を含めて回避可能です。
MSG
    exit 2
  fi
else
  # 8) 通常: 関連資料の Read チェック
  related_read=$(printf '%s\n' "$read_files" | grep -E -- "$related_pattern" || true)
  if [[ -n "$related_read" ]]; then
    exit 0
  fi

  cat >&2 <<MSG
[資料先読みゲート違反]
${file_path} を編集しようとしていますが、
直近で ${target_name} 配下の資料を Read していません。

資料先読みの原則:
- 該当セクションが参照する資料の本文を先に読む (ファイル名で判断しない)
- 最初に「読むべき資料リスト」を提示 → ユーザー確認 → 編集/提示

対象資料を Read してから再度編集を試みてください。
緊急時のみ [hook-bypass: resource-reading] を含めて回避可能です。
MSG
  exit 2
fi
