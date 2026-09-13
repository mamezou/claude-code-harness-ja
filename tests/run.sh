#!/bin/bash
# harness-ja の hook 合成テスト。
# 一時ディレクトリへ合成の会話履歴 JSONL / hook 入力 / 設定ファイルを作り、6 本の hook を
# 期待値つきで実行する。末尾に PASS / FAIL 件数を出し、FAIL が 1 件でもあれば exit 1。
#
# 使い方: bash tests/run.sh   (リポジトリ内のどのディレクトリからでも実行できる)
# 必要なコマンド:
#   jq      必須 (hook 本体が使う)
#   python3 任意 (検知ログの UTF-8 確認のみ。無ければその 1 件を SKIP)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
H="$ROOT/hooks"
EX="$ROOT/examples/harness.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq が見つかりません。jq を入れてから再実行してください。" >&2
  exit 1
fi
for f in cloud-change-check.sh draft-precheck.sh harness-change-check.sh no-inline-powershell.sh \
         require-reading.sh response-quality.sh; do
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
if [[ -z "$W" || ! -d "$W" ]]; then
  echo "一時ディレクトリを作れません (mktemp -d が失敗しました)。" >&2
  exit 1
fi
trap 'rm -rf "$W"' EXIT

PROJ="$W/proj"
NOCONF="$W/noconf"
REGEN="$W/regen"
CPD="$W/cpd"
TR="$W/tr"
IN="$W/in"
ALT="$W/alt"
mkdir -p "$PROJ/.claude" "$PROJ/docs/drafts" "$PROJ/docs/logs" "$PROJ/docs/runbooks" \
         "$NOCONF" "$REGEN/.claude" "$CPD" "$TR" "$IN" "$ALT/docs/logs"

CFG="$PROJ/.claude/harness.json"
NOCFG="$NOCONF/none.json"                       # 存在しないパス
BROKEN="$W/broken.json"
LOG="$PROJ/.claude/harness-detections.log"
CPD_LOG="$CPD/.claude/harness-detections.log"
REGEN_LOG="$REGEN/.claude/harness-detections.log"
WORKLOG="$PROJ/docs/logs/work-log-YYYYMMDD.md"
ALT_WORKLOG="$ALT/docs/logs/work-log-YYYYMMDD.md"
RUNBOOK="$PROJ/docs/runbooks/rg.md"

# ---------------------------------------------------------------------------
# 設定ファイル
# ---------------------------------------------------------------------------
# responseQuality.patterns は書かない (既定の [3, 4, 8, 19] を検査するため)
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
    "regenLimitPerInput": 3
  },
  "harnessChange": {
    "enabled": true,
    "token": "[harness-go]",
    "excludePatterns": [".claude/projects/"]
  },
  "cloudChange": {
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
        "target": "*/docs/logs/*.md",
        "mode": "logs",
        "requiredReadPattern": "(^|/)docs/logs/.*\\.md$",
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

printf '{ "responseQuality": \n' > "$BROKEN"      # JSON として読めない設定

cp "$CFG" "$REGEN/.claude/harness.json"
jq '.responseQuality.enabled=false'    "$CFG" > "$PROJ/.claude/harness-off.json"
jq '.noInlinePowershell.enabled=false' "$CFG" > "$PROJ/.claude/harness-psoff.json"
jq '.noInlinePowershell.cwdMatch="kdkkb"' "$CFG" > "$PROJ/.claude/harness-pscwd.json"
jq '.harnessChange.enabled=false'      "$CFG" > "$PROJ/.claude/harness-hgoff.json"
jq '.responseQuality.patterns=[5,18]'  "$CFG" > "$PROJ/.claude/harness-p518.json"
jq '.draftPrecheck.checks={"internalPaths":false}' "$CFG" > "$PROJ/.claude/harness-dpoff.json"
P518="$PROJ/.claude/harness-p518.json"
DPOFF="$PROJ/.claude/harness-dpoff.json"
touch "$PROJ/TODO.md" "$RUNBOOK"

# ---------------------------------------------------------------------------
# 合成の会話履歴 (JSONL)
# ---------------------------------------------------------------------------
mk_user()    { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
mk_user_id() { jq -cn --arg t "$1" --arg u "$2" '{type:"user",uuid:$u,message:{role:"user",content:$t}}'; }
mk_asst()    { jq -cn --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
mk_read()    { jq -cn --arg p "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Read",input:{file_path:$p}}]}}'; }
mk_write()   { jq -cn --arg p "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Write",input:{file_path:$p}}]}}'; }
mk_toolres() { jq -cn '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}'; }
# キーの後ろに空白のある JSON (jq -c では作れないため直接組み立てる)
mk_user_spaced() { printf '{"type": "user", "uuid": "%s", "message": {"role": "user", "content": "%s"}}\n' "$2" "$1"; }
mk_asst_spaced() {
  local t
  t=$(printf '%s' "$1" | jq -Rs .)
  printf '{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": %s}]}}\n' "$t"
}

# response-quality: 既定で有効な 4 パターン (3 / 4 / 8 / 19)
{ mk_user "状況を教えて"; mk_asst "ひな形を作成し、報告しました。"; }              > "$TR/rq-p3.jsonl"
{ mk_user "状況を教えて"; mk_asst "ひな形を作成しました。報告書は未着手です。"; } > "$TR/rq-p3ok.jsonl"
{ mk_user "状況を教えて"; mk_asst "詳細は § 3 を参照。"; }                        > "$TR/rq-p4.jsonl"
{ mk_user "状況を教えて"; mk_asst "詳細は 3 節を参照。"; }                        > "$TR/rq-p4ok.jsonl"
{ mk_user "状況を教えて"; mk_asst "以後注意します。"; }                           > "$TR/rq-p8.jsonl"
{ mk_user "状況を教えて"; mk_asst "検知を追加し、テストを実行した。"; }           > "$TR/rq-p8ok.jsonl"
{ mk_user "この設計書、あってる?"; mk_asst "ご指摘の設計書はありません。TODO の1行に記載がありました。"; } \
  > "$TR/rq-p19-doc.jsonl"
{ mk_user "この設計書、あってる?"; mk_asst "ご指摘の設計書はありません。目次を開いて確かめました。"; } \
  > "$TR/rq-p19-docok.jsonl"
{ mk_user "認識はあってる?"; mk_asst "認識にズレがあります。"; }                        > "$TR/rq-p19-dis.jsonl"
{ mk_user "認識はあってる?"; mk_asst "認識にズレがあります。出典は設計書の3章です。"; } > "$TR/rq-p19-disok.jsonl"

# response-quality: パターン 5 (文末) と 18 (文頭・行頭) の境界
{ mk_user "状況を教えて"; mk_asst "設定は効きます。"; }                                > "$TR/rq-p5.jsonl"
{ mk_user "状況を教えて"; mk_asst "レプリカが落ちる条件を確認した。"; }                > "$TR/rq-p5ok.jsonl"
{ mk_user "状況を教えて"; mk_asst "以下のように整理しました。"; }                      > "$TR/rq-p18.jsonl"
{ mk_user "状況を教えて"; mk_asst "手順は次のとおり。作業は以下のように進めた記録がある。"; } \
  > "$TR/rq-p18ok.jsonl"

# response-quality: バイパスの文字列 (それだけの行 / 質問文の中)
{ mk_user "$(printf '状況を教えて\n[hook-bypass: response-quality]')"; mk_asst "以後注意します。"; } \
  > "$TR/rq-bypass.jsonl"

# response-quality: 差し戻し回数の集計用 (uuid つき)
{ mk_user_id "状況を教えて" "u-1"; mk_asst "以後注意します。"; } > "$TR/rq-uuid1.jsonl"

# response-quality: 空白入り JSON の user 行を区切りとして認識できるか
# 区切りより前の応答に検知語を置き、区切りより後ろの応答は検知語なしにする
{ mk_asst "以後注意します。"
  mk_user_spaced "状況を教えて" "u-sp"
  mk_asst "アラート設定を更新した。件数は12件。"; } > "$TR/rq-spaced.jsonl"

# harness-change-check 用 (ツール結果行を挟む)
{ mk_user "hook を直して"; mk_toolres; } > "$TR/hg-nogo.jsonl"
{ mk_user "$(printf 'hook を直して\n[harness-go]')"; mk_toolres; } > "$TR/hg-go.jsonl"
{ mk_user "[harness-go] とは何ですか"; mk_toolres; } > "$TR/hg-inline.jsonl"

# cloud-change-check 用
{ mk_user "リソースグループを作って"; mk_toolres; } > "$TR/cg-nogo.jsonl"
{ mk_user "$(printf 'リソースグループを作って\n[change-go: project-a]')"; mk_read "$RUNBOOK"; } \
  > "$TR/cg-go.jsonl"
{ mk_user "$(printf 'リソースグループを作って\n[change-go: project-a]')"; mk_write "$RUNBOOK"; } \
  > "$TR/cg-writeonly.jsonl"
{ mk_user "[change-go: project-a] とは何ですか"; mk_read "$RUNBOOK"; } > "$TR/cg-inline.jsonl"

# require-reading 用
{ mk_user "TODO を更新して"; mk_toolres; }              > "$TR/rr-noread.jsonl"
{ mk_user "TODO を更新して"; mk_read "$PROJ/TODO.md"; } > "$TR/rr-read.jsonl"
{ mk_user "ログを追記して";  mk_read "$WORKLOG"; }      > "$TR/rr-logread.jsonl"
{ mk_user "ログを追記して";  mk_read "$ALT_WORKLOG"; }  > "$TR/rr-logalt.jsonl"

# no-inline-powershell 用 (6 行の powershell ブロック)
ps_text=$(printf '確認スクリプトです。\n```powershell\n$a = 1\n$b = 2\n$c = 3\n$d = 4\n$e = 5\n$f = 6\n```\n')
{ mk_user "確認方法を教えて"; mk_asst "$ps_text"; } > "$TR/ps-block.jsonl"
{ mk_user_spaced "確認方法を教えて" "u-ps"; mk_asst_spaced "$ps_text"; } > "$TR/ps-spaced.jsonl"

# ---------------------------------------------------------------------------
# hook 入力 JSON
# ---------------------------------------------------------------------------
stop_input() { # stop_input <transcript> <cwd> <stop_hook_active> [session_id]
  jq -cn --arg tr "$1" --arg cwd "$2" --argjson active "$3" --arg sid "${4:-}" \
    '{stop_hook_active:$active,transcript_path:$tr,cwd:$cwd}
     + (if $sid == "" then {} else {session_id:$sid} end)'
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
for n in p3 p3ok p4 p4ok p8 p8ok p19-doc p19-docok p19-dis p19-disok p5 p5ok p18 p18ok bypass spaced; do
  stop_input "$TR/rq-$n.jsonl" "$PROJ" false > "$IN/rq-$n.json"
done
stop_input "$TR/rq-p8.jsonl" "$PROJ"   true  > "$IN/rq-active.json"
stop_input "$TR/rq-p8.jsonl" "$NOCONF" false > "$IN/rq-noconf.json"

# 差し戻し回数の集計 (session_id と user 行の uuid でまとめる)
stop_input "$TR/rq-uuid1.jsonl" "$REGEN" false "s-regen" > "$IN/rq-regen1.json"
stop_input "$TR/rq-uuid1.jsonl" "$REGEN" true  "s-regen" > "$IN/rq-regen2.json"

# harness-change-check
write_input "$TR/hg-nogo.jsonl"   "$PROJ"   "$PROJ/.claude/rules/x.md"            "本文" > "$IN/hg-write.json"
write_input "$TR/hg-go.jsonl"     "$PROJ"   "$PROJ/.claude/rules/x.md"            "本文" > "$IN/hg-go.json"
write_input "$TR/hg-inline.jsonl" "$PROJ"   "$PROJ/.claude/rules/x.md"            "本文" > "$IN/hg-inline.json"
write_input "$TR/hg-nogo.jsonl"   "$PROJ"   "$PROJ/.claude/projects/p/state.json" "{}"   > "$IN/hg-proj.json"
write_input "$TR/hg-nogo.jsonl"   "$PROJ"   "$NOCONF/.claude/harness.json"        "{}"   > "$IN/hg-initcfg.json"
write_input "$TR/hg-nogo.jsonl"   "$PROJ"   "$CFG"                                "{}"   > "$IN/hg-existcfg.json"
write_input "$TR/hg-nogo.jsonl"   "$NOCONF" "$NOCONF/.claude/rules/x.md"          "本文" > "$IN/hg-noconf.json"
bash_input  "$TR/hg-nogo.jsonl" "$PROJ" "echo x > $PROJ/.claude/settings.json"  > "$IN/hg-bash.json"
bash_input  "$TR/hg-nogo.jsonl" "$PROJ" "cp $PROJ/.claude/hooks/x.sh /tmp/"     > "$IN/hg-read.json"
bash_input  "$TR/hg-nogo.jsonl" "$PROJ" 'mkdir -p .claude/rules'                > "$IN/hg-mkdir.json"
bash_input  "$TR/hg-nogo.jsonl" "$PROJ" \
  'cp -n "${CLAUDE_PLUGIN_ROOT}"/rules-templates/*.md .claude/rules/'           > "$IN/hg-initcp.json"

# cloud-change-check
cg_change="az group create --name rg-test --location japaneast"
bash_input "$TR/cg-nogo.jsonl"      "$PROJ"        "$cg_change"                            > "$IN/cg-create.json"
bash_input "$TR/cg-nogo.jsonl"      "$PROJ"        "az group list"                         > "$IN/cg-list.json"
bash_input "$TR/cg-go.jsonl"        "$PROJ"        "$cg_change"                            > "$IN/cg-go.json"
bash_input "$TR/cg-writeonly.jsonl" "$PROJ"        "$cg_change"                            > "$IN/cg-writeonly.json"
bash_input "$TR/cg-inline.jsonl"    "$PROJ"        "$cg_change"                            > "$IN/cg-inline.json"
bash_input "$TR/cg-nogo.jsonl"      "$NOCONF"      "$cg_change"                            > "$IN/cg-noconf.json"
bash_input "$TR/cg-nogo.jsonl"      "/w/project-a" "$cg_change"                            > "$IN/cg-example.json"
bash_input "$TR/cg-nogo.jsonl"      "/w/project-b" "npx cdk deploy MyStack"                > "$IN/cg-cdk.json"
bash_input "$TR/cg-nogo.jsonl"      "/w/project-b" "cdk watch MyStack"                     > "$IN/cg-cdkwatch.json"
bash_input "$TR/cg-nogo.jsonl"      "/w/project-b" "aws s3 sync ./site s3://bucket --delete" > "$IN/cg-s3sync.json"
bash_input "$TR/cg-nogo.jsonl"      "/w/project-b" "aws cloudformation deploy --template-file t.yml --stack-name s" \
  > "$IN/cg-cfndeploy.json"
bash_input "$TR/cg-nogo.jsonl"      "/w/project-b" "aws lambda invoke --function-name f out.json" > "$IN/cg-invoke.json"
bash_input "$TR/cg-nogo.jsonl"      "/w/other"     "aws s3api delete-bucket --bucket b"     > "$IN/cg-nomatch.json"
bash_input "$TR/cg-nogo.jsonl"      "/w/project-a-old" "$cg_change"                        > "$IN/cg-suffix.json"
bash_input "$TR/cg-nogo.jsonl"      "$PROJ"        "az account set --subscription foo"     > "$IN/cg-acct.json"
bash_input "$TR/cg-nogo.jsonl"      "$PROJ"        "az group show --name rg --query set"   > "$IN/cg-query.json"
bash_input "$TR/cg-nogo.jsonl"      "$PROJ"        "echo az group create --name demo"      > "$IN/cg-echo.json"

# draft-precheck
DRAFT="$PROJ/docs/drafts/report-draft.md"
DRAFT_EXCL="$PROJ/docs/drafts/report-internal-draft.md"
DRAFT_OUT="$PROJ/docs/other/report-draft.md"
dp_abs_body=$(printf 'ご確認ください。\n資料は /var/data/report にあります。\n')
dp_clean_body=$(printf 'ご確認ください。\n本日の打ち合わせの件、承知しました。\n')
dp_hon_body=$(printf '# 取引先 ご報告\n横串で確認します。\n')
dp_url_body=$(printf 'ご確認ください。\n手順は https://example.com/docs/setup をご覧ください。\n')
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT"      "$dp_abs_body"                  > "$IN/dp-abs.json"
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT_EXCL" "$dp_abs_body"                  > "$IN/dp-excl.json"
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT"      "$dp_clean_body"                > "$IN/dp-clean.json"
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT"      "$dp_url_body"                  > "$IN/dp-url.json"
edit_input  "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT"      "$dp_hon_body"                  > "$IN/dp-hon.json"
write_input "$TR/rr-noread.jsonl" "$PROJ"   "$DRAFT_OUT"  "資料は /var/data にあります。" > "$IN/dp-nontarget.json"
write_input "$TR/rr-noread.jsonl" "$NOCONF" "$DRAFT"      "資料は /var/data にあります。" > "$IN/dp-noconf.json"

# require-reading
edit_input  "$TR/rr-noread.jsonl"  "$PROJ"   "$PROJ/TODO.md"   "b"      > "$IN/rr-noread.json"
edit_input  "$TR/rr-read.jsonl"    "$PROJ"   "$PROJ/TODO.md"   "b"      > "$IN/rr-read.json"
edit_input  "$TR/rr-noread.jsonl"  "$NOCONF" "$PROJ/TODO.md"   "b"      > "$IN/rr-noconf.json"
edit_input  "$TR/rr-noread.jsonl"  "$PROJ"   "$PROJ/README.md" "b"      > "$IN/rr-nontarget.json"
write_input "$TR/rr-noread.jsonl"  "$PROJ"   "$WORKLOG"        "# ログ" > "$IN/rr-lognew.json"
edit_input  "$TR/rr-noread.jsonl"  "$PROJ"   "$WORKLOG"        "b"      > "$IN/rr-logedit.json"
edit_input  "$TR/rr-logread.jsonl" "$PROJ"   "$WORKLOG"        "b"      > "$IN/rr-logedit2.json"
edit_input  "$TR/rr-logalt.jsonl"  "$PROJ"   "$WORKLOG"        "b"      > "$IN/rr-logalt.json"

# no-inline-powershell
stop_input "$TR/ps-block.jsonl"  "$PROJ"   false > "$IN/ps-block.json"
stop_input "$TR/ps-block.jsonl"  "$PROJ/kdkkb/docs" false > "$IN/ps-cwd-hit.json"
stop_input "$TR/ps-block.jsonl"  "$PROJ/other"      false > "$IN/ps-cwd-miss.json"
stop_input "$TR/ps-spaced.jsonl" "$PROJ"   false > "$IN/ps-spaced.json"
stop_input "$TR/rq-p8ok.jsonl"   "$PROJ"   false > "$IN/ps-none.json"
stop_input "$TR/ps-block.jsonl"  "$NOCONF" false > "$IN/ps-noconf.json"

# ---------------------------------------------------------------------------
# 判定
# ---------------------------------------------------------------------------
pass=0
fail=0

verdict() { # verdict <名前> <期待> <実際> <PASS|FAIL>
  if [[ "$4" == PASS ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  printf '%-56s 期待=%s 実際=%s %s\n' "$1" "$2" "$3" "$4"
}

run() { # run <名前> <期待 exit> <hook> <config> <input> [期待メッセージ断片]
  local name="$1" exp="$2" hook="$3" cfg="$4" inp="$5" want="${6:-}" err rc=0 v
  err=$(env -u CLAUDE_PROJECT_DIR HARNESS_CONFIG="$cfg" bash "$H/$hook" < "$inp" 2>&1 >/dev/null) || rc=$?
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
lines() { grep -c . "$1" 2>/dev/null || echo 0; }

echo "== response-quality (既定で有効な 4 パターン) =="
rm -f "$LOG"
run "RQ-1 パターン3 ひな形の完了扱い -> block" 2 response-quality.sh "$CFG" "$IN/rq-p3.json" "ひな形・叩きを完了扱い"
run "RQ-2 パターン3 報告書は完了扱いでない -> pass" 0 response-quality.sh "$CFG" "$IN/rq-p3ok.json"
run "RQ-3 パターン4 組版記号 -> block" 2 response-quality.sh "$CFG" "$IN/rq-p4.json" "組版記号濫用"
run "RQ-4 パターン4 記号なし -> pass" 0 response-quality.sh "$CFG" "$IN/rq-p4ok.json"
run "RQ-5 パターン8 空約束 -> block" 2 response-quality.sh "$CFG" "$IN/rq-p8.json" "以後注意します"
run "RQ-6 パターン8 実行結果の報告 -> pass" 0 response-quality.sh "$CFG" "$IN/rq-p8ok.json"
run "RQ-7 パターン19 資料本文を引かずに不在を断定 -> block" 2 response-quality.sh "$CFG" "$IN/rq-p19-doc.json" "資料の不在を断定"
run "RQ-8 パターン19 資料の見出し・目次を引いた -> pass" 0 response-quality.sh "$CFG" "$IN/rq-p19-docok.json"
run "RQ-9 パターン19 出典を引かずに認識を否定 -> block" 2 response-quality.sh "$CFG" "$IN/rq-p19-dis.json" "認識を否定"
run "RQ-10 パターン19 出典を引いた -> pass" 0 response-quality.sh "$CFG" "$IN/rq-p19-disok.json"

echo
echo "== response-quality (パターンの選択と境界) =="
run "RQ-11 既定では パターン5 を実行しない -> pass" 0 response-quality.sh "$CFG" "$IN/rq-p5.json"
run "RQ-12 patterns=[5,18] で文末の装飾語 -> block" 2 response-quality.sh "$P518" "$IN/rq-p5.json" "装飾語"
run "RQ-13 文中の「落ちる」は文末でない -> pass" 0 response-quality.sh "$P518" "$IN/rq-p5ok.json"
run "RQ-14 行頭の定型句 -> block" 2 response-quality.sh "$P518" "$IN/rq-p18.json" "前置き・自己評価"
run "RQ-15 文中の定型句は対象外 -> pass" 0 response-quality.sh "$P518" "$IN/rq-p18ok.json"

echo
echo "== response-quality (記録・バイパス・上限) =="
rm -f "$LOG"
run "RQ-16 検知ログを残す -> block" 2 response-quality.sh "$CFG" "$IN/rq-p8.json" "以後注意します"
check "RQ-16a 検知ログの非空行数" 1 "$(lines "$LOG")"
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
  check "RQ-16b 検知ログが UTF-8 として decode 可能" OK "$utf8"
else
  printf '%-56s %s\n' "RQ-16b 検知ログが UTF-8 として decode 可能" "SKIP (python3 なし)"
fi
check "RQ-16c 検知ログに session / input のタグ" 1 "$(grep -c '\[session:.*\] \[input:.*\]' "$LOG" 2>/dev/null || echo 0)"

run "RQ-17 バイパスの文字列だけの行 -> pass" 0 response-quality.sh "$CFG" "$IN/rq-bypass.json"
check "RQ-17a 検知ログは pass で増えない" 1 "$(lines "$LOG")"
run "RQ-18 再生成で uuid が取れない -> pass" 0 response-quality.sh "$CFG" "$IN/rq-active.json"
run "RQ-19 空白入り JSON の user 行を区切りに使う -> pass" 0 response-quality.sh "$CFG" "$IN/rq-spaced.json"
run "RQ-20 enabled:false -> pass" 0 response-quality.sh "$PROJ/.claude/harness-off.json" "$IN/rq-p8.json"

# CLAUDE_PROJECT_DIR 優先の確認
rm -f "$CPD_LOG"
CLAUDE_PROJECT_DIR="$CPD" HARNESS_CONFIG="$CFG" bash "$H/response-quality.sh" < "$IN/rq-p8.json" >/dev/null 2>&1 || true
check "RQ-21 CLAUDE_PROJECT_DIR が logPath の基点" yes "$(exists "$CPD_LOG")"

# 同じ入力への差し戻しの上限 (regenLimitPerInput=3)
rm -f "$REGEN_LOG"
rq_run() { # rq_run <設定> <入力> -> 終了コードを出す
  local rc=0
  env -u CLAUDE_PROJECT_DIR HARNESS_CONFIG="$1" bash "$H/response-quality.sh" < "$2" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
REGEN_CFG="$REGEN/.claude/harness.json"
check "RQ-22 初回 -> block"                     2 "$(rq_run "$REGEN_CFG" "$IN/rq-regen1.json")"
check "RQ-23 再生成 1 回目 -> block"            2 "$(rq_run "$REGEN_CFG" "$IN/rq-regen2.json")"
check "RQ-24 再生成 2 回目 -> block"            2 "$(rq_run "$REGEN_CFG" "$IN/rq-regen2.json")"
check "RQ-25 再生成 3 回目 (上限到達) -> pass"  0 "$(rq_run "$REGEN_CFG" "$IN/rq-regen2.json")"
check "RQ-26 [regen-limit] の行数"              1 "$(grep -c 'regen-limit' "$REGEN_LOG" 2>/dev/null || echo 0)"

echo
echo "== cloud-change-check =="
run "CG-1 変更系 (承認・手順書なし) -> block" 2 cloud-change-check.sh "$CFG" "$IN/cg-create.json" "[change-go: project-a]"
run "CG-2 read-only なコマンド -> pass" 0 cloud-change-check.sh "$CFG" "$IN/cg-list.json"
run "CG-3 承認の文字列だけの行 + 手順書 Read -> pass" 0 cloud-change-check.sh "$CFG" "$IN/cg-go.json"
run "CG-4 手順書は Write しただけ -> block" 2 cloud-change-check.sh "$CFG" "$IN/cg-writeonly.json" "直近で手順書"
run "CG-5 承認の文字列が質問文の中 -> block" 2 cloud-change-check.sh "$CFG" "$IN/cg-inline.json" "[change-go: project-a]"
run "CG-6 設定ファイルなし -> pass" 0 cloud-change-check.sh "$NOCFG" "$IN/cg-noconf.json"
run "CG-7 examples 設定 + cwd project-a -> block" 2 cloud-change-check.sh "$EX" "$IN/cg-example.json" "[change-go: project-a]"
run "CG-8 examples 設定 + npx cdk deploy -> block" 2 cloud-change-check.sh "$EX" "$IN/cg-cdk.json" "[change-go: project-b]"
run "CG-9 cdk watch -> block" 2 cloud-change-check.sh "$EX" "$IN/cg-cdkwatch.json" "[change-go: project-b]"
run "CG-10 aws s3 sync --delete -> block" 2 cloud-change-check.sh "$EX" "$IN/cg-s3sync.json" "[change-go: project-b]"
run "CG-11 aws cloudformation deploy -> block" 2 cloud-change-check.sh "$EX" "$IN/cg-cfndeploy.json" "[change-go: project-b]"
run "CG-12 aws lambda invoke -> pass" 0 cloud-change-check.sh "$EX" "$IN/cg-invoke.json"
run "CG-13 どの案件にも一致しない変更系 -> block (設定不足)" 2 cloud-change-check.sh "$EX" "$IN/cg-nomatch.json" "設定不足"
run "CG-14 cwd が project-a-old は一致しない -> block (設定不足)" 2 cloud-change-check.sh "$EX" "$IN/cg-suffix.json" "設定不足"
run "CG-15 ローカル CLI 設定 -> pass (除外)" 0 cloud-change-check.sh "$CFG" "$IN/cg-acct.json"
run "CG-16 az group show --query set -> pass" 0 cloud-change-check.sh "$CFG" "$IN/cg-query.json"
run "CG-17 echo az group create -> pass" 0 cloud-change-check.sh "$CFG" "$IN/cg-echo.json"

echo
echo "== harness-change-check =="
run "HG-1 .claude/rules/ を Write (承認なし) -> block" 2 harness-change-check.sh "$CFG" "$IN/hg-write.json" "[harness-go]"
run "HG-2 Bash のリダイレクト先が .claude/ -> block" 2 harness-change-check.sh "$CFG" "$IN/hg-bash.json" "[harness-go]"
run "HG-3 .claude/ からのコピー (読み取り) -> pass" 0 harness-change-check.sh "$CFG" "$IN/hg-read.json"
run "HG-4 承認の文字列だけの行 -> pass" 0 harness-change-check.sh "$CFG" "$IN/hg-go.json"
run "HG-5 承認の文字列が質問文の中 -> block" 2 harness-change-check.sh "$CFG" "$IN/hg-inline.json" "[harness-go]"
run "HG-6 除外パス (.claude/projects/) -> pass" 0 harness-change-check.sh "$CFG" "$IN/hg-proj.json"
run "HG-7 初期化の cp (プラグイン配下から) -> pass" 0 harness-change-check.sh "$CFG" "$IN/hg-initcp.json"
run "HG-8 mkdir は書き換えに数えない -> pass" 0 harness-change-check.sh "$CFG" "$IN/hg-mkdir.json"
run "HG-9 harness.json の新規作成 -> pass" 0 harness-change-check.sh "$CFG" "$IN/hg-initcfg.json"
run "HG-10 既存の harness.json の書き換え -> block" 2 harness-change-check.sh "$CFG" "$IN/hg-existcfg.json" "[harness-go]"
run "HG-11 enabled:false -> pass" 0 harness-change-check.sh "$PROJ/.claude/harness-hgoff.json" "$IN/hg-write.json"

echo
echo "== draft-precheck =="
run "DP-1 対象パス + 絶対パス -> block" 2 draft-precheck.sh "$CFG" "$IN/dp-abs.json" "絶対パス検出"
run "DP-2 除外パターン (-internal-) -> pass" 0 draft-precheck.sh "$CFG" "$IN/dp-excl.json"
run "DP-3 対象パス + 問題なし -> pass" 0 draft-precheck.sh "$CFG" "$IN/dp-clean.json"
run "DP-4 URL 中の docs/ は内部パスでない -> pass" 0 draft-precheck.sh "$CFG" "$IN/dp-url.json"
run "DP-5 禁止語 + 見出し敬称抜け -> block" 2 draft-precheck.sh "$CFG" "$IN/dp-hon.json" "禁止語"
run "DP-6 checks.internalPaths=false -> pass" 0 draft-precheck.sh "$DPOFF" "$IN/dp-abs.json"
run "DP-7 対象外パス -> pass" 0 draft-precheck.sh "$CFG" "$IN/dp-nontarget.json"
run "DP-8 設定ファイルなし -> pass" 0 draft-precheck.sh "$NOCFG" "$IN/dp-noconf.json"
run "DP-9 examples 設定 (honorific 空) -> pass" 0 draft-precheck.sh "$EX" "$IN/dp-hon.json"

echo
echo "== require-reading =="
run "RR-1 TODO.md を Read なしで Edit -> block" 2 require-reading.sh "$CFG" "$IN/rr-noread.json" "必読資料の先読みの原則"
run "RR-2 直近に TODO.md の Read あり -> pass" 0 require-reading.sh "$CFG" "$IN/rr-read.json"
rm -f "$WORKLOG"
run "RR-3 logs 新規 + Read なし -> block" 2 require-reading.sh "$CFG" "$IN/rr-lognew.json" "新規ログファイル"
run "RR-4 対象外パス -> pass" 0 require-reading.sh "$CFG" "$IN/rr-nontarget.json"
run "RR-5 設定ファイルなし -> pass" 0 require-reading.sh "$NOCFG" "$IN/rr-noconf.json"
touch "$WORKLOG" "$ALT_WORKLOG"
run "RR-6 logs 既存編集 + 自ファイル Read なし -> block" 2 require-reading.sh "$CFG" "$IN/rr-logedit.json" "既存ログファイル"
run "RR-7 logs 既存編集 + 自ファイル Read あり -> pass" 0 require-reading.sh "$CFG" "$IN/rr-logedit2.json"
run "RR-8 同名ログの別パスを Read しただけ -> block" 2 require-reading.sh "$CFG" "$IN/rr-logalt.json" "既存ログファイル"

echo
echo "== no-inline-powershell =="
run "PS-1 6 行の powershell ブロック -> block" 2 no-inline-powershell.sh "$CFG" "$IN/ps-block.json" "scripts/{category}/*.ps1"
run "PS-2 空白入り JSON でも検知 -> block" 2 no-inline-powershell.sh "$CFG" "$IN/ps-spaced.json" "scripts/{category}/*.ps1"
run "PS-3 ブロックなし -> pass" 0 no-inline-powershell.sh "$CFG" "$IN/ps-none.json"
run "PS-4 enabled:false -> pass" 0 no-inline-powershell.sh "$PROJ/.claude/harness-psoff.json" "$IN/ps-block.json"
run "PS-5 cwdMatch 一致 -> block" 2 no-inline-powershell.sh "$PROJ/.claude/harness-pscwd.json" "$IN/ps-cwd-hit.json"
run "PS-6 cwdMatch 不一致 -> pass" 0 no-inline-powershell.sh "$PROJ/.claude/harness-pscwd.json" "$IN/ps-cwd-miss.json"

echo
echo "== 設定ファイルなし (全 hook が何もしない) =="
run "NC-1 response-quality -> pass" 0 response-quality.sh "$NOCFG" "$IN/rq-noconf.json"
run "NC-2 no-inline-powershell -> pass" 0 no-inline-powershell.sh "$NOCFG" "$IN/ps-noconf.json"
run "NC-3 cloud-change-check -> pass" 0 cloud-change-check.sh "$NOCFG" "$IN/cg-noconf.json"
run "NC-4 harness-change-check -> pass" 0 harness-change-check.sh "$NOCFG" "$IN/hg-noconf.json"
run "NC-5 draft-precheck -> pass" 0 draft-precheck.sh "$NOCFG" "$IN/dp-noconf.json"
run "NC-6 require-reading -> pass" 0 require-reading.sh "$NOCFG" "$IN/rr-noconf.json"

echo
echo "== 設定ファイルが JSON として読めない =="
run "BC-1 PreToolUse (cloud-change) -> block" 2 cloud-change-check.sh "$BROKEN" "$IN/cg-create.json" "設定ファイルが読めません"
run "BC-2 PreToolUse (harness-change) -> block" 2 harness-change-check.sh "$BROKEN" "$IN/hg-write.json" "設定ファイルが読めません"
run "BC-3 PreToolUse (draft-precheck) -> block" 2 draft-precheck.sh "$BROKEN" "$IN/dp-abs.json" "設定ファイルが読めません"
run "BC-4 PreToolUse (require-reading) -> block" 2 require-reading.sh "$BROKEN" "$IN/rr-noread.json" "設定ファイルが読めません"
run "BC-5 Stop (response-quality) -> pass + 通知" 0 response-quality.sh "$BROKEN" "$IN/rq-p8.json" "設定ファイルが読めません"
run "BC-6 Stop (no-inline-powershell) -> pass + 通知" 0 no-inline-powershell.sh "$BROKEN" "$IN/ps-block.json" "設定ファイルが読めません"

echo
echo "PASS ${pass} / FAIL ${fail}"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0
