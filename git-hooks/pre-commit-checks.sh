#!/bin/bash
# コミット内容の機械検査 (prepare-commit-msg から呼ばれる)
#
# 呼び出し元を prepare-commit-msg にしている理由:
#   pre-commit は --no-verify でスキップされる。prepare-commit-msg はされない。
#   commit-plan の一致確認と同じ強制力を持たせる。
#
# 検査1 シークレットの混入 (gitleaks)
#   git 管理外の変数ファイルの実値がログや差分表示に出てローテーションが必要になる
#   事故を防ぐ。--redact を付け、検知した値そのものは出力しない。
#
# 検査2 外部送付物の内部表現 (harness-ja の draft-precheck.sh を再利用)
#   内部パス・ローカル拡張子・外部 AI 言及の混入を防ぐ。検査ロジックを二重に
#   持たないため、プラグインの hook へ stdin で渡す。対象ファイルの判定は
#   .claude/harness.json の draftPrecheck.targets に従う (hook 側で判定する)。
#
# プラグインの場所は次の順で探す:
#   1. 環境変数 HARNESS_PLUGIN_ROOT
#   2. git config harness.pluginRoot
#   3. ~/.claude/plugins/cache/*/harness-ja/*/ のうち最新
#
# gitleaks が無い場合は警告して通す。検査の仕組みが無いことで
# 全コミットを止めると運用が回らないため。

set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

fail() {
  printf '[commit-check] %s\n' "$1" >&2
  exit 1
}

# ----- 検査1: シークレットの混入 -----
gitleaks_bin=""
for candidate in \
  "$(command -v gitleaks 2>/dev/null || true)" \
  "$(go env GOPATH 2>/dev/null || true)/bin/gitleaks" \
  "$HOME/go/bin/gitleaks"
do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    gitleaks_bin="$candidate"
    break
  fi
done

if [[ -z "$gitleaks_bin" ]]; then
  printf '[commit-check] gitleaks が見つかりません。シークレット検査を飛ばします。\n' >&2
  printf '[commit-check] 導入: go install github.com/zricethezav/gitleaks/v8@latest\n' >&2
else
  scan_out=$("$gitleaks_bin" git --staged --no-banner --redact "$root" 2>&1) || {
    fail "ステージ内容にシークレットの可能性がある文字列を検出しました。
${scan_out}
値そのものは伏せています。該当箇所を確認し、実値を含めない形へ直してください。
既に外部へ出た値はローテーションが必要です。
誤検知の場合は .gitleaks.toml の allowlist へ追加してください。"
  }
fi

# ----- 検査2: 外部送付物の内部表現 -----
precheck=""
if [[ -n "${HARNESS_PLUGIN_ROOT:-}" ]]; then
  precheck="$HARNESS_PLUGIN_ROOT/hooks/draft-precheck.sh"
fi
if [[ ! -f "$precheck" ]]; then
  cfg_root=$(git config --get harness.pluginRoot 2>/dev/null || true)
  [[ -n "$cfg_root" ]] && precheck="$cfg_root/hooks/draft-precheck.sh"
fi
if [[ ! -f "$precheck" ]]; then
  precheck=$(ls -t "$HOME"/.claude/plugins/cache/*/harness-ja/*/hooks/draft-precheck.sh 2>/dev/null | head -1 || true)
fi

if [[ -n "$precheck" && -f "$precheck" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$root/.claude/harness.json" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    content=$(git show ":$f" 2>/dev/null) || continue
    out=$(jq -nc --arg root "$root" --arg p "$root/$f" --arg c "$content" \
      '{cwd:$root, tool_name:"Write", tool_input:{file_path:$p, content:$c}}' \
      | CLAUDE_PROJECT_DIR="$root" HARNESS_CONFIG="$root/.claude/harness.json" bash "$precheck" 2>&1) || {
      fail "外部送付物に内部表現を検出しました: ${f}
${out}"
    }
  done < <(git -c core.quotepath=false diff --cached --name-only --diff-filter=ACM)
fi

exit 0
