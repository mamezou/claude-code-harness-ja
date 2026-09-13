#!/bin/bash
# az / aws / cdk の変更系コマンドを、手順書 (runbook) 参照 + ユーザーの GO の下でのみ許可する
# (PreToolUse, matcher=Bash)
#
# 発火条件:
#   - コマンドが az / aws / cdk の変更系
#   - 案件判定はコマンド内容と cwd で行う (cwd 配下でなくても発火する)
#     - 設定の cloudChange.projects[] を配列順に照合し、最初に一致した要素を使う
#     - clis[] に検出した CLI (az / aws / cdk) が含まれ、かつ cwdMatch が空、または
#       コマンドか cwd に cwdMatch の文字列を含めば一致
#     - どの要素にも一致しない変更系コマンド (他案件のプロファイル等) は対象外
#
# 通過条件 (両方満たす、または bypass あり):
#   (A) 直近 200 行の transcript で runbookPattern に一致するファイルの
#       Read/Write/Edit/MultiEdit がある
#   (B) 最後のユーザーのテキスト入力に [change-go: <name>] がある
#       (ツール実行結果の行は読み飛ばすため、トークン 1 通で次の入力までの複数コマンドが通る)
#
# バイパス:
#   - 最後のユーザーのテキスト入力に [hook-bypass: cloud-change] がある場合、全条件無視
#
# 除外:
#   - 単独の az config / az account set (ローカル CLI 設定)
#   - read-only (list/get/show/describe/query、cdk synth/diff) と
#     aws login / aws configure / aws sts get-caller-identity
#
# 設定 (.claude/harness.json):
#   cloudChange.enabled          false で無効化
#   cloudChange.projects[]       name / clis[] / cwdMatch / runbookPattern / runbookHint / guideRef
#   設定ファイルが無い、または projects が空なら何もしない

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

input=$(cat)
harness_load_config "$input"

if ! cfg_enabled '.cloudChange'; then
  exit 0
fi

project_count=$(cfg '.cloudChange.projects | length' '0')
if [[ "${project_count:-0}" -eq 0 ]]; then
  exit 0
fi

principal=$(harness_principal)

# 1) cwd 取得 (案件判定の補助にのみ使用。cwd では発火制限しない)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

# 2) Bash コマンド抽出
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
if [[ -z "$command" ]]; then
  exit 0
fi

# 2.5) 単独の az config / az account set は除外 (ローカル CLI 設定のみ)
# 制御演算子 (;, &, |) を含む複合コマンドは除外対象外。
if ! printf '%s' "$command" | grep -qE '[;&|]'; then
  if printf '%s' "$command" | grep -qE '^[[:space:]]*az[[:space:]]+config[[:space:]]+'; then
    exit 0
  fi
  if printf '%s' "$command" | grep -qE '^[[:space:]]*az[[:space:]]+account[[:space:]]+set([[:space:]]|$)'; then
    exit 0
  fi
fi

# 3) 変更系コマンド判定
az_change=0
aws_change=0
cdk_change=0

# az の変更系 verb (独立トークン、階層深さ任意)
az_change_verbs='create|update|delete|set|assign|add|remove|restart|start|stop|enable|disable|import|invoke-action'
if printf '%s' "$command" | grep -qE "(^|[[:space:]])az[[:space:]]+[^|;&]*[[:space:]](${az_change_verbs})([[:space:]]|$)"; then
  az_change=1
fi

# az rest --method put/post/patch/delete (大文字小文字・= 区切り両対応)
if printf '%s' "$command" | grep -qiE '(^|[[:space:]])az[[:space:]]+rest[[:space:]].*(--method|-m)([[:space:]]+|=)(put|post|patch|delete)([[:space:]]|$)'; then
  az_change=1
fi

# aws の変更系
aws_change_patterns='create-|update-|delete-|put-|modify-|attach-|detach-|add-|remove-|register-|deregister-|start-|stop-|enable-|disable-|associate-|disassociate-|revoke-|authorize-|tag-|untag-|run-instances|terminate-instances|reboot-instances'
if printf '%s' "$command" | grep -qE "(^|[[:space:]])aws[[:space:]]+[^|;&]*[[:space:]](${aws_change_patterns})"; then
  aws_change=1
fi

# cdk の変更系 (deploy / destroy / bootstrap。synth / diff は read-only)
if printf '%s' "$command" | grep -qE '(^|[[:space:]])(npx[[:space:]]+)?cdk[[:space:]]+[^|;&]*(deploy|destroy|bootstrap)([[:space:]]|$)'; then
  cdk_change=1
fi

if [[ "$az_change" -eq 0 && "$aws_change" -eq 0 && "$cdk_change" -eq 0 ]]; then
  exit 0
fi

detected_clis=""
[[ "$az_change" -eq 1 ]] && detected_clis="${detected_clis} az"
[[ "$aws_change" -eq 1 ]] && detected_clis="${detected_clis} aws"
[[ "$cdk_change" -eq 1 ]] && detected_clis="${detected_clis} cdk"

# 4) 案件判定 (projects[] の配列順に最初の一致を採用)
project=""
runbook_pattern=""
runbook_hint=""
guide_ref=""
while IFS= read -r proj; do
  [[ -z "$proj" ]] && continue
  name=$(printf '%s' "$proj" | jq -r '.name // empty')
  [[ -z "$name" ]] && continue
  cli_hit=0
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    case " ${detected_clis} " in
      *" $c "*) cli_hit=1 ;;
    esac
  done < <(printf '%s' "$proj" | jq -r '.clis[]?')
  [[ "$cli_hit" -eq 1 ]] || continue
  cwd_match=$(printf '%s' "$proj" | jq -r '.cwdMatch // empty')
  if [[ -n "$cwd_match" ]] && ! printf '%s' "${command} ${cwd}" | grep -qF -- "$cwd_match"; then
    continue
  fi
  project="$name"
  runbook_pattern=$(printf '%s' "$proj" | jq -r '.runbookPattern // empty')
  runbook_hint=$(printf '%s' "$proj" | jq -r '.runbookHint // empty')
  guide_ref=$(printf '%s' "$proj" | jq -r '.guideRef // empty')
  break
done < <(cfg_list '.cloudChange.projects[]? | @json')

# どの要素にも一致しない変更系コマンドは対象外
if [[ -z "$project" ]]; then
  exit 0
fi

# 要素に指定が無い場合の保険 (空パターンは全一致になるため既定を置く)
[[ -n "$runbook_pattern" ]] || runbook_pattern='runbook.*\.md'
[[ -n "$runbook_hint" ]] || runbook_hint='ファイル名に runbook を含む .md'
[[ -n "$guide_ref" ]] || guide_ref='クラウド変更の手順'

go_token="[change-go: ${project}]"

detected_cmd=$(printf '%s' "$command" | sed -E 's/^[[:space:]]*//' | awk '{print $1, $2, $3, $4}')

# 5) transcript 取得
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
if [[ -z "$transcript" || ! -f "$transcript" ]]; then
  cat >&2 <<MSG
[クラウド変更コマンドの停止]
transcript が取得できないため、runbook 参照と GO の確認ができません。
新規セッションの最初の変更コマンドは、手順書を Read し、${principal}に
${go_token} を含むメッセージで GO を出してもらってから実行してください。
MSG
  exit 2
fi

# 6) 最後のユーザーのテキスト入力を取得
#    content が文字列のエントリ、または tool_result を含まない配列(text 要素の連結)を
#    ユーザーの入力とみなし、ツール実行結果(tool_result 配列)は読み飛ばす。
last_user_msg=$(harness_last_user_text "$transcript")

# 7) バイパス判定
if printf '%s' "$last_user_msg" | grep -qF '[hook-bypass: cloud-change]'; then
  exit 0
fi

# 8) 承認トークン判定
has_go=0
if printf '%s' "$last_user_msg" | grep -qF "$go_token"; then
  has_go=1
fi

# 9) runbook 系ファイルアクセス判定 (案件別パターン)
runbook_access=$(tail -200 "$transcript" \
  | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and (.name=="Read" or .name=="Write" or .name=="Edit" or .name=="MultiEdit")) | .input.file_path // .input.path // empty' 2>/dev/null \
  | grep -E -- "$runbook_pattern" || true)

has_runbook=0
if [[ -n "$runbook_access" ]]; then
  has_runbook=1
fi

# 10) 両方満たせば通過
if [[ "$has_go" -eq 1 && "$has_runbook" -eq 1 ]]; then
  exit 0
fi

# 11) ブロック
missing=""
if [[ "$has_runbook" -eq 0 ]]; then
  missing="${missing}  - 直近で runbook 系ファイル (${runbook_hint}) を Read/Write/Edit していない\n"
fi
if [[ "$has_go" -eq 0 ]]; then
  missing="${missing}  - 最後の${principal}のテキスト入力に ${go_token} が無い\n"
fi

cat >&2 <<MSG
[クラウド変更コマンドの停止]
az / aws / cdk の変更系コマンド (${detected_cmd}...) を実行しようとしていますが、
以下の条件が満たされていません:
$(printf "${missing}")

${guide_ref}の手順:
1. 手順書を作成または Read する (${runbook_hint})
2. ${principal}に内容を確認してもらう
3. ${principal}が ${go_token} を含むメッセージで GO を出す
4. その直後に変更コマンドを実行する

read-only コマンド (list/get/show/describe/query、cdk synth/diff) はブロック対象外です。
緊急時のみ、${principal}が [hook-bypass: cloud-change] を含めることで回避可能です。
アシスタント側からのバイパス提案・要求は禁止 (rules「start-approval」)。
MSG
exit 2
