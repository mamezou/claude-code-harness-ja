#!/bin/bash
# harness-ja 共通: 利用側プロジェクトの .claude/harness.json を読む。
# 各 hook は `source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"` で取り込む。
#
# 使い方:
#   harness_load_config "$hook_input_json"   # cwd / CLAUDE_PROJECT_DIR から設定ファイルを特定
#   cfg '.changeGate.enabled' 'true'         # jq フィルタで値を取る。null なら第 2 引数の既定値
#   cfg_list '.draftPrecheck.bannedTerms[]?' # 配列を 1 行 1 要素で出す
#   cfg_enabled '.changeGate'                # .enabled が false なら 1 (無効)、それ以外は 0
#
# 設定ファイルの探索順:
#   1. 環境変数 HARNESS_CONFIG (テストや複数プロジェクト用の上書き)
#   2. ${CLAUDE_PROJECT_DIR}/.claude/harness.json
#   3. hook 入力 JSON の cwd から上へ辿って最初に見つかる .claude/harness.json
# 見つからなければ HARNESS_CONFIG_PATH は空。cfg は既定値を返す。

HARNESS_CONFIG_PATH=""
HARNESS_CONFIG_JSON="{}"

harness_load_config() {
  local input="${1:-}" cwd="" dir=""
  if [[ -n "${HARNESS_CONFIG:-}" && -f "${HARNESS_CONFIG}" ]]; then
    HARNESS_CONFIG_PATH="${HARNESS_CONFIG}"
  elif [[ -n "${CLAUDE_PROJECT_DIR:-}" && -f "${CLAUDE_PROJECT_DIR}/.claude/harness.json" ]]; then
    HARNESS_CONFIG_PATH="${CLAUDE_PROJECT_DIR}/.claude/harness.json"
  else
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
    dir="${cwd:-$PWD}"
    while [[ -n "$dir" && "$dir" != "/" ]]; do
      if [[ -f "$dir/.claude/harness.json" ]]; then
        HARNESS_CONFIG_PATH="$dir/.claude/harness.json"
        break
      fi
      dir=$(dirname "$dir")
    done
  fi
  if [[ -n "$HARNESS_CONFIG_PATH" ]]; then
    HARNESS_CONFIG_JSON=$(jq -c . "$HARNESS_CONFIG_PATH" 2>/dev/null || echo '{}')
  fi
}

# cfg <jq filter> [default]
cfg() {
  local filter="$1" default="${2:-}" val
  val=$(printf '%s' "$HARNESS_CONFIG_JSON" | jq -r "${filter} // empty" 2>/dev/null || true)
  if [[ -z "$val" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# cfg_list <jq filter producing multiple values>
cfg_list() {
  printf '%s' "$HARNESS_CONFIG_JSON" | jq -r "$1" 2>/dev/null || true
}

# cfg_enabled <jq path of a section>  -> return 0 if enabled (default), 1 if "enabled": false
cfg_enabled() {
  local v
  v=$(printf '%s' "$HARNESS_CONFIG_JSON" | jq -r "if ${1}.enabled == false then \"false\" else \"true\" end" 2>/dev/null || echo true)
  [[ "$v" != "false" ]]
}

# 承認者の呼び名 (通知文で使う)。既定は「依頼者」
harness_principal() {
  cfg '.principal' '依頼者'
}

# transcript の末尾から、依頼者の最後のテキスト入力を {uuid, text} の 1 行 JSON で返す
# harness_last_user_entry <transcript> [末尾行数 (既定 2000)]
# 除外するもの:
#   - ツール結果の行 (content 配列に tool_result を含む)
#   - isMeta の行 (hook のフィードバック等、依頼者が書いていない user 行)
#   - ローカルコマンドの記録 (<command-name> / <local-command-stdout> / <local-command-caveat>)
# uuid は「同じ入力への差し戻し回数」の集計キーに使う。取れなければ空文字。
harness_last_user_entry() {
  local transcript="$1" tail_lines="${2:-2000}"
  [[ -f "$transcript" ]] || return 0
  tail -n "$tail_lines" "$transcript" | jq -cR -n '
    [inputs | fromjson? // empty
     | select(.type=="user" and ((.isMeta // false) | not))
     | select((.message.content|type)=="string"
              or ((.message.content|type)=="array"
                  and ([.message.content[]? | select(.type=="tool_result")] | length)==0))
     | {uuid: (.uuid // ""),
        text: (if (.message.content|type)=="string" then .message.content
               else ([.message.content[]? | select(.type=="text") | .text] | join("\n")) end)}
     | select(.text | test("^\\s*<(command-name|local-command-stdout|local-command-caveat)") | not)]
    | last // empty' 2>/dev/null || true
}

# transcript 全体から、ツール結果を含まない最後のユーザー入力テキストを取り出す
harness_last_user_text() {
  local transcript="$1" msg
  [[ -f "$transcript" ]] || return 0
  msg=$(grep '"type":"user"' "$transcript" | grep -v '"tool_result"' | tail -1 \
    | jq -r 'select(.type=="user") | .message.content
        | if type=="string" then .
          elif type=="array" and ([.[] | select(.type=="tool_result")] | length)==0
            then ([.[] | select(.type=="text") | .text] | join("\n"))
          else empty end
        | @base64' 2>/dev/null \
    | tail -1 || true)
  printf '%s' "$msg" | base64 -d 2>/dev/null || true
}
