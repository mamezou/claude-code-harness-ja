#!/bin/bash
# az / aws / cdk の変更系コマンドを、手順書 (runbook) の Read と承認の文字列の下でのみ
# 通す (PreToolUse, matcher=Bash)
#
# 発火条件:
#   - コマンド行の先頭 (行頭、または ; && || | ( の直後。sudo・環境変数の代入・npx は
#     読み飛ばす) が az / aws / cdk で、その操作が変更系
#     ("echo az group create ..." のような文字列は先頭語が echo なので対象外)
#   - 案件判定はコマンド内容と cwd で行う (cwd 配下でなくても発火する)
#     - 設定の cloudChange.projects[] を配列順に照合し、最初に一致した要素を使う
#     - clis[] に検出した CLI (az / aws / cdk) が含まれ、かつ cwdMatch が空、または
#       cwdMatch がパス区切り単位で cwd かコマンド中のパスに一致すれば一致
#     - どの要素にも一致しない変更系コマンドは「設定不足」として止める
#
# 変更系の判定:
#   az   最初の `--` オプションより前の部分に変更系の語がある (`az group show --query set`
#        は --query より後ろの set を見ないため対象外)、または az rest --method put/post/patch/delete
#   aws  サブコマンドの位置 (aws <サービス> <操作>) が deploy、create- 等の変更系、
#        s3 の sync/cp/mv/rm/rb/mb、run-instances 等
#        (lambda invoke、sts get-caller-identity、configure、login は対象外)
#   cdk  deploy / destroy / bootstrap / watch (synth / diff は対象外)
#
# 通過条件 (両方満たす、またはバイパスあり):
#   (A) 直近 200 行の transcript で runbookPattern に一致するファイルの Read がある
#       (Write / Edit / MultiEdit は数えない。書いただけでは読んだことにならない)
#   (B) 依頼者の最後のテキスト入力に [change-go: <name>] がそれだけの行としてある
#
# バイパス:
#   - 依頼者の最後のテキスト入力に [hook-bypass: cloud-change] がそれだけの行としてある
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
harness_config_guard pre

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

# az の変更系の語 (独立トークンで照合する。"assignment" は "assign" に一致させない)
az_change_verbs='create|update|delete|set|assign|add|remove|restart|start|stop|enable|disable|import|invoke-action'

trim() { # 前後の空白を落とす
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 断片の先頭から sudo・環境変数の代入・env / command を取り除く
strip_prefix_words() {
  local s w allow_opts=0
  s=$(trim "$1")
  while [[ -n "$s" ]]; do
    w="${s%%[[:space:]]*}"
    if [[ "$w" != -* && "$w" == *=* ]]; then
      s=$(trim "${s#"$w"}"); continue
    fi
    if [[ "$w" == sudo || "$w" == env || "$w" == command ]]; then
      s=$(trim "${s#"$w"}"); allow_opts=1; continue
    fi
    if [[ "$allow_opts" -eq 1 && "$w" == -* ]]; then
      s=$(trim "${s#"$w"}"); continue
    fi
    break
  done
  printf '%s' "$s"
}

# コマンド行を制御演算子で分割し、各断片の先頭語だけを CLI とみなす
while IFS= read -r seg; do
  seg=$(strip_prefix_words "$seg")
  [[ -z "$seg" ]] && continue
  head_word="${seg%%[[:space:]]*}"
  # npx cdk / npx -y cdk
  if [[ "$head_word" == npx || "$head_word" == pnpx || "$head_word" == bunx ]]; then
    seg=$(trim "${seg#"$head_word"}")
    while [[ -n "$seg" && "${seg%%[[:space:]]*}" == -* ]]; do
      head_word="${seg%%[[:space:]]*}"
      seg=$(trim "${seg#"$head_word"}")
    done
    head_word="${seg%%[[:space:]]*}"
  fi
  rest=$(trim "${seg#"$head_word"}")

  case "$head_word" in
    az)
      # 最初の `--` オプションより前の部分だけを変更系の語の判定に使う
      az_prefix=$(printf '%s' "$rest" | awk '{for (i=1; i<=NF; i++) { if ($i ~ /^--/) break; printf "%s ", $i }}')
      if printf ' %s ' "$az_prefix" | grep -qE "[[:space:]](${az_change_verbs})[[:space:]]"; then
        az_change=1
      fi
      # az rest --method put/post/patch/delete (大文字小文字・= 区切り両対応)
      if printf '%s' "$rest" | grep -qiE '^rest([[:space:]]|$).*(--method|-m)([[:space:]]+|=)(put|post|patch|delete)([[:space:]]|$)'; then
        az_change=1
      fi
      ;;
    aws)
      aws_service=""; aws_op=""
      read -r aws_service aws_op _ <<< "$rest" || true
      [[ "$aws_op" == -* ]] && aws_op=""
      if [[ "$aws_service" == "s3" ]]; then
        case "$aws_op" in
          sync|cp|mv|rm|rb|mb) aws_change=1 ;;
        esac
      fi
      case "$aws_op" in
        deploy) aws_change=1 ;;
        create-*|update-*|delete-*|put-*|modify-*|attach-*|detach-*|add-*|remove-*) aws_change=1 ;;
        register-*|deregister-*|start-*|stop-*|enable-*|disable-*) aws_change=1 ;;
        associate-*|disassociate-*|revoke-*|authorize-*|tag-*|untag-*) aws_change=1 ;;
        run-instances|terminate-instances|reboot-instances) aws_change=1 ;;
      esac
      ;;
    cdk)
      # オプションとその直後の値を読み飛ばし、残る語に deploy 等があれば変更系
      # (`cdk synth --output deploy` は deploy を --output の値として読み飛ばす)
      skip_next=0
      while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        if [[ "$t" == -* ]]; then
          if [[ "$t" == *=* ]]; then skip_next=0; else skip_next=1; fi
          continue
        fi
        if [[ "$skip_next" -eq 1 ]]; then skip_next=0; continue; fi
        case "$t" in
          deploy|destroy|bootstrap|watch) cdk_change=1 ;;
        esac
      done < <(printf '%s\n' "$rest" | tr -s '[:space:]' '\n')
      ;;
  esac
done < <(printf '%s\n' "$command" | tr ';|&()' '\n')

if [[ "$az_change" -eq 0 && "$aws_change" -eq 0 && "$cdk_change" -eq 0 ]]; then
  exit 0
fi

detected_clis=""
[[ "$az_change" -eq 1 ]] && detected_clis="${detected_clis} az"
[[ "$aws_change" -eq 1 ]] && detected_clis="${detected_clis} aws"
[[ "$cdk_change" -eq 1 ]] && detected_clis="${detected_clis} cdk"

detected_cmd=$(printf '%s' "$command" | sed -E 's/^[[:space:]]*//' | awk '{print $1, $2, $3, $4}')

# 4) 案件判定 (projects[] の配列順に最初の一致を採用)
#    cwdMatch はパス区切り単位で照合する。`/work/project-a-old` は `project-a` に
#    一致させない。
cwd_norm=$(printf '%s' "$cwd" | sed -E 's#/+#/#g; s#/$##')
cwd_matches() { # cwd_matches <cwdMatch>
  local m="$1"
  [[ "$cwd_norm" == */"$m" ]] && return 0
  [[ "$cwd_norm" == */"$m"/* ]] && return 0
  [[ "$command" == *"/$m/"* ]] && return 0
  return 1
}

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
  if [[ -n "$cwd_match" ]] && ! cwd_matches "$cwd_match"; then
    continue
  fi
  project="$name"
  runbook_pattern=$(printf '%s' "$proj" | jq -r '.runbookPattern // empty')
  runbook_hint=$(printf '%s' "$proj" | jq -r '.runbookHint // empty')
  guide_ref=$(printf '%s' "$proj" | jq -r '.guideRef // empty')
  break
done < <(cfg_list '.cloudChange.projects[]? | @json')

# どの案件にも一致しない変更系コマンドは、素通りさせずに設定の不足として止める
if [[ -z "$project" ]]; then
  cat >&2 <<MSG
[クラウド変更コマンドの停止]
変更系コマンド (${detected_cmd}...) を検知しましたが、設定のどの案件にも一致しません。
検出した CLI:${detected_clis} / cwd: ${cwd_norm}

設定不足: \`cloudChange.projects[]\` に案件を追加してください。
追加する項目は name / clis[] / cwdMatch / runbookPattern / runbookHint / guideRef です。
対象外にしたい環境なら、その案件の cwdMatch を実際のパスに合わせてください。
MSG
  exit 2
fi

# 要素に指定が無い場合の保険 (空パターンは全一致になるため既定を置く)
[[ -n "$runbook_pattern" ]] || runbook_pattern='runbook.*\.md'
[[ -n "$runbook_hint" ]] || runbook_hint='ファイル名に runbook を含む .md'
[[ -n "$guide_ref" ]] || guide_ref='クラウド変更の手順'

go_token="[change-go: ${project}]"

# 5) transcript 取得
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
if [[ -z "$transcript" || ! -f "$transcript" ]]; then
  cat >&2 <<MSG
[クラウド変更コマンドの停止]
transcript が取得できないため、手順書の Read と承認の確認ができません。
新規セッションの最初の変更コマンドは、手順書を Read し、${principal}に
${go_token} だけの行を含むメッセージで承認してもらってから実行してください。
MSG
  exit 2
fi

# 6) 依頼者の最後のテキスト入力を取得
last_user_msg=$(harness_last_user_message "$transcript")

# 7) バイパス判定 (それだけの行にある場合のみ有効)
if harness_has_token "$last_user_msg" '[hook-bypass: cloud-change]'; then
  exit 0
fi

# 8) 承認の文字列判定 (それだけの行にある場合のみ有効)
has_go=0
if harness_has_token "$last_user_msg" "$go_token"; then
  has_go=1
fi

# 9) 手順書の Read 判定 (案件別パターン。Write / Edit / MultiEdit は数えない)
runbook_access=$(tail -200 "$transcript" \
  | jq -rR -n '[inputs | fromjson? // empty] | .[]
      | select(.type=="assistant") | .message.content[]?
      | select(.type=="tool_use" and .name=="Read")
      | .input.file_path // .input.path // empty' 2>/dev/null \
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
  missing="${missing}  - 直近で手順書 (${runbook_hint}) を Read していない\n"
fi
if [[ "$has_go" -eq 0 ]]; then
  missing="${missing}  - 最後の${principal}のテキスト入力に ${go_token} だけの行が無い\n"
fi

cat >&2 <<MSG
[クラウド変更コマンドの停止]
az / aws / cdk の変更系コマンド (${detected_cmd}...) を実行しようとしていますが、
以下の条件が満たされていません:
$(printf "${missing}")

${guide_ref}の手順:
1. 手順書を Read する (${runbook_hint})
2. ${principal}に内容を確認してもらう
3. ${principal}が ${go_token} だけの行を含むメッセージで承認する
4. その直後に変更コマンドを実行する

read-only コマンド (list/get/show/describe/query、cdk synth/diff) はブロック対象外です。
緊急時のみ、${principal}が [hook-bypass: cloud-change] だけの行を書くことで回避できます。
アシスタント側からのバイパスの提案・要求は禁止 (rules「start-approval」)。
MSG
exit 2
