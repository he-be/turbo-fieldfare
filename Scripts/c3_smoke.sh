#!/usr/bin/env bash
# C3 — 実機スモーク (適合テスト計画 docs/serving/CONFORMANCE.md §1 の C3 行)。
#
# モデルを積む唯一の適合層。curl で叩き、期待値は **HTTP 番号と JSON 述語**で
# 書く (CONFORMANCE §1)。金の文言と突き合わせるのは、決定性と正しさそのものが
# 主張である DEV-13 の 1 か所だけで、そこには理由をコメントに書いてある。
# 内容を比べる検査はすべて `temperature: 0` — 再実行が再実行であるために。
#
# **このスクリプトはサーバーを起動しない・止めない・再起動しない。**
# 指定した URL で誰も聴いていなければ、その場で落ちて建て方を印字する。
#
# 使い方:
#   ./Scripts/c3_smoke.sh --base-url http://127.0.0.1:8091
#   ./Scripts/c3_smoke.sh --list
#   ./Scripts/c3_smoke.sh --only GEN-4-named,DEV-13
#
# **人が先にやること** (このスクリプトは代行しない):
#
#   # 1. AGENTS.md "Test rules" のプロセス検査。何か出たら建てない。
#   pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'
#
#   # 2. 建てる (docs/SERVER_RUNBOOK.md §1(a) の 16K 構成をそのまま)
#   swift build -c release --product TurboFieldfareServer
#   .build/release/TurboFieldfareServer \
#     --model scratch/gemma4-qat-sym.gturbo \
#     --port 8091 \
#     --ctx-size 16384 \
#     --expert-cache-slots 32 \
#     --verification trusted-install \
#     --draft-block-size 4
#
#   # 3. 200 になるまで待つ (ロードに 20〜40 秒。runbook §3)
#   curl -s http://127.0.0.1:8091/v1/models
#
# 判定は 4 つ:
#   PASS    述語が全部通った
#   FAIL    SPEC の行が破れている。行の ID がそのまま出る ("GEN-4-named FAILED")
#   PENDING 暫定の 501。CONFORMANCE §1 の「暫定期間はスキップ印を付けて赤のまま
#           数える」に従い、**赤として数える** (終了コードに効く)
#   SKIP    走らせられない (画像が無い・文脈が足りない 等)。理由を必ず印字する。
#           既定では終了コードに効かない。`--strict` で赤にできる
#
# 終了コード: 0 = 全部 PASS/SKIP、1 = FAIL か PENDING あり、2 = 前提が満たせない
# (依存コマンドが無い・別のモデルプロセスがいる・サーバーが応答しない)。

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

BASE_URL="http://127.0.0.1:8091"
MODEL=""
IMAGE="${TF_C3_IMAGE:-}"
TIMEOUT="${TF_C3_TIMEOUT:-240}"
ONLY=""
STRICT=0
LIST_ONLY=0

# DEV-13 用。既定の巻き戻し上界は 2048 トークン
# (SPEC §12 DEV-13: `min(maxContext, slidingWindow + prefillChunkTokens) - slidingWindow`
#  = min(n_ctx, 1024 + 2048) - 1024)。`--prefill-chunk-tokens` を既定から動かした
# サーバーに当てるときだけ TF_C3_REWIND_LIMIT で上げる。
REWIND_LIMIT="${TF_C3_REWIND_LIMIT:-2048}"
REWIND_MARGIN=256
FILLER_LINES="${TF_C3_FILLER_LINES:-260}"

# AGENTS.md "Test rules" / SERVER_RUNBOOK.md §0 と同じ並び。
PGREP_PATTERN='TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'

# 検査の並び。DEV-13 はキャッシュ状態を捨てさせるので必ず最後。
ALL_CHECKS="GEN-1 GEN-3-object GEN-3-schema GEN-4-required GEN-4-named GEN-4-reject GEN-12 GEN-8 GEN-14 RSN-4-max-tokens RSN-4-budget CACHE-1 CACHE-1-thinking MSG-6 DEV-13"

usage() {
    cat <<USAGE
$SCRIPT_NAME — C3 実機スモーク (CONFORMANCE §1)

  --base-url URL   サーバーの根 (既定 $BASE_URL)。末尾の /v1 は付けても付けなくてよい
  --model ID       要求に載せる model 名 (既定: /v1/models の 1 件目。R5 により検査されない)
  --image PATH     MSG-6 が使う写真 (既定: \$TF_SAMPLE_IMGS → ~/Pictures/sample_imgs → sample_imgs/)
  --only A,B       この検査だけ走らせる
  --timeout SEC    1 要求あたりの上限 (既定 $TIMEOUT)
  --strict         SKIP も赤として数える
  --list           検査の一覧を出して終わる
  -h, --help       これ

環境変数: TF_SAMPLE_IMGS TF_C3_IMAGE TF_C3_TIMEOUT TF_C3_REWIND_LIMIT TF_C3_FILLER_LINES
USAGE
}

list_checks() {
    cat <<'LIST'
GEN-1             tools 宣言 → 宣言済みツールの呼び出しが返り、引数が JSON として読める
GEN-3-object      response_format: json_object → 本文が JSON として読め、オブジェクトである (DEV-18)
GEN-3-schema      response_format: json_schema → 本文がそのスキーマの形を満たす
GEN-4-required    tool_choice: required → ツールが呼ばれ、散文で答えない
GEN-4-named       tool_choice 名前指定 → その 1 本だけが呼ばれる (DEV-17)
GEN-4-reject      文法で作れない拒否は要求側の 400 (未宣言の名前 / required なのに tools が空)
GEN-12            response_format (非 text) × tool_choice required は 400
GEN-8             tool call ターンを返しても LCP が切れない (正準形。INV-1 の実機側)
RSN-4-max-tokens  max_tokens 80 の思考 ON で本文が空にならない (CONFORMANCE §2 の実測欠陥)
RSN-4-budget      reasoning_budget_tokens を使い切っても本文が空にならない
CACHE-1           2 ターン目の cached_tokens > 0 (思考 OFF)
CACHE-1-thinking  同上 + reasoning_content を返した思考 ON のターン (MSG-5 / INV-1)
GEN-14            tools を宣言した要求でも投機デコードが走る (timings.draft_n > 0)
MSG-6             tools × 画像 × 思考を 1 要求で同時に (入口で 400 にしない)
DEV-13            リングより深い巻き戻し → 全 prefill に落ち、答えは正しいまま
LIST
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base-url) BASE_URL="${2:-}"; shift 2 ;;
        --base-url=*) BASE_URL="${1#*=}"; shift ;;
        --model) MODEL="${2:-}"; shift 2 ;;
        --model=*) MODEL="${1#*=}"; shift ;;
        --image) IMAGE="${2:-}"; shift 2 ;;
        --image=*) IMAGE="${1#*=}"; shift ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --only=*) ONLY="${1#*=}"; shift ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --timeout=*) TIMEOUT="${1#*=}"; shift ;;
        --strict) STRICT=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'error: 知らない引数: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$LIST_ONLY" -eq 1 ]; then list_checks; exit 0; fi

BASE_URL="${BASE_URL%/}"
BASE_URL="${BASE_URL%/v1}"
CHAT_URL="$BASE_URL/v1/chat/completions"

# ------------------------------------------------------------------ 出力

PASS_LIST=""
FAIL_LIST=""
PEND_LIST=""
SKIP_LIST=""
SKIP_REASONS=""

CUR_ID=""
CUR_STATE=""
CUR_T0=0

say()  { printf '%s\n' "$*"; }
note() { printf '     %s\n' "$*"; }
ok()   { printf '     ok    %s\n' "$*"; }

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

begin() {   # $1 = ID, $2 = 一行の説明
    CUR_ID="$1"
    CUR_STATE="pass"
    CUR_T0="$(date +%s)"
    printf '\n── %-16s %s\n' "$1" "$2"
}

fail() {    # 述語が破れた
    CUR_STATE="fail"
    printf '     FAIL  %s\n' "$*"
}

pending() { # 暫定の 501 (CONFORMANCE §1)
    CUR_STATE="pending"
    printf '     PEND  %s\n' "$*"
}

skip() {    # 走らせられない。理由は必ず出す
    CUR_STATE="skip"
    SKIP_REASONS="$SKIP_REASONS$CUR_ID: $*
"
    printf '     SKIP  %s\n' "$*"
    return 1
}

finish() {
    local dt=$(( $(date +%s) - CUR_T0 ))
    case "$CUR_STATE" in
        pass)    PASS_LIST="$PASS_LIST $CUR_ID"; printf '     [%s] PASSED (%ss)\n' "$CUR_ID" "$dt" ;;
        fail)    FAIL_LIST="$FAIL_LIST $CUR_ID"; printf '     [%s] FAILED (%ss)\n' "$CUR_ID" "$dt" ;;
        pending) PEND_LIST="$PEND_LIST $CUR_ID"; printf '     [%s] PENDING — 暫定 501。CONFORMANCE §1 により赤 (%ss)\n' "$CUR_ID" "$dt" ;;
        skip)    SKIP_LIST="$SKIP_LIST $CUR_ID"; printf '     [%s] SKIPPED (%ss)\n' "$CUR_ID" "$dt" ;;
    esac
}

# ------------------------------------------------------------------ 依存

for tool in curl jq base64; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool が要る (このスクリプトは curl + jq だけで書いてある)"
done

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c3-smoke.XXXXXX")" || die "作業ディレクトリを作れない"

# 要求と応答は残す (失敗を人が読むため)。1 本も要求を出さずに終わったときだけ畳む。
cleanup_run_dir() {
    if ! ls "$RUN_DIR"/*.res.json >/dev/null 2>&1; then
        rm -rf "$RUN_DIR"
    fi
}
trap cleanup_run_dir EXIT

# ------------------------------------------------------------------ 前提

# AGENTS.md "Test rules": モデルを使う実行は同時に 1 つ。ここではサーバーが
# 1 本だけ立っていることを確かめる。**何も終了させない** — 出たらユーザーに返す。
preflight_processes() {
    local all others servers
    all="$RUN_DIR/pgrep.txt"
    pgrep -fl "$PGREP_PATTERN" 2>/dev/null \
        | grep -v -e 'pgrep' -e "$SCRIPT_NAME" > "$all"
    others="$(grep -v 'TurboFieldfareServer' "$all")"
    servers="$(grep -c 'TurboFieldfareServer' "$all")"
    if [ -n "$others" ]; then
        printf 'error: モデルを使う別のプロセスがいる (AGENTS.md "Test rules")。\n' >&2
        printf '%s\n' "$others" >&2
        printf '止めるかどうかはユーザーが決める。このスクリプトは何も終了させない。\n' >&2
        exit 2
    fi
    if [ "$servers" -gt 1 ]; then
        printf 'error: TurboFieldfareServer が %s 本立っている。1 本にしてから走らせる。\n' "$servers" >&2
        cat "$all" >&2
        exit 2
    fi
    if [ "$servers" -eq 0 ]; then
        note "注意: TurboFieldfareServer のプロセスが見当たらない。$BASE_URL が答えるなら別物の可能性がある"
    fi
}

preflight_server() {
    local status body
    body="$RUN_DIR/health.json"
    status="$(curl --silent --show-error --max-time 10 --output "$body" \
        --write-out '%{http_code}' "$BASE_URL/health" 2>"$RUN_DIR/health.err")"
    if [ $? -ne 0 ] || [ "$status" = "000" ]; then
        cat >&2 <<EOF
error: $BASE_URL が答えない。$(head -1 "$RUN_DIR/health.err" 2>/dev/null)

このスクリプトはサーバーを起動しない。人が別のターミナルで建てる
(docs/SERVER_RUNBOOK.md §1(a)、先に AGENTS.md のプロセス検査):

  .build/release/TurboFieldfareServer \\
    --model scratch/gemma4-qat-sym.gturbo \\
    --port 8091 \\
    --ctx-size 16384 \\
    --expert-cache-slots 32 \\
    --verification trusted-install \\
    --draft-block-size 4

ロードに 20〜40 秒。curl -s $BASE_URL/v1/models が 200 になってから戻る。
EOF
        exit 2
    fi
    if [ "$status" = "503" ]; then
        printf 'error: まだロード中 (503 model_loading、LIF-2)。20〜40 秒待って %s/v1/models が 200 になってから走らせる。\n' "$BASE_URL" >&2
        exit 2
    fi
    if [ "$status" != "200" ]; then
        printf 'error: GET /health が %s を返した。本文: %s\n' "$status" "$(head -c 300 "$body")" >&2
        exit 2
    fi
    say "health   200 $(jq -c . "$body" 2>/dev/null)"
}

N_CTX=""
VISION=""
preflight_props() {
    local status body
    body="$RUN_DIR/props.json"
    status="$(curl --silent --max-time 10 --output "$body" --write-out '%{http_code}' \
        "$BASE_URL/props" 2>/dev/null)"
    if [ "$status" = "200" ]; then
        N_CTX="$(jq -r '.default_generation_settings.n_ctx // empty' "$body" 2>/dev/null)"
        VISION="$(jq -r '.modalities.vision // empty' "$body" 2>/dev/null)"
        say "props    200 n_ctx=${N_CTX:-?} vision=${VISION:-?} build=$(jq -r '.build_info // "?"' "$body")"
    else
        # EP-4 は P3。まだ無ければ n_ctx は分からないので、それに依存する検査が
        # 自分で測って判断する。
        say "props    $status — n_ctx と modalities は分からないまま進む (EP-4 は P3)"
    fi
}

preflight_model() {
    local body status
    body="$RUN_DIR/models.json"
    status="$(curl --silent --max-time 10 --output "$body" --write-out '%{http_code}' \
        "$BASE_URL/v1/models" 2>/dev/null)"
    [ "$status" = "200" ] || die "GET /v1/models が $status。サーバーの準備ができていない"
    if [ -z "$MODEL" ]; then
        MODEL="$(jq -r '.data[0].id // empty' "$body")"
    fi
    [ -n "$MODEL" ] || die "/v1/models から model id を読めない。--model で指定する"
    say "model    $MODEL"
}

# ------------------------------------------------------------------ HTTP

LAST_STATUS=""
LAST_BODY=""

post() {    # $1 = 要求本文のファイル, $2 = この呼び出しの名前
    local req="$1" name="$2" rc err
    LAST_BODY="$RUN_DIR/$name.res.json"
    err="$RUN_DIR/$name.curl.err"
    LAST_STATUS="$(curl --silent --show-error --max-time "$TIMEOUT" \
        --output "$LAST_BODY" --write-out '%{http_code}' \
        -H 'Content-Type: application/json' --data @"$req" "$CHAT_URL" 2>"$err")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 28 ]; then
            fail "curl が ${TIMEOUT}s で切れた ($name)"
            return 1
        fi
        printf '\nerror: サーバーが応答しなくなった (curl rc=%s): %s\n' \
            "$rc" "$(head -1 "$err")" >&2
        printf 'このスクリプトは建て直さない。stderr の error: 行を読む (SERVER_RUNBOOK §6)。\n' >&2
        printf '応答本文: %s\n' "$RUN_DIR" >&2
        exit 2
    fi
    note "POST /v1/chat/completions → $LAST_STATUS  ($name)"
    return 0
}

expect_status() {   # $1 = 期待する HTTP 番号
    if [ "$LAST_STATUS" = "$1" ]; then
        ok "HTTP $1"
        return 0
    fi
    fail "HTTP $1 のはずが $LAST_STATUS: $(jq -c '.error // .' "$LAST_BODY" 2>/dev/null | head -c 300)"
    return 1
}

# 暫定の 501 を PENDING に落とす (CONFORMANCE §1: 最終挙動を C3 に書き、暫定は
# 印を付けて赤のまま数える)。GEN-3 / GEN-4 のように段のある行だけで使う。
pending_if_not_supported() {
    if [ "$LAST_STATUS" = "501" ]; then
        pending "$(jq -r '.error.message // "not_supported_error"' "$LAST_BODY" 2>/dev/null)"
        return 0
    fi
    return 1
}

assert() {  # $1 = jq 述語, $2 = 説明
    local out
    if out="$(jq -e "$1" "$LAST_BODY" 2>&1)"; then
        ok "$2"
        return 0
    fi
    fail "$2 — jq: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
    return 1
}

capture() { jq -r "$1 // empty" "$LAST_BODY" 2>/dev/null; }

# 部分文字列の照合。金の文言と比べてよいのは DEV-13 の 1 か所だけなので、
# jq の述語とは別の名前にしてある。
assert_contains() {  # $1 = jq のパス, $2 = 期待する部分文字列, $3 = 説明
    local value
    value="$(capture "$1")"
    case "$value" in
        *"$2"*) ok "$3"; return 0 ;;
        *) fail "$3 — 実際: $(printf '%s' "$value" | head -c 160)"; return 1 ;;
    esac
}

# ------------------------------------------------------------------ 部品

# 2 本のツール。型は素直なものだけ (GEN-2 の近似落としを踏まないため)。
tools_json() {
    cat <<'JSON'
[
  {"type":"function","function":{
    "name":"get_weather",
    "description":"Current weather for a city.",
    "parameters":{"type":"object",
      "properties":{"location":{"type":"string","description":"City name."}},
      "required":["location"],"additionalProperties":false}}},
  {"type":"function","function":{
    "name":"get_time",
    "description":"Current wall-clock time in a timezone.",
    "parameters":{"type":"object",
      "properties":{"timezone":{"type":"string","description":"IANA timezone."}},
      "required":["timezone"],"additionalProperties":false}}}
]
JSON
}

image_data_uri() {   # $1 = ファイル。data URI を stdout へ (MSG-3: data URI のみ)
    local file="$1" mime
    case "$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')" in
        *.jpg|*.jpeg) mime="image/jpeg" ;;
        *.png)        mime="image/png" ;;
        *.webp)       mime="image/webp" ;;
        *.gif)        mime="image/gif" ;;
        *.bmp)        mime="image/bmp" ;;
        *) return 1 ;;
    esac
    printf 'data:%s;base64,%s' "$mime" "$(base64 < "$file" | tr -d '\n')"
}

# 画像の実体はリポジトリの外にある (docs/mtp/40-HANDOFF.md §3)。
# Scripts/demo/serve.py と同じ規約: TF_SAMPLE_IMGS → ~/Pictures/sample_imgs →
# リポジトリ内の sample_imgs/。1 枚だけ名指ししたいときは TF_C3_IMAGE / --image。
find_image() {
    local dir=""
    if [ -n "$IMAGE" ]; then
        [ -f "$IMAGE" ] || return 1
        printf '%s' "$IMAGE"
        return 0
    fi
    if [ -n "${TF_SAMPLE_IMGS:-}" ]; then
        dir="${TF_SAMPLE_IMGS/#\~/$HOME}"
    elif [ -d "$HOME/Pictures/sample_imgs" ]; then
        dir="$HOME/Pictures/sample_imgs"
    else
        dir="$REPO_ROOT/sample_imgs"
    fi
    [ -d "$dir" ] || return 1
    local pick
    pick="$(ls -1 "$dir" 2>/dev/null | grep -Ei '\.(jpg|jpeg|png|webp|gif|bmp)$' | sort | head -1)"
    [ -n "$pick" ] || return 1
    printf '%s/%s' "$dir" "$pick"
}

# ------------------------------------------------------------------ 検査

# GEN-1: tools を宣言したら、宣言したツールの呼び出しが返り、引数が JSON として
# 読める。tool_choice は書かない = auto なので、呼ぶかどうかはモデルが決める
# (GEN-5 の遅延文法)。ここだけが落ちて GEN-4-required が通るなら、破れているのは
# 文法ではなくモデルの判断であり、要求文の方を疑う。
check_gen1() {
    begin GEN-1 "tools 宣言 → 宣言済みツールの呼び出しが返る"
    jq -n --arg model "$MODEL" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user",
            content:"Call the get_weather tool for Kyoto. Do not answer in prose."}],
        tools: $tools,
        temperature: 0,
        max_tokens: 128
    }' > "$RUN_DIR/gen1.req.json"
    post "$RUN_DIR/gen1.req.json" gen1 || { finish; return; }
    pending_if_not_supported && { finish; return; }
    expect_status 200 || { finish; return; }
    assert '.choices[0].finish_reason == "tool_calls"' 'finish_reason == "tool_calls" (RSP-4)'
    assert '(.choices[0].message.tool_calls | length) >= 1' 'tool_calls が 1 本以上'
    assert '[.choices[0].message.tool_calls[].function.name]
            | all(. == "get_weather" or . == "get_time")' \
           '呼ばれた名前がすべて宣言済み'
    assert '[.choices[0].message.tool_calls[].function.arguments | fromjson | type]
            | all(. == "object")' \
           '引数が JSON オブジェクトとして読める'
    assert '[.choices[0].message.tool_calls[]
             | select(.function.name == "get_weather")
             | (.function.arguments | fromjson | has("location"))] | all' \
           'get_weather の必須プロパティ location がある'
    note "呼ばれた: $(capture '[.choices[0].message.tool_calls[].function | .name + .arguments] | join(" ")')"
    finish
}

# GEN-3 / DEV-18: schema の無い json_object は「任意の JSON オブジェクト」に拘束
# される。JSON を頼まれて Markdown を 200 で返すのは R4 違反。
check_gen3_object() {
    begin GEN-3-object "response_format: json_object → 本文が JSON のオブジェクト"
    jq -n --arg model "$MODEL" '{
        model: $model,
        messages: [{role:"user",
            content:"Give the capital of France as a JSON object with the keys city and country."}],
        response_format: {type:"json_object"},
        temperature: 0,
        max_tokens: 128
    }' > "$RUN_DIR/gen3o.req.json"
    post "$RUN_DIR/gen3o.req.json" gen3o || { finish; return; }
    pending_if_not_supported && { finish; return; }
    expect_status 200 || { finish; return; }
    assert '.choices[0].message.content | type == "string" and (length > 0)' '本文が空でない文字列'
    assert '.choices[0].message.content | fromjson | type == "object"' \
           '本文が JSON として読め、オブジェクトである (DEV-18)'
    note "本文: $(capture '.choices[0].message.content' | head -c 160)"
    finish
}

# GEN-3: json_schema はスキーマの形を満たす。値そのものは見ない (金の文言では
# なく述語)。additionalProperties:false なので鍵は 2 つちょうど。
check_gen3_schema() {
    begin GEN-3-schema "response_format: json_schema → 本文がスキーマの形を満たす"
    jq -n --arg model "$MODEL" '{
        model: $model,
        messages: [{role:"user", content:"Describe the city of Kyoto."}],
        response_format: {type:"json_schema", json_schema:{
            name:"city_fact", strict:true,
            schema:{type:"object",
                properties:{city:{type:"string"}, population:{type:"integer"}},
                required:["city","population"], additionalProperties:false}}},
        temperature: 0,
        max_tokens: 128
    }' > "$RUN_DIR/gen3s.req.json"
    post "$RUN_DIR/gen3s.req.json" gen3s || { finish; return; }
    pending_if_not_supported && { finish; return; }
    expect_status 200 || { finish; return; }
    assert '.choices[0].message.content | fromjson | type == "object"' '本文が JSON オブジェクト'
    assert '.choices[0].message.content | fromjson | keys == ["city","population"]' \
           '鍵が city と population ちょうど (additionalProperties:false)'
    assert '.choices[0].message.content | fromjson | (.city|type) == "string"' 'city が文字列'
    assert '.choices[0].message.content | fromjson
            | (.population|type) == "number" and (.population == (.population|floor))' \
           'population が整数'
    note "本文: $(capture '.choices[0].message.content' | head -c 160)"
    finish
}

# GEN-4: required は最初から拘束する。散文で答えて 200 は R4 違反。
check_gen4_required() {
    begin GEN-4-required "tool_choice: required → ツールが呼ばれ、散文で答えない"
    jq -n --arg model "$MODEL" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user", content:"Hello! Just say hi back."}],
        tools: $tools,
        tool_choice: "required",
        temperature: 0,
        max_tokens: 128
    }' > "$RUN_DIR/gen4r.req.json"
    post "$RUN_DIR/gen4r.req.json" gen4r || { finish; return; }
    pending_if_not_supported && { finish; return; }
    expect_status 200 || { finish; return; }
    assert '.choices[0].finish_reason == "tool_calls"' 'finish_reason == "tool_calls"'
    assert '(.choices[0].message.tool_calls | length) >= 1' 'ツールが呼ばれている'
    assert '[.choices[0].message.tool_calls[].function.name]
            | all(. == "get_weather" or . == "get_time")' '名前が宣言済み'
    assert '(.choices[0].message.content // "") | gsub("\\s";"") | length == 0' \
           '散文の本文が付いていない'
    finish
}

# GEN-4 / DEV-17: 名前指定はその関数だけを文法で固定する。天気を訊いておいて
# get_time を指名するので、「指定を無視して auto に落ちる」実装はここで落ちる。
check_gen4_named() {
    begin GEN-4-named "tool_choice 名前指定 → その 1 本だけが呼ばれる (DEV-17)"
    jq -n --arg model "$MODEL" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user", content:"What is the weather in Kyoto right now?"}],
        tools: $tools,
        tool_choice: {type:"function", function:{name:"get_time"}},
        temperature: 0,
        max_tokens: 128
    }' > "$RUN_DIR/gen4n.req.json"
    post "$RUN_DIR/gen4n.req.json" gen4n || { finish; return; }
    pending_if_not_supported && { finish; return; }
    expect_status 200 || { finish; return; }
    assert '(.choices[0].message.tool_calls | length) == 1' '呼び出しはちょうど 1 本'
    assert '.choices[0].message.tool_calls[0].function.name == "get_time"' \
           '指名した get_time が呼ばれている (get_weather ではない)'
    assert '.choices[0].message.tool_calls[0].function.arguments
            | fromjson | type == "object" and has("timezone")' \
           '引数が JSON オブジェクトで、必須の timezone がある'
    finish
}

# GEN-4: 文法では作れない 2 つの拒否は要求の側で 400 にする。生成に入らないので
# モデルは動かない — この 2 本だけは C0/C1 と同じ検査を実機で確かめるだけである。
check_gen4_reject() {
    begin GEN-4-reject "文法で作れない拒否は 400 (未宣言の名前 / required なのに tools が空)"
    jq -n --arg model "$MODEL" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user", content:"hi"}],
        tools: $tools,
        tool_choice: {type:"function", function:{name:"no_such_tool"}},
        temperature: 0, max_tokens: 16
    }' > "$RUN_DIR/gen4x1.req.json"
    post "$RUN_DIR/gen4x1.req.json" gen4x1 || { finish; return; }
    expect_status 400 && \
        assert '.error.type == "invalid_request_error"' '未宣言の名前は invalid_request_error'

    jq -n --arg model "$MODEL" '{
        model: $model,
        messages: [{role:"user", content:"hi"}],
        tools: [],
        tool_choice: "required",
        temperature: 0, max_tokens: 16
    }' > "$RUN_DIR/gen4x2.req.json"
    post "$RUN_DIR/gen4x2.req.json" gen4x2 || { finish; return; }
    expect_status 400 && \
        assert '.error.type == "invalid_request_error"' 'tools が空の required は invalid_request_error'
    finish
}

# GEN-12: 「必ずツールを呼べ」と「この JSON の形で答えろ」は同時に満たせない。
# 片方を黙って捨てて 200 を返すのが R4 違反。
check_gen12() {
    begin GEN-12 "response_format (非 text) × tool_choice required → 400"
    jq -n --arg model "$MODEL" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user", content:"Kyoto の天気を JSON で。"}],
        tools: $tools,
        tool_choice: "required",
        response_format: {type:"json_object"},
        temperature: 0, max_tokens: 64
    }' > "$RUN_DIR/gen12.req.json"
    post "$RUN_DIR/gen12.req.json" gen12 || { finish; return; }
    expect_status 400 || { finish; return; }
    assert '.error.type == "invalid_request_error"' 'invalid_request_error である'
    finish
}

# RSN-4: 思考の予算が尽きたら終了タグを強制挿入して本文へ移らせる。
# CONFORMANCE §2 が実測した欠陥そのもの (max_tokens: 80 で reasoning 357 字・
# content 空) を、同じ数字で再現する。**この行のために C3 がある。**
check_rsn4_max_tokens() {
    begin RSN-4-max-tokens "max_tokens 80 の思考 ON で本文が空にならない"
    jq -n --arg model "$MODEL" '{
        model: $model,
        messages: [{role:"user", content:"9.11 と 9.9 はどちらが大きい? 理由も添えて。"}],
        chat_template_kwargs: {enable_thinking: true},
        temperature: 0,
        max_tokens: 80
    }' > "$RUN_DIR/rsn4a.req.json"
    post "$RUN_DIR/rsn4a.req.json" rsn4a || { finish; return; }
    expect_status 200 || { finish; return; }
    assert '(.choices[0].message.content // "") | gsub("\\s";"") | length > 0' \
           '本文が空でない (RSN-4)'
    note "finish_reason=$(capture '.choices[0].finish_reason') reasoning=$(capture '.choices[0].message.reasoning_content | length')B content=$(capture '.choices[0].message.content | length')B"
    finish
}

# RSN-4: 予算そのものを明示した側 (REQ-reasoning-budget)。
check_rsn4_budget() {
    begin RSN-4-budget "reasoning_budget_tokens を使い切っても本文が空にならない"
    jq -n --arg model "$MODEL" '{
        model: $model,
        messages: [{role:"user",
            content:"9.11 と 9.9 はどちらが大きい? 理由も添えて。"}],
        chat_template_kwargs: {enable_thinking: true},
        reasoning_budget_tokens: 24,
        temperature: 0,
        max_tokens: 256
    }' > "$RUN_DIR/rsn4b.req.json"
    post "$RUN_DIR/rsn4b.req.json" rsn4b || { finish; return; }
    expect_status 200 || { finish; return; }
    assert '(.choices[0].message.content // "") | gsub("\\s";"") | length > 0' \
           '本文が空でない (RSN-4)'
    note "finish_reason=$(capture '.choices[0].finish_reason') reasoning=$(capture '.choices[0].message.reasoning_content | length')B content=$(capture '.choices[0].message.content | length')B"
    finish
}

# CACHE-1/2 + RSP-1: 2 ターン目は 1 ターン目の接頭辞を再利用する。
# 観測値は cached_tokens の 1 種類だけ (CACHE-6)。
check_cache1() {
    begin CACHE-1 "2 ターン目の cached_tokens > 0 (思考 OFF)"
    local first
    jq -n --arg model "$MODEL" '{
        model: $model,
        messages: [{role:"user", content:"Name three prime numbers, comma separated."}],
        chat_template_kwargs: {enable_thinking: false},
        temperature: 0, max_tokens: 64
    }' > "$RUN_DIR/cache1a.req.json"
    post "$RUN_DIR/cache1a.req.json" cache1a || { finish; return; }
    expect_status 200 || { finish; return; }
    first="$(capture '.choices[0].message.content')"
    [ -n "$first" ] || { skip "1 ターン目の本文が空で、2 ターン目に返せない"; finish; return; }

    # 完了したターンをそのまま返す = INV-1 の前提。書き換えれば LCP はそこで切れる。
    jq -n --arg model "$MODEL" --arg first "$first" '{
        model: $model,
        messages: [
            {role:"user", content:"Name three prime numbers, comma separated."},
            {role:"assistant", content:$first},
            {role:"user", content:"Now name three more."}],
        chat_template_kwargs: {enable_thinking: false},
        temperature: 0, max_tokens: 64
    }' > "$RUN_DIR/cache1b.req.json"
    post "$RUN_DIR/cache1b.req.json" cache1b || { finish; return; }
    expect_status 200 || { finish; return; }
    assert '.usage.prompt_tokens_details.cached_tokens | type == "number"' \
           'usage に cached_tokens がある (RSP-1)'
    assert '.usage.prompt_tokens_details.cached_tokens > 0' \
           'cached_tokens > 0 (CACHE-1/CACHE-2)'
    assert '.usage.prompt_tokens_details.cached_tokens <= .usage.prompt_tokens' \
           'cached_tokens <= prompt_tokens'
    note "cached=$(capture '.usage.prompt_tokens_details.cached_tokens') prompt=$(capture '.usage.prompt_tokens')"
    finish
}

# CACHE-1 + MSG-5 + INV-1: 思考を返したターンを reasoning_content ごと返せば、
# 接頭辞はそのターンを越えて生き残る。pi の常用セッションがこの形。
check_cache1_thinking() {
    begin CACHE-1-thinking "思考 ON のターンを reasoning_content ごと返して cached_tokens > 0"
    local first reasoning
    jq -n --arg model "$MODEL" '{
        model: $model,
        messages: [{role:"user", content:"12 × 13 はいくつ?"}],
        chat_template_kwargs: {enable_thinking: true},
        temperature: 0, max_tokens: 256
    }' > "$RUN_DIR/cache2a.req.json"
    post "$RUN_DIR/cache2a.req.json" cache2a || { finish; return; }
    expect_status 200 || { finish; return; }
    first="$(capture '.choices[0].message.content')"
    reasoning="$(capture '.choices[0].message.reasoning_content')"
    if [ -z "$reasoning" ]; then
        skip "思考が返らなかった (reasoning_content が無い)。サーバーが思考を閉じているか、要求の enable_thinking が効いていない"
        finish; return
    fi
    [ -n "$first" ] || { skip "1 ターン目の本文が空で、2 ターン目に返せない (RSN-4 の結果を先に見る)"; finish; return; }

    jq -n --arg model "$MODEL" --arg first "$first" --arg reasoning "$reasoning" '{
        model: $model,
        messages: [
            {role:"user", content:"12 × 13 はいくつ?"},
            {role:"assistant", content:$first, reasoning_content:$reasoning},
            {role:"user", content:"では 12 × 14 は?"}],
        chat_template_kwargs: {enable_thinking: true},
        temperature: 0, max_tokens: 256
    }' > "$RUN_DIR/cache2b.req.json"
    post "$RUN_DIR/cache2b.req.json" cache2b || { finish; return; }
    expect_status 200 || { finish; return; }
    assert '.usage.prompt_tokens_details.cached_tokens > 0' \
           'cached_tokens > 0 (CACHE-1 + MSG-5 の思考持ち回り)'
    note "cached=$(capture '.usage.prompt_tokens_details.cached_tokens') prompt=$(capture '.usage.prompt_tokens')"
    finish
}

# GEN-8 / DEV-15 — 生成した tool call が正準形かどうかを、外から見える唯一の
# ところで見る。GEN-8 の理由は INV-1 (描き直し == 生成) であり、生成が正準形で
# なければ**次のターンの LCP がその tool call の手前で切れる**。応答の
# `arguments` は組み立て直された JSON なので、生の方言は読めない — だから
# 「切れなかった」を数字で見る:
#   cached_tokens >= (1 ターン目の prompt_tokens + completion_tokens) − 余裕
# 余裕は CACHE-3 の末尾 1 トークン捨てとターン境界のぶん。cached がこれより
# 小さければ、描き直しは tool call ターンを越えられていない。
check_gen8() {
    begin GEN-8 "tool call ターンを返しても LCP が切れない (生成が正準形である証拠)"
    local p1 c1 threshold name args callid
    jq -n --arg model "$MODEL" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user", content:"What is the weather in Kyoto?"}],
        tools: $tools,
        tool_choice: "required",
        chat_template_kwargs: {enable_thinking: false},
        temperature: 0, max_tokens: 128
    }' > "$RUN_DIR/gen8a.req.json"
    post "$RUN_DIR/gen8a.req.json" gen8a || { finish; return; }
    pending_if_not_supported && { finish; return; }
    expect_status 200 || { finish; return; }
    name="$(capture '.choices[0].message.tool_calls[0].function.name')"
    args="$(capture '.choices[0].message.tool_calls[0].function.arguments')"
    callid="$(capture '.choices[0].message.tool_calls[0].id')"
    if [ -z "$name" ] || [ -z "$args" ]; then
        skip "1 ターン目で tool call が返らなかった。GEN-4-required の結果を先に見る"
        finish; return
    fi
    p1="$(capture '.usage.prompt_tokens')"
    c1="$(capture '.usage.completion_tokens')"
    if [ -z "$p1" ] || [ -z "$c1" ]; then
        skip "usage が読めない (prompt_tokens / completion_tokens)。RSP-1 を先に見る"
        finish; return
    fi
    threshold=$(( p1 + c1 - 8 ))
    note "1 ターン目: prompt=$p1 completion=$c1 呼び出し=$name$args"

    # MSG-5: assistant の tool_calls と tool role + tool_call_id を返す。
    jq -n --arg model "$MODEL" --argjson tools "$(tools_json)" \
          --arg name "$name" --arg args "$args" --arg id "$callid" '{
        model: $model,
        messages: [
            {role:"user", content:"What is the weather in Kyoto?"},
            {role:"assistant", content:null,
             tool_calls:[{id:$id, type:"function",
                          function:{name:$name, arguments:$args}}]},
            {role:"tool", tool_call_id:$id, content:"22C, clear."}],
        tools: $tools,
        chat_template_kwargs: {enable_thinking: false},
        temperature: 0, max_tokens: 128
    }' > "$RUN_DIR/gen8b.req.json"
    post "$RUN_DIR/gen8b.req.json" gen8b || { finish; return; }
    expect_status 200 || { finish; return; }
    note "2 ターン目: cached=$(capture '.usage.prompt_tokens_details.cached_tokens') prompt=$(capture '.usage.prompt_tokens') 下限=$threshold"
    assert '.usage.prompt_tokens_details.cached_tokens > 0' 'cached_tokens > 0'
    assert ".usage.prompt_tokens_details.cached_tokens >= $threshold" \
           "再利用が tool call ターンを越えている (>= $threshold = prompt+completion-8。GEN-8 / DEV-15 / INV-1)"
    finish
}

# GEN-14 / RSP-3: 文法拘束は投機デコードを止めない。**ワイヤから見えるのは
# `timings.draft_n` だけ**であり、CONFORMANCE §5 の完了の定義が「MTP が効いて
# いる」をこの数字で見ると決めている (2026-08-21 に数字で見たら、tools を
# 宣言した要求は 1 本も走っていなかった)。
#
# 3 本投げる: (a) tools 無しの下敷き — ここで `draft_n` が無ければサーバーが
# `--draft-block-size 0` で建っているので SKIP、(b) tools + `tool_choice: auto`
# (遅延文法。常用クライアントの形)、(c) `tool_choice: required` (非遅延。最初の
# トークンから拘束がかかる形)。
#
# **どれも思考 OFF で投げる。**思考 ON の要求で締切が立つと RSN-4 の終了タグ
# 強制が働きうるので、SPEC §12 **DEV-14** によって plain 経路に落ちる — それは
# GEN-14 の話ではない。ただし締切が立つのは **`max_tokens` が文脈の残りより
# 実際に短いとき**だけである (RSN-4、P7)。ここで `max_tokens: 128` を指定して
# いるのはまさにその形なので、思考 OFF にしておかないと GEN-14 ではなく
# DEV-14 を測ってしまう。
check_gen14() {
    begin GEN-14 "tools を宣言した要求でも投機が走る (timings.draft_n > 0)"
    local prompt='Name three prime numbers larger than one hundred and say why each is prime.'

    jq -n --arg model "$MODEL" --arg p "$prompt" '{
        model: $model,
        messages: [{role:"user", content:$p}],
        reasoning_effort: "none",
        temperature: 0,
        max_tokens: 128
    }' > "$RUN_DIR/gen14a.req.json"
    post "$RUN_DIR/gen14a.req.json" gen14a || { finish; return; }
    expect_status 200 || { finish; return; }
    if ! jq -e '.timings.draft_n? // empty | . > 0' "$LAST_BODY" >/dev/null 2>&1; then
        skip "tools 無しの要求にも timings.draft_n が無い。原因は 3 つのどれか — (1) **サーバーのバイナリが P6 より前** (ログに mtp= は出るのに draft_n が無いならこれ。swift build -c release --product TurboFieldfareServer で建て直す)、(2) --draft-block-size 0 で建っている、(3) ドラフターの入っていないバンドル。GEN-14 はここでは判定できない"
        finish
        return
    fi
    note "下敷き (tools 無し): draft_n=$(capture '.timings.draft_n') accepted=$(capture '.timings.draft_n_accepted')"

    jq -n --arg model "$MODEL" --arg p "$prompt" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user", content:$p}],
        tools: $tools,
        reasoning_effort: "none",
        temperature: 0,
        max_tokens: 128
    }' > "$RUN_DIR/gen14b.req.json"
    post "$RUN_DIR/gen14b.req.json" gen14b || { finish; return; }
    expect_status 200 || { finish; return; }
    assert '.timings.draft_n > 0' \
           'tools 宣言 (遅延文法) の要求でも投機が走った (GEN-14)'
    assert '.timings.draft_n_accepted >= 0' 'draft_n_accepted が載っている (RSP-3)'
    assert '.timings.draft_n_accepted <= .timings.draft_n' '採用数は提案数を超えない'
    note "tools 宣言: draft_n=$(capture '.timings.draft_n') accepted=$(capture '.timings.draft_n_accepted')"

    jq -n --arg model "$MODEL" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user",
            content:"Call the get_weather tool for Kyoto. Do not answer in prose."}],
        tools: $tools,
        tool_choice: "required",
        reasoning_effort: "none",
        temperature: 0,
        max_tokens: 128
    }' > "$RUN_DIR/gen14c.req.json"
    post "$RUN_DIR/gen14c.req.json" gen14c || { finish; return; }
    expect_status 200 || { finish; return; }
    assert '(.choices[0].message.tool_calls | length) >= 1' 'required でツールが呼ばれた'
    assert '.timings.draft_n > 0' \
           'tool_choice: required (非遅延。全位置が拘束される) でも投機が走った (GEN-14)'
    note "required: draft_n=$(capture '.timings.draft_n') accepted=$(capture '.timings.draft_n_accepted')"
    finish
}

# MSG-6: tools × 画像 × 思考は同時に成立する。組合せを入口で 400 にしない。
check_msg6() {
    begin MSG-6 "tools × 画像 × 思考を 1 要求で同時に"
    if [ "${VISION:-}" = "false" ]; then
        skip "/props の modalities.vision が false — このモデルに vision タワーが無い"
        finish; return
    fi
    local file uri
    if ! file="$(find_image)"; then
        skip "画像フィクスチャが無い。TF_SAMPLE_IMGS か --image で指す (既定は ~/Pictures/sample_imgs、リポジトリ外)"
        finish; return
    fi
    if ! uri="$(image_data_uri "$file")"; then
        skip "$file の拡張子から MIME を決められない"
        finish; return
    fi
    note "画像: $file ($(( ${#uri} / 1024 )) KiB の data URI)"
    jq -n --arg model "$MODEL" --arg uri "$uri" --argjson tools "$(tools_json)" '{
        model: $model,
        messages: [{role:"user", content:[
            {type:"text", text:"この写真に写っているものを 1 文で説明して。必要なら道具を使ってよい。"},
            {type:"image_url", image_url:{url:$uri}}]}],
        tools: $tools,
        chat_template_kwargs: {enable_thinking: true},
        temperature: 0,
        max_tokens: 256
    }' > "$RUN_DIR/msg6.req.json"
    post "$RUN_DIR/msg6.req.json" msg6 || { finish; return; }
    if [ "$LAST_STATUS" = "400" ]; then
        case "$(capture '.error.code')" in
            image_too_large|too_many_images|request_too_large)
                skip "フィクスチャが大きすぎる ($(capture '.error.code'))。TF_C3_IMAGE で小さい写真を指す"
                finish; return ;;
            vision_not_installed)
                skip "このモデルに vision タワーが入っていない (vision_not_installed)"
                finish; return ;;
        esac
    fi
    # MSG-6 の要点は、この組合せが入口で 400 にならないこと。
    expect_status 200 || { finish; return; }
    assert '(.choices[0].message.tool_calls | length? // 0) > 0
            or ((.choices[0].message.content // "") | gsub("\\s";"") | length > 0)' \
           'tool call か本文のどちらかが返っている'
    assert '.usage.prompt_tokens > 200' 'プロンプトに画像のソフトトークンが乗っている'
    note "finish=$(capture '.choices[0].finish_reason') prompt=$(capture '.usage.prompt_tokens') reasoning=$(capture '.choices[0].message.reasoning_content | length')B"
    finish
}

# DEV-13 — CONFORMANCE §2 が「式からの導出で、実測していない」と記録し、C3 に
# 送った 1 行。**誰もまだ走らせたことがないのがこの検査の存在理由である。**
#
# KV カーソルを戻せるのはリングの余裕まで (既定 2048 トークン)。それより深い
# 分岐は接頭辞を捨てて全 prefill に落ちる。確かめるのは 2 つ:
#   (1) cached_tokens == 0 — 半端に巻き戻さず、捨てている
#   (2) 答えが正しいまま — 潰れた KV を読み続けていない
# (2) だけは金の文言と比べる。**それが主張そのもの**だからで、temperature 0 に
# してあるので再実行は再実行である。
check_dev13() {
    begin DEV-13 "リングより深い巻き戻し → 全 prefill に落ち、答えは正しいまま"
    local needle="TF-4821" base branch answer prompt_tokens cached
    if [ -n "$N_CTX" ] && [ "$N_CTX" -lt $(( REWIND_LIMIT + 1024 )) ]; then
        skip "コンテキストが足りない: n_ctx=$N_CTX、この検査には $(( REWIND_LIMIT + 1024 )) 以上が要る。--ctx-size を上げたサーバーで走らせる"
        finish; return
    fi

    base="$RUN_DIR/dev13.base.txt"
    branch="$RUN_DIR/dev13.branch.txt"
    write_dev13_doc "$needle" plain "$base"
    write_dev13_doc "$needle" edited "$branch"

    # (A) 素の 1 ターン。長さを測り、針が読めることを確かめる。
    jq -n --arg model "$MODEL" --rawfile doc "$base" '{
        model: $model,
        messages: [{role:"user", content:$doc}],
        chat_template_kwargs: {enable_thinking: false},
        temperature: 0, max_tokens: 32
    }' > "$RUN_DIR/dev13a.req.json"
    post "$RUN_DIR/dev13a.req.json" dev13a || { finish; return; }
    if [ "$LAST_STATUS" = "400" ] && [ "$(capture '.error.type')" = "exceed_context_size_error" ]; then
        skip "プロンプトがコンテキストに入らない (ERR-4): $(capture '.error.message'). TF_C3_FILLER_LINES を下げるか --ctx-size を上げる"
        finish; return
    fi
    expect_status 200 || { finish; return; }
    prompt_tokens="$(capture '.usage.prompt_tokens')"
    answer="$(capture '.choices[0].message.content')"
    note "1 ターン目: prompt_tokens=$prompt_tokens 本文=$(printf '%s' "$answer" | head -c 60)"

    if [ -z "$prompt_tokens" ] || [ "$prompt_tokens" -lt $(( REWIND_LIMIT + REWIND_MARGIN )) ]; then
        skip "詰め物が短い: prompt_tokens=${prompt_tokens:-?}、分岐の深さを $REWIND_LIMIT より深くするには $(( REWIND_LIMIT + REWIND_MARGIN )) 以上が要る。TF_C3_FILLER_LINES を上げる"
        finish; return
    fi
    case "$answer" in
        *"$needle"*) ok "1 ターン目が針 $needle を読めている (比較の土台)" ;;
        *) skip "1 ターン目が針を読めていない (本文: $(printf '%s' "$answer" | head -c 80))。全 prefill の答えと比べるものが無い"
           finish; return ;;
    esac

    # (B) 同じ本文で 2 ターン目。ここで保持される接頭辞の末尾が、巻き戻しの起点。
    jq -n --arg model "$MODEL" --rawfile doc "$base" --arg first "$answer" '{
        model: $model,
        messages: [
            {role:"user", content:$doc},
            {role:"assistant", content:$first},
            {role:"user", content:"Repeat the part number."}],
        chat_template_kwargs: {enable_thinking: false},
        temperature: 0, max_tokens: 32
    }' > "$RUN_DIR/dev13b.req.json"
    post "$RUN_DIR/dev13b.req.json" dev13b || { finish; return; }
    expect_status 200 || { finish; return; }
    cached="$(capture '.usage.prompt_tokens_details.cached_tokens')"
    note "2 ターン目: cached=$cached prompt=$(capture '.usage.prompt_tokens')"
    if [ -z "$cached" ] || [ "$cached" -le 0 ]; then
        skip "巻き戻す接頭辞が保持されていない (cached=$cached)。まず CACHE-1 の結果を見る"
        finish; return
    fi

    # (C) 詰め物の 2 行目 (先頭から数十トークンの位置) だけを書き換えて分岐する。
    # 分岐の深さ ≒ prompt_tokens − 数十 で、上の門番により REWIND_LIMIT より深い。
    jq -n --arg model "$MODEL" --rawfile doc "$branch" --arg first "$answer" '{
        model: $model,
        messages: [
            {role:"user", content:$doc},
            {role:"assistant", content:$first},
            {role:"user", content:"Repeat the part number."}],
        chat_template_kwargs: {enable_thinking: false},
        temperature: 0, max_tokens: 32
    }' > "$RUN_DIR/dev13c.req.json"
    post "$RUN_DIR/dev13c.req.json" dev13c || { finish; return; }
    expect_status 200 || { finish; return; }
    note "分岐後: cached=$(capture '.usage.prompt_tokens_details.cached_tokens') prompt=$(capture '.usage.prompt_tokens') 本文=$(capture '.choices[0].message.content' | head -c 60)"
    assert '.usage.prompt_tokens_details.cached_tokens == 0' \
           "$REWIND_LIMIT より深い分岐は接頭辞を捨てて全 prefill (DEV-13)"
    # 金の文言で比べる唯一の場所。DEV-13 の主張は「それでも正しく答える」であり、
    # 針が返ることがその主張である。temperature 0 なので再実行は再実行。
    assert_contains '.choices[0].message.content' "$needle" \
                    "全 prefill でも針 $needle を読めている (DEV-13 の主張そのもの)"
    finish
}

# DEV-13 の本文。針を先頭に置き、そのうしろに詰め物を並べ、最後に質問する。
# `edited` は 2 行目だけを書き換える = 分岐点を先頭近くに置く。
write_dev13_doc() {  # $1 = 針, $2 = plain|edited, $3 = 出力先
    local needle="$1" variant="$2" out="$3" i
    {
        printf 'Part number: %s.\n' "$needle"
        i=1
        while [ "$i" -le "$FILLER_LINES" ]; do
            if [ "$variant" = "edited" ] && [ "$i" -eq 2 ]; then
                printf 'line %03d: the quick brown fox jumps over the lazy dog again.\n' "$i"
            else
                printf 'line %03d: the quick brown fox jumps over the lazy dog.\n' "$i"
            fi
            i=$(( i + 1 ))
        done
        printf 'Question: what is the part number stated at the top? Answer with only the part number.\n'
    } > "$out"
}

run_check() {
    case "$1" in
        GEN-1)            check_gen1 ;;
        GEN-3-object)     check_gen3_object ;;
        GEN-3-schema)     check_gen3_schema ;;
        GEN-4-required)   check_gen4_required ;;
        GEN-4-named)      check_gen4_named ;;
        GEN-4-reject)     check_gen4_reject ;;
        GEN-12)           check_gen12 ;;
        RSN-4-max-tokens) check_rsn4_max_tokens ;;
        RSN-4-budget)     check_rsn4_budget ;;
        CACHE-1)          check_cache1 ;;
        CACHE-1-thinking) check_cache1_thinking ;;
        GEN-8)            check_gen8 ;;
        GEN-14)           check_gen14 ;;
        MSG-6)            check_msg6 ;;
        DEV-13)           check_dev13 ;;
        *) die "知らない検査: $1 (--list で一覧)" ;;
    esac
}

# ------------------------------------------------------------------ 実行

# 名前の検査はサーバーに触る前に済ませる (打ち間違いで要求を出さない)。
SELECTED="$ALL_CHECKS"
if [ -n "$ONLY" ]; then
    SELECTED="$(printf '%s' "$ONLY" | tr ',' ' ')"
    for name in $SELECTED; do
        case " $ALL_CHECKS " in
            *" $name "*) ;;
            *) die "知らない検査: $name (--list で一覧)" ;;
        esac
    done
fi

say "C3 実機スモーク (CONFORMANCE §1) — $(date '+%Y-%m-%d %H:%M:%S')"
say "base-url $BASE_URL"
say "検査     $SELECTED"
preflight_processes
preflight_server
preflight_model
preflight_props
say "本文の控え: $RUN_DIR"

for name in $SELECTED; do
    run_check "$name"
done

# ------------------------------------------------------------------ まとめ

count() { set -- $1; printf '%s' "$#"; }

say ""
say "==== まとめ"
printf '  PASS %s  FAIL %s  PENDING %s  SKIP %s\n' \
    "$(count "$PASS_LIST")" "$(count "$FAIL_LIST")" "$(count "$PEND_LIST")" "$(count "$SKIP_LIST")"
[ -n "$FAIL_LIST" ] && printf '  FAILED:  %s\n' "$FAIL_LIST"
[ -n "$PEND_LIST" ] && printf '  PENDING: %s (暫定 501。CONFORMANCE §1 により赤)\n' "$PEND_LIST"
if [ -n "$SKIP_LIST" ]; then
    printf '  SKIPPED: %s\n' "$SKIP_LIST"
    printf '%s' "$SKIP_REASONS" | sed 's/^/    /'
fi
say "  応答本文: $RUN_DIR"

status=0
[ -n "$FAIL_LIST" ] && status=1
[ -n "$PEND_LIST" ] && status=1
if [ "$STRICT" -eq 1 ] && [ -n "$SKIP_LIST" ]; then status=1; fi
exit "$status"
