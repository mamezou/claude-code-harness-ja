#!/bin/bash
# harness-ja の hook 合成テスト。
# 一時ディレクトリへ合成 transcript / hook 入力 / 設定ファイルを作り、5 本の hook を
# 期待値つきで実行する。末尾に PASS / FAIL 件数を出し、FAIL が 1 件でもあれば exit 1。
#
# 使い方: bash tests/run.sh   (リポジトリ内のどのディレクトリからでも実行できる)
# 必要なコマンド:
#   jq      必須 (hook 本体が使う)
#   python3 任意 (検知ログの UTF-8 確認のみ。無ければその 1 件を SKIP)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
H="$ROOT/hooks"
EX="$ROOT/examples/harness.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq が見つかりません。jq を入れてから再実行してください。" >&2
  exit 1
fi
for f in change-gate.sh draft-precheck.sh no-inline-powershell.sh require-reading.sh response-quality.sh; do
  if [[ ! -f "$H/$f" ]]; then
    echo "hook が見つかりません: $H/$f" >&2
    exit 1
  fi
done
if [[ ! -f "$EX" ]]; then
  echo "サンプル設定が見つかりません: $EX" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 作業領域 (終了時に削除)
# ---------------------------------------------------------------------------
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

PROJ="$W/proj"
NOCONF="$W/noconf"
REGEN="$W/regen"
CPD="$W/cpd"
TR="$W/tr"
IN="$W/in"
mkdir -p "$PROJ/.claude" "$PROJ/docs/drafts" "$PROJ/docs/logs" \
         "$NOCONF" "$REGEN/.claude" "$CPD" "$TR" "$IN"

CFG="$PROJ/.claude/harness.json"
NOCFG="$NOCONF/none.json"                       # 存在しないパス
LOG="$PROJ/.claude/harness-detections.log"
NOCONF_LOG="$NOCONF/.claude/harness-detections.log"
CPD_LOG="$CPD/.claude/harness-detections.log"
REGEN_LOG="$REGEN/.claude/harness-detections.log"
WORKLOG="$PROJ/docs/logs/work-log-YYYYMMDD.md"

# ---------------------------------------------------------------------------
# 設定ファイル
# ---------------------------------------------------------------------------
cat > "$CFG" <<'JSON'
{
  "version": 1,
  "principal": "依頼者",
  "responseQuality": {
    "enabled": true,
    "logPath": ".claude/harness-detections.log",
    "uiTerms": [],
    "fluffTerms": [],
    "bannedLeads": [],
    "regenSkipWindowSec": 1800,
    "regenSkipThreshold": 2
  },
  "changeGate": {
    "enabled": true,
    "projects": [
      {
        "name": "project-a",
        "clis": ["az"],
        "runbookPattern": "(docs/runbooks/.*\\.md|runbook.*\\.md)",
        "runbookHint": "docs/runbooks/*.md",
        "guideRef": "手順書の運用"
      },
      {
        "name": "project-b",
        "clis": ["aws", "cdk"],
        "cwdMatch": "project-b",
        "runbookPattern": "(docs/runbooks/.*\\.md|runbook.*\\.md)",
        "runbookHint": "docs/runbooks/ 配下の .md",
        "guideRef": "手順書の運用"
      }
    ]
  },
  "draftPrecheck": {
    "enabled": true,
    "targets": ["*/docs/drafts/*-draft.md", "*/docs/drafts/*-draft.txt"],
    "excludePatterns": ["-internal-", "_internal", "/archive/"],
    "bannedTerms": ["横串"],
    "honorific": { "name": "取引先", "suffix": "様" }
  },
  "requireReading": {
    "enabled": true,
    "rules": [
      {
        "target": "*/proj/TODO.md",
        "requiredReadPattern": "(^|/)proj/TODO\\.md$",
        "hint": "TODO.md"
      },
      {
        "target": "*/proj/docs/logs/*.md",
        "mode": "logs",
        "requiredReadPattern": "(^|/)proj/docs/logs/.*\\.md$",
        "hint": "docs/logs/"
      }
    ]
  },
  "noInlinePowershell": {
    "enabled": true,
    "scriptDirHint": "scripts/{category}/*.ps1"
  }
}
JSON

cp "$CFG" "$REGEN/.claude/harness.json"
jq '.responseQuality.enabled=false'    "$CFG" > "$PROJ/.claude/harness-off.json"
jq '.noInlinePowershell.enabled=false' "$CFG" > "$PROJ/.claude/harness-psoff.json"
touch "$PROJ/TODO.md"

# ---------------------------------------------------------------------------
# 合成 transcript
# ---------------------------------------------------------------------------
mk_user()    { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
mk_asst()    { jq -cn --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
mk_read()    { jq -cn --arg p "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Read",input:{file_path:$p}}]}}'; }
mk_toolres() { jq -cn '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}'; }

# response-quality 用
{ mk_user "状況を教えて";                                 mk_asst "設定は効きます。"; }                  > "$TR/rq-block.jsonl"
{ mk_user "状況を教えて";                                 mk_asst "アラート設定を更新した。件数は12件。"; } > "$TR/rq-pass.jsonl"
{ mk_user "状況を教えて [hook-bypass: response-quality]"; mk_asst "設定は効きます。"; }                  > "$TR/rq-bypass.jsonl"

# change-gate 用 (ツール結果行を挟む)
{ mk_user "リソースグループを作って";                        mk_toolres; }                          > "$TR/cg-nogo.jsonl"
{ mk_user "リソースグループを作って [change-go: project-a]"; mk_read "$PROJ/docs/runbooks/rg.md"; } > "$TR/cg-go.jsonl"

# require-reading 用
{ mk_user "TODO を更新して"; mk_toolres; }              > "$TR/rr-noread.jsonl"
{ mk_user "TODO を更新して"; mk_read "$PROJ/TODO.md"; } > "$TR/rr-read.jsonl"
{ mk_user "ログを追記して";  mk_read "$WORKLOG"; }        > "$TR/rr-logread.jsonl"

# no-inline-powershell 用 (6 行の powershell ブロック)
ps_text=$(printf '確認スクリプトです。\n```powershell\n$a = 1\n$b = 2\n$c = 3\n$d = 4\n$e = 5\n$f = 6\n```\n')
{ mk_user "確認方法を教えて"; mk_asst "$ps_text"; } > "$TR/ps-block.jsonl"

# ---------------------------------------------------------------------------
# hook 入力 JSON
# ---------------------------------------------------------------------------
stop_input() { # stop_input <transcript> <cwd> <stop_hook_active>
  jq -cn --arg tr "$1" --arg cwd "$2" --argjson active "$3" \
    '{stop_hook_active:$active,transcript_path:$tr,cwd:$cwd}'
}
bash_input() { # bash_input <transcript> <cwd> <command>
  jq -cn --arg tr "$1" --arg cwd "$2" --arg c "$3" \
    '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$tr,cwd:$cwd}'
}
write_input() { # write_input <transcript> <cwd> <file_path> <content>
  jq -cn --arg tr "$1" --arg cwd "$2" --arg p "$3" --arg c "$4" \
    '{tool_name:"Write",tool_input:{file_path:$p,content:$c},transcript_path:$tr,cwd:$cwd}'
}
edit_input() { # edit_input <transcript> <cwd> <file_path> <new_string>
  jq -cn --arg tr "$1" --arg cwd "$2" --arg p "$3" --arg n "$4" \
    '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"a",new_string:$n},transcript_path:$tr,cwd:$cwd}'
}

# response-quality
stop_input "$TR/rq-block.jsonl"  "$PROJ"   false > "$IN/rq-block.json"
stop_input "$TR/rq-pass.jsonl"   "$PROJ"   false > "$IN/rq-pass.json"
stop_input "$TR/rq-bypass.jsonl" "$PROJ"   false > "$IN/rq-bypass.json"
stop_input "$TR/rq-block.jsonl"  "$PROJ"   true  > "$IN/rq-active.json"
stop_input "$TR/rq-block.jsonl"  "$NOCONF" false > "$IN/rq-noconf.json"
stop_input "$TR/rq-block.jsonl"  "$REGEN"  false > "$IN/rq-regen.json"

# change-gate
cg_change="az group create --name rg-test --location japaneast"
bash_input "$TR/cg-nogo.jsonl" "$PROJ"        "$cg_change"                        > "$IN/cg-create.json"
bash_input "$TR/cg-nogo.jsonl" "$PROJ"        "az group list"                     > "$IN/cg-list.json"
bash_input "$TR/cg-go.jsonl"   "$PROJ"        "$cg_change"                        > "$IN/cg-go.json"
bash_input "$TR/cg-nogo.jsonl" "$NOCONF"      "$cg_change"                        > "$IN/cg-noconf.json"
bash_input "$TR/cg-nogo.jsonl" "/w/project-a" "$cg_change"                        > "$IN/cg-example.json"
bash_input "$TR/cg-nogo.jsonl" "/w/project-b" "npx cdk deploy MyStack"            > "$IN/cg-cdk.json"
bash_input "$TR/cg-nogo.jsonl" "/w/other"     "aws s3api create-bucket --bucket b" > "$IN/cg-nomatch.json"
bash_input "$TR/cg-nogo.jsonl" "$PROJ"        "az account set --subscription foo"  > "$IN/cg-acct.json"

# draft-precheck
DRAFT="$PROJ/docs/drafts/report-draft.md"
DRAFT_EXCL="$PROJ/docs/drafts/report-internal-draft.md"
DRAFT_OUT="$PROJ/docs/other/report-draft.md"
dp_abs_body=$(printf 'ご確認ください。\n資料は /var/data/report にあります。\n')
dp_clean_body=$(printf 'ご確認ください。\n本日の打ち合わせの件、承知しました。\n')
dp_hon_body=$(printf '# 取引先 ご報告\n横串で確認します。\n')
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT"      "$dp_abs_body"                  > "$IN/dp-abs.json"
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT_EXCL" "$dp_abs_body"                  > "$IN/dp-excl.json"
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT"      "$dp_clean_body"                > "$IN/dp-clean.json"
edit_input  "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT"      "$dp_hon_body"                  > "$IN/dp-hon.json"
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT_OUT"  "資料は /var/data にあります。" > "$IN/dp-nontarget.json"
write_input "$TR/rr-noread.jsonl" "$NOCONF" "$DRAFT"      "資料は /var/data にあります。" > "$IN/dp-noconf.json"

# require-reading
edit_input  "$TR/rr-noread.jsonl"  "$PROJ"   "$PROJ/TODO.md"   "b"     > "$IN/rr-noread.json"
edit_input  "$TR/rr-read.jsonl"    "$PROJ"   "$PROJ/TODO.md"   "b"     > "$IN/rr-read.json"
edit_input  "$TR/rr-noread.jsonl"  "$NOCONF" "$PROJ/TODO.md"   "b"     > "$IN/rr-noconf.json"
edit_input  "$TR/rr-noread.jsonl"  "$PROJ"   "$PROJ/README.md" "b"     > "$IN/rr-nontarget.json"
write_input "$TR/rr-noread.jsonl"  "$PROJ"   "$WORKLOG"        "# ログ" > "$IN/rr-lognew.json"
edit_input  "$TR/rr-noread.jsonl"  "$PROJ"   "$WORKLOG"        "b"     > "$IN/rr-logedit.json"
edit_input  "$TR/rr-logread.jsonl" "$PROJ"   "$WORKLOG"        "b"     > "$IN/rr-logedit2.json"

# no-inline-powershell
stop_input "$TR/ps-block.jsonl" "$PROJ" false > "$IN/ps-block.json"
stop_input "$TR/rq-pass.jsonl"  "$PROJ" false > "$IN/ps-none.json"

# ---------------------------------------------------------------------------
# 判定
# ---------------------------------------------------------------------------
pass=0
fail=0

verdict() { # verdict <名前> <期待> <実際> <PASS|FAIL>
  if [[ "$4" == PASS ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  printf '%-52s 期待=%s 実際=%s %s\n' "$1" "$2" "$3" "$4"
}

run() { # run <名前> <期待 exit> <hook> <config> <input> [期待メッセージ断片]
  local name="$1" exp="$2" hook="$3" cfg="$4" inp="$5" want="${6:-}" err rc v
  err=$(env -u CLAUDE_PROJECT_DIR HARNESS_CONFIG="$cfg" bash "$H/$hook" < "$inp" 2>&1 >/dev/null)
  rc=$?
  v=PASS
  [[ "$rc" == "$exp" ]] || v=FAIL
  if [[ -n "$want" ]] && ! printf '%s' "$err" | grep -qF -- "$want"; then v=FAIL; fi
  verdict "$name" "$exp" "$rc" "$v"
  if [[ "$v" == FAIL && -n "$err" ]]; then printf '%s\n' "$err" | head -6 | sed 's/^/      /'; fi
}

check() { # check <名前> <期待値> <実際値>
  local v=PASS
  [[ "$3" == "$2" ]] || v=FAIL
  verdict "$1" "$2" "$3" "$v"
}

exists() { if [[ -f "$1" ]]; then echo yes; else echo no; fi; }

echo "== response-quality =="
rm -f "$LOG"
run "RQ-1 効きます -> block" 2 response-quality.sh "$CFG" "$IN/rq-block.json" "効きます"
check "RQ-1a 検知ログの非空行数" 1 "$(grep -c . "$LOG" 2>/dev/null || echo 0)"

if command -v python3 >/dev/null 2>&1; then
  utf8=$(python3 - "$LOG" <<'PY'
import sys
try:
    s = open(sys.argv[1], 'rb').read().decode('utf-8')
except Exception:
    print('NG'); raise SystemExit(0)
print('OK' if [l for l in s.split('\n') if l.strip()] else 'NG')
PY
)
  check "RQ-1b 検知ログが UTF-8 として decode 可能" OK "$utf8"
else
  printf '%-52s %s\n' "RQ-1b 検知ログが UTF-8 として decode 可能" "SKIP (python3 なし)"
fi

run "RQ-2 検知語なし -> pass" 0 response-quality.sh "$CFG" "$IN/rq-pass.json"
run "RQ-3 bypass トークン -> pass" 0 response-quality.sh "$CFG" "$IN/rq-bypass.json"
check "RQ-3a 検知ログは RQ-2/3 で増えない" 1 "$(grep -c . "$LOG")"
run "RQ-4 stop_hook_active=true -> pass" 0 response-quality.sh "$CFG" "$IN/rq-active.json"

# 設定ファイル無し (cwd 配下にも無い) -> 既定値で block
rm -f "$NOCONF_LOG"
run "RQ-5 設定なし -> 既定値で block" 2 response-quality.sh "$NOCFG" "$IN/rq-noconf.json" "効きます"
check "RQ-5a 既定 logPath は cwd 配下へ解決" yes "$(exists "$NOCONF_LOG")"

# CLAUDE_PROJECT_DIR 優先の確認
rm -f "$CPD_LOG"
CLAUDE_PROJECT_DIR="$CPD" HARNESS_CONFIG="$CFG" bash "$H/response-quality.sh" < "$IN/rq-block.json" >/dev/null 2>&1
check "RQ-5b CLAUDE_PROJECT_DIR が logPath の基点" yes "$(exists "$CPD_LOG")"

run "RQ-6 enabled:false -> pass" 0 response-quality.sh "$PROJ/.claude/harness-off.json" "$IN/rq-block.json"

# regen-skip (窓 1800 秒 / 閾値 2): 3 回目は差し戻さず [regen-skip] を記録して通過
rm -f "$REGEN_LOG"
regen_rc=()
for i in 1 2 3; do
  env -u CLAUDE_PROJECT_DIR HARNESS_CONFIG="$REGEN/.claude/harness.json" \
    bash "$H/response-quality.sh" < "$IN/rq-regen.json" >/dev/null 2>&1
  regen_rc+=("$?")
done
check "RQ-7 regen-skip 連続実行 1 回目 -> block" 2 "${regen_rc[0]}"
check "RQ-8 regen-skip 連続実行 2 回目 -> block" 2 "${regen_rc[1]}"
check "RQ-9 regen-skip 連続実行 3 回目 -> pass"  0 "${regen_rc[2]}"
check "RQ-10 [regen-skip] の行数" 1 "$(grep -c 'regen-skip' "$REGEN_LOG" 2>/dev/null || echo 0)"

echo
echo "== change-gate =="
run "CG-1 変更系 (GO/runbook なし) -> block" 2 change-gate.sh "$CFG" "$IN/cg-create.json" "[change-go: project-a]"
run "CG-2 read-only なコマンド -> pass" 0 change-gate.sh "$CFG" "$IN/cg-list.json"
run "CG-3 GO + runbook Read -> pass" 0 change-gate.sh "$CFG" "$IN/cg-go.json"
run "CG-4 設定ファイルなし -> pass" 0 change-gate.sh "$NOCFG" "$IN/cg-noconf.json"
run "CG-5 examples 設定 + cwd project-a -> block" 2 change-gate.sh "$EX" "$IN/cg-example.json" "[change-go: project-a]"
run "CG-6 examples 設定 + cdk deploy (project-b) -> block" 2 change-gate.sh "$EX" "$IN/cg-cdk.json" "[change-go: project-b]"
run "CG-7 どの案件にも一致しない変更系 -> pass" 0 change-gate.sh "$EX" "$IN/cg-nomatch.json"
run "CG-8 ローカル CLI 設定 -> pass (除外)" 0 change-gate.sh "$CFG" "$IN/cg-acct.json"

echo
echo "== draft-precheck =="
run "DP-1 対象パス + 絶対パス -> block" 2 draft-precheck.sh "$CFG" "$IN/dp-abs.json" "絶対パス検出"
run "DP-2 除外パターン (-internal-) -> pass" 0 draft-precheck.sh "$CFG" "$IN/dp-excl.json"
run "DP-3 対象パス + 問題なし -> pass" 0 draft-precheck.sh "$CFG" "$IN/dp-clean.json"
run "DP-4 禁止語 + 見出し敬称抜け -> block" 2 draft-precheck.sh "$CFG" "$IN/dp-hon.json" "禁止語"
run "DP-5 対象外パス -> pass" 0 draft-precheck.sh "$CFG" "$IN/dp-nontarget.json"
run "DP-6 設定ファイルなし -> pass" 0 draft-precheck.sh "$NOCFG" "$IN/dp-noconf.json"
run "DP-7 examples 設定 (honorific 空) -> pass" 0 draft-precheck.sh "$EX" "$IN/dp-hon.json"

echo
echo "== require-reading =="
run "RR-1 TODO.md を Read なしで Edit -> block" 2 require-reading.sh "$CFG" "$IN/rr-noread.json" "資料先読みの原則"
run "RR-2 直近に TODO.md の Read あり -> pass" 0 require-reading.sh "$CFG" "$IN/rr-read.json"
rm -f "$WORKLOG"
run "RR-3 logs 新規 + Read なし -> block" 2 require-reading.sh "$CFG" "$IN/rr-lognew.json" "新規ログファイル"
run "RR-4 対象外パス -> pass" 0 require-reading.sh "$CFG" "$IN/rr-nontarget.json"
run "RR-5 設定ファイルなし -> pass" 0 require-reading.sh "$NOCFG" "$IN/rr-noconf.json"
touch "$WORKLOG"
run "RR-6 logs 既存編集 + 自ファイル Read なし -> block" 2 require-reading.sh "$CFG" "$IN/rr-logedit.json" "既存ログファイル"
run "RR-7 logs 既存編集 + 自ファイル Read あり -> pass" 0 require-reading.sh "$CFG" "$IN/rr-logedit2.json"

echo
echo "== no-inline-powershell =="
run "PS-1 6 行の powershell ブロック -> block" 2 no-inline-powershell.sh "$CFG" "$IN/ps-block.json" "scripts/{category}/*.ps1"
run "PS-2 ブロックなし -> pass" 0 no-inline-powershell.sh "$CFG" "$IN/ps-none.json"
run "PS-3 enabled:false -> pass" 0 no-inline-powershell.sh "$PROJ/.claude/harness-psoff.json" "$IN/ps-block.json"

echo
echo "PASS ${pass} / FAIL ${fail}"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0
