#!/bin/bash
# 応答の文体検査 (Stop hook)
# 直近のユーザー入力より後ろにある assistant text を連結し、有効なパターンを検知したら
# exit 2 で応答を作り直させる。
#
# 実行するパターンは responseQuality.patterns で選ぶ (既定 [3, 4, 8, 19])。
# 配列に無い番号のパターンは実行しない。番号とコードは 19 種を残してある。
#
# 検知パターン (番号 / 検知ルール / 根拠となる文体規則)
#   1  選択肢羅列 + 末尾確認質問
#      「解釈 A:」「**A.**」「- A.」形式のラベルが 2 つ以上 + 末尾 5 行に確認質問
#      根拠: 相手に解釈作業を委ねない。推奨を 1 つに絞る
#   2  英語 UI 名・専門用語の濫用
#      辞書語 (Overview / Tables / Diagnostic Settings 等) が和訳括弧なしの行に出る
#      根拠: 意味の曖昧な英単語の濫用禁止
#   3  ひな形・叩きの完了扱い  (既定で有効)
#      「叩き v1」「ひな形」「△ 」「要確認」と「完了 / 起票済 / 終わり / 報告」の共起。
#      「報告」は二段判定で、「報告」を含み「報告書」を含まないときだけ数える
#      根拠: 成果物の前提を先に固定する (rules「start-approval」)
#   4  組版記号の使用  (既定で有効)
#      § ¶ ‡ † を検出
#      根拠: 組版記号の禁止
#   5  装飾語・抽象語で文を締める / 矮小化表現
#      辞書語が文末 (「。」の直前、または行末) にある
#      根拠: 抽象語で止めない。装飾語で文を締めない。矮小化表現を使わない
#   6  言い換え対象語
#      「粒度」「観点」「整合性」等の辞書語を 2 語以上検出
#      根拠: 避ける言葉と言い換えの表
#   7  指示語の多用
#      これ / それ / この / その 等 (慣用語を除く) が 3 回以上
#      根拠: 指示語の置換確認 (目安 2 回以下)
#   8  空約束・態度の宣言  (既定で有効)
#      「気をつけます」「徹底します」「静かに待ちます」等を 1 語でも検出
#      根拠: 宣言ではなく仕組みと実行結果を書く
#   9  質問への応答での無指示作業の宣言
#      直前のユーザー入力が疑問形で命令形を含まないのに「作成します」等の作業宣言がある
#      根拠: 疑問形は修正指示ではない (rules「start-approval」まず分類する)
#  10  長い識別子のフル表記の繰り返し
#      バッククォート外で 20 文字以上の英字識別子が同一表記 3 回以上
#      根拠: 長い英字識別子は初出のみフル表記し、以後は短い呼び名で書く
#  11  整理用ラベルでの報告
#      応答内で作った整理用の呼び名 (「通1」「2通目」等) で成果物を指す
#      根拠: 読み手の画面にある実名で書く (成果物報告の型)
#  12  結論をぼかす締め
#      「指示をください」「指示を待ちます」「これ以上〜しません」等を 1 語でも検出
#      根拠: 実行可能な作業をユーザーへ丸投げしない (rules「start-approval」作業の継続)
#  13  送付文面の 1 文が 60 字超
#      ユーザー入力が文面の依頼のとき、文面行 (> ※ ■ ・ 始まり) に 61 字以上の文がある
#      根拠: 一文は 60 字前後まで
#  14  指摘への理由なしの撤回・同意
#      ユーザー入力に否定・矛盾の指摘があり、応答が 200 字未満で撤回・同意語を含み、
#      理由・根拠・変わった事実のいずれも書いていない
#      根拠: 根拠は外部動作に置く。指摘には確認済みの事実を再掲する
#  15  見出し・表のセルが文で終わる
#      見出し行 (#) と表のセル (|) の末尾が「です」「ます」「する」「ない」等の述語
#      根拠: 表のセル・見出しは体言止めか名詞句で書く
#  16  表のセルと本文の重複
#      8 字以上の表のセルと同じ文字列が、表の外の本文にも出ている
#      根拠: 表と本文で同じ内容を繰り返さない
#  17  括弧の中に述語がある
#      () （） の中身が述語で終わっている
#      根拠: 括弧の中身に述語があれば括弧を使わない
#  18  前置き・自己評価の定型句
#      辞書語が文頭 (「。」の直後) または行頭にある
#      根拠: 前置きで始めない。充足を自己判定しない。自分の文案を自分で評価しない
#  19  確認質問への根拠なしの否定断定  (既定で有効)
#      依頼者の入力が確認形 (あってる / よね / ですか / 〜とは 等) で、応答に
#      (a) 資料の不在の断定 (「という資料はありません」等) があるのに資料本文の引用
#          (N章 / 見出し / 目次 / 冒頭) がない、または
#      (b) 依頼者の認識を否定する語 (ズレ / 食い違い / 認識が違う 等) があるのに
#          出典の引用 (出典 / N行 / N章 / 見出し) がない
#      根拠: 正本の食い違いは片方に倒さない。両方の出典を引用して未決として示す
#            (rules「start-approval」着手前)
#
# 設定 (.claude/harness.json):
#   responseQuality.enabled             false で無効化
#   responseQuality.patterns            実行するパターン番号の配列 (既定 [3, 4, 8, 19])
#   responseQuality.logPath             検知ログの置き場 (既定 .claude/harness-detections.log)
#   responseQuality.uiTerms[]           パターン 2 の辞書へ追加
#   responseQuality.fluffTerms[]        パターン 5 の辞書へ追加
#   responseQuality.bannedLeads[]       パターン 18 の辞書へ追加
#   responseQuality.regenLimitPerInput  同じ入力への差し戻しの上限回数 (既定 3)
#
# バイパス:
#   - 依頼者の最後のテキスト入力に [hook-bypass: response-quality] がそれだけの行として
#     あれば exit 0
#
# 再生成の扱い:
#   - 差し戻し後の再生成 (stop_hook_active=true) も検査する。無条件に通すと、差し戻し
#     直後に体裁だけ直した再送が検査されない
#   - 同じ依頼者入力への差し戻しは regenLimitPerInput 回まで。上限に達した生成は
#     [regen-limit] 付きで記録して通す (無限ループ防止を兼ねる)
#   - 検知ログの集計はセッション単位。行に [session:<id>] [input:<uuid>] のタグを付ける

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

input=$(cat)
harness_load_config "$input"
harness_config_guard stop

if ! cfg_enabled '.responseQuality'; then
  exit 0
fi

principal=$(harness_principal)

# 0) 実行するパターンの選択 (既定 3 / 4 / 8 / 19)
active_patterns=$(cfg_list '.responseQuality.patterns[]?' | tr '\n' ' ')
if [[ -z "${active_patterns// /}" ]]; then
  active_patterns="3 4 8 19"
fi
pat_on() { # pat_on <番号>
  case " ${active_patterns} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# 1) 再生成フラグとセッション ID
#    stop_hook_active=true は差し戻し後の再生成。検査は行い、差し戻し回数の上限は 14) で見る。
#    session_id は検知ログの集計単位 (取れなければ transcript のファイル名で代用)。
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')

# 2) transcript 取得
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
if [[ -z "$transcript" || ! -f "$transcript" ]]; then
  exit 0
fi
if [[ -z "$session_id" ]]; then
  session_id=$(basename "$transcript" .jsonl)
fi

# 3) 直近のユーザー入力より後ろにある assistant text を全部連結して取得
#    transcript では thinking / tool_use / text がそれぞれ別行に記録されるため、最後の
#    assistant 行だけを見ると、途中でツールを使う応答は本文の大部分が検査されずに通る。
#    ツール結果も type=="user" で記録されるので、区切りには tool_result を含まない
#    user 行を使う。
#    Stop 発火時に最終 assistant text 行が transcript へまだ書き込まれておらず、text が
#    空のまま素通りする競合があるため、空の間は 0.2 秒待って再読込する (最大 10 回 = 2 秒)。
#    行の判定は jq で行う。grep の文字列一致 ('"type":"user"') では、空白入りの JSON
#    ('"type": "user"') を user 行と認識できず検査が空振りする。
#    差し戻し後の再生成では hook のフィードバック行 (isMeta) が区切りになり、再生成した
#    本文だけが検査対象になる。対象は末尾 scan_tail 行。JSON として読めない行は読み飛ばす。
scan_tail=5000
get_scan_text() {
  tail -n "$scan_tail" "$transcript" | jq -rR -n '
    [inputs | fromjson? // empty] as $all
    | ($all | map(.type=="user"
        and ((.message.content|type)=="string"
             or ((.message.content|type)=="array"
                 and ([.message.content[]? | select(.type=="tool_result")] | length)==0)))
       | rindex(true)) as $i
    | $all[(($i // -1)+1):][]
    | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null || true
}

text=$(get_scan_text)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -n "$text" ]] && break
  sleep 0.2
  text=$(get_scan_text)
done
if [[ -z "$text" ]]; then
  exit 0
fi

# 4) 最後の依頼者のテキスト入力 (バイパスの文字列とパターン 9 / 13 / 14 / 19 の判定に使う)
#    ツール結果行・isMeta 行 (hook のフィードバック等)・ローカルコマンドの記録は除外する。
#    除外しないと、差し戻し後は hook のフィードバック文が依頼者の入力として扱われる。
#    uuid は「同じ入力への差し戻し回数」の集計キー (14 を参照)。
last_user_json=$(harness_last_user_entry "$transcript" "$scan_tail")
user_uuid=$(printf '%s' "$last_user_json" | jq -r '.uuid // empty' 2>/dev/null || true)
user_text=$(printf '%s' "$last_user_json" | jq -r '.text // empty' 2>/dev/null || true)
if harness_has_token "${user_text:-}" '[hook-bypass: response-quality]'; then
  exit 0
fi
# 再生成なのに集計キーが取れない場合は、無限ループ防止を優先して通す
if [[ "$stop_hook_active" == "true" && -z "$user_uuid" ]]; then
  exit 0
fi

violations=()

# コードブロックを除いた本文 (パターン 2 / 10 / 15 / 16 / 17 が使う)
prose_text=$(printf '%s\n' "$text" | awk '/^```/ {in_code = !in_code; next} !in_code {print}')

# コードブロック / バッククォート / 引用括弧内を除いた本文 (語の辞書検査が使う)
# 説明文中で検知語を引用した場合の誤検知を防ぐ
filtered_text=$(printf '%s\n' "$text" \
  | awk '/^```/ {in_code = !in_code; next} !in_code {print}' \
  | sed 's/`[^`]*`//g' \
  | sed 's/「[^」]*」//g' \
  | sed 's/『[^』]*』//g' \
  | sed 's/([^)]*)//g' \
  | sed 's/([^)]*)//g')

# 「。」で文に割った本文 (文末・文頭の判定に使う)
sentence_text=$(printf '%s\n' "$filtered_text" | sed 's/。/。\n/g')

# 文末に語があるか (「。」の直前、または行末)
sentence_tail_hit() { # sentence_tail_hit <文に割った本文> <語>
  local w="$2" line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line%。}"
    while [[ -n "$line" && "$line" == *[[:space:]] ]]; do line="${line%?}"; done
    [[ -n "$line" && "$line" == *"$w" ]] && return 0
  done <<< "$1"
  return 1
}

# 文頭または行頭に語があるか (箇条書き・引用・見出しの記号は先頭から落とす)
sentence_lead_hit() { # sentence_lead_hit <文に割った本文> <語>
  local w="$2" line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    while [[ "$line" == [-*\>#]* ]]; do
      line="${line#?}"
      line="${line#"${line%%[![:space:]]*}"}"
    done
    [[ -n "$line" && "$line" == "$w"* ]] && return 0
  done <<< "$1"
  return 1
}

# 5) パターン 1: 選択肢羅列 + 推奨欠落 / 確認質問終わり
# ラベル形式:
#   - 「解釈 A:」「解釈 B:」「解釈 A.」
#   - 「**A.**」「**A:**」「**解釈 A:**」(markdown 太字)
#   - 「- A.」「* A.」(リスト先頭)
if pat_on 1; then
  option_count=$(printf '%s\n' "$text" | grep -cE '(解釈[[:space:]]*[A-D][:.：]|\*\*(解釈[[:space:]]*)?[A-D][.:：]|^[[:space:]]*[-*][[:space:]]+[A-D][.:：][[:space:]])' || true)
  if [[ ${option_count:-0} -ge 2 ]]; then
    last_lines=$(printf '%s\n' "$text" | tail -5)
    if printf '%s\n' "$last_lines" | grep -qE '[??]|どっち|どれですか|どちら|進めて良い|お願いします|OK[[:space:]]?ですか|よろしい|いずれ|どうですか|何を選びますか'; then
      violations+=("選択肢羅列 + 末尾確認質問 (Output Style「Concise JA」「相手に解釈作業を委ねる」違反)")
    fi
  fi
fi

# 6) パターン 2: 英語 UI 名・専門用語の濫用
# 辞書: 管理画面のブレード名など、和訳を併記すべき語
# "Logs" は除外。正式サービス名 (CloudWatch Logs 等) に反応する誤検知が出るため。
if pat_on 2; then
  declare -a ng_words=("Overview" "Tables" "Diagnostic Settings" "Containers" "Storage browser" "Activity log" "Adjustable" "TPS" "RPS" "Pipeline")
  while IFS= read -r w; do
    [[ -n "$w" ]] && ng_words+=("$w")
  done < <(cfg_list '.responseQuality.uiTerms[]?')
  ng_hits=()
  for word in "${ng_words[@]}"; do
    # 出現行のうち、和訳併記 ( ( ) または （ ） ) を含まない行
    # 例外: コードブロック内 / バッククォート内は除外
    bad_lines=$(printf '%s\n' "$prose_text" \
      | grep -nF -- "$word" \
      | grep -vE '`[^`]*'"$word"'[^`]*`' \
      | grep -vE '[((].*[))]' || true)
    if [[ -n "$bad_lines" ]]; then
      ng_hits+=("$word")
    fi
  done
  if [[ ${#ng_hits[@]} -gt 0 ]]; then
    joined=$(IFS=,; echo "${ng_hits[*]}")
    violations+=("英語 UI 名濫用: [$joined] が和訳括弧なしで使われた (Output Style「Concise JA」「意味の曖昧な英単語の濫用禁止」違反)")
  fi
fi

# 8) パターン 3: 「叩き v1」「ひな形」「△ 」「要確認」+ 完了系
# 「報告」は二段判定にする。「報告」を含み「報告書」を含まない場合だけ完了系とみなす
# (grep -E は否定先読み (?!) を解釈しないため、1 つの正規表現では書けない)。
if pat_on 3; then
  if printf '%s' "$filtered_text" | grep -qE '叩き[[:space:]]*v[0-9]+|ひな形|△[[:space:]]|要確認'; then
    done_word=0
    if printf '%s' "$filtered_text" | grep -qE '完了|起票済|終わり|まとめました'; then
      done_word=1
    fi
    if printf '%s' "$filtered_text" | grep -qF '報告' \
      && ! printf '%s' "$filtered_text" | grep -qF '報告書'; then
      done_word=1
    fi
    if [[ "$done_word" -eq 1 ]]; then
      violations+=("ひな形・叩きを完了扱い (rules「start-approval」「成果物の前提を先に固定する」違反)")
    fi
  fi
fi

# 9) パターン 4: 組版記号 (§ ¶ ‡ †) 使用検知
if pat_on 4; then
  typographic_marks=("§" "¶" "‡" "†")
  typo_hits=()
  for mark in "${typographic_marks[@]}"; do
    if printf '%s' "$filtered_text" | grep -qF "$mark"; then
      typo_hits+=("$mark")
    fi
  done
  if [[ ${#typo_hits[@]} -gt 0 ]]; then
    joined=$(IFS=,; echo "${typo_hits[*]}")
    violations+=("組版記号濫用: [$joined] が使われた (Output Style「Concise JA」「組版記号の禁止」違反)")
  fi
fi

# 10) パターン 5: 装飾語・抽象語で文を締める / 矮小化表現
# 文末 (「。」の直前、または行末) にある語だけを数える。文の途中の「落ちる条件」等は
# 正当な用法のため対象外。
if pat_on 5; then
  declare -a fluff=(
    "効きます" "効きました" "効く" "効いて" "効いた"
    "落ちます" "落ちました" "落ちる" "落ちて" "落ちた"
    "重いです" "先です"
    "ここが分かれ目" "分かれ目です" "素直です" "直結します" "本質は" "肝心" "に乗ります"
    "だけです" "これだけです" "のみです" "だけになります"
  )
  while IFS= read -r w; do
    [[ -n "$w" ]] && fluff+=("$w")
  done < <(cfg_list '.responseQuality.fluffTerms[]?')
  fluff_hits=()
  for w in "${fluff[@]}"; do
    if sentence_tail_hit "$sentence_text" "$w"; then
      fluff_hits+=("$w")
    fi
  done
  if [[ ${#fluff_hits[@]} -ge 1 ]]; then
    joined=$(IFS=,; echo "${fluff_hits[*]}")
    violations+=("装飾語・抽象語で文を締めた: [$joined] (Output Style「Concise JA」「抽象語で止めない・矮小化表現を使わない」違反)")
  fi
fi

# 10-B) パターン 6: 「避ける言葉と言い換え」の表に載る語
# 技術用語として正当な用法と衝突しにくい語だけを対象にする。
if pat_on 6; then
  declare -a paraphrase=(
    "ジャーゴン" "整合性" "落とし込み" "棚卸し" "プレーン" "読み替え" "再構成"
    "粒度" "観点" "切り分け" "メタ情報" "スコープ" "母数"
  )
  paraphrase_hits=()
  for w in "${paraphrase[@]}"; do
    if printf '%s' "$filtered_text" | grep -qF "$w"; then
      paraphrase_hits+=("$w")
    fi
  done
  if [[ ${#paraphrase_hits[@]} -ge 2 ]]; then
    joined=$(IFS=,; echo "${paraphrase_hits[*]}")
    violations+=("言い換え対象語の使用: [$joined] (Output Style「Concise JA」「避ける言葉と言い換え」の表を参照)")
  fi
fi

# 10-C) パターン 7: 指示語の多用 (3 回以上で発火)
# 慣用語 (それぞれ / そのまま / そのもの / それ自体 / これから / それでも / それでは / それとも)
# は指示対象を持たないため数えない。引用「」・コードブロックは filtered_text で除外済み。
if pat_on 7; then
  demonstrative_count=$(printf '%s' "$filtered_text" \
    | sed -E 's/それぞれ|そのまま|そのもの|それ自体|これから|それでも|それでは|それとも//g' \
    | grep -oE 'これにより|こうした|こういった|これら|それら|この|これ|それ|その' \
    | wc -l || true)
  if [[ ${demonstrative_count:-0} -ge 3 ]]; then
    violations+=("指示語の多用: これ/それ/この/その等が ${demonstrative_count} 回。対象の名詞へ置き換える (Output Style「Concise JA」「指示語の置換確認」目安 2 回以下)")
  fi
fi

# 10-D) パターン 8: 空約束・態度の宣言
# 宣言だけの再発防止と、自分の状態の演出 (「静かに待ちます」等) を応答から締め出す。
# 仕組み・実行結果は禁止語なしで書ける (例: 「hook に検知を追加し、テストした」)。
if pat_on 8; then
  declare -a empty_promises=(
    "気をつけます" "心がけます" "徹底します" "意識します"
    "二度としません" "以後注意します" "肝に銘じ" "静かに待ちます"
  )
  promise_hits=()
  for w in "${empty_promises[@]}"; do
    if printf '%s' "$filtered_text" | grep -qF "$w"; then
      promise_hits+=("$w")
    fi
  done
  if [[ ${#promise_hits[@]} -gt 0 ]]; then
    joined=$(IFS=,; echo "${promise_hits[*]}")
    violations+=("空約束・態度の宣言: [$joined] (宣言ではなく仕組み・実行結果を書く)")
  fi
fi

# 10-E) パターン 9: 質問への応答での無指示作業の宣言
# 疑問形は質問または情報提供であり、修正指示ではない。質問へは回答と評価を返し、作業は
# 指示を受けてから行う。
# 誤検知抑制: ユーザー入力に命令形・依頼形があれば対象外。宣言の検知語は未来形のみ。
if pat_on 9; then
  interrog_re='[??]|でしょうね|でしょうか|ですか|ますか|ませんか|っけ|のかな'
  imper_re='してください|して下さい|しなさい|してね|しといて|しとけ|お願いします|お願いね|頼む|やって|直して|直せ|作って|作れ|書いて|書け|追記して|反映して|進めて|講じて|消して|削除して|戻して|更新して|修正して|実行して'
  if [[ -n "${user_text:-}" ]] \
    && printf '%s' "$user_text" | grep -qE "$interrog_re" \
    && ! printf '%s' "$user_text" | grep -qE "$imper_re"; then
    declare -a work_decls=(
      "書き直します" "作り直します" "書き換えます" "作成します" "新規作成します"
      "追記します" "反映します" "編集します" "修正します" "更新します" "適用します"
    )
    decl_hits=()
    for w in "${work_decls[@]}"; do
      if printf '%s' "$filtered_text" | grep -qF -- "$w"; then
        decl_hits+=("$w")
      fi
    done
    if [[ ${#decl_hits[@]} -gt 0 ]]; then
      joined=$(IFS=,; echo "${decl_hits[*]}")
      violations+=("質問への応答で無指示の作業を宣言: [$joined] (rules「start-approval」「まず分類する」違反。疑問形は修正指示ではない。回答と評価を返し、指示を待つ)")
    fi
  fi
fi

# 10-F) パターン 10: 長い識別子のフル表記の繰り返し
# バッククォートで書いた識別子は数えない。
if pat_on 10; then
  ident_text=$(printf '%s\n' "$prose_text" | sed 's/`[^`]*`//g')
  top_ident=$(printf '%s\n' "$ident_text" \
    | grep -oE '[A-Za-z][A-Za-z0-9_./-]{19,}' \
    | sort | uniq -c | sort -rn | head -1 || true)
  top_count=$(printf '%s' "$top_ident" | awk '{print $1}')
  top_name=$(printf '%s' "$top_ident" | awk '{print $2}')
  if [[ -n "${top_count:-}" && ${top_count:-0} -ge 3 ]]; then
    violations+=("長い識別子のフル表記の繰り返し: ${top_name} が ${top_count} 回 (初出のみフル表記し、以後は短い呼び名かバッククォートで書く)")
  fi
fi

# 10-G) パターン 11: 整理用ラベルでの報告
# 応答内で作った整理用の呼び名 (通1 / 2通目 等) で成果物を指す書き方を検知する。
if pat_on 11; then
  self_label_hits=$(printf '%s' "$filtered_text" \
    | grep -oE '(^|[^交流貫開共直])通[0-9１-９]|[0-9１-９]通目' || true)
  if [[ -n "$self_label_hits" ]]; then
    joined=$(printf '%s' "$self_label_hits" | head -3 | tr '\n' ',')
    violations+=("整理用ラベルでの報告: [$joined] (Output Style「Concise JA」「成果物報告の型」。読み手の画面にある実名で書く)")
  fi
fi

# 10-H) パターン 12: 結論をぼかす締め (指示の丸投げ / 自己卑下の約束)
# 承認依頼の文言 (「可否をください」「[change-go」) は対象外。
if pat_on 12; then
  handoff_hits=$(printf '%s' "$filtered_text" \
    | grep -oE '指示をください|指示ください|指示を待ちます|指示をお願いします|指示いただければ|これ以上[^。]{0,12}しません|もう[^。]{0,8}しません|以後[^。]{0,12}しません' || true)
  if [[ -n "$handoff_hits" ]]; then
    joined=$(printf '%s\n' "$handoff_hits" | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')
    violations+=("結論をぼかす締め: [$joined] (rules「start-approval」「作業の継続」。次の一手を自分で決めて示す。約束でなく仕組みと実行結果を書く)")
  fi
fi

# 10-I) パターン 13: 送付文面の 1 文が 60 字超
# ユーザー入力が文面の依頼のときだけ動かす (資料からの引用に反応させない)。
if pat_on 13; then
  draft_req_re='文面|ドラフト|送付|送って|返信案|依頼文|※|Slack|Teams'
  if [[ -n "${user_text:-}" ]] && printf '%s' "$user_text" | grep -qE "$draft_req_re"; then
    long_sents=$(printf '%s\n' "$text" \
      | awk '/^```/ {in_code = !in_code; next} !in_code {print}' \
      | grep -E '^[[:space:]]*(>|※|■|・)' \
      | sed -E 's/^[[:space:]]*((> ?|※ ?|■ ?|・ ?)+)//' \
      | sed 's/。/。\n/g' \
      | grep -v 'http' \
      | LC_ALL=C.UTF-8 grep -E '^.{61,}' || true)
    if [[ -n "$long_sents" ]]; then
      first=$(printf '%s\n' "$long_sents" | head -1 | LC_ALL=C.UTF-8 grep -oE '^.{1,30}')
      violations+=("文面の1文が60字超: [${first}…] (Output Style「Concise JA」「一文は60字前後まで」。文を分ける)")
    fi
  fi
fi

# 10-J) パターン 14: 指摘への理由なしの撤回・同意
# ユーザー入力に否定・矛盾の指摘があり、応答が短く (200 字未満) 撤回・同意の語を含み、
# 理由・根拠・変わった事実のいずれも書いていなければ止める。
if pat_on 14; then
  critique_re='いらない|いりません|違う|違います|ゴミ|嘘|二転三転|矛盾|なめて|さぼって|保身|おかしい|間違'
  concede_re='いりません|外します|取り下げます|撤回します|訂正します|そのとおりです|おっしゃるとおり|ご指摘のとおり|不要です'
  reason_re='理由は|根拠は|変わった事実|変わっていない|事実は|実測|確認した結果|出典|事実を再掲'
  if [[ -n "${user_text:-}" ]] && printf '%s' "$user_text" | grep -qE "$critique_re"; then
    concede_hits=$(printf '%s' "$filtered_text" | grep -oE "$concede_re" || true)
    resp_len=$(printf '%s' "$filtered_text" | LC_ALL=C.UTF-8 wc -m)
    if [[ -n "$concede_hits" && ${resp_len:-0} -lt 200 ]] \
      && ! printf '%s' "$filtered_text" | grep -qE "$reason_re"; then
      joined=$(printf '%s\n' "$concede_hits" | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')
      violations+=("理由なしの撤回・同意: [$joined] (指摘には確認済みの事実を再掲し、どの根拠が変わったかを書く。変わっていなければ結論を変えない)")
    fi
  fi
fi

# 10-K) パターン 15: 見出し・表のセルが文で終わる
# 地の文と箇条書きは対象にしない。
pred_end='(です|ます|ました|でした|します|しました|される|されます|できます|できません|ません|ない|する|ある|なる)$'
if pat_on 15; then
  struct_lines=$(printf '%s\n' "$prose_text" \
    | grep -E '^[[:space:]]*(#{1,6} |\|)' || true)
  struct_bad=$(printf '%s\n' "$struct_lines" \
    | sed -E 's/^[[:space:]]*(#{1,6} )//' \
    | tr '|' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | sed -E 's/[。、]$//' \
    | grep -vE '^-*$' \
    | grep -E "$pred_end" || true)
  if [[ -n "$struct_bad" ]]; then
    joined=$(printf '%s\n' "$struct_bad" | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')
    violations+=("見出し・表のセルが文で終わる: [$joined] (Output Style「Concise JA」。体言止めか名詞句で書く)")
  fi
fi

# 10-L) パターン 16: 表のセルと本文の重複
if pat_on 16; then
  cell_text=$(printf '%s\n' "$prose_text" | grep -E '^[[:space:]]*\|' \
    | tr '|' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -vE '^-*$' | LC_ALL=C.UTF-8 grep -E '^.{8,}' || true)
  body_text=$(printf '%s\n' "$prose_text" | grep -vE '^[[:space:]]*\|' || true)
  dup_cells=""
  while IFS= read -r cell; do
    [[ -z "$cell" ]] && continue
    if printf '%s' "$body_text" | grep -qF -- "$cell"; then
      dup_cells+="$cell"$'\n'
    fi
  done <<< "$cell_text"
  if [[ -n "${dup_cells//[$'\n' ]/}" ]]; then
    joined=$(printf '%s' "$dup_cells" | sort -u | head -2 | tr '\n' ',' | sed 's/,$//')
    violations+=("表のセルと本文が重複: [$joined] (Output Style「Concise JA」。表で書いた内容を本文で言い直さない)")
  fi
fi

# 10-M) パターン 17: 括弧の中に述語がある
if pat_on 17; then
  paren_bad=$(printf '%s\n' "$prose_text" \
    | sed 's/`[^`]*`//g' \
    | grep -oE '[(（][^()（）]{4,}[)）]' \
    | sed -E 's/^[(（]//; s/[)）]$//' \
    | grep -E "$pred_end" || true)
  if [[ -n "$paren_bad" ]]; then
    joined=$(printf '%s\n' "$paren_bad" | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')
    violations+=("括弧の中に述語がある: [$joined] (Output Style「Concise JA」。括弧を外して本文へ出すか、名詞への短い限定に直す)")
  fi
fi

# 10-N) パターン 19: 確認質問への根拠なしの否定断定
# 確認質問に、資料を開かないまま「ありません」「認識がズレています」と答える型を止める。
#   (a) 資料の不在の断定は、資料本文を開いた痕跡 (N章 / 見出し / 目次 / 冒頭 / 節) を要求する。
#   (b) 依頼者の認識の否定は、出典の引用 (出典 / N行 / N章 / 見出し / パス:行) を要求する。
# 限界: 引用した出典が適切かは判定できない。意味レベルの判定は rules「start-approval」で扱う。
if pat_on 19; then
  confirm_re='あってる|あってます|合ってる|合ってます|よね|ですか|でしょうか|ますか|[??]|正しい|間違って|とは[。]?$|とは[。]?[[:space:]]'
  doc_negate_re='という(資料|ファイル|手順書|設計書|文書|ページ)は(ありません|ない|存在しません|存在しない)|(資料|ファイル|手順書|設計書|文書|ページ)は(ありません|存在しません|存在しない)|(資料|ファイル|手順書|設計書|文書|ページ)の不在'
  doc_evidence_re='[0-9０-９]+章|見出し|目次|冒頭|本文[0-9０-９]*章|本文の|節に|[0-9０-９]+\.[0-9０-９]+節?'
  disagree_re='ズレ|食い違|認識が違|認識と違|誤りです|間違いです|正しくありません|合っていません|そうではありません'
  cite_re='出典|[0-9０-９]+行|[0-9０-９]+章|見出し|\.(md|txt|json|sh):[0-9]+'
  if [[ -n "${user_text:-}" ]] && printf '%s' "$user_text" | grep -qE "$confirm_re"; then
    neg_hits=$(printf '%s' "$filtered_text" | grep -oE "$doc_negate_re" || true)
    if [[ -n "$neg_hits" ]] && ! printf '%s' "$prose_text" | grep -qE "$doc_evidence_re"; then
      joined=$(printf '%s\n' "$neg_hits" | sort -u | head -2 | tr '\n' ',' | sed 's/,$//')
      violations+=("資料本文を引かずに資料の不在を断定: [$joined] (rules「start-approval」着手前。資料の見出し・章を開いてから書く。TODO・作業ログの要約は根拠にしない)")
    fi
    dis_hits=$(printf '%s' "$filtered_text" | grep -oE "$disagree_re" || true)
    if [[ -n "$dis_hits" ]] && ! printf '%s' "$prose_text" | grep -qE "$cite_re"; then
      joined=$(printf '%s\n' "$dis_hits" | sort -u | head -2 | tr '\n' ',' | sed 's/,$//')
      violations+=("出典を引かずに${principal}の認識を否定: [$joined] (rules「start-approval」着手前。両方の出典を引用して提示する。記録と発言が食い違えば既定は記録が古い)")
    fi
  fi
fi

# 11) パターン 18: 前置き・自己評価の定型句
# 文頭 (「。」の直後) または行頭に現れた定型句だけを検知する。
if pat_on 18; then
  declare -a banned_leads=(
    "こう追記する"
    "こう入れる"
    "こうです"
    "こういうことです"
    "こういう意味です"
    "これです"
    "これにします"
    "それで進めます"
    "切り分けはこうです"
    "整理はこうです"
    "次です"
    "以下のように"
    "以下です"
    "なので整理としては"
    "つまり整理はこうです"
    "こうなります"
    "十分です"
    "自然です"
    "安全です"
    "通りやすいです"
    "だけです"
    "これだけです"
    "のみです"
    "だけになります"
    "これで足ります"
    "この一段落で足ります"
    "次の2行で十分です"
    "この粒度でよい"
    "この粒度で良い"
    "この粒度で聞くのがよい"
    "この粒度で聞くのが良い"
    "最初はこの粒度"
    "これでよい"
    "これで良い"
    "この前提でよいです"
    "この前提で良いです"
    "このくらいが近いです"
    "このくらいが良いです"
  )
  while IFS= read -r w; do
    [[ -n "$w" ]] && banned_leads+=("$w")
  done < <(cfg_list '.responseQuality.bannedLeads[]?')
  banned_hits=()
  for w in "${banned_leads[@]}"; do
    if sentence_lead_hit "$sentence_text" "$w"; then
      banned_hits+=("$w")
    fi
  done
  if [[ ${#banned_hits[@]} -gt 0 ]]; then
    joined=$(IFS=,; echo "${banned_hits[*]}")
    violations+=("前置き・自己評価の定型句: [$joined] (文体規則違反)")
  fi
fi

# 12) 違反なしなら通過
if [[ ${#violations[@]} -eq 0 ]]; then
  exit 0
fi

# 13) 検知ログの置き場を決める
#     相対パスは CLAUDE_PROJECT_DIR、設定ファイルのあるディレクトリの親 (プロジェクト
#     ルート)、hook 入力の cwd の順に解決する。
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
log_path=$(cfg '.responseQuality.logPath' '.claude/harness-detections.log')
if [[ "$log_path" = /* ]]; then
  detect_log="$log_path"
else
  log_base=""
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    log_base="$CLAUDE_PROJECT_DIR"
  elif [[ -n "$HARNESS_CONFIG_PATH" ]]; then
    log_base=$(dirname "$(dirname "$HARNESS_CONFIG_PATH")")
  elif [[ -n "$hook_cwd" ]]; then
    log_base="$hook_cwd"
  else
    log_base="$PWD"
  fi
  detect_log="${log_base%/}/${log_path}"
fi
log_dir=$(dirname "$detect_log")
[[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null || true

# 14) 同じ入力への差し戻しの上限 (検知ログを参照する)
#   記録形式: <時刻>\t[session:<id>] [input:<uuid>] <検知内容>
#             通過の記録は先頭に [regen-limit] を付け、件数に数えない。
#             記録の失敗でブロック自体を落とさないため、エラーは無視する。
#   同一セッション・同一 uuid への差し戻しが regenLimitPerInput 件に達していたら、
#   今回は [regen-limit] 付きで記録して通過する。再生成の無限ループ防止を兼ねる。
#   タグの無い旧形式の行は集計に入らない。
regen_limit=$(cfg '.responseQuality.regenLimitPerInput' '3')
tag_session="[session:${session_id}]"
tag_input="[input:${user_uuid}]"
log_detection() { # log_detection <先頭に付けるタグ (無ければ空文字)>
  {
    printf '%s\t%s%s %s ' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" "$tag_session" "$tag_input"
    printf '%s' "$(IFS='|'; echo "${violations[*]}")" | tr -d '\n' | LC_ALL=C.UTF-8 grep -oE '^.{1,300}' | tr -d '\n'
    printf '\n'
  } >> "$detect_log" 2>/dev/null || true
}
if [[ -f "$detect_log" && -n "$user_uuid" ]]; then
  # grep が 0 件のとき pipefail で代入が失敗し set -e で落ちるため、末尾に || true を置く
  same_input_blocks=$(grep -aF -- "$tag_session" "$detect_log" | grep -aF -- "$tag_input" \
    | grep -avF -- '[regen-limit]' | wc -l || true)
  if (( same_input_blocks >= regen_limit )); then
    log_detection "[regen-limit] "
    exit 0
  fi
fi

# 15) ブロック
{
  echo "[応答の文体違反]"
  echo "以下のパターンを検知しました。応答を作り直してください:"
  echo ""
  for v in "${violations[@]}"; do
    echo "  - $v"
  done
  echo ""
  echo "バイパス (緊急時のみ、${principal}の明示指示で): 次のユーザーメッセージに [hook-bypass: response-quality] だけの行を含める"
} >&2

# 16) 検知の記録
#     停止・再稼働の判断材料が「再発したか」だけになるのを避ける。
#     どのパターンが誤検知を多く出しているかを、後から件数で見られるようにする。
#     形式と置き場は 14) を参照。
log_detection ""

exit 2
