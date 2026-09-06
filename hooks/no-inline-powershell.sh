#!/bin/bash
# PowerShell スクリプトをテキストでインライン提示するのを Stop 時に検知してブロックする
# (ファイル化して渡す運用の機械的強制)
#
# 検知条件:
#   - 直近の assistant ターン text に ```powershell または ```ps1 の 5 行以上の block がある
#   - かつ、直近 100 行の assistant tool_use 内に Write(*.ps1) が無い
# 上記を満たしたら exit 2 + メッセージ → 再生成させる
#
# 設定 (.claude/harness.json):
#   noInlinePowershell.enabled        false で無効化
#   noInlinePowershell.scriptDirHint  ファイル化先の案内 (既定 scripts/*.ps1)

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

input=$(cat)
harness_load_config "$input"

if ! cfg_enabled '.noInlinePowershell'; then
  exit 0
fi

script_dir_hint=$(cfg '.noInlinePowershell.scriptDirHint' 'scripts/*.ps1')

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

if [[ -z "$transcript" || ! -f "$transcript" ]]; then
  exit 0
fi

# 1) 最後の assistant message を 1 件取得
last_asst=$(grep '"type":"assistant"' "$transcript" | tail -1 || true)
if [[ -z "$last_asst" ]]; then
  exit 0
fi

# 2) text content を結合
text=$(printf '%s' "$last_asst" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null || true)
if [[ -z "$text" ]]; then
  exit 0
fi

# 3) ```powershell / ```ps1 で始まる fenced code block で 5 行以上のものを検出
has_block=$(printf '%s\n' "$text" | awk '
  BEGIN { in_block=0; lines=0; found=0 }
  /^```(powershell|ps1)([[:space:]]|$)/ { in_block=1; lines=0; next }
  in_block && /^```/ { if (lines>=5) found=1; in_block=0; next }
  in_block { lines++ }
  END { print (found ? "yes" : "no") }
')

if [[ "$has_block" != "yes" ]]; then
  exit 0
fi

# 4) 直近 100 行の transcript で Write(*.ps1) が呼ばれていれば許容
ps1_write=$(tail -100 "$transcript" \
  | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Write") | .input.file_path // empty' 2>/dev/null \
  | grep -E '\.ps1$' || true)

if [[ -n "$ps1_write" ]]; then
  exit 0
fi

# 5) ブロック
cat >&2 <<MSG
[インライン PowerShell 提示の禁止]
PowerShell スクリプトをインラインのコードブロックでユーザーに提示しています。
ルール: ${script_dir_hint} に Write してパスのみ提示すること（直接コピペ禁止）。
スクリプトをファイル化して再提示してください。
MSG
exit 2
