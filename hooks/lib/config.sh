#!/bin/bash
# harness-ja 共通: 利用側プロジェクトの .claude/harness.json を読む。
# 各 hook は `source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"` で取り込む。
#
# 使い方:
#   harness_load_config "$hook_input_json"   # cwd / CLAUDE_PROJECT_DIR から設定ファイルを特定
#   harness_config_guard pre                 # 設定ファイルが壊れているときの共通の止め方
#   cfg '.cloudChange.enabled' 'true'        # jq フィルタで値を取る。null なら第 2 引数の既定値
#   cfg_list '.draftPrecheck.bannedTerms[]?' # 配列を 1 行 1 要素で出す
#   cfg_enabled '.cloudChange'               # 設定ファイルがあり .enabled が false でなければ 0
#   cfg_enabled_optin '.noInlinePowershell'  # .enabled が true のときだけ 0 (既定は無効)
#
# 設定ファイルの探索順:
#   1. 環境変数 HARNESS_CONFIG (テストや複数プロジェクト用の上書き)
#   2. ${CLAUDE_PROJECT_DIR}/.claude/harness.json
#   3. hook 入力 JSON の cwd から上へ辿って最初に見つかる .claude/harness.json
#
# 設定ファイルが見つからない場合、cfg_enabled / cfg_enabled_optin は偽を返す。
# 初期化前のプロジェクトでは全 hook が何もしない (初期化は Skill /harness-ja:harness-init)。
# 設定ファイルはあるが JSON として読めない場合は HARNESS_CONFIG_BROKEN=1 になる。
# 既定値で動かすと安全機能の一部だけが効くため、harness_config_guard で止める。

HARNESS_CONFIG_PATH=""
HARNESS_CONFIG_JSON="{}"
HARNESS_CONFIG_BROKEN=0

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
    if HARNESS_CONFIG_JSON=$(jq -c . "$HARNESS_CONFIG_PATH" 2>/dev/null); then
      HARNESS_CONFIG_BROKEN=0
    else
      HARNESS_CONFIG_JSON="{}"
      HARNESS_CONFIG_BROKEN=1
    fi
  fi
}

# harness_config_guard <pre|stop>
# 設定ファイルが JSON として読めないときに hook を終える。
#   pre  (PreToolUse): stderr へ出して exit 2 (ツール実行を止める)
#   stop (Stop):       stderr へ出して exit 0 (応答は止めない)
harness_config_guard() {
  [[ "$HARNESS_CONFIG_BROKEN" -eq 1 ]] || return 0
  printf '設定ファイルが読めません: %s\n' "$HARNESS_CONFIG_PATH" >&2
  if [[ "${1:-pre}" == "stop" ]]; then
    exit 0
  fi
  exit 2
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

# cfg_enabled <jq path of a section>
#   0 (有効): 設定ファイルがあり、.enabled が false でない
#   1 (無効): 設定ファイルが無い、または .enabled が false
cfg_enabled() {
  local v
  [[ -n "$HARNESS_CONFIG_PATH" ]] || return 1
  v=$(printf '%s' "$HARNESS_CONFIG_JSON" | jq -r "if ${1}.enabled == false then \"false\" else \"true\" end" 2>/dev/null || echo true)
  [[ "$v" != "false" ]]
}

# cfg_enabled_optin <jq path of a section>
#   0 (有効): 設定ファイルがあり、.enabled が true
#   1 (無効): それ以外 (既定は無効。設定で明示的に有効化する機能に使う)
cfg_enabled_optin() {
  local v
  [[ -n "$HARNESS_CONFIG_PATH" ]] || return 1
  v=$(printf '%s' "$HARNESS_CONFIG_JSON" | jq -r "if ${1}.enabled == true then \"true\" else \"false\" end" 2>/dev/null || echo false)
  [[ "$v" == "true" ]]
}

# cfg_flag <jq path> [既定 "true" | "false"]
#   真偽値の設定を読む。cfg は jq の `//` を使うため false を既定値へ倒してしまう。
#   個別の検査を止める設定 (draftPrecheck.checks.* 等) は本関数で読む。
cfg_flag() {
  local path="$1" default="${2:-true}" v
  v=$(printf '%s' "$HARNESS_CONFIG_JSON" | jq -r "${path} | if . == null then \"\" else tostring end" 2>/dev/null || true)
  [[ -n "$v" ]] || v="$default"
  [[ "$v" == "true" ]]
}

# 承認者の呼び名 (通知文で使う)。既定は「依頼者」
harness_principal() {
  cfg '.principal' '依頼者'
}

# harness_has_token <text> <token>
# 承認の文字列・バイパスの文字列の判定。文字列がそれだけの行 (前後の空白のみ可) に
# あるときだけ 0 を返す。引用・質問の中に含まれる場合 (「[harness-go] とは何ですか」)
# は 1 を返す。
harness_has_token() {
  local text="${1:-}" token="${2:-}"
  [[ -n "$token" ]] || return 1
  [[ -n "$text" ]] || return 1
  printf '%s\n' "$text" | awk -v tok="$token" '
    {
      line = $0
      gsub(/\r/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == tok) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }'
}

# transcript の末尾から、依頼者の最後のテキスト入力を {uuid, text} の 1 行 JSON で返す
# harness_last_user_entry <transcript> [末尾行数 (既定 2000)]
# 除外するもの:
#   - ツール結果の行 (content 配列に tool_result を含む)
#   - isMeta の行 (hook のフィードバック等、依頼者が書いていない user 行)
#   - ローカルコマンドの記録 (<command-name> / <local-command-stdout> / <local-command-caveat>)
# uuid は「同じ入力への差し戻し回数」の集計キーに使う。取れなければ空文字。
# 行の判定は jq で行う。grep の文字列一致 ('"type":"user"') では、空白入りの JSON
# ('"type": "user"') を user 行と認識できない。
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

# harness_last_user_message <transcript> [末尾行数]
# 依頼者の最後のテキスト入力の本文だけを返す (harness_last_user_entry の薄い包み)
harness_last_user_message() {
  harness_last_user_entry "$1" "${2:-2000}" | jq -r '.text // empty' 2>/dev/null || true
}
